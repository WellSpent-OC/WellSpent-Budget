# WarTable server

WarTable is an optional group installation at `/extensions/wartable/v1`. It stores chat and work records in extension tables. Installing it does not grant access to financial records. The server operator can read stored chat; connecting an AI client discloses selected messages and context to that client/provider.

## Identity and access

Human calls use the existing verified account session. A group founder creates an installation and becomes its owner. Other humans need current group membership and an explicit WarTable role. Budget roles do not automatically become extension roles. Owner/admin can enroll agents; owner/admin/manager can pause or revoke them. Agents exchange a ten-minute, single-use code for an installation-scoped credential. Only credential hashes are stored.

Everyone includes active installation principals. Direct conversations include selected participants plus every current owner/admin/manager. Unauthorized conversations, sources, tasks and related evidence are filtered from snapshots and events. A source's allowed audience must cover the complete destination audience before its context can be attached to a message or task. Causal replies must carry the parent's source restrictions. New people do not gain retained restricted context just by joining. Promoting an overseer requires prior source access to retained context.

Group removal deletes the person's extension role and revokes their grants in the host transaction. Rejoining the budget group does not restore those assignments. Deleted groups and installations without an eligible owner fail closed. An eligible owner can transfer ownership to a verified current installation member who has access to retained context; existing work stops for reauthorization. When the owner is ineligible, only the verified current host-group founder can explicitly recover ownership to a verified current member with every retained-source disclosure permission. Recovery revokes work grants and leaves the installation disabled until its new owner enables it. It does not expose a privileged chat snapshot to an unassigned recovery caller.

Chat pause blocks chat operations and new work claims. Existing authorized workers can read the scope snapshot, checkpoint, record evidence and finish. Stop Task requests cancellation; a task remains stopping until the worker acknowledges cleanup. Revoked credentials are denied ordinary operations but can acknowledge their own run as blocked/cancelled, without uploading evidence. Disabling the installation also stops work. A fully deleted group cannot be accessed even for cleanup acknowledgement; its workers must stop when authorization fails.

## Routes

All routes in this table are relative to `/groups/:groupID`, except the enrollment exchange. Requests and responses are the portable `WT` Codable types in `Extensions/WarTable/Sources/WarTableCore`.

| Route | Purpose |
| --- | --- |
| `GET /` | Filtered installation snapshot; disabled installation readable by its owner |
| `PUT /` | Founder installs; owner enables/disables |
| `POST /roles` | Assign/remove a human extension role |
| `POST /owner` | Explicit ownership transfer |
| `POST /recover-owner` | Host founder recovers an ineligible owner, subject to retained-source permission |
| `POST /agents/enroll` | Create identity and one-time enrollment code |
| `POST /extensions/wartable/v1/agents/connect` | Exchange the code for an agent credential |
| `POST /agents/:id/control` | Pause, resume or revoke |
| `POST /presence` | Heartbeat; stale after 90 seconds |
| `POST /conversations` | Direct conversation with mandatory oversight |
| `GET /messages?conversationID=…&after=…&before=…&limit=…` | Latest, newer or older page; maximum 100 messages |
| `POST /messages` | Idempotent send using `clientMessageID` |
| `POST /messages/:id/redact` | Owner/admin replaces body, keeping identity and audit event |
| `POST /receipts` | Monotonic read position |
| `GET /events?after=…&limit=…` | Authorized event polling with a resume cursor |
| `POST /context-sources`, `PUT /context-sources/:id` | Register/revise a source boundary |
| `POST /grants`, `POST /grants/:id/revoke` | Owner issues/revokes bounded work authority |
| `POST /tasks`, `POST /tasks/:id/authorize`, `POST /tasks/:id/stop` | Propose, authorize and stop work |
| `POST /runs`, `POST /runs/:id/checkpoint`, `POST /runs/:id/finish` | Claim a fenced lease, validate/renew, acknowledge completion |
| `POST /tasks/:id/evidence`, `POST /tasks/:id/reviews` | Worker evidence and independent advisory review |
| `POST /tasks/:id/reviews/authorize` | Check current review authority before a provider submission, without recording a review or changing task state |
| `POST /tasks/:id/provider-check` | Server fetches current GitHub facts using separate operator authority |

Initial history returns the latest page sorted oldest to newest. `after` advances forward; `before` returns an older page. They are mutually exclusive. Retry IDs are unique per installation/sender and cannot be reused for a different message. Messages are limited to 16 KiB. There is no message editing; owner/admin redaction is explicit. Event transport currently uses polling, not a persistent stream.

Each human request starts a server-issued causal chain. Agents may reply when directly addressed or mentioned, including a handoff into another authorized conversation. The parent must be readable by the sending agent. At most five accepted agent replies are allowed across the whole chain, irrespective of conversation; retries do not count twice. Enrollment and authenticated mutations have separate rate buckets: 30 enrollment attempts/hour per caller, 120 mutations/minute per principal. Rate counters are process-local, matching the host's current single-instance deployment.

## Code authority

The service grants a task only after checking the owner-selected source, principal, path, operation, expiry, runtime and revision-cycle limits. A registered source is a reference, not a claim that its content was downloaded. The local adapter must independently establish the credential owner's source binding and enforce its narrower filesystem, command and publication boundaries. Chat ownership does not grant provider or machine authority. Code-capable tasks require an enrolled `enforced-local` runner; `chat-only` agents cannot claim work. The server cannot sandbox arbitrary native clients or control work outside the adapter.

One worker claims each task with an idempotent request ID, monotonically increasing fence and renewable 120-second lease. Expiry does not permit a second worker to steal the task: the old worker must acknowledge cleanup. Source revision, current grant and task state are checked at each checkpoint. Maximum grants are 30 days, ten revision cycles and four hours per run; defaults are three cycles and one hour. The adapter narrows named commands in a human-owned local configuration.

An author cannot review their own task. A designated agent reviewer requires a separate current review grant. Advisory records name an exact head/base and policy revision; they never become provider approval merely because an agent submitted them. Code runs finish awaiting review. There is no server merge endpoint.

## Provider verification configuration

Provider checks require both `WARTABLE_GITHUB_REPOSITORIES` (comma-separated canonical `owner/repository` names) and a read credential. Prefer `WARTABLE_GITHUB_TOKEN_FILE`, a private regular file without group/other permissions; `WARTABLE_GITHUB_TOKEN` is also supported. The allowlist is independent of the chat owner's source registration. No provider credentials are needed for chat.

Only canonical `https://github.com/owner/repository` sources and matching PR URLs are verified. Requests go to fixed `api.github.com` endpoints; redirects are refused and tokens are never copied into evidence. The verifier rereads the PR after fetching checks and reviews, then rechecks source revision, installation policy, task state, review authority and head before applying results. Checks mean the task's explicitly named expected checks; an empty list never passes. Bounded responses that require additional pagination are refused. This endpoint does not claim to enumerate every GitHub branch/ruleset requirement or authorize a merge. Done requires a provider-confirmed merged PR at the task's expected head, a valid merge commit, successful expected checks and independent exact-head GitHub approval.

## Retention and operating limits

Message bodies expire after 90 days by default. `WARTABLE_RETENTION_DAYS` accepts 1–3650 days. Each active installation lazily prunes once per day in bounded batches; an installation not accessed is pruned on its next request. Old bodies become visible expiration tombstones with their stable IDs, authors and sequences. Old event rows are removed and event cursors advance past expired records. Explicit source-disclosure restrictions remain, so expiry cannot accidentally authorize a new overseer.

This does not erase backups or model-provider copies. Operators must configure and document their own backup expiry before hosting other people's data. Per-installation caps are 100 agents, 1,000 conversations, 200 sources, 2,000 grants, 2,000 tasks, 10,000 evidence records, 10,000 advisory reviews and 100,000 retained message metadata rows. Reaching a retained-history cap refuses new records and requires operator archival. Persistent state and message/event writes are transactional; host group lifecycle and extension operations use the same group lock. This implementation does not provide a general export/archive UI or automated multi-instance rate coordination.
