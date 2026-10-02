import Foundation
import Crypto
import WellSpentCrypto
import WellSpentModel
import WellSpentStore

public enum SharingError: Error, Equatable {
    /// Inviting needs `manage`, and inviting someone at `manage` or above needs `admin`.
    case notAllowed(needed: AccessLevel)
    case badLink
    case alreadyAMember
}

/// Sharing a group, end to end, in three moves.
///
/// 1. The inviter makes a link (`createInvite`). The server gets a hash of its
///    secret and the terms. The secret stays on this device and in the link.
/// 2. The person who got the link answers it (`join`). Their answer carries their
///    public keys and is sealed with the secret, so only the inviter can open it,
///    and opening it proves it came from whoever got the link.
/// 3. The inviter's app, on its next sync, opens the answer and adds them
///    (`finishInvites`): a signed membership entry, and the group's keys sealed
///    to them.
///
/// Then the new member's own app registers its device in the group
/// (`prepare`), which is what lets other members accept what it writes.
public struct Sharing: Sendable {
    let store: Store
    let keyRing: KeyRing
    let transport: any InviteTransport
    let identity: IdentityKeyPair
    let device: DeviceKeyPair
    let userID: UserID

    /// How long a link works for.
    public static let linkLifetime: TimeInterval = 7 * 24 * 60 * 60

    public init(store: Store, keyRing: KeyRing, transport: any InviteTransport,
                identity: IdentityKeyPair, device: DeviceKeyPair, userID: UserID) {
        self.store = store
        self.keyRing = keyRing
        self.transport = transport
        self.identity = identity
        self.device = device
        self.userID = userID
    }

    // MARK: - 1. Invite

    public func createInvite(group: GroupID, groupName: String, level: AccessLevel,
                             historyAccess: HistoryAccess, inviterName: String,
                             now: Date = Date()) async throws -> InviteLink {
        let state = try await membership(of: group)
        let needed = Self.levelNeededToAdd(at: level)
        guard state.allows(userID, needed) else { throw SharingError.notAllowed(needed: needed) }

        let secret = InviteSecret()
        let expiresAt = now.addingTimeInterval(Self.linkLifetime)
        try await transport.createInvite(NewInvite(
            id: secret.id, group: group, level: level, historyAccess: historyAccess,
            expiresAt: expiresAt))
        try store.save(SentInvite(id: secret.id, groupID: group, secret: secret.bytes, level: level,
                                  historyAccess: historyAccess, expiresAt: expiresAt, createdAt: now))
        return InviteLink(secret: secret.bytes, groupName: groupName, inviterName: inviterName)
    }

    /// The same rule the membership log enforces, checked before a link is made
    /// rather than when the answer comes back.
    public static func levelNeededToAdd(at level: AccessLevel) -> AccessLevel {
        level >= .manage ? .admin : .manage
    }

    public func cancelInvite(_ id: Data) async throws {
        try? await transport.deleteInvite(id: id)
        try store.deleteSentInvite(id)
    }

    // MARK: - 2. Join

    /// Answers an invite. Until the inviter's app finishes it, the group shows as
    /// waiting, under the name the link gave it.
    ///
    /// `beforeComingBack` runs first when the group is one this Mac removed,
    /// before the answer is sent, so the caller can let go of what is still
    /// queued for it the way its next sync would have.
    @discardableResult
    public func join(_ link: InviteLink, displayName: String,
                     beforeComingBack: @Sendable (GroupID) async throws -> Void = { _ in })
        async throws -> PendingJoin {
        let secret: InviteSecret
        do { secret = try InviteSecret(bytes: link.secret) } catch { throw SharingError.badLink }

        let lookup = try await transport.lookupInvite(id: secret.id)
        guard lookup.inviterUserID != userID else { throw SharingError.alreadyAMember }
        if try store.group(lookup.group)?.isDeleted == true {
            try await beforeComingBack(lookup.group)
        }

        let sealed = try InviteCrypto.sealAcceptance(
            InviteAcceptance(accepterUserID: userID, accepterKeys: identity.publicKeys,
                             displayName: displayName),
            invite: lookup.invite(id: secret.id), secret: secret)
        // A group's ID is also its record's ID. On an ID this Mac already
        // holds as something else, such as a member's profile, the waiting
        // group hid that record here for good, and every later change to it
        // was ignored. The app picks random group IDs, so only a modified one
        // makes a link like this. Refused before the answer goes out.
        if let held = try store.holder(of: RecordID(lookup.group.uuid)), held.type != .groupMeta {
            throw SharingError.badLink
        }
        try await transport.acceptInvite(id: secret.id, sealed: sealed)

        let name = link.groupName.isEmpty ? "Shared group" : link.groupName
        let join = PendingJoin(groupID: lookup.group, groupName: name,
                               inviterName: link.inviterName, displayName: displayName,
                               level: lookup.level)
        try store.save(join)
        let existing = try store.group(lookup.group)
        if existing == nil || existing?.isDeleted == true {
            // A placeholder, so the group appears now. Never queued: the real
            // record arrives, encrypted, once they are in, and replaces it.
            //
            // A group this Mac removed on its own, by declining an invite or by
            // deleting it here only, comes back the same way. Its pulls start
            // again from the beginning, so what was deleted here is replaced by
            // the server's copy. Rows still queued from before the removal are
            // dropped too. They describe a group this Mac let go of, and a pull
            // would weigh them as this Mac's newest edits, so a record deleted
            // here could stay deleted while they sent it live to everyone else.
            // The app sends them first, through `beforeComingBack`, so only
            // what could not go is dropped here.
            if existing != nil {
                try store.forgetPulls(in: lookup.group)
                try store.clearOutbox(in: lookup.group)
            }
            try store.save(BudgetGroup(id: lookup.group, name: name), queue: false)
        }
        return join
    }

    // MARK: - 3. Finish

    /// Adds everyone who has answered one of this device's invites to `group`.
    /// Returns who was added. An answer that does not open was not sealed with
    /// the link's secret, so it is refused and the spoiled invite removed.
    ///
    /// So is one the server refuses to add. An answer is bound to the link's
    /// secret, not to an account, so whoever holds the link can answer with
    /// keys that are not their sign-up keys, someone else's ID, or an ID with
    /// no account. Thrown, the refusal stopped this Mac's sync of the group
    /// on every round until the link expired. A refusal that came because
    /// the log moved on while the add was on its way is not the answer's
    /// fault, so that invite stays for the next sync.
    @discardableResult
    public func finishInvites(group: GroupID, now: Date = Date()) async throws -> [InviteAcceptance] {
        var log = try await verifiedLog(of: group)
        guard !log.isEmpty else { return [] }
        var state = try MembershipLog.replay(log, scope: .group(group))
        guard state.allows(userID, .manage) else { return [] }

        var added: [InviteAcceptance] = []
        for pending in try await transport.invites(in: group) {
            // Made on another device: that device holds the secret.
            guard let sent = try store.sentInvite(pending.id) else { continue }

            if pending.expiresAt <= now {
                try await cancelInvite(pending.id)
                continue
            }
            guard let sealed = pending.acceptance else { continue }

            let invite = Invite(id: sent.id, scope: .group(group), level: sent.level,
                                historyAccess: sent.historyAccess, inviterUserID: userID,
                                inviterKeys: identity.publicKeys, expiresAt: sent.expiresAt)
            guard let acceptance = try? InviteCrypto.openAcceptance(
                sealed, invite: invite, secret: try InviteSecret(bytes: sent.secret), inviter: identity)
            else {
                try await cancelInvite(pending.id)
                continue
            }
            // Other keys are already on this person's ID, and someone has
            // signed with them, so the add would be refused on every sync.
            // The invite goes instead, and the rest of the sync goes on.
            if let held = state.keys[acceptance.accepterUserID], held != acceptance.accepterKeys,
               state.signers.contains(acceptance.accepterUserID) {
                try await cancelInvite(pending.id)
                continue
            }
            guard state.level(of: acceptance.accepterUserID) == AccessLevel.none,
                  (try? acceptance.accepterKeys.signingKey) != nil,
                  (try? acceptance.accepterKeys.kemKey) != nil else {
                try await cancelInvite(pending.id)
                continue
            }
            guard state.allows(userID, Self.levelNeededToAdd(at: sent.level)) else { continue }
            // Nobody is added to a group this Mac has let go of. The invite
            // stays open, and letting go of the group cancels it. What a
            // member added "from now on" is owed is read now, before the add
            // goes out, because the group can be removed from this Mac while
            // it is on its way.
            guard let owed = try store.liveBudgets(ifLive: group) else { break }

            let (epoch, keys, fresh) = try keysForNewMember(acceptance, group: group, state: state,
                                                            history: sent.historyAccess)
            let entry = try MembershipLogEntry.signed(
                scope: .group(group), sequence: UInt64(log.count), previousHash: state.head,
                action: .add, subjectUserID: acceptance.accepterUserID,
                subjectKeys: acceptance.accepterKeys, level: sent.level, epochAfter: epoch,
                author: identity, authorUserID: userID)
            do {
                try await transport.appendMembership(entry, group: group, wrappedKeys: keys)
            } catch where Self.isRefusal(error) {
                guard try await verifiedLog(of: group).count == log.count else { break }
                try await cancelInvite(pending.id)
                continue
            }
            // Kept only now the server has the entry. A held key is never
            // replaced, so keys for an epoch that never started would keep
            // out the ones that did. The entry is kept too, as the founding
            // one is: a server that left it out of later reads could get a
            // second "from now on" invite to start the same epoch again.
            try store.append(entry, in: group)
            for key in fresh { try keyRing.remember(key) }
            try await cancelInvite(pending.id)
            if sent.historyAccess == .fromNow { try resealStructure(of: group, budgets: owed) }

            log.append(entry)
            state = try MembershipLog.replay(log, scope: .group(group))
            added.append(acceptance)
        }
        return added
    }

    /// Whether a server turned a request down, as opposed to not being
    /// reached or failing on its side. Signing in again, or waiting out a
    /// limit, is not a refusal of the request itself.
    static func isRefusal(_ error: any Error) -> Bool {
        if error is ServerRefused { return true }
        guard case HTTPTransport.Failure.http(let status, _) = error else { return false }
        return (400 ..< 500).contains(status) && status != 401 && status != 429
    }

    /// The keys a new member gets.
    ///
    /// `.all`: every group key this device holds, sealed to them, and every budget
    /// key sealed under the group key of its epoch. They read everything.
    ///
    /// `.fromNow`: a new epoch first. Fresh group and budget keys, sealed to every
    /// member including them. They hold nothing older, so they read nothing older.
    /// The fresh keys come back too, for the caller to keep once the server has
    /// taken the entry.
    private func keysForNewMember(_ acceptance: InviteAcceptance, group: GroupID,
                                  state: MembershipState,
                                  history: HistoryAccess) throws -> (Epoch, [WrappedKey], [ScopedKey]) {
        let budgets = try store.budgets(in: group, includeDeleted: true).map(\.id)

        switch history {
        case .fromNow:
            var members = state.members.compactMap { id in state.keys[id].map { (userID: id, keys: $0) } }
            members.append((userID: acceptance.accepterUserID, keys: acceptance.accepterKeys))
            let epoch = state.epoch.next
            let rotation = try keyRing.rotate(group: group, budgets: budgets, to: epoch, members: members)
            return (epoch, rotation.wrapped, rotation.keys)

        case .all:
            var wrapped: [WrappedKey] = []
            for groupKey in try store.cachedKeys(scope: .group(group)) {
                wrapped.append(try KeyWrap.wrapToIdentity(
                    groupKey, recipient: acceptance.accepterKeys,
                    recipientUserID: acceptance.accepterUserID,
                    sender: identity, senderUserID: userID))
                for budget in budgets {
                    guard keyRing.has(scope: .budget(budget), epoch: groupKey.epoch) else { continue }
                    let budgetKey = try keyRing.key(for: .budget(budget), epoch: groupKey.epoch)
                    wrapped.append(try KeyWrap.wrapUnderGroupKey(
                        budgetKey, groupKey: groupKey.material, senderUserID: userID))
                }
            }
            return (state.epoch, wrapped, [])
        }
    }

    /// "From now on" hides past transactions, not the group itself. The group and
    /// its budgets were sealed under the old key, so a new member could not see
    /// them, and their own transactions would have no budget to belong to. Queuing
    /// them again seals them under the new key on the next push. The rows are
    /// marked as carrying no edit, so a newer edit pulled before that push wins
    /// over them and goes out in their place, rather than being sent over. They
    /// are queued live even if the group was removed from this Mac during the
    /// add: it is still live for everyone else, so letting go of it sends them.
    private func resealStructure(of group: GroupID, budgets: [BudgetID]) throws {
        try store.queueReseal(of: group, budgets: budgets)
    }

    // MARK: - Before each sync of a shared group

    /// Two things a shared group needs before records move.
    ///
    /// This device must be registered in the group, or every member refuses what
    /// it signs. The founder's device is registered by the founding entry; anyone
    /// who joined registers their own here.
    ///
    /// A budget this device added to a shared group needs a key the others can
    /// get. It is minted here and published sealed under the group key. Only for
    /// budgets that have never synced: a budget someone else made gets its key
    /// from them, and minting a second one would split it in two. Only a
    /// manager adds budgets, so nobody else mints one, and the server refuses
    /// a key from anyone else.
    public func prepare(group: GroupID) async throws {
        let log = try await verifiedLog(of: group)
        guard !log.isEmpty else { return }
        let state = try MembershipLog.replay(log, scope: .group(group))
        guard state.allows(userID, .read) else { return }

        if state.device(device.id, of: userID) == nil {
            let entry = try MembershipLogEntry.signed(
                scope: .group(group), sequence: UInt64(log.count), previousHash: state.head,
                action: .addDevice, subjectUserID: userID, subjectKeys: nil,
                level: state.level(of: userID), epochAfter: state.epoch,
                deviceID: device.id, devicePublicKey: device.publicKey,
                author: identity, authorUserID: userID)
            try await transport.appendMembership(entry, group: group, wrappedKeys: [])
        }

        guard state.members.count > 1, state.allows(userID, .manage) else { return }
        try keyRing.absorb(try await transport.wrappedKeys(group: group, for: userID),
                           in: group, membership: state)
        guard keyRing.has(scope: .group(group), epoch: state.epoch) else { return }
        let groupKey = try keyRing.key(for: .group(group), epoch: state.epoch)

        var fresh: [WrappedKey] = []
        for budget in try store.budgets(in: group) {
            guard !keyRing.has(scope: .budget(budget.id), epoch: state.epoch),
                  try store.recordVersion(RecordID(budget.id.uuid)) == nil else { continue }
            let key = ScopedKey.generate(scope: .budget(budget.id), epoch: state.epoch)
            try keyRing.remember(key)
            fresh.append(try KeyWrap.wrapUnderGroupKey(key, groupKey: groupKey.material,
                                                       senderUserID: userID))
        }
        if !fresh.isEmpty { try await transport.uploadKeys(fresh, group: group) }
    }

    /// After a sync: once a group this person asked to join has let them in,
    /// write the name they chose as their member profile and stop waiting.
    /// Returns true when it did, so the caller can sync once more to send it.
    public func completeJoin(group: GroupID) async throws -> Bool {
        guard let join = try store.pendingJoin(group) else { return false }
        let log = try await transport.membershipLog(group: group, since: 0)
        guard !log.isEmpty,
              try MembershipLog.replay(log, scope: .group(group)).allows(userID, .read) else { return false }
        // Turned down while the log was being read, so there is no name to write.
        guard try store.pendingJoin(group) != nil else { return false }
        try store.save(MemberProfile(groupID: group, userID: userID, displayName: join.displayName))
        try store.deletePendingJoin(group)
        return true
    }

    // MARK: -

    private func membership(of group: GroupID) async throws -> MembershipState {
        try MembershipLog.replay(try await transport.membershipLog(group: group, since: 0),
                                 scope: .group(group))
    }
}
