# Email invitations

Addressed invitations add a pending state before group membership. The server must be updated before clients can send them. This change does not deploy a server, configure an email provider or create an account automatically.

## API

- `POST /api/v2/groups/:groupID/invites` accepts the existing level, history and expiry fields plus `email`, `inviteeName` and `inviterName`. Addressed invitations return `id` and `expiresAt`; the token goes only in the email. Omitting email preserves the earlier link API.
- `GET /api/v2/invitations` lists unexpired, usable invitations for the signed-in account's confirmed email. It grants no budget access.
- `POST /api/v2/invitations/:id/accept` returns the existing group response after creating membership and the invited member's profile in one transaction.
- `POST /api/v2/invitations/:id/reject` closes the invitation without membership.
- The existing group's invitations endpoint includes recipient names, addresses and Pending or Rejected status for managers. The existing delete endpoint cancels a pending invitation.

Acceptance, rejection, cancellation and member changes serialize on the group's database row. The server rechecks the current inviter's authority, recipient address, expiry and terminal state inside the transaction. The existing role and history rules still apply. Old link acceptance uses that same transaction; a forwarded addressed link cannot admit a different account.

New recipients can create and confirm an account with the invited address using the existing app account flow. Their invitation then appears in the inbox. Passwordless account creation is separate work.

## Migration and delivery

`AddEmailInvitations` adds nullable invitation columns and the email suppression and quota-lock tables. Existing links remain valid. Apply the normal database migration once before starting multiple server instances; the existing `SKIP_AUTO_MIGRATE` deployment agreement still applies. Back up the database using the deployment's normal procedure first.

Invitation rows form a durable delivery queue. A worker claims each row before sending, rechecks eligibility and suppression, and retries transient failures with increasing delays. It stops after six attempts. A restart retains the queue and its leases. Delivery is not guaranteed: suppression or exhausted retries can prevent sending. A provider timeout after accepting the email may cause a duplicate on retry, but not duplicate membership.

The existing email-code key derives invitation and stop-email tokens with separate purposes. Only hashes are stored. Keep that key stable across server instances and restarts. Rotating it prevents delivery of still-queued invitations whose derived token no longer matches; already delivered invitation links remain checked by their stored hash. Address suppression hashes also depend on this key, so a rotation requires a deliberate suppression migration plan.

The default daily limits are twenty invitations per sender, five for a sender whose email was confirmed less than three days ago, and five to one address. A non-live server with an explicitly enabled test mailbox gives sixty times those limits only when both addresses are reserved example.com test addresses. Pending duplicates in a group are refused. A rejection or cancellation permits a new invitation within those limits. Stopping invitation emails leaves in-app invitations available.

## Links

`GET /invite/:token` serves a read-only landing page on the existing sync or staging server. It opens the corresponding app. GET does not accept, reject, confirm an address or create an account. The page uses no third-party resources and sends no-store and no-referrer headers. The application logger omits invitation URLs; any reverse proxy must also redact or disable access logs for these paths and `/email/invites/stop`.

`INVITATION_PUBLIC_BASE_URL` may select a supported HTTPS WellSpent origin after its routing serves these endpoints. The default works without changing the public website. Do not point email links at the website before installing that routing.

The existing mailer supplies delivery. Test mail is captured locally, with no real recipients. Provider bounce/complaint webhooks and a delivery-failure interface are separate work; Pending currently means that the recipient has not answered, not a provider delivery receipt.

## Verification

Server tests cover recipient binding, View profiles and budget access, terminal races, removal and reinvitation, unknown recipients who register later, quotas, retry/suppression behavior, migration, landing-page escaping and URL log redaction. Run the server tests on SQLite and Postgres. Client tests cover the inbox, session changes, network failure recovery and retained links. Linux UI tests exercise two isolated app instances against a disposable server; Apple UI tests require their platform runners.
