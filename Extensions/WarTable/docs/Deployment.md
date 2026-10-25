# WarTable host setup

WarTable ships as a compiled extension in the Linux app and the existing WellSpent server. Build both from the same revision. The server creates separate `wartable_*` tables through its normal migration runner. Budget rows are not used as chat records.

For a first installation, use a disposable development server or your normal staging process with synthetic accounts. Production rollout uses the host's normal backup, migration, health-check and rollback process. Do not copy a production database into a test environment. A UI build by itself does not add WarTable to an older server.

## Provider verification

GitHub publication belongs to the local connector and requires an explicit operator binding. The server independently verifies provider state before marking work complete. Configure only the repositories approved for this installation:

```text
WARTABLE_GITHUB_REPOSITORIES=example/project,example/another-project
WARTABLE_GITHUB_TOKEN_FILE=/run/secrets/wartable-github-read
```

The token file is a private regular file, mode `0600`, readable only by the server account. Grant only read access to the listed repositories, pull requests, checks and commit statuses. The fallback `WARTABLE_GITHUB_TOKEN` environment variable is supported where the deployment's secret manager supplies it. Never commit token files or put token values in chat, shell arguments or logs.

The repository allowlist is mandatory even if a token could read other repositories. The connector's publication credential is separate from this server credential. Provider endpoints use `api.github.com`; arbitrary source URLs do not become authenticated fetch destinations.

**Check GitHub state** fetches authoritative facts for the task's exact PR and commit. A claimed approval or merge in a chat message is not accepted as provider confirmation. Provider unavailability leaves the task awaiting review. There is no automatic merge, deployment or release endpoint.

## Linux workers

Install Python 3.11 or newer and bubblewrap on each worker that will run checks. Chat and approved source reads need Python only. An execution request probes the sandbox and fails closed if namespaces are unavailable. Configure permitted checks as argument arrays in the operator's private source binding; arbitrary chat text is never evaluated as a shell command.

Worker directories and connector configuration stay outside source repositories. A worker copies explicitly selected files into an isolated snapshot. It does not alter the developer's current checkout or expose its Git credentials to test commands. Test commands have no network access and cannot read the user's home directory. Native tools belonging to the surrounding AI client are outside this boundary.

Each client has a distinct enrollment and token. See [Connectors](Connectors.md) for commands and the public/private source publication rules. A second client is not allowed to take over a live or unacknowledged task lease.

## Operations

Record the installation owner and the current extension admins and managers. Their oversight includes retained direct-conversation history. Budget roles and WarTable roles are separate. Source access must be approved before a role change would disclose restricted history.

Back up the extension tables with the server database under the installation's chosen backup retention and access policy. Message redaction does not erase an older backup. Server-readable chat must be described as such; the host's budget encryption wording is not a chat privacy guarantee.

`WARTABLE_RETENTION_DAYS` sets message-body retention, default 90 days and accepted range 1 through 3650. Cleanup runs lazily at most daily when an installation is used. Expired messages retain sequence/author metadata as tombstones; they do not retain the original body. Old events expire separately. Backups retain whatever their own policy permits. Installation metadata, roles and work evidence require their own retention review. An installation stops accepting new messages at its metadata cap rather than growing without bound.

The owner can transfer ownership to another verified current board member. The server checks that retained source content may be disclosed to that person. Existing work stops for reauthorization. Removing an owner from the host group or deleting the host group blocks further ordinary extension operations.

If the owner is no longer eligible, the verified host-group founder can recover ownership for an eligible, source-approved member. Recovery revokes grants, stops work, records an audit event and leaves WarTable disabled for an access review. It does not reveal the old chat to an otherwise unauthorized founder or permit taking over an installation with an eligible owner.

Linux drafts are stored under the active account and server namespace with private directory/file permissions. Drafts include the pending send identifier so a lost response can be retried after restart without posting twice. They are cleared on sign-out and when server authorization is revoked. A storage error prevents sending an unrecorded retry identifier. Drafts are local plaintext protected by filesystem permissions; they are not a server chat archive.

Run the existing server health check and the extension tests after migration. For a functional check, enable WarTable in a synthetic group, enroll a synthetic agent, exchange a causal reply, then revoke the credential and confirm the next request is denied. Test account switching, disabling the extension and a lost-response retry before inviting users.
