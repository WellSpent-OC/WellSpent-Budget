# Architecture decisions

Written 2026-09-26, updated 2026-09-27. Each entry says what was chosen and why, so
a later session does not re-open a settled question or silently reverse one.

> **This file describes intent, not progress.** Some of what follows is built and
> tested; some is a decision waiting to be implemented. Do not read a paragraph
> here as evidence that the code exists. **`STATUS.md` is the record of what is
> actually built**, and it is the one to trust when the two disagree.

## The four decisions that shape everything

**Swift core, SwiftUI on Apple.** Mac ships first, iOS second and shares most of the
view code. The core package (models, store, sync, crypto) compiles on Linux, so the
Linux box gets a terminal client rather than a second GUI framework. Android comes
much later as its own app. No web client, deliberately.

**Local-first, end to end encrypted.** Every device holds a full plaintext SQLite
database. The server holds ciphertext and cannot read amounts, merchants, budget
names or receipts. This is a selling point, not just a precaution.

**Sharing is in v1.** Not deferred. Sharing with a spouse and with a business partner
is the reason for rebuilding, so the schema and the crypto are designed around it
from the first commit.

**Statements arrive as files.** CSV, OFX, QFX, and PDF with OCR. No bank aggregator,
so no third party holds account access and there is no per-user cost. The importer
is built so an aggregator could feed the same pipeline later if customers want it.

## Crypto

**`import Crypto`, never `import CryptoKit`.** swift-crypto re-exports CryptoKit on
Apple platforms and supplies its own implementation on Linux. One call site, both
platforms, no `#if`.

**macOS 14 / iOS 17 floor, set by HPKE.** Verified against the local SDK: CryptoKit
marks `public enum HPKE` as available from macOS 14.0. Three releases back, so it
costs nothing.

**HPKE in auth mode wraps group keys.** Auth mode mixes the sender's private key
into the derivation, so the recipient learns who wrapped the key without a second
signature to check.

**One trap worth knowing.** `HPKE.Sender` has two initialisers that differ only by
generic constraint. The `HPKEKEMPublicKey` one is macOS 26 and later.
`Curve25519.KeyAgreement.PublicKey` conforms to `HPKEDiffieHellmanPublicKey`, which
is the macOS 14 overload, so normal code lands on the right one. Typing an argument
as `HPKEKEMPublicKey` would silently raise the floor by twelve OS versions.

**Group keys wrap to the person, not to the device.** One wrap per member per epoch
instead of one per device. The cost is honest: a lost device means rotating the
identity key, not just deleting a row.

**Budget keys are random and wrapped, not derived from the group key.** If they were
derived, sharing one budget would mean handing over the group. Independent keys,
wrapped two ways, cover both the group case and the single-budget case.

**Per-record content keys are derived, not stored.** `HKDF(budgetKey, salt: recordID)`.
No storage cost, and a nonce mistake stays contained to one record. A fresh random
nonce is still used on every seal, so two devices can edit offline without
coordinating.

**AES-GCM for content, ChaCha20-Poly1305 inside HPKE.** Both platforms have AES in
hardware. ChaCha appears only because it is what the standard Curve25519 HPKE suite
specifies. A `CiphersuiteID` byte rides in every envelope, so neither is permanent.
`XWingMLKEM768X25519` is already in swift-crypto 5 for when X25519 is not enough.

**HKDF for the recovery code, not scrypt.** A slow memory-hard function exists to
make guessing a human-chosen password expensive. The recovery code is 128 bits from
the system generator, so there is nothing to guess and scrypt would only slow down
legitimate recovery. Scrypt still has a job: the Linux keystore passphrase, where
the input really is a human guess.

## Invites, and the one genuinely novel part

The usual problem: the server hands you a public key and claims it is your partner's,
and if the server is lying it reads everything. Verification screens do not fix this,
because nobody taps them.

The fix uses a fact about how people actually share. The invite link goes over
iMessage, and the server does not control iMessage. The link carries a random secret
the server never sees, and that secret becomes an HPKE pre-shared key. If the sealed
acceptance opens, the sender held the secret, so it is the person you texted. The
server cannot forge it and cannot substitute a key.

`serverWithoutTheSecretCannotAnswerTheInvite` in the test suite is that property,
written down.

`HistoryAccess` falls out of this for one enum's worth of work. `.all` wraps the
current keys, so a spouse sees everything. `.fromNow` bumps the epoch first, so a
business partner cannot read anything from before they joined.

**Known gap: a re-seal can win over an edit made before it was pulled.** After a
`.fromNow` invite, the inviter's app sends the group and its budgets again under the
new key. Each goes out as a newer version of the record, carrying what the
inviter's Mac holds. Another member who edits one of them before pulling it can
make the edit at a lower Lamport value. Then the re-seal wins on every Mac, and the
edit is kept only as a conflict copy on theirs. Neither the server nor a receiving app can
tell a re-seal from an edit. Fixing it needs a signed field in the envelope that
says so, which is a format change every app and the server must understand.

## What encryption does not do

Encryption enforces exactly one rung of the ladder: **read**. Holding the key is
reading. Anyone who can decrypt can also produce valid ciphertext, so write, manage,
admin and superadmin are not cryptographic properties.

They get two non-cryptographic layers. The server refuses the write, judging the
author against the membership log as it stands when the push arrives. Honest
clients reject any signed envelope whose author is below `write`, judging against
the log as it stands when they pull it, not at the point the envelope was written.
`AccessLevel.isCryptographicallyEnforced` exists to keep this from being forgotten.

Deleting a whole group takes more than write. Only its founder or an admin may, and
the server and honest clients refuse a group delete from anyone else
(`MembershipState.mayDeleteGroup`). For anyone else, Delete removes the group from
their own Mac and queues no deletes. What they saved before it still goes out once,
such as a group re-sealed for someone they had just added. A new invite link brings
the group back. A group's delete is also final: it beats any live version of the
group record whatever its Lamport value, and no live version can replace it
(`RecordEnvelope.replaces`).

Budgets take Manage. Write (the Add role) is for adding transactions and changing
or deleting your own. Making, changing or deleting a budget, and publishing a new
budget's key, needs Manage. The screens offer it only to a manager, the app does
not send it from anyone else, and the server and other members' apps refuse it.
A group nobody else has joined is always its owner's, because the founder is
superadmin.

What is sealed inside an envelope must match the envelope. The server and every
member judge a record by its envelope's IDs, but an app saves the record inside
under the IDs it carries. So a receiving app refuses a record whose own ID, group
or budget differs from its envelope's, one whose ID this Mac already holds as
another type or in another group, and a transaction or receipt that names a
budget in another group (`SyncEngine.belongsHere`). The sending app seals every
record under the IDs it carries at the time.

A member profile's ID is worked out from the group and the person
(`RecordID.memberProfile`), so anyone can work out someone else's in advance. The
server finds records by ID across all groups, so it keeps that ID for its owner: a
profile must sit on its sender's own ID, and no other record may use an ID of that
shape. Storing rows by group and ID instead was considered and not done. The
server would then take the same ID in two groups, and an app can only refuse
whichever copy it sees second. A member could plant a copy in a group she founded,
and a new member's Mac that synced that group first would refuse the real record.

**Known gap: the two sides judge at different points in the log.** If an author's
level changes between a push and someone's pull, the members who pulled first keep
the record, the members who pull later refuse it, and nothing brings them back
together. For a group delete, that splits the group. A Mac that pulls a whole group
again from the start, after a new invite link brought it back, judges every old
record against today's log as well. The shipping app never lowers a member's level,
but a modified app can, today. The log takes a level change or a removal from a
Manage member for anyone below Manage. From an admin it takes them for anyone,
other admins included, and it lets an admin change the founder's level. Only
removing the founder is refused. Any member, at any level, can also revoke any
device, or register any device as their own, and either one makes every Mac that
pulls later ignore what that device signed. So the split can be caused from the
lowest level. The server stores any entry that replays, and every honest app
replays it. It has to be settled before a change-role or remove feature ships,
most likely by judging both sides at the envelope's signed `membershipSequence`,
which nothing reads today.

For the second layer to mean anything, the membership list must be verifiable, or
the server could lie about who held what. So membership is an append-only
hash-chained log, each entry signed by an admin's identity key, replayed by clients.
Only the first entry may found the group. A founding entry is checked against the
keys it carries, so one anywhere later would let any member name herself founder.

## A version sent twice is stored once

When the device that wrote the stored version of a record sends that version again,
the server takes it as already stored and changes nothing. "That version" means the
same record, the same Lamport value and the same delete flag. This is what a reply
lost on the way back looks like: the app cannot tell its push was taken, so it sends
the row again. Every send is sealed afresh with a new random nonce, so the bytes never
match, and the server does not compare them.

That is safe only while a device never seals two different contents under one record
and one Lamport value. Two rules keep it that way. Code that breaks either one makes
the server answer "already stored" for content nobody else has, and that device then
disagrees with every other one, with nothing on screen to say so.

- **The local database never goes back in time while the device key stays.** The
  database lives in Application Support and the device key in the Keychain, so they
  can come apart. Restoring only the database from a backup, or running a cloned Mac
  next to the original, reuses Lamport values. Anything that restores, copies or
  resets the database must also give the device a new key.
- **New content never goes out again at the same Lamport value.** Every change goes
  through a queued save, which takes a fresh Lamport value. That includes sealing a
  record again under a new key: the re-seal after a "from now on" invite queues new
  rows (`Store.queueReseal`), and must keep doing so. Never re-seal a queued row in
  place. If the check ever needs to be exact, the outbox could keep the sealed
  envelope and send those same bytes again, and the server could then compare them.

## Carried over from the 2014 API

**Client-generated identifiers.** `api/sync.rb` carries the comment "sync_id must be
created in client or we could end up with unsinked duplicates", and migration 009
added the unique index that turned silent duplicate rows into a loud error. Correct
then, correct now, and here the client id is the primary key rather than a second
column.

**The ladder, gaps and all.** read 3, write 5, manage 7, admin 11, superadmin 13. The
gaps leave room to add a rung without renumbering.

**The superadmin quirk.** `models/Membership.rb` compares with `>=` for every rung
except superadmin, which is `==`. An admin is not a superadmin however the numbers
compare. There is a test pinning this, because it looks like a bug and is not.

## Deliberately not carried over

The `From-Date` sync cursor. `api/sync.rb` pulled with `where('updated_at >= ?')`,
which loses records on clock skew or a same-second write. Replaced by a
server-assigned monotonic sequence. This matters more now, because a dropped record
is ciphertext and shows up as missing data with no error.

Everything in the old auth path. The support backdoor header, the plain `==`
password comparison, the hardcoded AWS keys in `controllers/EmailController.rb`, the
transaction IDOR that let any authenticated user rewrite any transaction by id. All
of it is in the old backend's git history and should be assumed public.

## Decided since

- Domain: `wellspent.space`.
- Where the server runs: self-hosted, at `sync.wellspent.space`. The operating notes
  are kept privately, outside this repository.

## Open, not yet decided

- Whether v1 encrypts the local SQLite file. SQLCipher has no Linux target and
  reaches GRDB as a binary xcframework, so cross-platform local encryption means
  maintaining a fork. Receipt blobs should be encrypted on local disk regardless.
- Subscriptions. StoreKit 2 when there is something to sell. The old schema had
  levels 0, 5, 7, 11, 13 and a payments table, which is a starting point.

## The three places this is most likely to go wrong

**The recovery code, presented too early and never confirmed.** This fails quietly.
Nothing breaks the day it is skipped. It breaks months later when a drive dies, and
by then nothing can be done. Present it when there is something to lose, not at
signup, and make it blocking before the first share.

**Merge granularity, decided by the envelope format before anyone notices.** Whole
record snapshots mean two devices editing different fields of one transaction
produce two complete ciphertexts and one silently wins. v1 resolves by
`(lamport, deviceID)` and keeps the loser as a conflict copy. The envelope carries a
`payloadKind` field, unused, so v2 can move to operation-level sync without a format
break.

**Key material at rest on Linux.** There is no good answer. The identity key should
follow the ssh-agent shape: a 0600 file sealed with a scrypt-derived passphrase key,
unlocked once per session. Requiring the passphrase on every command guarantees it
gets switched off within a week.
