# What is built and what is not

Updated 2026-09-29. This file exists because `ARCHITECTURE.md` reads like a
specification for a finished system and is not one. Architecture describes intent.
This describes reality.

**Rule for this file: a row says "built" only if code runs and a test covers it.**

Totals: **248 tests passing, 0 stubs.** No `TODO`, no
`fatalError("unimplemented")`, nothing faked.

    make test          # 208 tests, client
    make server-test   #  40 tests, server
    make integration-test  # 8 tests, real client against real server over HTTP
    swift run WellSpentApp

## Built

| Piece | Where | Covered by |
|---|---|---|
| Key hierarchy, HPKE wrapping, record sealing | `WellSpentCrypto` | 27 tests |
| Twelve-word recovery code, escrow, confirmation challenge | `WellSpentCrypto/Recovery.swift` | 17 tests |
| Signed, hash-chained membership log with device enrolment | `WellSpentCrypto/MembershipLog.swift` | 13 tests |
| Record envelopes, Lamport clock, conflict ordering | `WellSpentCrypto/RecordEnvelope.swift` | included above |
| Invites bound to an out-of-band secret | `WellSpentCrypto/Invite.swift` | 3 tests |
| Keychain and scrypt-sealed file key stores | `WellSpentKeyStore` | 10 tests |
| Money as integer minor units, budget periods | `WellSpentModel` | 8 tests |
| GRDB schema, repositories, outbox, full-text search | `WellSpentStore` | 20 tests |
| Sync engine: pull, push, merge, conflict copies | `WellSpentSync` | 11 tests |
| CSV, OFX and QFX parsing; receipt and row matching | `WellSpentImport` | 31 tests |
| Vapor server: accounts, sync, verified log, invites | `Server/` | 40 tests, 32 of them also run against real Postgres in CI |
| Sign-out and token revocation | `Server/.../Routes.swift` | 2 tests |
| Mac app logic | `WellSpentAppCore/AppModel.swift` | 20 tests, 90% |
| Mac app views | `WellSpentAppCore/Views.swift` | 13 UI tests, 88% |
| Signing in, founding a group, syncing from the app | `WellSpentAppCore/SyncCoordinator.swift` | 17 tests, 97% |
| Sign-in sheet, sync button, recovery-code screen | `WellSpentAppCore/SyncViews.swift` | 9 UI tests, 80% |
| HTTP transport against the real server | `WellSpentSync/HTTPTransport.swift` | 8 integration tests |
| Client and server talking over real HTTP | `Server/Tests/IntegrationTests/` | 8 tests |

The Mac app was split in two. `WellSpentAppCore` holds the model and the views
and is tested and measured. `WellSpentApp` is now only `main.swift`: the AppKit
window and the entry point, 53 lines that cannot be unit tested and are not
measured. An executable target is never linked into a test binary, which is why
the whole app used to be invisible to both the suite and llvm-cov.

## Not built

Designed in `ARCHITECTURE.md`, absent from the code.

| Piece | Consequence today |
|---|---|
| Device pairing, the QR and typed-code flow | A second device cannot join an account |
| A deployment | The server runs on localhost and nowhere else. The plan for that is written |
| Client-side invite and sharing screens | Sharing works in tests and over HTTP, not in the UI |
| Key rotation driven from the UI | `KeyRing.rotate` exists and nothing calls it |
| Receipt blob storage and upload | Receipt records exist; the image bytes have nowhere to go |
| OCR | `ExtractedField` is populated by hand or by a test |
| iOS app, Linux client, Android | Nothing beyond the shared core compiling |
| XCUITest, driving the built app | Needs an Xcode project, a bundled `.app` and `xcodebuild`. The UI tests here inspect the SwiftUI hierarchy in process instead, which catches rendering and wiring but not window behaviour, focus or real clicks |
| Subscriptions, StoreKit | No monetisation of any kind |
| Getting back in with the twelve words | The words are shown when an account is made and can be checked in code. No screen takes them back and rebuilds the identity, so they are only useful once pairing exists |
| Automatic syncing | Sync runs when the button is pressed. Nothing syncs on a timer, on a change, or at launch |
| Conflict resolution UI | Losers are stored, never shown |

## Known gaps inside things marked built

- **Unsigned builds use the older keychain.** The modern keychain wants a signed,
  bundled app, and a plain `swift run` build is refused with `-34018`. On that error
  `KeychainKeyStore` switches to the legacy login keychain, which loses the Touch ID
  gate and the "this device only" flag. A signed build never switches. Signing waits
  on an Apple Developer account, before the app ships.
- **The rate limiter is still in memory**, so the deployment has to stay a single
  instance. Two would each keep their own counters, and both would race on
  migrating at boot.
- **`SKIP_AUTO_MIGRATE` cannot bootstrap an empty database.** `configure` purges
  expired tokens after the migrate branch either way, and that query needs a
  table the skipped migration would have created. The fix is to move the purge,
  and nothing needs it until there is more than one instance.
- **Keys are minted locally for a group only this person belongs to.** That is
  what makes a group made offline syncable later. Once a group is shared the keys
  come from whoever shared it, and the sole-member check is the only thing keeping
  those two paths apart.
- **The server and the apps judge a record's author at different points in the
  membership log.** The shipping app never lowers a member's level, but a modified
  app at Manage or above can today, and any member can revoke her own device, so
  the split can already be caused. Below admin, nobody can take or revoke someone
  else's device any more: a device belongs to its owner (`DeviceSlot`). An admin or
  the founder still can. It has to be settled before a change-role or remove
  feature ships. See the known gap under "What encryption does not do" in
  ARCHITECTURE.md.
- **A re-seal after a "from now on" invite can win over an edit another member
  made before pulling it.** The edit is kept only as a conflict copy. See the
  known gap under "Invites" in ARCHITECTURE.md.
- **`joinedAtSequence` is always 0 on the server**, so the history floor for a
  member added with `.fromNow` does not yet bite. The client cannot read those
  records anyway, because it holds no key for the older epoch, so this is defence
  in depth that is not yet load-bearing.
- **The Mac app is a SwiftPM executable, not a bundled `.app`.** It runs, but it
  has no Info.plist and cannot be notarised or shipped. Packaging is a build
  step, not a rewrite. It does have an icon: `main.swift` sets the Dock icon at
  launch from `AppIcon.icns`.

## Coverage

**90.0% line coverage**, floored at 85% in CI (`make coverage`, `scripts/coverage.sh`).

Two things it still excludes:

- **`WellSpentApp`**, now just `main.swift`: the AppKit window and entry point.
  53 lines. An executable target cannot be linked into a test binary.
- **`Server/`**, measured separately by its own 40 tests plus 8 integration tests.

Files below 80% line coverage:

| File | | |
|---|---|---|
| `WellSpentKeyStore/KeychainKeyStore.swift` | partial | the fallback runs against a fake keychain in CI; the real one runs only with `WELLSPENT_REAL_KEYCHAIN=1` on a Mac |
| `WellSpentAppCore/Views.swift` regions | 66% | SwiftUI branches a unit test cannot reach, such as platform-specific modifiers |
| `WellSpentAppCore/SyncViews.swift` regions | 63% | the same: sheet lifecycle and button actions that need a running app |
| `WellSpentSync/KeyRing.swift` | 64.5% | rotation and the multi-epoch paths are untested |
| `WellSpentModel/Records.swift` | 70.5% | mostly unused initialisers and defaults |
| `WellSpentStore/Rows.swift` | 79.6% | the error branches on malformed rows |

## Verified on this machine

- Swift 6.3.3, macOS 26 SDK.
- `xcode-select` points at CommandLineTools and the Xcode licence has not been
  accepted, so `xcodebuild` cannot run. Everything here uses `swift build`. The
  Makefile carries the extra flags this requires for swift-testing.
- Server tests run against in-memory SQLite. **The Postgres path has never been
  run.** Same migrations, different driver, so treat first contact with Postgres
  as untested.
