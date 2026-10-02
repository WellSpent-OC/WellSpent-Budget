import Foundation
import Crypto
import WellSpentCrypto

/// A server that behaves like the real one, in memory.
///
/// This is not only a test double. It enforces the same rules the Vapor server
/// enforces, which is the point: the authorisation logic is written once, here,
/// as an executable description of what the server must do. If a rule is wrong
/// here it is wrong there, and the sync tests catch it without a Postgres
/// instance.
///
/// Note what it never does: decrypt. It has no keys and no way to get them.
public final class InMemoryTransport: SyncTransport, @unchecked Sendable {
    private struct Stored {
        var envelope: RecordEnvelope
        var serverSeq: UInt64
    }

    private struct State {
        var records: [GroupID: [RecordID: Stored]] = [:]
        var logs: [GroupID: [MembershipLogEntry]] = [:]
        var keys: [GroupID: [WrappedKey]] = [:]
        var sequence: UInt64 = 0
        var refusals: [(RecordID, String)] = []
        var invites: [Data: StoredInvite] = [:]
        var people: [UserID: IdentityPublicKeys] = [:]
    }

    private struct StoredInvite {
        var terms: NewInvite
        var inviterUserID: UserID
        var acceptance: SealedAcceptance?
    }


    // Scoped locking, because `lock()` and `unlock()` cannot be called from an
    // async context under Swift 6 strict concurrency.
    private let lock = NSLock()
    private var state = State()

    private func withState<T>(_ body: (inout State) -> T) -> T {
        lock.withLock { body(&state) }
    }

    public init() {}

    // MARK: - Seeding

    public func seed(log: [MembershipLogEntry], for group: GroupID) {
        withState { $0.logs[group] = log }
    }

    public func seed(keys wrapped: [WrappedKey], for group: GroupID) {
        withState { $0.keys[group, default: []].append(contentsOf: wrapped) }
    }

    public func append(_ entry: MembershipLogEntry, to group: GroupID) {
        withState { $0.logs[group, default: []].append(entry) }
    }

    public var storedRecordCount: Int {
        withState { $0.records.values.reduce(0) { $0 + $1.count } }
    }

    public var refusals: [(RecordID, String)] {
        withState { $0.refusals }
    }

    /// Proof, in a test, that the server is holding ciphertext and nothing else.
    public func ciphertexts(in group: GroupID, ofType type: RecordType? = nil) -> [Data] {
        withState { state in
            (state.records[group] ?? [:]).values
                .filter { type == nil || $0.envelope.recordType == type }
                .map(\.envelope.ciphertext)
        }
    }

    // MARK: - SyncTransport

    public func push(_ envelopes: [RecordEnvelope], group: GroupID) async throws -> PushResult {
        withState { state in
            let membership = try? MembershipLog.replay(state.logs[group] ?? [], scope: .group(group))
            var accepted: [RecordID] = []
            var rejected: [RecordID: String] = [:]

            // Every record is judged on its own. One bad row must not take the
            // batch down with it, which is exactly what the old Ruby API did by
            // using `break` inside the loop.
            for envelope in envelopes {
                guard let membership else {
                    rejected[envelope.recordID] = "no membership log for this group"
                    continue
                }
                guard envelope.groupID == group else {
                    rejected[envelope.recordID] = "record is not in this group"
                    continue
                }
                // As on the real server: a value at or above the ceiling
                // would leave every app that pulled it no room on its clock.
                guard envelope.lamport < RecordEnvelope.lamportCeiling else {
                    rejected[envelope.recordID] = RecordEnvelope.lamportTooLargeRefusal
                    continue
                }
                let level = membership.level(of: envelope.authorUserID)
                guard level.allows(.write) else {
                    rejected[envelope.recordID] = "author holds \(level), needs write"
                    continue
                }
                guard let registration = membership.devices[envelope.authorDeviceID],
                      registration.userID == envelope.authorUserID else {
                    rejected[envelope.recordID] = "device is not enrolled for this author"
                    continue
                }
                guard let signing = try? registration.signingKey,
                      envelope.verifySignature(byDeviceKey: signing) else {
                    rejected[envelope.recordID] = "signature does not verify"
                    continue
                }
                // The group's own record uses the group's ID, and nothing else
                // may, as on the real server.
                guard (envelope.recordType == .groupMeta) == (envelope.recordID.uuid == group.uuid) else {
                    rejected[envelope.recordID] = "record ID does not match its type"
                    continue
                }
                // Deleting the group deletes it for everyone, so it takes the
                // founder or an admin, not just write.
                if envelope.recordType == .groupMeta, envelope.isDeleted,
                   !membership.mayDeleteGroup(envelope.authorUserID) {
                    rejected[envelope.recordID] = "only the founder or an admin can delete the group"
                    continue
                }
                // A budget takes a manager, as on the real server.
                if envelope.recordType == .budget, !level.allows(.manage) {
                    rejected[envelope.recordID] = "only a manager can change a budget"
                    continue
                }
                // A member profile sits on its sender's own ID, and nothing
                // else on an ID shaped like one, as on the real server.
                let profileIDIsWrong = envelope.recordType == .memberProfile
                    ? envelope.recordID != .memberProfile(group: group, user: envelope.authorUserID)
                    : envelope.recordID.isNameBased
                if profileIDIsWrong {
                    rejected[envelope.recordID] = "that ID belongs to a member profile"
                    continue
                }
                // This is where the real server checks the ceiling: after the
                // rules above. The same check near the top of this loop still
                // runs first, so an envelope that breaks the ceiling and one of
                // these rules gets a different reason from each server until
                // that earlier copy is removed.
                guard envelope.lamport < RecordEnvelope.lamportCeiling else {
                    rejected[envelope.recordID] = RecordEnvelope.lamportTooLargeRefusal
                    continue
                }
                // The real server finds a record by its ID alone, in any group,
                // and refuses one that does not match what it found.
                let stored = state.records.values.lazy
                    .compactMap { $0[envelope.recordID]?.envelope }.first
                if let stored, stored.groupID != group || stored.recordType != envelope.recordType {
                    rejected[envelope.recordID] = "another record already has this ID"
                    continue
                }
                // The stored version, sent again by the device that wrote it,
                // as after a lost reply. Taken as already stored, as on the
                // real server, and nothing changes.
                if let stored, stored.lamport == envelope.lamport,
                   stored.authorDeviceID == envelope.authorDeviceID,
                   stored.isDeleted == envelope.isDeleted {
                    accepted.append(envelope.recordID)
                    continue
                }
                // Last write wins, as on the real server, for every type. A
                // group's delete is final. Taking an older version here, as
                // this server once did for everything but the group record,
                // let tests pass that the real server would fail: the app
                // turns that refusal into a conflict copy and drops the row.
                if let stored,
                   !envelope.replaces(lamport: stored.lamport, device: stored.authorDeviceID,
                                      isDeleted: stored.isDeleted) {
                    // Only a group's delete is final. Any other record refused
                    // here is older, delete or not, and the app treats only
                    // that reason as one no later sync can change.
                    let reopens = stored.recordType == .groupMeta && stored.isDeleted && !envelope.isDeleted
                    rejected[envelope.recordID] = reopens
                        ? "the group has been deleted"
                        : RecordEnvelope.olderVersionRefusal
                    continue
                }

                state.sequence += 1
                state.records[group, default: [:]][envelope.recordID] =
                    Stored(envelope: envelope, serverSeq: state.sequence)
                accepted.append(envelope.recordID)
            }

            state.refusals.append(contentsOf: rejected.map { ($0.key, $0.value) })
            return PushResult(accepted: accepted, rejected: rejected, serverSeq: state.sequence)
        }
    }

    public func pull(group: GroupID, since: UInt64, limit: Int) async throws -> PullResult {
        withState { state in
            let all = (state.records[group] ?? [:]).values
                .filter { $0.serverSeq > since }
                .sorted { $0.serverSeq < $1.serverSeq }

            let page = Array(all.prefix(limit))
            return PullResult(
                envelopes: page.map(\.envelope),
                serverSeq: page.last?.serverSeq ?? since,
                hasMore: all.count > page.count
            )
        }
    }

    public func membershipLog(group: GroupID, since: UInt64) async throws -> [MembershipLogEntry] {
        withState { ($0.logs[group] ?? []).filter { $0.sequence >= since } }
    }

    public func wrappedKeys(group: GroupID, for user: UserID) async throws -> [WrappedKey] {
        // Group keys are addressed to a person. Budget keys are sealed under the
        // group key, so everyone who holds that gets them.
        withState { ($0.keys[group] ?? []).filter { $0.recipientUserID == nil || $0.recipientUserID == user } }
    }
}

// MARK: - Invites

/// Why the in-memory server refused an invite call.
public enum InviteFailure: Error, Equatable {
    case notFound, expired, alreadyAccepted
}

extension InMemoryTransport {
    /// A connection as one person. The in-memory server has no sign-in, and the
    /// invite calls need to know who is calling, the way the HTTP server learns it
    /// from a token.
    public func session(for user: UserID, keys: IdentityPublicKeys) -> InMemorySession {
        withState { $0.people[user] = keys }
        return InMemorySession(server: self, user: user)
    }

    func storeInvite(_ terms: NewInvite, by inviter: UserID) {
        withState { $0.invites[terms.id] = StoredInvite(terms: terms, inviterUserID: inviter) }
    }

    func lookup(_ id: Data) throws -> InviteLookup {
        let found: (StoredInvite, IdentityPublicKeys?)? = withState { state in
            state.invites[id].map { ($0, state.people[$0.inviterUserID]) }
        }
        guard let (invite, keys) = found, let keys else { throw InviteFailure.notFound }
        guard invite.terms.expiresAt > Date() else { throw InviteFailure.expired }
        return InviteLookup(group: invite.terms.group, level: invite.terms.level,
                            historyAccess: invite.terms.historyAccess,
                            inviterUserID: invite.inviterUserID, inviterKeys: keys,
                            expiresAt: invite.terms.expiresAt)
    }

    func accept(_ id: Data, sealed: SealedAcceptance) throws {
        let outcome: InviteFailure? = withState { state in
            guard let invite = state.invites[id] else { return .notFound }
            guard invite.terms.expiresAt > Date() else { return .expired }
            guard invite.acceptance == nil else { return .alreadyAccepted }
            state.invites[id]?.acceptance = sealed
            return nil
        }
        if let outcome { throw outcome }
    }

    func pendingInvites(in group: GroupID) -> [PendingInvite] {
        withState { state in
            state.invites.values.filter { $0.terms.group == group }.map {
                PendingInvite(id: $0.terms.id, level: $0.terms.level,
                              historyAccess: $0.terms.historyAccess,
                              expiresAt: $0.terms.expiresAt, acceptance: $0.acceptance)
            }
        }
    }

    func removeInvite(_ id: Data) {
        withState { $0.invites[id] = nil }
    }

    /// Every invite, for tests that check one was cleaned up.
    public var inviteCount: Int { withState { $0.invites.count } }
}

/// One person's connection to an `InMemoryTransport`.
public final class InMemorySession: InviteTransport, @unchecked Sendable {
    public let server: InMemoryTransport
    public let user: UserID

    init(server: InMemoryTransport, user: UserID) {
        self.server = server
        self.user = user
    }

    public func push(_ envelopes: [RecordEnvelope], group: GroupID) async throws -> PushResult {
        try await server.push(envelopes, group: group)
    }
    public func pull(group: GroupID, since: UInt64, limit: Int) async throws -> PullResult {
        try await server.pull(group: group, since: since, limit: limit)
    }
    public func membershipLog(group: GroupID, since: UInt64) async throws -> [MembershipLogEntry] {
        try await server.membershipLog(group: group, since: since)
    }
    public func wrappedKeys(group: GroupID, for user: UserID) async throws -> [WrappedKey] {
        try await server.wrappedKeys(group: group, for: user)
    }
    public func appendMembership(_ entry: MembershipLogEntry, group: GroupID,
                                 wrappedKeys: [WrappedKey]) async throws {
        server.append(entry, to: group)
        if !wrappedKeys.isEmpty { server.seed(keys: wrappedKeys, for: group) }
    }
    public func createInvite(_ invite: NewInvite) async throws {
        server.storeInvite(invite, by: user)
    }
    public func lookupInvite(id: Data) async throws -> InviteLookup {
        try server.lookup(id)
    }
    public func acceptInvite(id: Data, sealed: SealedAcceptance) async throws {
        try server.accept(id, sealed: sealed)
    }
    public func invites(in group: GroupID) async throws -> [PendingInvite] {
        server.pendingInvites(in: group)
    }
    public func deleteInvite(id: Data) async throws {
        server.removeInvite(id)
    }
    public func uploadKeys(_ keys: [WrappedKey], group: GroupID) async throws {
        server.seed(keys: keys, for: group)
    }
}
