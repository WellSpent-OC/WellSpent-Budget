import Foundation
import WellSpentCrypto
import WellSpentModel
import WellSpentStore
import WellSpentSync

/// The one-time move of a group made before the switch: everything this
/// Mac holds of it goes up once, and then what arrived is checked.
///
/// The server kept every account, group and membership through the switch,
/// with the same IDs, but none of the records: those were sealed. So the
/// device that made each group sends it again, readably, and checks the
/// totals before, after, and on a fresh download of the server's copy.
/// Nothing local is ever deleted by the move.
public struct MoveCheck: Codable, Equatable, Sendable {
    public let group: GroupID
    /// This Mac's totals before the move, after it, and the server's.
    public let before: GroupTotals
    public let after: GroupTotals
    /// Nil for a member's move, which compares only this Mac's totals.
    public let server: GroupTotals?
    /// Whether the server kept the key past statements were fingerprinted
    /// with. When it did not, a statement imported again adds its lines again.
    public let importKeyMatched: Bool
    /// Entries other members own, left for each of them to send when they
    /// update. The server lets only an entry's owner store it first.
    public let awaitingOwners: Int
    /// Entries filed in this group under a budget of another group, which an
    /// import before 2026-10-02 could make. Neither server takes them, so
    /// they stay on this Mac only, and the totals compared leave them out.
    public let strandedEntries: Int
    public let matches: Bool
    public let attempts: Int
}

extension SyncCoordinator {
    /// Tries before a move that does not check out is marked done anyway,
    /// with its report kept. Nothing is lost either way.
    static let moveAttempts = 3

    static let notYourGroupsReason = """
        These budgets were made by a different WellSpent account, so this account cannot send \
        them. Nothing was changed. Sign in with the account that made them.
        """

    /// What each group's move found, as last checked.
    public var moveChecks: [GroupID: MoveCheck] {
        var checks: [GroupID: MoveCheck] = [:]
        for group in (try? store.groups(includeDeleted: true)) ?? [] {
            guard let stored = try? store.moveCheck(group.id),
                  let check = try? JSONDecoder().decode(MoveCheck.self, from: Data(stored.reportJSON.utf8))
            else { continue }
            checks[group.id] = check
        }
        return checks
    }

    /// The founder's move: give the server the group's old import key, queue
    /// everything this person may store, send it, and check.
    func moveAsCreator(_ group: GroupID, level: AccessLevel) async throws -> SyncReport {
        guard let userID else { throw Failure.notSignedIn }
        // The server kept the IDs, so the person it names as founder made
        // this group here. If not, this account is not the one that did.
        guard try store.foundingSubject(of: group) == userID else {
            throw Failure.server(Self.notYourGroupsReason)
        }
        let totals = try store.groupTotals(in: group)
        let before = Self.comparable(totals)
        // The key past imports used. A group with none gets one now, so the
        // server never ends up with no key and its members waiting for good.
        let localKey = try store.oldestGroupKey(group).flatMap { $0.count == 32 ? $0 : nil }
            ?? store.localKey(for: .group(group)).rawBytes
        let made = try await requireTransport().createGroup(id: group, importKey: localKey)
        try store.saveServerGroup(ServerGroupInfo(made))

        let resend = try store.prepareResend(of: group, scope: .everything, me: userID)
        let report = try await sync(group, level: made.level)
        let after = Self.comparable(try store.groupTotals(in: group))
        let server = try await serverTotals(of: group)
        try record(MoveCheck(group: group, before: before, after: after, server: server,
                             importKeyMatched: made.importKey == localKey,
                             awaitingOwners: resend.skipped, strandedEntries: Self.stranded(totals),
                             matches: before == after && after == server,
                             attempts: try nextAttempt(group)))
        return report
    }

    /// A member's move, once the founder's is done: take the founder's copy,
    /// and send this person's own entries, which only they may store.
    func adopt(_ listed: ServerGroup) async throws -> SyncReport {
        guard let userID else { throw Failure.notSignedIn }
        let totals = try store.groupTotals(in: listed.id)
        let before = Self.comparable(totals)
        try store.prepareResend(of: listed.id, scope: .ownRecords, me: userID)
        let report = try await sync(listed.id, level: listed.level)
        let after = Self.comparable(try store.groupTotals(in: listed.id))
        try record(MoveCheck(group: listed.id, before: before, after: after, server: nil,
                             importKeyMatched: try store.oldestGroupKey(listed.id).map { $0 == listed.importKey } ?? true,
                             awaitingOwners: 0, strandedEntries: Self.stranded(totals), matches: before == after,
                             attempts: try nextAttempt(listed.id)))
        return report
    }

    /// A fresh download of the server's copy, into a database of its own
    /// that is thrown away after.
    private func serverTotals(of group: GroupID) async throws -> GroupTotals {
        guard let userID else { throw Failure.notSignedIn }
        let scratch = Store(database: try WellSpentDatabase.inMemory())
        try scratch.placeholderGroup(group, name: "")
        let engine = ReadableSyncEngine(store: scratch, transport: try requireTransport(),
                                        clientID: DeviceID(), userID: userID)
        try await engine.pull(group: group)
        return Self.comparable(try scratch.groupTotals(in: group))
    }

    private func nextAttempt(_ group: GroupID) throws -> Int {
        (try store.moveCheck(group)?.attempts ?? 0) + 1
    }

    /// Saved, and the group marked moved once it checks out, or after the
    /// last try.
    private func record(_ check: MoveCheck) throws {
        let json = String(decoding: try JSONEncoder().encode(check), as: UTF8.self)
        try store.saveMoveCheck(StoredMoveCheck(groupID: check.group, attempts: check.attempts,
                                                matches: check.matches, reportJSON: json))
        if check.matches || check.attempts >= Self.moveAttempts {
            try store.markMoved(check.group)
        }
    }

    /// What can be compared with the server's copy. A deleted group sends
    /// only its delete, so only that it is deleted, and its name, count.
    /// Entries under another group's budget never reach a server, so they
    /// are left out (and counted as stranded).
    static func comparable(_ totals: GroupTotals) -> GroupTotals {
        guard !totals.groupDeleted else {
            return GroupTotals(groupName: totals.groupName, groupDeleted: true, budgets: [], receipts: 0,
                               statements: 0, profiles: 0)
        }
        var kept = totals
        kept.budgets = totals.budgets.filter { $0.name != nil }
        return kept
    }

    static func stranded(_ totals: GroupTotals) -> Int {
        totals.groupDeleted ? 0 : totals.budgets.filter { $0.name == nil }.map(\.transactionCount).reduce(0, +)
    }
}
