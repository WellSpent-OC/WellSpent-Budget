import Testing
import Foundation
@testable import WellSpentSync
import WellSpentCrypto
import WellSpentModel

/// The in-memory server keeps the real server's rules. These are the rules
/// the app depends on, ported from the server package's own tests, so the
/// engine's tests stand on rules that match.

/// A record as the app would send it.
private func wire<R: SyncedRecord>(_ record: R, budget: BudgetID? = nil, lamport: UInt64,
                                   device: DeviceID = DeviceID()) throws -> WireRecord {
    WireRecord(id: RecordID(record.id.uuid), type: R.recordType, budgetID: budget, lamport: lamport,
               clientID: device, isDeleted: record.isDeleted,
               body: String(decoding: try RecordCodec.encoder.encode(record), as: UTF8.self))
}

private struct Household {
    let server = InMemoryReadableServer()
    let founder: InMemoryReadableSession
    let founderID: UserID
    let group: BudgetGroup
    let budget: Budget

    init() async throws {
        founder = server.client()
        founderID = try await founder.signUp(email: "founder@example.com", password: "founder password",
                                             deviceLabel: nil).userID
        let code = try #require(server.lastCode(for: "founder@example.com", purpose: .verify))
        try await founder.verifyEmail(code: code)
        group = BudgetGroup(name: "Household")
        _ = try await founder.createGroup(id: group.id, importKey: nil)
        budget = Budget(groupID: group.id, name: "Food", limit: Money(minorUnits: 10_000))
        let result = try await founder.push([try wire(group, lamport: 1), try wire(budget, budget: budget.id, lamport: 2)],
                                            group: group.id)
        #expect(result.rejected.isEmpty)
    }

    /// Someone who joined with `level`, with a confirmed address.
    func member(_ email: String, level: AccessLevel, history: HistoryAccess = .all)
        async throws -> (InMemoryReadableSession, UserID) {
        let client = server.client()
        let id = try await client.signUp(email: email, password: "member password", deviceLabel: nil).userID
        try await client.verifyEmail(code: try #require(server.lastCode(for: email, purpose: .verify)))
        let invite = try await founder.createInvite(group: group.id, level: level, history: history, days: nil)
        _ = try await client.acceptInvite(token: invite.token)
        return (client, id)
    }

    func spend(_ amount: Int, by user: UserID?) -> Transaction {
        Transaction(budgetID: budget.id, groupID: group.id, date: Date(timeIntervalSince1970: 1_790_000_000),
                    merchant: "Market", amount: Money(minorUnits: amount), createdBy: user)
    }
}

@Suite("In-memory readable server")
struct InMemoryReadableServerTests {
    @Test func aPasswordResetEndsEveryOtherSession() async throws {
        let server = InMemoryReadableServer()
        let laptop = server.client(), desktop = server.client()
        _ = try await laptop.signUp(email: "Person@Example.com", password: "first password", deviceLabel: "Laptop")
        try await laptop.verifyEmail(code: try #require(server.lastCode(for: "person@example.com", purpose: .verify)))
        await #expect(throws: ReadableTransportError.badCredentials) {
            try await desktop.signIn(email: "person@example.com", password: "not the password", deviceLabel: nil)
        }
        _ = try await desktop.signIn(email: "person@example.com", password: "first password", deviceLabel: "Desk")

        try await desktop.forgotPassword(email: "person@example.com")
        let code = try #require(server.lastCode(for: "person@example.com", purpose: .reset))
        _ = try await desktop.resetPassword(email: "person@example.com", code: code,
                                            newPassword: "second password", deviceLabel: "Desk")
        #expect(try await desktop.me().emailVerified)
        await #expect(throws: ReadableTransportError.sessionEnded("Unauthorized")) { try await laptop.me() }
    }

    /// The fake keeps the address rule and the device names as the server does.
    @Test func addressesAndDeviceNamesFollowTheServer() async throws {
        let server = InMemoryReadableServer()
        for bad in ["first last@example.com", "a@b..com"] {
            await #expect(throws: ReadableTransportError.http(status: 400,
                                                              reason: "that does not look like an email address")) {
                try await server.client().signUp(email: bad, password: "long enough pass", deviceLabel: nil)
            }
        }
        let client = server.client()
        _ = try await client.signUp(email: "p@example.com", password: "long enough pass", deviceLabel: "  Desk  ")
        let other = server.client()
        _ = try await other.signIn(email: "p@example.com", password: "long enough pass", deviceLabel: "   ")
        #expect(Set(try await client.sessions().map(\.deviceLabel)) == ["Desk", nil])
        #expect(try await client.me().emailVerified == false)
        let seeded = server.seedAccount(email: "seeded@example.com", password: "long enough pass")
        let seededClient = server.client()
        #expect(try await seededClient.signIn(email: "seeded@example.com", password: "long enough pass",
                                              deviceLabel: nil).userID == seeded)
        #expect(try await seededClient.me().emailVerified == false, "the switch confirms no address")
    }

    @Test func changingThePasswordKeepsThisDeviceOnly() async throws {
        let server = InMemoryReadableServer()
        let laptop = server.client(), desktop = server.client()
        _ = try await laptop.signUp(email: "p@example.com", password: "first password", deviceLabel: nil)
        _ = try await desktop.signIn(email: "p@example.com", password: "first password", deviceLabel: nil)
        await #expect(throws: ReadableTransportError.wrongCurrentPassword) {
            try await laptop.changePassword(current: "wrong password", new: "second password")
        }
        try await laptop.changePassword(current: "first password", new: "second password")
        _ = try await laptop.me()
        await #expect(throws: ReadableTransportError.sessionEnded("Unauthorized")) { try await desktop.me() }
    }

    /// A group made before the switch has no import key until its founder's
    /// app brings the old one, which is kept once set.
    @Test func aLegacyGroupTakesItsFoundersImportKeyOnce() async throws {
        let server = InMemoryReadableServer()
        let founder = server.seedAccount(email: "founder@example.com", password: "founder password")
        let group = GroupID()
        server.seedLegacyGroup(id: group, founder: founder)
        let client = server.client()
        _ = try await client.signIn(email: "founder@example.com", password: "founder password", deviceLabel: nil)
        #expect(try await client.groups().map(\.importKey) == [Data()])

        let old = Data(repeating: 4, count: 32)
        #expect(try await client.createGroup(id: group, importKey: old).importKey == old)
        #expect(try await client.createGroup(id: group, importKey: Data(repeating: 9, count: 32)).importKey == old)

        let stranger = server.client()
        _ = try await stranger.signUp(email: "s@example.com", password: "stranger password", deviceLabel: nil)
        await #expect(throws: ReadableTransportError.http(status: 409, reason: "that group already exists")) {
            try await stranger.createGroup(id: group, importKey: old)
        }
    }

    /// The first account to store an entry owns it. A transaction sent with
    /// no owner is given its sender.
    @Test func entriesBelongToWhoeverStoredThemFirst() async throws {
        let home = try await Household()
        let (writer, writerID) = try await home.member("w@example.com", level: .write)

        let legacy = home.spend(-100, by: nil)
        _ = try await home.founder.push([try wire(legacy, budget: home.budget.id, lamport: 3)], group: home.group.id)
        let stored = try #require(home.server.records(in: home.group.id).first { $0.id == legacy.id })
        #expect(stored.createdBy == home.founderID)
        let body = try RecordCodec.decoder.decode(Transaction.self, from: Data(stored.body.utf8))
        #expect(body.createdBy == home.founderID, "the server writes the owner in")

        var edited = legacy
        edited.merchant = "Changed by the writer"
        edited.createdBy = home.founderID
        let refused = try await writer.push([try wire(edited, budget: home.budget.id, lamport: 4)], group: home.group.id)
        #expect(refused.rejected[legacy.id] == "only its owner or a manager can change it")

        let theirs = home.spend(-200, by: writerID)
        let own = try await writer.push([try wire(theirs, budget: home.budget.id, lamport: 5)], group: home.group.id)
        #expect(own.accepted == [theirs.id])

        var renamed = home.budget
        renamed.name = "Groceries"
        let budget = try await writer.push([try wire(renamed, budget: renamed.id, lamport: 6)], group: home.group.id)
        #expect(budget.rejected[RecordID(renamed.id.uuid)] == "only a manager can change a budget")
    }

    /// A record must be what it says it is, where it was sent.
    @Test func aRecordMustMatchWhereItWasSent() async throws {
        let home = try await Household()
        let other = BudgetGroup(name: "Other")
        _ = try await home.founder.createGroup(id: other.id, importKey: nil)
        let spent = home.spend(-100, by: home.founderID)
        let misplaced = try await home.founder.push([try wire(spent, budget: home.budget.id, lamport: 3)],
                                                    group: other.id)
        #expect(misplaced.rejected[spent.id] == "the record does not match where it was sent")

        let stranger = UserID()
        let profile = MemberProfile(groupID: home.group.id, userID: stranger, displayName: "Not me")
        let squat = try await home.founder.push([try wire(profile, lamport: 3)], group: home.group.id)
        #expect(squat.rejected[profile.id] == "that ID belongs to a member profile")

        let mine = MemberProfile(groupID: home.group.id, userID: home.founderID, displayName: "Me")
        #expect(try await home.founder.push([try wire(mine, lamport: 3)], group: home.group.id).accepted == [mine.id])

        let future = WireRecord(id: RecordID(), type: RecordType(rawValue: "future"), budgetID: nil, lamport: 3,
                                clientID: DeviceID(), isDeleted: false, body: "{}")
        #expect(try await home.founder.push([future], group: home.group.id).rejected[future.id] == "unknown record type")
    }

    /// The same version sent again is taken and changes nothing. An older one
    /// is refused, and a tie goes to the higher device ID.
    @Test func lastWriterWinsAndAResendIsANoOp() async throws {
        let home = try await Household()
        let device = DeviceID()
        let spent = home.spend(-100, by: home.founderID)
        let first = try await home.founder.push([try wire(spent, budget: home.budget.id, lamport: 10, device: device)],
                                                group: home.group.id)
        let again = try await home.founder.push([try wire(spent, budget: home.budget.id, lamport: 10, device: device)],
                                                group: home.group.id)
        #expect(again.accepted == [spent.id])
        #expect(again.serverSeq == first.serverSeq, "nothing new was stored")

        let older = try await home.founder.push([try wire(spent, budget: home.budget.id, lamport: 9)],
                                                group: home.group.id)
        #expect(older.rejected[spent.id] == RecordEnvelope.olderVersionRefusal)

        let low = DeviceID(UUID(uuidString: "00000000-0000-4000-8000-000000000000")!)
        let high = DeviceID(UUID(uuidString: "FFFFFFFF-FFFF-4FFF-BFFF-FFFFFFFFFFFF")!)
        _ = try await home.founder.push([try wire(spent, budget: home.budget.id, lamport: 11, device: high)],
                                        group: home.group.id)
        let tie = try await home.founder.push([try wire(spent, budget: home.budget.id, lamport: 11, device: low)],
                                              group: home.group.id)
        #expect(tie.rejected[spent.id] == RecordEnvelope.olderVersionRefusal)
    }

    @Test func lamportValuesFarAheadOfTheGroupAreRefused() async throws {
        let home = try await Household()
        let spent = home.spend(-100, by: home.founderID)
        let ahead = try await home.founder.push([try wire(spent, budget: home.budget.id,
                                                          lamport: 2 + RecordEnvelope.lamportLead + 1)],
                                                group: home.group.id)
        #expect(ahead.rejected[spent.id] == RecordEnvelope.lamportTooFarAheadRefusal)
        let huge = try await home.founder.push([try wire(spent, budget: home.budget.id,
                                                         lamport: RecordEnvelope.lamportCeiling)],
                                               group: home.group.id)
        #expect(huge.rejected[spent.id] == RecordEnvelope.lamportTooLargeRefusal)
    }

    /// Deleting a group is final: nothing lands in it after.
    @Test func aDeletedGroupTakesNothingMore() async throws {
        let home = try await Household()
        var gone = home.group
        gone.isDeleted = true
        _ = try await home.founder.push([try wire(gone, lamport: 5)], group: home.group.id)
        #expect(try await home.founder.groups().first?.deleted == true)
        let late = home.spend(-100, by: home.founderID)
        let refused = try await home.founder.push([try wire(late, budget: home.budget.id, lamport: 6)],
                                                  group: home.group.id)
        #expect(refused.rejected[late.id] == InMemoryReadableServer.groupDeletedRefusal)
    }

    /// A member who joined "from now on" sees the group, its budgets and its
    /// people, and nothing stored before they joined. The cursor still
    /// reaches the end.
    @Test func aFromNowMemberPullsOnlyWhatCameAfterThem() async throws {
        let home = try await Household()
        let before = home.spend(-100, by: home.founderID)
        _ = try await home.founder.push([try wire(before, budget: home.budget.id, lamport: 3)], group: home.group.id)
        let (partner, _) = try await home.member("p@example.com", level: .write, history: .fromNow)
        let after = home.spend(-200, by: home.founderID)
        _ = try await home.founder.push([try wire(after, budget: home.budget.id, lamport: 4)], group: home.group.id)

        let page = try await partner.pull(group: home.group.id, since: 0, limit: 500)
        #expect(page.records.map(\.id) == [RecordID(home.group.id.uuid), RecordID(home.budget.id.uuid), after.id])
        #expect(page.serverSeq == 4)
        #expect(page.hasMore == false)

        let paged = try await home.founder.pull(group: home.group.id, since: 0, limit: 2)
        #expect(paged.records.count == 2 && paged.hasMore && paged.serverSeq == 2)
    }

    /// An invite speaks for its maker as they are now, and joining needs a
    /// confirmed address.
    @Test func invitesFollowTheirMakerAndNeedAConfirmedAddress() async throws {
        let home = try await Household()
        let (admin, adminID) = try await home.member("a@example.com", level: .admin)
        let invite = try await admin.createInvite(group: home.group.id, level: .write, history: .all, days: 7)
        #expect(try await admin.invites(in: home.group.id).map(\.id) == [invite.id])
        #expect(try await home.founder.previewInvite(token: invite.token).level == .write)

        let unconfirmed = home.server.client()
        _ = try await unconfirmed.signUp(email: "u@example.com", password: "joiner password", deviceLabel: nil)
        await #expect(throws: ReadableTransportError.http(status: 403,
                                                          reason: "confirm your email address before joining a group")) {
            try await unconfirmed.acceptInvite(token: invite.token)
        }
        try await unconfirmed.verifyEmail(code: try #require(home.server.lastCode(for: "u@example.com", purpose: .verify)))

        try await home.founder.remove(adminID, from: home.group.id)
        await #expect(throws: ReadableTransportError.http(status: 410, reason: "that invite is no longer valid")) {
            try await unconfirmed.acceptInvite(token: invite.token)
        }
        #expect(try await admin.groups().isEmpty, "a removed member no longer sees the group")
    }

    @Test func membersAreChangedOnlyByThoseWhoMay() async throws {
        let home = try await Household()
        let (manager, _) = try await home.member("m@example.com", level: .manage)
        let (_, writerID) = try await home.member("w@example.com", level: .write)
        try await manager.setLevel(.read, of: writerID, in: home.group.id)
        await #expect(throws: ReadableTransportError.http(status: 403, reason: "that needs admin")) {
            try await manager.setLevel(.manage, of: writerID, in: home.group.id)
        }
        await #expect(throws: ReadableTransportError.http(status: 403, reason: "the founder's level cannot change")) {
            try await manager.setLevel(.read, of: home.founderID, in: home.group.id)
        }
        let levels = Dictionary(uniqueKeysWithValues: try await home.founder.members(of: home.group.id)
            .map { ($0.userID, $0.level) })
        #expect(levels[writerID] == .read && levels[home.founderID] == .superadmin)
    }
}
