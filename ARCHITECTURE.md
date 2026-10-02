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

Budgets and the group's name take Manage. Write (the Add role) is for adding
transactions and changing or deleting your own. Making, changing or deleting a
budget, and renaming the group, needs Manage. The screens offer them only to a
manager, the app does not send them from anyone else, and the server and other
members' apps refuse them. Renaming is not in the Add role's text, so it was
decided by that text; it renames the group for every member. A group nobody else
has joined is always its owner's, because the founder is superadmin.

Handing out keys also takes Manage; the next section has the rules.

What is sealed inside an envelope must match the envelope. The server and every
member judge a record by its envelope's IDs, but an app saves the record inside
under the IDs it carries. So a receiving app refuses a record whose own ID, group
or budget differs from its envelope's, one whose ID this Mac already holds as
another type or in another group, and a transaction or receipt that names a
budget in another group (`SyncEngine.belongsHere`). The sending app seals every
record under the IDs it carries at the time, and does not send a transaction or
receipt filed under another group's budget, which every other member would
refuse. A statement import files each row under its budget's own group.

A record that can never be saved as it is does not stop a sync for good. One whose
seal does not open with the key this Mac holds for its epoch is counted as
undecryptable, and one whose contents do not decode as what its envelope says is
refused. A save this Mac's database refuses for a reason that will repeat, a
constraint, is set aside and counted (`SyncReport.unsaved`), tried again on later
pulls, and that record's queued row stays out of the push meanwhile: the failed
save also undid moving a re-seal above the newer version, and sending it would put
this Mac's old content over that version on every Mac. Either way the pull moves
past it. Before, the error stopped the pull before its cursor moved, so one bad
record from any member at Add stopped the group syncing for everyone else, for
good. A failure that can clear up, such as a full disk, still stops the pull before
its cursor moves, so the record comes again once it can be saved.

Two of those had causes of their own. A Mac holds one imported row per fingerprint
in a group, and two members who import the same statement each send theirs, so a
pulled row whose fingerprint this Mac already holds is kept without it. The
fingerprint is kept to one side and goes back out with the row when this Mac saves
it again; sent without it, the member who imported it would add the line again on
their next overlapping import. And a transaction that arrives before its budget is set
aside and applied once the budget is in, usually at the end of the same pull: a
budget edited after its transactions sorts after them on the server, so a new
member pulling everything met them first. A set-aside row leaves only once it has
been dealt with, and one still waiting for its budget is not opened at all. A record
in a format a newer build writes is set aside too, as an unknown type is, for after
an update, but only from someone who may write, signed when its format is known, and
only up to a limit per sender in each group (`SyncEngine.setAsideLimit`). Past the
limit such a record is passed over like a refused one, and the pull moves on, so an
update does not bring it back. A record set aside because this build cannot read
it, or whose retry fails, keeps a queued plain re-seal of it out of the push: the
re-seal would send this Mac's older content over that version. It waits only while
that version would still replace the one on file here, so once an edit made here
has gone out over it, later re-seals go too. Edits and deletes made here always go
out. Holding them too let any member at Add freeze another member's record for
good, by sending a copy of it in a made-up format.

A member profile's ID is worked out from the group and the person
(`RecordID.memberProfile`), so anyone can work out someone else's in advance. The
server finds records by ID across all groups, so it keeps that ID for its owner: a
profile must sit on its sender's own ID, and no other record may use an ID of that
shape. Storing rows by group and ID instead was considered and not done. The
server would then take the same ID in two groups, and an app can only refuse
whichever copy it sees second. A member could plant a copy in a group she founded,
and a new member's Mac that synced that group first would refuse the real record.

Groups, records and budgets whose keys have been published share that one space
of IDs, and the first group to use an ID keeps it (`IDClaims`). A group cannot be
founded on an ID a record or a published budget key already uses, or on one shaped
like a profile's: a group on someone's profile ID hid that profile on the Mac of
everyone who answered its link. The app also refuses a link to a group whose ID it
already holds as something else. A budget's key is published before its record is
pushed, so the key claims the ID: no record of another type, and nothing in
another group, may take it after that. Before, a member of another group who read
the key pushed a record on that ID first, and the budget was refused on every sync.

**Known limit: a server that lies can still plant an ID on a Mac that does not hold
it yet.** It needs a member of some group this Mac is in to sign a record on another
group's record ID, and a server that serves it first. That Mac keeps the planted
copy and refuses the real record when it comes. The honest server refuses the plant,
and a dishonest server can keep any record off a Mac simply by not serving it, so
what this adds is that the record stays refused after the server is honest again.
Closing it would mean binding every record ID to its group, which changes how IDs
are made.

**Known gap: the two sides judge at different points in the log.** If an author's
level changes between a push and someone's pull, the members who pulled first keep
the record, the members who pull later refuse it, and nothing brings them back
together. For a group delete, that splits the group. A Mac that pulls a whole group
again from the start, after a new invite link brought it back, judges every old
record against today's log as well. The shipping app never lowers a member's level,
but a modified app can, today. The log takes a level change or a removal from a
Manage member for anyone below Manage. From an admin it takes them for anyone,
other admins included, and it lets an admin change the founder's level. Only
removing the founder is refused. Below admin, a device can now be registered and
revoked only by its owner, as theirs (`DeviceSlot`), and only a manager moves the
epoch, so a member below Manage can no longer split the group through someone
else's device. She can still revoke her own, which makes every Mac that pulls later
ignore what that device signed, and an admin or the founder can still revoke
anyone's. The server stores any entry that replays, and every honest app
replays it. It has to be settled before a change-role or remove feature ships,
most likely by judging both sides at the envelope's signed `membershipSequence`,
which nothing reads today.

For the second layer to mean anything, the membership list must be verifiable, or
the server could lie about who held what. So membership is an append-only
hash-chained log, each entry signed by an admin's identity key, replayed by clients.
Only the first entry may found the group. A founding entry is checked against the
keys it carries, so one anywhere later would let any member name herself founder.

The replay also checks what each entry changes (`MembershipLog.checkWhatItChanges`):

- **A person's keys are their own.** Servers take an add or a level change only
  with the keys the person signed up with, so a manager cannot put keys she made on
  someone's ID, before they join or before their first sync. The log refuses an add
  or a level change that leaves someone a member with no keys, so one sent without
  keys cannot get round that check. Such an add left a member nobody could invite,
  and a key stored for them with it stayed in their slot after they were removed.
  Once they have signed an entry, only their own entry can replace their keys in
  the log: a manager could put her keys in the founder's place, every entry he
  signed after that was refused, and keys for a new epoch were sealed to her. The
  log alone lets keys nobody has signed with be replaced by a later level change,
  and a removal clears them; that matters only for a log a server made up, since an
  honest one holds sign-up keys. An add is for someone outside the group. A server
  takes a group key sealed to the person an add names, and an add of a current
  member let a manager fill her empty older-epoch slots with junk keys.
  An inviter whose add would be refused, or is refused by the server, drops that
  invite instead of failing every sync. Whoever holds a link can answer it with keys
  that are not theirs, or with someone else's ID, so a refused add counts as the
  answer's fault. The one exception is a log that moved on while the add was on its
  way: then the invite stays for the next sync.
- **A device belongs to the person and the device together** (`DeviceSlot`), and is
  registered only by the founding entry or an entry of its own, never inside an add
  or a level change. A Mac uses one device ID in every group, and every member can
  read it. Registered by the ID alone, a member at View could take the founder's
  device, cut it off, or take someone's ID first in a group they had not joined yet.
  In an add or a level change, a manager could enrol a device of her own under
  someone else's name and sign records as them. Below admin, a member registers and
  revokes only her own devices; an admin or the founder can still register or revoke
  anyone's. Because two people can each register one device ID, a record is this
  Mac's own only when it is this person on this device; the servers' "already
  stored" answer compares both, and a tie between versions on one device ID is
  broken by who wrote it (`RecordEnvelope.replaces`). A server reads who wrote the
  stored version from its envelope. The app keeps the author with each version it
  stores. A version stored before it did counts as this person's when it is on this
  Mac's own device ID: this Mac sent it in nearly every case, since earlier builds
  skipped most of what others signed under its ID as its own coming back.
- **The epoch starts at the first one and moves one step at a time, and only by a
  manager**, who is the one who can hand out the new epoch's keys. An epoch nobody
  holds keys for left every member's edits queued for good. The next epoch is worked
  out without adding past the top of the 32-bit range: a group founded at the top,
  then any entry that moved the epoch, stopped the server process on every post.
  Registering a device never moves the epoch, so its entry names the current one.
  It takes only View, and one naming the next epoch was taken for the entry that
  started it, so the server refused the keys the real start carried.

## Keys a Mac takes in

Every app seals and opens records with the group and budget keys it holds, so a
key from the wrong person, or for the wrong thing, changes what other members'
Macs can read. Any member could once send keys of her own with any entry, such as
the one that registers her laptop, and every member's app took the last key it
opened in place of the one it held. Nothing sealed with the real key opened after
that, on any sync.

The server takes keys only from a manager: on the log route only with an entry
whose author may manage the group, and on the keys route as before. Each key must
come from the person sending it, for an epoch the group has reached, and be one of
two kinds. A group key for this group, sealed to one of its members, travels only
with a membership entry, and only for the person that entry adds or for the epoch
that entry starts. A budget key, sealed under the group key, is for a budget no
other group uses (`WrappedKey.refusal`). The first key stored for a scope, epoch
and recipient is the one kept, so every member's app is handed the same one.

Because the first key is kept, nothing may fill a slot before the real key. A
manager could once attach junk keys for older epochs to any entry of her own,
sealed to a member who joined "from now on", and fill that member's empty slots.
An entry that leaves someone out of the group also takes the group keys stored for
them, in the same transaction (`MembershipLog.groupKeysDropped`). Otherwise a junk
key sealed to them with their add stayed after they were removed, and when they
were invited back with everything so far, the real key was dropped.

The server also takes a budget key only from someone who holds that epoch's group
key: one someone else sealed to them, one they sealed to themselves with the entry
that started that epoch, or the first one, which the founder made. The entry that
started an epoch is the one that moved the group to it, never one that only names
it. A manager added "from now on" could otherwise fill an older epoch's empty slot
with junk, and the real key sent later was dropped. The check matters only for an
empty slot. A key for a filled one is dropped anyway, and refusing it refused the
whole invite: a manager removed and added back "from now on" could never again
share everything so far, because her stored keys went with the removal.

The app takes a group key only for the group being synced, sealed to this person
by someone who may manage it; the seal proves who sent it. It opens a budget key
only with that group's key for the same epoch, and never for a budget it holds in
another group. It takes nothing for an epoch its log has not reached. And it never
replaces a key it already holds (`KeyRing.absorb`). It judges all of that on the
log it has verified: the one it holds plus what extends it. The key step before
each sync used to read the whole log and replay it alone, and a server could
answer that one read with a made-up chain, founded with keys it made, while
answering the engine honestly.

Because a held key is never replaced, nothing may get there before the real one.
Keys this Mac makes for a new epoch are kept only once the server has taken the
entry that starts it. A statement import makes a key only for a group of this
person's own. And a group is treated as this person's alone, so that its keys are
made here, only on the log this Mac has verified, and only when this person founded
it with their own key. A server can make up a log naming someone its only member,
and can even put their public keys in it, since those are not secret; it cannot sign
a founding entry with their key. The inviter keeps the entry it sends, as the
founder keeps the founding one, so a server that leaves it out of later reads cannot
get the same epoch started twice.

**Known limit: who sent a budget key is not proven.** It is sealed under the group
key, which every member holds. A server that lies, working with a member, could
hand a new member a wrong budget key before the real one, and that member would
then not read that budget. Nothing is revealed: the member who made the wrong key
could already read the budget.

## Known gaps, tracked

Known and not fixed yet, each for the reason given. They bear on whether sharing
is safe, so they are listed here until they are.

Older problems, set aside for work of their own. One more, a manager enrolling a
device under another member's name with a level change, is closed by the device
rule above.

- **A member at Add with a modified app can replace other members' transactions on
  the server.** The server never compares the author when it updates a row. Members
  who hold the original refuse her version, but one who pulls later, such as a new
  member, keeps it. She can also change or delete any receipt or statement.
- **A manager can freeze a group by starting an epoch she gives nobody keys for.**
  Everyone else's edits then stay queued. This was narrowed from any member to
  Manage.
- **A lying server can stop a Mac sending in a group with one unsigned record
  carrying a high Lamport value.** The pull takes the value into the clock before it
  checks who signed the record.
- **A lost reply on a "from now on" invite skips the re-seal for good.**
- **A new budget's key is kept before its upload, and never sent again if the upload
  fails.**
- **One transaction with an extreme amount crashes every other member's app, on
  every launch.** A member at Add with a modified app can push an amount at the edge
  of the number range, and the totals overflow.
- **A server that lies can give a brand-new member a made-up copy of a group.** On
  first contact a Mac holds no log, so it takes the server's first answer whole.
- **An admin can lower the founder to nothing, or make herself superadmin.** Only
  removing the founder is refused.
- **One 403 from a server that lies makes a member's Mac found its group again,**
  writing over the founding entry it stored.
- **A manager can stop every "from now on" invite in a group with keys nobody can
  seal to.** Sealing the new epoch's key to every member fails on such keys before
  the add is sent (`Sharing.keysForNewMember`), so the inviter's sync stops at that
  group on every round until the link expires.
- **A member at View can make a group's log grow without limit.** Registering the
  same device again, with the same key, is taken each time, and every member's app
  replays every entry.
- **A junk group key a Mac took in during a brief membership keeps the real one out
  later.** Servers drop a removed person's group keys, but their Mac keeps what it
  took in, and never replaces a key it holds. A manager with a modified app could
  add someone with a junk key, remove them, and a later invite would not let them
  read.
- **A removal followed at once by a re-add lets a manager refill a current member's
  slots with junk keys.** The member's current Mac keeps its real keys. A second Mac,
  or the same one after a reinstall, takes the junk ones for good.

Each of these key gaps needs a manager with a modified app, and each leads to
"cannot read", never to "can read what they should not". A server cannot open a
key, so it cannot tell a junk one from a real one.

**Key commitments (planned).** The entry that starts an epoch will carry a hash of
that epoch's group key, and every Mac will refuse a group key that does not match
it, whoever sent it. That closes the whole class of a manager planting keys: the
two gaps above, and the re-add route the log now refuses. It changes the format of
a membership entry, so it is planned for before sharing goes beyond the household.

Plausible, dormant, or small:

- **Keys from a manager who is later demoted can never be taken in.** The app judges
  a key by its sender's level today. Nothing in the app lowers a level yet; it will
  matter once removing members is built.
- **What a pull passes over is not shown.** Records it could not open, refused, or
  could not save are counts in the sync report that nothing displays.
- **The first-key rule is a read and then an insert.** Two key uploads at the same
  moment can both store a key for one slot. Membership entries are serialised by
  their sequence, so only the keys route is exposed.
- **Set-aside rows have no expiry, and stay when their group is deleted.** Records of
  a type or format this build cannot read are limited per sender in each group, and
  past that limit one is passed over for good. Transactions waiting for their budget
  and saves that keep failing are not limited. Each is a record on the server, and
  one waiting for its budget is not opened while it waits.
- **A plain re-seal waits behind a version this build cannot read.** A record with
  such a version set aside here keeps its queued re-seal back until an update can
  read that version, or an edit made here goes out over it. Letting go of the group
  drops the re-seal. A member added "from now on" cannot read that record until
  someone edits it. Edits and deletes made here still go out, and are weighed by
  Lamport value as usual.
- **An edit with a re-seal queued over it can go out over a newer version this build
  cannot read.** It goes out at the re-seal's fresh Lamport value, not the value the
  edit was made at. Dormant until a build writes a newer record format.
- **Made-up keys someone has signed with keep that person out, on a server that
  lies.** An honest server takes only sign-up keys in an add, and the log takes no
  add that leaves someone without keys. A server that lies can hold made-up keys on
  someone's ID, signed with as them; the inviter's add is then dropped rather than
  failing every sync, and the person cannot join that group. A removal clears keys
  nobody signed with. An honest server also drops the group keys it stored for
  them, but a server that lies can keep them.

## A version sent twice is stored once

When the person and device that wrote the stored version of a record send that
version again, the server takes it as already stored and changes nothing. "That
version" means the same record, the same Lamport value, the same author and device,
and the same delete flag. This is what a reply
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

## How far a Lamport value may go

A Lamport value grows by one for each save, and every app's clock for a group is
the highest value it has pulled from that group plus its own saves since. Two
limits stop a forged value from leaving those clocks no room.

**The ceiling.** Every server refuses a value at or above 2^62, and an app ignores
one a server hands over anyway, keeping it out of its clock
(`RecordEnvelope.lamportCeiling`). Above Int.max, converting the value stopped the
server process for every user. Near the top of a signed 64-bit integer, every app
that pulled it crashed on its next save.

**The lead.** Every server also refuses a value more than 2^24 above the highest
value the group has ever stored, read once before each push
(`RecordEnvelope.lamportLead`). The ceiling alone left a gap: a member at Add could
set her own Mac's clock just under it by editing its database, and the stock app
signed the next value. Every Mac that pulled that value then had no room to save in
the group, for good, while still showing "Last synced". With the lead, each push
can raise the group's highest value by 2^24 at most, so reaching the ceiling takes
about 2^38 pushes in a row. Reading the highest value once per push means one push
of many records climbs once, not once per record.

2^24 is about 16.8 million. An honest push is never that far ahead: everything a
Mac pulled was at or below the group's highest value, which only ever goes up, so
its clock is ahead by at most the saves it made since its last pull. Months offline,
or importing a statement of tens of thousands of rows, is far below that. A larger
lead would let a forged value climb faster and buy nothing for an honest one.

The server keeps each group's highest value on the group's row (`max_lamport`),
and only ever raises it, even when two pushes change one record at the same moment.
The `AddGroupMaxLamport` migration added it and filled it from the records already
stored, leaving out any at or above the ceiling, in one transaction that is safe to
run again (DEPLOY.md has the recovery line for a server built before that). Values stored before the ceiling
existed are not repaired: a Mac that took one in cannot save in that group until it
is lowered, which no build does yet.

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

Everything in the old auth path. Nothing from it is reused: it had serious flaws,
and its history should be assumed public.

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
produce two complete ciphertexts and one silently wins. v1 resolves by Lamport
value, then device ID, then author, and keeps the loser as a conflict copy. The
envelope carries a `payloadKind` field, unused, so v2 can move to operation-level
sync without a format break.

**Key material at rest on Linux.** There is no good answer. The identity key should
follow the ssh-agent shape: a 0600 file sealed with a scrypt-derived passphrase key,
unlocked once per session. Requiring the passphrase on every command guarantees it
gets switched off within a week.
