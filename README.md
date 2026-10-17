# WellSpent Budget

A budgeting app built for its author's own business first, to be sold afterwards.

## Where this came from

The original WellSpent shipped as an iOS app with a Ruby backend. This is a rewrite
from scratch: a Swift client and a Swift server, with sharing built in from the start.

## Privacy

Your budgets sync through WellSpent's server. Connections and backups are encrypted.
The server can read your budgets, which is how it checks who may change what and how
it resets a forgotten password.

Earlier versions of WellSpent used end-to-end encryption instead. `ARCHITECTURE.md`
keeps that design as history, marked "before readable sync".

## Status

Alpha. The Mac and Linux apps both have sign-in and accounts, budget groups and
budgets, entries, bank statement import, sync, and sharing: an invite link, joining,
members and their levels, and leaving.

Not built yet: receipt storage and OCR, settling up between members, and the iOS
and Android apps.

**`STATUS.md` has the row-by-row breakdown** as of 2026-09-29, before readable sync
and these screens. It is rewritten once every account has moved. Read it before
trusting `ARCHITECTURE.md`, which describes intent rather than progress.

## Install a beta

Numbered betas are published on the [Releases page](../../releases), marked
"Pre-release". For now each one is started by hand, not by every change to `main`.
It runs on macOS 14 or later, on Apple silicon and Intel Macs.

1. Download the newest `WellSpent-0.1.0-beta.N.zip` and open it. You get
   `WellSpent.app`.
2. Drag `WellSpent.app` into Applications.
3. Open it. macOS stops it the first time, because the beta is not signed with an
   Apple Developer ID. Open System Settings, then Privacy & Security, scroll down,
   and click **Open Anyway** next to WellSpent. Confirm once more. After that it
   opens normally.
4. The first time it saves your sign-in, macOS asks for your login password.
   Choose **Always Allow**.

To update, quit WellSpent and replace the app with a newer beta. Your budgets stay:
they live in `~/Library/Application Support/WellSpent`, not in the app. Each new beta
counts as a new app to macOS, so expect steps 3 and 4 again after every update.
That is normal, not a sign anything broke.

## Building

    make build          # client package
    make test           # client tests
    make server-build   # Vapor server, separate package
    make server-test    # server tests
    make run            # WellSpent Staging, signed so the keychain stops asking
    make ui-test-build  # compiles the Mac UI test through Xcode; no window opens
    make ui-test        # runs it: the real window against staging, two test accounts
    make testflight         # WellSpent.app signed for the Mac App Store, in a signed .pkg, checked by App Store Connect
    make testflight-upload  # uploads the .pkg that make testflight checked

`make test` carries extra flags because this machine has `xcode-select` pointed at
CommandLineTools and the Xcode licence has not been accepted. See the Makefile.

`make ui-test` needs Xcode and xcodegen (`brew install xcodegen`), and four
variables exported in the shell: `WELLSPENT_UI_TEST_EMAIL`,
`WELLSPENT_UI_TEST_PASSWORD`, `WELLSPENT_UI_TEST_EMAIL_2` and
`WELLSPENT_UI_TEST_PASSWORD_2`, two confirmed accounts on the staging server. Keep
them in a file outside the repo and source it first. The test launches the app with
`WELLSPENT_DATA_ROOT` set, which a staging build reads to keep its databases in that
folder and its keys in memory, so nothing reaches Application Support or the
keychain. The window opens on screen for the run.

`make testflight` needs Xcode and four things that stay outside the repo: the Mac App
Store provisioning profile, the two certificate names, and the App Store Connect API
key id and issuer id. The scripts say which variables name them and where they are
read from by default.

## Layout

    Sources/WellSpentCrypto/     identifiers and access levels, and the sealed design
                                 from before readable sync, kept to move existing
                                 accounts across
    Sources/WellSpentKeyStore/   Keychain on Apple, scrypt-sealed file on Linux
    Sources/WellSpentModel/      money, budgets, transactions, receipts
    Sources/WellSpentStore/      GRDB schema, repositories, outbox
    Sources/WellSpentSync/       pull, push, merge, conflict copies
    Sources/WellSpentImport/     CSV, OFX and QFX parsing, matching
    Sources/WellSpentAppCore/    the app's model and screens, shared by Mac and Linux
    Sources/WellSpentApp/        SwiftUI, macOS
    Linux/                       the Linux desktop app, its own package, with
                                 sign-ins kept in the desktop keyring
    Server/                      Vapor and Postgres, its own package

## Platforms

macOS 14 and iOS 17 are the floor, set by HPKE. Mac ships first, then iOS. Linux
has a desktop app of its own in `Linux/`, drawn from the same shared screens as the
Mac. Android is much later. There is deliberately no web client.

## License

MIT, for everything here: the app, the shared libraries, the Linux app and the sync
server. The text is in `LICENSE`, with a copy in `Server/LICENSE` because the
server is its own package.

Earlier versions were published under the GNU General Public License v3.0 (the app)
and the GNU Affero General Public License v3.0 (the server). Copies taken then keep
those terms.

How to contribute: `CONTRIBUTING.md`.
