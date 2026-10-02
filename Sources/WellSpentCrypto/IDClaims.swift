import Foundation

/// What already uses an ID, in any group.
///
/// Groups, records, and budgets whose keys have been published share one space
/// of IDs. A server finds rows by ID alone, and an app that holds something
/// under an ID ignores anything else that arrives on it, so whichever group uses
/// an ID first keeps it. Every server fills this in from what it stores and asks
/// it the same questions, so the rules cannot drift between them.
public struct IDClaims: Sendable {
    public struct Record: Sendable, Equatable {
        public let group: UUID
        public let type: RecordType
        public init(group: UUID, type: RecordType) {
            self.group = group
            self.type = type
        }
    }

    /// A group has this ID.
    public var isGroup = false
    /// The record stored on this ID, if there is one.
    public var records: [Record] = []
    /// The groups that published a budget key under this ID.
    public var budgetKeys: Set<UUID> = []

    public init() {}

    /// Whether a new group may take this ID: nothing uses it, and it is not
    /// shaped like a member profile's. A group founded on someone's profile ID,
    /// or a record's, hid that record on the Mac of everyone who answered the
    /// group's link.
    public func areFree(forGroup id: UUID) -> Bool {
        !RecordID(id).isNameBased && !isGroup && records.isEmpty && budgetKeys.isEmpty
    }

    /// Whether `group` may publish a key for a budget on this ID: nothing uses
    /// it except that group's own budget. A key for another group's budget took
    /// that budget over on the Macs of people in both groups.
    public func areFree(forBudgetIn group: UUID, id: UUID) -> Bool {
        !RecordID(id).isNameBased && !isGroup
            && records.allSatisfy { $0.group == group && $0.type == .budget }
            && budgetKeys.isSubset(of: [group])
    }

    /// Whether a new record of `type` may be stored on this ID in `group`. A
    /// budget's key is published before its record is pushed, and the ID it
    /// showed let a member of another group push a record there first. The
    /// budget was then refused on every sync.
    public func areFree(forRecordOf type: RecordType, in group: UUID, id: UUID) -> Bool {
        (!isGroup || id == group)
            && budgetKeys.isSubset(of: [group])
            && (budgetKeys.isEmpty || type == .budget)
    }
}

extension WrappedKey {
    /// Why a server should not store this key in `group`, or nil when it may.
    /// The caller has already checked that `sender` may manage the group.
    ///
    /// Every member's app opens the keys a server hands out, and seals and
    /// opens records with them, so a key from the wrong person or for the wrong
    /// thing changes what other members' Macs can read. A key must come from
    /// the person sending it, for an epoch the group has reached, and be one of
    /// two kinds. A group key for this group, sealed to one of its members,
    /// travels only with a membership entry (`sealedToPeople`). A budget key,
    /// sealed under the group key, is for a budget no other group uses; `claims`
    /// says who uses its ID.
    ///
    /// A later epoch is refused because a server keeps only the first key for
    /// each scope, epoch and recipient. One stored ahead of time would win over
    /// the keys a real rotation hands out. For the same reason a budget key
    /// comes only from someone who holds that epoch's group key
    /// (`senderHoldsGroupKey`): a manager who joined "from now on" could fill
    /// an older epoch's empty slot with junk, and the real key sent later was
    /// dropped.
    public func refusal(in group: GroupID, sealedToPeople: Bool, sender: UserID,
                        state: MembershipState, claims: IDClaims?,
                        senderHoldsGroupKey: Bool) -> String? {
        switch (wrapKind, scope) {
        case (.hpkeToIdentity, .group(let id)) where sealedToPeople:
            guard id == group, let recipientUserID, state.level(of: recipientUserID) > .none else {
                return "a group key goes only to a member of this group"
            }
        case (.aesUnderGroupKey, .budget(let budget)) where recipientUserID == nil:
            guard let claims, claims.areFree(forBudgetIn: group.uuid, id: budget.uuid) else {
                return "another record or group already uses that budget's ID"
            }
            guard senderHoldsGroupKey else {
                return "a budget key comes only from someone who holds that epoch's group key"
            }
        default:
            return sealedToPeople ? "that kind of key is not handed out here"
                                  : "only budget keys sealed under the group key"
        }
        guard senderUserID == sender else { return "a key must come from the person sending it" }
        guard epoch <= state.epoch else { return "the group has not reached that key's epoch" }
        return nil
    }
}

extension MembershipLog {
    /// Whether `user` holds `group`'s key for `epoch`, as far as a server can
    /// tell without opening any key. `log` is the group's log, ending with
    /// `requestEntry` when keys travel with an entry. `sentNow` are the keys
    /// in the same request and `stored` the ones the server holds.
    ///
    /// The founder made the first key. Otherwise the key must be sealed to
    /// them: by someone else, or by themselves only when they started that
    /// epoch. A server cannot open a key, so one a manager sealed to herself
    /// in the same request, for an epoch she was not starting, counted, and
    /// let her fill an old epoch's empty budget-key slot with junk.
    public static func holdsGroupKey(_ user: UserID, of group: GroupID, at epoch: Epoch,
                                     log: [MembershipLogEntry], requestEntry: MembershipLogEntry?,
                                     sentNow: [WrappedKey], stored: [WrappedKey]) -> Bool {
        let starter = entryStarting(epoch, in: log)
        if epoch == .initial, starter?.action == .found, starter?.authorUserID == user { return true }
        func sealedToThem(_ key: WrappedKey) -> Bool {
            key.wrapKind == .hpkeToIdentity && key.scope == .group(group) && key.epoch == epoch
                && key.recipientUserID == user
        }
        if let requestEntry, starter == requestEntry, sentNow.contains(where: sealedToThem) { return true }
        return stored.contains { sealedToThem($0) && ($0.senderUserID != user || starter?.authorUserID == user) }
    }

    /// The entry that moved the group to `epoch`: the founding entry for the
    /// first one, otherwise the first entry that changed the epoch to it.
    /// Only entries that move the epoch count. The first entry merely naming
    /// an epoch was taken as its start, and a device entry, which needs only
    /// View, could name the next one before anyone started it.
    static func entryStarting(_ epoch: Epoch, in log: [MembershipLogEntry]) -> MembershipLogEntry? {
        var current: Epoch?
        for entry in log where entry.action != .addDevice && entry.epochAfter != current {
            if entry.epochAfter == epoch { return entry }
            current = entry.epochAfter
        }
        return nil
    }
}
