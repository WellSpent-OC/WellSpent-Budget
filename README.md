# WellSpent Budget

A budgeting app built for its author's own business first, to be sold afterwards.

## Where this came from

The original WellSpent shipped as an iOS app with a Ruby backend. This is a rewrite
from scratch: a Swift client and a Swift server, with sharing built in from the start.

## Status

**6,147 lines of source, 2,527 of tests, 150 tests passing, no stubs.**

Built: the crypto, key stores, domain model, local database, sync engine,
statement import, the Vapor server, and a Mac app that runs.

Not built: device pairing, sharing and recovery screens, receipt storage and OCR,
a real HTTP transport for the client, and every platform except the Mac.

**`STATUS.md` has the row-by-row breakdown**, including the known gaps inside the
things marked built. Read that before trusting `ARCHITECTURE.md`, which describes
intent rather than progress.

## Install a beta

Every change that lands on `main` becomes a numbered beta on the
[Releases page](../../releases), marked "Pre-release". It runs on macOS 14 or later,
on Apple silicon and Intel Macs.

1. Download the newest `WellSpent-0.1.0-beta.N.zip` and open it. You get
   `WellSpent.app`.
2. Drag `WellSpent.app` into Applications.
3. Open it. macOS stops it the first time, because the beta is not signed with an
   Apple Developer ID. Open System Settings, then Privacy & Security, scroll down,
   and click **Open Anyway** next to WellSpent. Confirm once more. After that it
   opens normally.
4. The first time it stores keys, macOS asks for your login password. Choose
   **Always Allow**.

To update, quit WellSpent and replace the app with a newer beta. Your budgets stay:
they live in `~/Library/Application Support/WellSpent`, not in the app.

## Building

    make build          # client package
    make test           # 135 tests
    make server-build   # Vapor server, separate package
    make server-test    #  15 tests
    make run            # the Mac app, signed so the keychain stops asking

`make test` carries extra flags because this machine has `xcode-select` pointed at
CommandLineTools and the Xcode licence has not been accepted. See the Makefile.

## Layout

    Sources/WellSpentCrypto/     key hierarchy, sealing, wrapping, invites, recovery
    Sources/WellSpentKeyStore/   Keychain on Apple, scrypt-sealed file on Linux
    Sources/WellSpentModel/      money, budgets, transactions, receipts
    Sources/WellSpentStore/      GRDB schema, repositories, outbox
    Sources/WellSpentSync/       pull, push, merge, conflict copies
    Sources/WellSpentImport/     CSV, OFX and QFX parsing, matching
    Sources/WellSpentApp/        SwiftUI, macOS
    Server/                      Vapor and Postgres, its own package

## Platforms

macOS 14 and iOS 17 are the floor, set by HPKE. Mac ships first, then iOS. The core
package compiles on Linux, so the Linux box gets a terminal client from the same
code. Android is much later. There is deliberately no web client.

## License

- The app and the shared libraries: GNU General Public License v3.0, in `LICENSE`.
- The sync server (`Server/`): GNU Affero General Public License v3.0, in
  `Server/LICENSE`. It also covers anyone who runs a changed copy of the server for
  other people.

Contributions need a signed contributor agreement before they can be merged. See
`CONTRIBUTING.md`.
