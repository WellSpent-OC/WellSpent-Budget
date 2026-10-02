import Foundation
import Crypto
import WellSpentCrypto
import WellSpentModel
import WellSpentStore

/// One round of syncing for one group: seal what is queued, send it, take what
/// came back, and merge.
///
/// Two rules shape everything here.
///
/// First, pull before push. Taking other people's changes first means our Lamport
/// clock has already moved past theirs when we seal, so our writes sort after the
/// state we actually saw rather than colliding with it.
///
/// Second, nothing is ever silently dropped. A record that loses a conflict is
/// kept as a conflict copy. A record we cannot decrypt is counted and left on the
/// server rather than skipped past, because the key for its epoch may still be on
/// its way.
public actor SyncEngine {
    private let store: Store
    private let keyRing: KeyRing
    private let transport: any SyncTransport
    private let identity: IdentityKeyPair
    private let device: DeviceKeyPair
    private let userID: UserID
    /// Records whose pulled version this round could not save, or cannot
    /// read. Their queued rows wait rather than go out over that version.
    private var heldBack: Set<RecordID> = []
    /// The most records of a type or format this build cannot read that are
    /// kept from one sender in one group, waiting for an update. Past it,
    /// another such record from them is passed over like a refused one, and
    /// the pull moves on.
    static let setAsideLimit = 10_000

    public init(store: Store, keyRing: KeyRing, transport: any SyncTransport,
                identity: IdentityKeyPair, device: DeviceKeyPair, userID: UserID) {
        self.store = store
        self.keyRing = keyRing
        self.transport = transport
        self.identity = identity
        self.device = device
        self.userID = userID
    }

    @discardableResult
    public func sync(group: GroupID) async throws -> SyncReport {
        var report = SyncReport()
        heldBack = []

        let membership = try await refreshMembership(group: group)
        guard membership.allows(userID, .read) else { throw SyncError.notAMember(group) }

        try await pullKeys(group: group, membership: membership)
        report = try await pull(group: group, membership: membership, into: report)

        if membership.allows(userID, .write) {
            report = try await push(group: group, membership: membership, into: report)
        }

        return report
    }

    /// The group's access history: what this device already holds and has
    /// verified, plus whatever the server adds to the end of it.
    public func membership(of group: GroupID) async throws -> MembershipState {
        try await refreshMembership(group: group)
    }

    /// Sends what is queued for a group without taking anything in first. For
    /// a group this Mac is letting go of whose pull keeps failing, so what it
    /// owes others still goes out once.
    ///
    /// Plain re-seal rows are left out. With no pull they cannot be weighed
    /// against newer versions, and would send this Mac's old copy over another
    /// member's newer edit, with no copy of that edit kept anywhere. The cost:
    /// a member added "from now on" cannot read that record until someone next
    /// edits it, because the re-seal under the new key never goes. A row with
    /// this person's own edit on top of a re-seal still goes, sent unweighed at
    /// its fresh value, as every row did here before: the edit is theirs, and
    /// removing a group from this Mac promises their unsent edits still go.
    public func pushWithoutPulling(group: GroupID) async throws -> SyncReport {
        let membership = try await refreshMembership(group: group)
        guard membership.allows(userID, .write) else { return SyncReport() }
        try await pullKeys(group: group, membership: membership)
        return try await push(group: group, membership: membership, into: SyncReport(),
                              leavingReseals: true)
    }

    /// Sends a group's delete, and whatever else is queued for it, without
    /// taking anything in first.
    ///
    /// For a group deleted on this Mac. A pull would write other members' newer
    /// edits over the delete, so the group would come back here and nowhere
    /// else. Nothing is sent, and the answer is nil, unless this person may
    /// delete the group for everyone. That is judged on the same verified
    /// history the push is sealed with.
    public func pushDelete(group: GroupID) async throws -> SyncReport? {
        let membership = try await refreshMembership(group: group)
        guard membership.mayDeleteGroup(userID) else { return nil }
        try await pullKeys(group: group, membership: membership)
        return try await push(group: group, membership: membership, into: SyncReport())
    }

    // MARK: - Membership

    /// Fetch, verify and store the access history.
    ///
    /// The verification is the point. The server hands over a list and the client
    /// replays it, checking the hash chain and every signature. A server that
    /// rewrites who had what level fails here rather than being believed.
    private func refreshMembership(group: GroupID) async throws -> MembershipState {
        let known = try store.membershipLog(for: group)
        let since = UInt64(known.count)
        let incoming = try await transport.membershipLog(group: group, since: since)

        let combined = known + incoming.filter { $0.sequence >= since }
        guard !combined.isEmpty else { throw SyncError.notAMember(group) }

        let state: MembershipState
        do {
            state = try MembershipLog.replay(combined, scope: .group(group))
        } catch {
            throw SyncError.membershipRefused(String(describing: error))
        }

        for entry in incoming where entry.sequence >= since {
            try store.append(entry, in: group)
        }
        return state
    }

    private func pullKeys(group: GroupID, membership: MembershipState) async throws {
        let wrapped = try await transport.wrappedKeys(group: group, for: userID)
        guard !wrapped.isEmpty else { return }
        try keyRing.absorb(wrapped, in: group, membership: membership)
    }

    // MARK: - Pull

    private func pull(group: GroupID, membership: MembershipState,
                      into report: SyncReport) async throws -> SyncReport {
        var report = report
        var cursor = try store.syncState(for: group).serverSeq
        var highestLamport = try store.syncState(for: group).lamport

        var more = true
        while more {
            let page = try await transport.pull(group: group, since: cursor, limit: 200)
            more = page.hasMore
            cursor = page.serverSeq
            report.serverSeq = page.serverSeq
            report.pulled += page.envelopes.count

            for envelope in page.envelopes {
                // Everything here is judged against this group's members. An
                // envelope that names another group would be judged by the
                // wrong ones, so it is refused, as the server refuses to store
                // one. This looks at the envelope only, not at the record
                // sealed inside it.
                guard envelope.groupID == group else {
                    report.ignored += 1
                    continue
                }
                // A server refuses a Lamport value at or above the ceiling, so
                // this came from one that did not. Taken in, it would leave
                // this Mac's clock no room to grow. It is ignored, and kept
                // out of the clock.
                guard envelope.lamport < RecordEnvelope.lamportCeiling else {
                    report.ignored += 1
                    continue
                }
                highestLamport = max(highestLamport, envelope.lamport)
                do {
                    switch try apply(envelope, membership: membership, serverSeq: page.serverSeq) {
                    case .applied:  report.applied += 1
                    case .conflict: report.conflicts += 1
                    case .echo:     report.echoes += 1
                    case .ignored:  report.ignored += 1
                    case .deferred: report.deferred += 1
                    case .undecryptable: report.undecryptable += 1
                    case .unsaved: report.unsaved += 1
                    }
                } catch SyncError.noKeyForEpoch {
                    // Expected, and not an error. Either the key is still on its
                    // way, or this record predates our joining with `.fromNow`.
                    report.undecryptable += 1
                } catch EnvelopeError.wrongScopeKey {
                    report.undecryptable += 1
                }
            }

            if page.envelopes.isEmpty { more = false }
        }

        // Once per pull, after it: a transaction set aside because its budget
        // had not arrived usually finds it later in the same pull, and a record
        // an older build set aside is applied now this one can read it.
        report = try replayDeferred(group: group, membership: membership, into: report)
        try store.recordPull(group: group, serverSeq: cursor, observedLamport: highestLamport)
        return report
    }

    /// Records set aside, applied now that they can be: ones an older build of
    /// this app could not read, and transactions that arrived before their
    /// budget. One that still cannot be applied stays, untouched: a type or a
    /// format this build cannot read, or a transaction whose budget is still
    /// missing.
    ///
    /// A record that stays because this build cannot read it, or because a
    /// retry failed, is held back from the push too. A queued re-seal of it
    /// would otherwise send this Mac's older content over the version that
    /// waits here, on every Mac.
    ///
    /// A row leaves only once it has been dealt with. It was deleted first,
    /// and a failure in between lost it with nothing counted.
    private func replayDeferred(group: GroupID, membership: MembershipState,
                                into report: SyncReport) throws -> SyncReport {
        var report = report
        for (envelope, serverSeq) in try store.deferredEnvelopes(in: group) {
            guard envelope.recordType.isKnown, envelope.version == RecordEnvelope.currentVersion else {
                heldBack.insert(envelope.recordID)
                continue
            }
            if envelope.recordType == .transaction, let budget = envelope.budgetID,
               try store.budget(budget) == nil {
                continue
            }
            // Set aside earlier in this same pull because it could not be
            // saved: tried again on the next one.
            if heldBack.contains(envelope.recordID) { continue }
            let outcome: ApplyOutcome
            do {
                outcome = try apply(envelope, membership: membership, serverSeq: serverSeq)
            } catch {
                // Its key has not arrived yet, or this pull cannot settle it
                // for another reason. It stays, for a later pull, and its
                // queued row waits with it.
                report.undecryptable += 1
                heldBack.insert(envelope.recordID)
                continue
            }
            switch outcome {
            case .applied: report.applied += 1
            case .conflict: report.conflicts += 1
            case .ignored: report.ignored += 1
            case .undecryptable: report.undecryptable += 1
            case .unsaved: report.unsaved += 1
            case .echo, .deferred: break
            }
            // Set aside again by apply when it is still not ready, or still
            // cannot be saved, so it stays.
            if outcome != .deferred && outcome != .unsaved {
                try store.deleteDeferredEnvelope(envelope.recordID)
            }
        }
        return report
    }

    enum ApplyOutcome {
        case applied
        case conflict
        /// Our own record coming back. Already local, nothing to do.
        case echo
        /// Set aside: a type this build cannot read yet, for after an update,
        /// or a transaction whose budget has not arrived yet.
        case deferred
        /// Refused: a bad signature, an unenrolled device, an author who is no
        /// longer allowed to write, or contents that do not decode.
        case ignored
        /// Signed by someone allowed to write, and does not open with the key
        /// this Mac holds for its epoch.
        case undecryptable
        /// Passed every check, and this Mac's database would not save it, for
        /// a reason that will repeat. Set aside, to be tried again.
        case unsaved
    }

    private func apply(_ envelope: RecordEnvelope, membership: MembershipState,
                       serverSeq: UInt64) throws -> ApplyOutcome {
        // Our own record coming back, already here. Unless this Mac has since
        // forgotten it: a group brought back after being removed here only is
        // pulled again from the start with no versions on file, and its own
        // records have to be written again like anyone else's. Ours means
        // this person on this device: someone else can register this
        // device's ID as their own, and what they signed under it was
        // skipped here as if this Mac had sent it.
        if envelope.authorDeviceID == device.id, envelope.authorUserID == userID,
           try store.recordVersion(envelope.recordID) != nil || store.isQueued(envelope.recordID) {
            return .echo
        }
        // The group's own record uses the group's ID, and nothing else may. The
        // server refuses anything else, so this came from a server that did not.
        guard (envelope.recordType == .groupMeta) == (envelope.recordID.uuid == envelope.groupID.uuid) else {
            return .ignored
        }
        let authorLevel = membership.level(of: envelope.authorUserID)
        guard authorLevel.allows(.write) else {
            // Someone who kept the key after being demoted. Honest peers ignore it.
            return .ignored
        }
        // The signing key comes from the membership log's device registry, not
        // from the envelope. A revoked laptop is simply no longer in there, so
        // anything it signs from now on is ignored.
        guard let registration = membership.device(envelope.authorDeviceID, of: envelope.authorUserID),
              registration.userID == envelope.authorUserID,
              let signingKey = try? registration.signingKey else {
            return .ignored
        }

        // A type a newer version of the app makes, or a format it writes, is
        // kept rather than dropped: the pull cursor moves past it now, so once
        // an update teaches this build to read it, `replayDeferred` applies it
        // from here. Only from someone who may write, signed when the format
        // is one this build knows, and only so many from each sender, or any
        // member or a server that lies could fill this Mac with them. Counted
        // per sender, one member at Add cannot use up the room other members'
        // records need.
        if !envelope.recordType.isKnown || envelope.version != RecordEnvelope.currentVersion {
            if envelope.version == RecordEnvelope.currentVersion,
               !envelope.verifySignature(byDeviceKey: signingKey) {
                return .ignored
            }
            guard try store.unreadableCount(in: envelope.groupID, from: envelope.authorUserID,
                                            except: envelope.recordID) < Self.setAsideLimit else {
                return .ignored
            }
            try store.deferEnvelope(envelope, serverSeq: serverSeq, unreadable: true)
            return .deferred
        }

        let scope: KeyScope = envelope.budgetID.map { .budget($0) } ?? .group(envelope.groupID)
        let key = try keyRingKey(scope: scope, epoch: envelope.keyEpoch)

        // A record that cannot be opened is counted and passed over. Thrown,
        // it stopped the pull before the cursor moved, so the same record
        // stopped every later sync of the group, for every member, for good.
        let payload: Data
        do {
            payload = try RecordCodec.openData(from: envelope, scopeKey: key,
                                               deviceKey: signingKey, authorLevel: authorLevel)
        } catch EnvelopeError.badSignature, EnvelopeError.unsupportedVersion, EnvelopeError.authorNotEntitled {
            return .ignored
        } catch {
            // The seal does not open with the key this Mac holds for its
            // epoch: sealed under another key, or not sealed properly at all.
            return .undecryptable
        }

        // Everything above judged the envelope. What gets saved is the record
        // sealed inside it, under the IDs it carries itself.
        guard try belongsHere(payload, envelope: envelope) else { return .ignored }

        // The server checks that the author may write at all. Whose record it is
        // can only be checked here, because only members can read the payload.
        guard let payload = try authorised(payload, envelope: envelope,
                                           authorLevel: authorLevel, membership: membership) else {
            return .ignored
        }

        // A transaction is saved under its budget, so the budget must be here
        // first. Pulled from the start, a budget edited since sorts after its
        // own transactions, and saving one before it failed the whole pull.
        // Set aside, it is applied once the budget is in, usually at the end
        // of this same pull.
        if envelope.recordType == .transaction, let budget = envelope.budgetID,
           try store.budget(budget) == nil {
            try store.deferEnvelope(envelope, serverSeq: serverSeq)
            return .deferred
        }

        // A save this Mac's database refuses for a reason that will repeat,
        // a constraint, is set aside and counted, and the pull goes on.
        // Thrown, it stopped the pull before the cursor moved, so the group
        // stopped syncing here for good. Its queued row stays out of this
        // round's push: the failed save also undid moving a re-seal above
        // the newer version, and sending it would put this Mac's old content
        // over that version on every Mac. Anything else, such as a full
        // disk, is thrown as before, so the pull stops before its cursor
        // moves and the record comes again once it can be saved.
        let outcome: ApplyOutcome
        do {
            outcome = try store.inOneTransaction { store in
                try settle(envelope, payload: payload, membership: membership,
                           serverSeq: serverSeq, in: store)
            }
        } catch where Store.isLastingFailure(error) {
            try store.deferEnvelope(envelope, serverSeq: serverSeq)
            heldBack.insert(envelope.recordID)
            return .unsaved
        }
        // A copy of this record set aside earlier is older than this one, or
        // is this one. Applied later, it would only come back as a conflict.
        try store.deleteDeferredEnvelope(envelope.recordID)
        return outcome
    }

    /// Weighs an incoming record against what this Mac holds, and keeps the
    /// winner, as one database transaction. A save made on this Mac while it
    /// runs lands before it or after it, never in the middle, so the record
    /// written is the one that was weighed.
    nonisolated private func settle(_ envelope: RecordEnvelope, payload: Data,
                                    membership: MembershipState, serverSeq: UInt64,
                                    in store: Store) throws -> ApplyOutcome {
        // Last write wins, by the same rule the server applies. A group's
        // delete is final, so it is compared with whether this Mac holds the
        // group as deleted. That holds with no version on file too: a waiting
        // group declined here was never pulled, and the inviter's live record
        // must not bring it back.
        let groupIsDeletedHere = try envelope.recordType == .groupMeta
            && store.group(envelope.groupID)?.isDeleted == true
        // An edit made here, still queued, that this Mac will send, is the
        // version it holds. It is also what the server will weigh against
        // this envelope, so the same rule decides between them here. Any
        // other queued row gives way, and the version on file decides as
        // before: a row that only seals the record again under a new key, and
        // a row this Mac will never send. Letting those win kept other
        // members' newer edits out, and a re-seal then sent the old text over
        // them on every Mac. An edit with a re-seal queued over it is weighed
        // at the value it was made at, for the same reason.
        let queued = try store.queuedPush(envelope.recordID)
        let rival = try queued.flatMap { try willSend($0, membership: membership, in: store) ? $0 : nil }
        // A group removed from this Mac only, with a re-seal of its record
        // still owed to someone just added, is live for everyone else. A live
        // version pulled while letting go of it is weighed like any record,
        // and when it is newer the re-seal carries it. Losing to the delete
        // here, it was kept only as a hidden copy, and the re-seal sent this
        // Mac's old name over it. The group stays deleted on this Mac.
        let removedHereOnly = groupIsDeletedHere && !envelope.isDeleted
            && queued?.owesReseal == true && queued?.isDeleted == false
        let localIsDeleted = groupIsDeletedHere && !removedHereOnly
        let incomingWins: Bool
        if let rival {
            incomingWins = envelope.replaces(lamport: rival.weighedLamport, device: device.id,
                                             isDeleted: localIsDeleted || rival.isDeleted,
                                             author: userID)
        } else {
            // A version stored before migration v7 has no author on file. On
            // this Mac's own device ID it is this person's: before then,
            // nobody else could sign under it here.
            incomingWins = try store.recordVersion(envelope.recordID).map {
                envelope.replaces(lamport: $0.lamport, device: $0.device, isDeleted: localIsDeleted,
                                  author: $0.author ?? ($0.device == device.id ? userID : nil))
            } ?? (envelope.isDeleted || !localIsDeleted)
        }
        if !incomingWins {
            try store.recordConflict(
                recordID: envelope.recordID, recordType: envelope.recordType,
                payloadJSON: String(decoding: payload, as: UTF8.self),
                lamport: envelope.lamport, device: envelope.authorDeviceID
            )
            return .conflict
        }

        var outcome = ApplyOutcome.applied
        if let queued {
            // An edit made here that loses, or that this Mac would never
            // send. Either way the server will not take it, so it is kept as
            // a conflict copy.
            if !queued.isReseal, let mine = try self.payload(for: queued, in: store) {
                try store.recordConflict(
                    recordID: queued.recordID, recordType: queued.recordType,
                    payloadJSON: String(decoding: mine, as: UTF8.self),
                    lamport: queued.weighedLamport, device: device.id
                )
                outcome = .conflict
            }
            if queued.owesReseal, !envelope.isDeleted {
                // A re-seal's job is to send the record under the current
                // key, so it stays, whatever happened to an edit it was
                // queued over. It moves above the version taken in, and sends
                // that, rather than being refused as older.
                try store.requeue(queued.recordID, above: envelope.lamport)
            } else {
                // Nothing left to send. A re-seal of a record now deleted
                // has nothing to seal.
                try store.clearOutbox([queued])
            }
        }

        try write(payload, type: envelope.recordType, isDeleted: envelope.isDeleted || removedHereOnly,
                  in: store)
        try store.setRecordVersion(envelope.recordID, lamport: envelope.lamport,
                                   device: envelope.authorDeviceID, author: envelope.authorUserID,
                                   serverSeq: serverSeq)
        return outcome
    }

    /// Whether a queued row is an edit made here that this Mac will send.
    /// Push runs only for a member who may write, and drops a change to
    /// someone else's transaction that the member may not make.
    nonisolated private func willSend(_ item: PendingPush, membership: MembershipState,
                                      in store: Store) throws -> Bool {
        guard !item.isReseal, membership.allows(userID, .write) else { return false }
        return try mayPush(item, membership: membership, in: store)
    }

    /// Ownership rules, applied to a decrypted payload before it is accepted.
    ///
    /// - A transaction belongs to whoever first pushed it, and that never changes.
    ///   Someone who can only add may change their own and nobody else's. A
    ///   manager may change anyone's.
    /// - A member profile can only be written by the member it names.
    /// - A group record describes the group it travels in. Only the group's
    ///   founder or an admin may delete it, so a delete from anyone else is
    ///   refused and the group stays. Renaming it takes a manager, as a
    ///   budget does.
    /// - A budget is made, changed and deleted by a manager. Write is for
    ///   transactions.
    ///
    /// Returns the payload to store, which for an old transaction with no owner
    /// yet is rewritten to name its signed author. Nil means refuse it.
    private func authorised(_ payload: Data, envelope: RecordEnvelope,
                            authorLevel: AccessLevel, membership: MembershipState) throws -> Data? {
        let author = envelope.authorUserID
        switch envelope.recordType {
        case .transaction:
            guard var incoming = try? RecordCodec.decoder.decode(Transaction.self, from: payload) else {
                return nil
            }
            let existing = try store.transaction(envelope.recordID)
            if let owner = existing?.createdBy, incoming.createdBy != owner {
                return nil   // nobody re-assigns a transaction
            }
            if existing == nil, let claimed = incoming.createdBy, claimed != author {
                return nil   // nobody adds one in someone else's name
            }
            let owner = existing?.createdBy ?? incoming.createdBy ?? author
            if owner != author && !authorLevel.allows(.manage) {
                return nil
            }
            guard incoming.createdBy == nil else { return payload }
            incoming.createdBy = owner
            return try RecordCodec.encoder.encode(incoming)

        case .memberProfile:
            guard let incoming = try? RecordCodec.decoder.decode(MemberProfile.self, from: payload),
                  incoming.userID == author,
                  incoming.groupID == envelope.groupID,
                  envelope.recordID == MemberProfile.recordID(group: envelope.groupID, user: author)
            else { return nil }
            return payload

        case .groupMeta:
            guard let incoming = try? RecordCodec.decoder.decode(BudgetGroup.self, from: payload),
                  incoming.id == envelope.groupID else { return nil }
            if envelope.isDeleted {
                return membership.mayDeleteGroup(author) ? payload : nil
            }
            return authorLevel.allows(.manage) ? payload : nil

        case .budget:
            return authorLevel.allows(.manage) ? payload : nil

        default:
            return payload
        }
    }

    /// Whether the record sealed in an envelope is the one the envelope names,
    /// in the group and budget it names, and nothing this Mac already holds
    /// as something else.
    ///
    /// Ownership, versions and the seal are all checked against the envelope's
    /// IDs, but `write` saves the record under the IDs inside it. Without this,
    /// a member could send someone else's transaction under a fresh ID and
    /// take it over, or send a budget from another group through a group she
    /// founded and overwrite it there.
    private func belongsHere(_ payload: Data, envelope: RecordEnvelope) throws -> Bool {
        // Contents that do not decode as the type the envelope names are
        // refused here, like any other record that does not match.
        guard let inside = try? RecordBinding(payload, type: envelope.recordType),
              inside.matches(envelope) else { return false }

        // A record this Mac already holds keeps its type and its group. One
        // reusing its ID from elsewhere would move it, or take over its version.
        if let held = try store.holder(of: envelope.recordID),
           held.type != envelope.recordType || held.group != envelope.groupID {
            return false
        }
        // A transaction or receipt is shown in the budget it names, so that
        // budget must be in the group whose members judged it.
        if envelope.recordType != .budget, let budget = envelope.budgetID,
           let home = try store.budget(budget)?.groupID, home != envelope.groupID {
            return false
        }
        return true
    }

    /// Decode and save, without queueing an outbound copy. A record we just
    /// received must not bounce straight back to the server.
    nonisolated private func write(_ payload: Data, type: RecordType, isDeleted: Bool,
                                   in store: Store) throws {
        let decoder = RecordCodec.decoder
        switch type {
        case .groupMeta:
            var value = try decoder.decode(BudgetGroup.self, from: payload)
            value.isDeleted = isDeleted
            try store.save(value, queue: false)
        case .budget:
            var value = try decoder.decode(Budget.self, from: payload)
            value.isDeleted = isDeleted
            try store.save(value, queue: false)
        case .transaction:
            var value = try decoder.decode(Transaction.self, from: payload)
            value.isDeleted = isDeleted
            // This Mac holds one imported row per fingerprint in a group. Two
            // members who import the same statement each send theirs, and
            // saving the other's failed on every pull. It is kept without the
            // fingerprint, which only this Mac's next import reads.
            if let fingerprint = value.importFingerprint,
               let holder = try store.transaction(withFingerprint: fingerprint, in: value.groupID),
               holder != value.id {
                value.importFingerprint = nil
                // Kept to one side, and sent with the row again, so the
                // member who imported it still has it when this Mac saves
                // the row again.
                try store.holdFingerprint(fingerprint, for: value.id)
            }
            try store.save(value, queue: false)
        case .receipt:
            var value = try decoder.decode(Receipt.self, from: payload)
            value.isDeleted = isDeleted
            try store.save(value, queue: false)
        case .statement:
            var value = try decoder.decode(ImportedStatement.self, from: payload)
            value.isDeleted = isDeleted
            try store.save(value, queue: false)
        case .memberProfile:
            var value = try decoder.decode(MemberProfile.self, from: payload)
            value.isDeleted = isDeleted
            try store.save(value, queue: false)
        default:
            // Unreachable: `apply` sets aside any type this build cannot read
            // before it gets here.
            break
        }
    }

    // MARK: - Push

    /// How many queued rows go to the server in one request.
    private static let pageSize = 200

    /// Sends what is queued for a group, a page at a time, oldest first.
    ///
    /// Every page goes out, not only the first. Rows the server kept refusing
    /// used to fill the first page on every round, and nothing queued behind
    /// them was ever sent. A page that comes back short is the last one, so a
    /// row saved while this round is out waits for the next.
    private func push(group: GroupID, membership: MembershipState, into report: SyncReport,
                      leavingReseals: Bool = false) async throws -> SyncReport {
        var report = report
        var after: UInt64?
        while true {
            let page = try store.pendingPushes(in: group, after: after, limit: Self.pageSize)
            guard let last = page.last else { break }
            let sending = leavingReseals ? page.filter { !$0.isReseal } : page
            report = try await push(sending, group: group, membership: membership, into: report)
            guard page.count == Self.pageSize else { break }
            after = last.lamport
        }
        return report
    }

    private func push(_ pending: [PendingPush], group: GroupID, membership: MembershipState,
                      into report: SyncReport) async throws -> SyncReport {
        var report = report
        var envelopes: [RecordEnvelope] = []
        var sealed: [(push: PendingPush, payload: Data)] = []
        var gone: [PendingPush] = []

        for item in pending where !heldBack.contains(item.recordID) {
            guard let payload = try payload(for: item, in: store) else {
                // No record to seal, because it is no longer in this Mac's
                // database, so there is nothing to send. The row is dropped
                // here. Only rows the server takes are cleared below, so
                // leaving it there kept it queued for good. A type this build
                // does not know is different: a newer build queued it and will
                // send it, so it stays.
                if item.recordType.isKnown { gone.append(item) }
                continue
            }
            // Sealed under the IDs the record carries now, not the ones its
            // queued row was saved with, because every member refuses an
            // envelope that does not describe what is inside it.
            guard let inside = try RecordBinding(payload, type: item.recordType),
                  inside.id == item.recordID.uuid, inside.group == item.groupID,
                  try budgetIsInItsGroup(inside, type: item.recordType),
                  try mayPush(item, membership: membership, in: store) else {
                // Every other member would refuse it, so sending it would only
                // leave this device disagreeing with everyone else. The screens
                // never offer this; reaching here means a bug, so count it.
                try store.clearOutbox([item])
                report.rejected += 1
                continue
            }
            let scope: KeyScope = inside.budget.map { .budget($0) } ?? .group(item.groupID)
            guard let key = try? keyRingKey(scope: scope, epoch: membership.epoch) else {
                // No key for the current epoch yet. Leave it queued and try again.
                continue
            }

            let envelope = try RecordCodec.sealData(
                payload, recordID: item.recordID, recordType: item.recordType,
                groupID: item.groupID, budgetID: inside.budget, scopeKey: key,
                lamport: item.lamport, author: userID, device: device,
                membershipSequence: membership.sequence, isDeleted: item.isDeleted
            )
            envelopes.append(envelope)
            sealed.append((item, payload))
        }
        try store.clearOutbox(gone)

        guard !envelopes.isEmpty else { return report }

        let result = try await transport.push(envelopes, group: group)
        report.pushed += result.accepted.count
        report.rejected += result.rejected.count
        report.serverSeq = max(report.serverSeq, result.serverSeq)

        // Only clear what the server actually took. A record refused for most
        // reasons stays queued, so the next round tries it again rather than
        // losing it. So does a record saved again while the push was out: its
        // row now has a newer Lamport value than the one sealed above, so it
        // is not the row that was sent.
        let accepted = Set(result.accepted.map(\.uuid))
        try store.clearOutbox(sealed.map(\.push).filter { accepted.contains($0.recordID.uuid) })

        // A row refused as older than the version the server holds can never
        // be taken. Its Lamport value is fixed, so sending it again would be
        // refused again, on every sync. It leaves the queue, and what it said
        // is kept as a conflict copy, as for an edit that loses on a pull.
        // The newer version normally comes in on a later pull.
        let older = sealed.filter { result.rejected[$0.push.recordID] == RecordEnvelope.olderVersionRefusal }
        for (item, payload) in older {
            try store.recordConflict(
                recordID: item.recordID, recordType: item.recordType,
                payloadJSON: String(decoding: payload, as: UTF8.self),
                lamport: item.lamport, device: device.id
            )
        }
        try store.clearOutbox(older.map(\.push))
        report.conflicts += older.count

        // Record the version the server now holds, which is the one sealed above.
        // A newer row still queued goes out next round and moves this on then.
        for (recordID, lamport) in zip(envelopes.map(\.recordID), envelopes.map(\.lamport))
        where accepted.contains(recordID.uuid) {
            try store.setRecordVersion(recordID, lamport: lamport, device: device.id, author: userID,
                                       serverSeq: result.serverSeq)
        }

        return report
    }

    /// The same rules `authorised` applies to incoming records, applied to our
    /// own before they leave: someone else's transaction, any budget, or a
    /// change to the group's name needs a manager.
    nonisolated private func mayPush(_ item: PendingPush, membership: MembershipState,
                                     in store: Store) throws -> Bool {
        if item.recordType == .budget { return membership.allows(userID, .manage) }
        if item.recordType == .groupMeta, !item.isDeleted { return membership.allows(userID, .manage) }
        guard item.recordType == .transaction,
              let owner = try store.transaction(item.recordID)?.createdBy else { return true }
        return owner == userID || membership.allows(userID, .manage)
    }

    /// Whether a transaction or receipt names a budget in the group it is sent
    /// to, when this Mac holds that budget. Every member refuses one that does
    /// not (`belongsHere`), so sending it would leave this Mac showing a
    /// record nobody else has.
    private func budgetIsInItsGroup(_ inside: RecordBinding, type: RecordType) throws -> Bool {
        guard type != .budget, let budget = inside.budget,
              let home = try store.budget(budget)?.groupID else { return true }
        return home == inside.group
    }

    nonisolated private func payload(for push: PendingPush, in store: Store) throws -> Data? {
        let encoder = RecordCodec.encoder
        switch push.recordType {
        case .groupMeta:
            guard let value = try store.group(GroupID(push.recordID.uuid)) else { return nil }
            return try encoder.encode(value)
        case .budget:
            guard let value = try store.budget(BudgetID(push.recordID.uuid)) else { return nil }
            return try encoder.encode(value)
        case .transaction:
            guard var value = try store.transaction(push.recordID) else { return nil }
            if value.createdBy == nil {
                // Made before signing in, or before owners existed. Whoever first
                // pushes it owns it, which on this device is us.
                value.createdBy = userID
                try store.save(value, queue: false)
            }
            // A fingerprint this Mac cleared on arrival goes back out with the
            // row. Sent without it, the next overlapping import by the member
            // who made it added the line again.
            if value.importFingerprint == nil, let held = try store.heldFingerprint(for: push.recordID) {
                value.importFingerprint = held
            }
            return try encoder.encode(value)
        case .receipt:
            guard let value = try store.receipt(push.recordID) else { return nil }
            return try encoder.encode(value)
        case .statement:
            let all = try store.statements(in: push.groupID)
            guard let value = all.first(where: { $0.id == push.recordID }) else { return nil }
            return try encoder.encode(value)
        case .memberProfile:
            guard let value = try store.profile(push.recordID) else { return nil }
            return try encoder.encode(value)
        default:
            // This build only ever queues types it knows.
            return nil
        }
    }

    private func keyRingKey(scope: KeyScope, epoch: Epoch) throws -> ScopedKey {
        try keyRing.key(for: scope, epoch: epoch)
    }
}

/// The IDs a record carries inside its sealed payload. An envelope must repeat
/// all three, so what members judge is what gets saved.
struct RecordBinding: Equatable {
    let id: UUID
    let group: GroupID
    /// The budget whose key seals it. A budget is sealed with its own key, so
    /// it names itself. Nil for a record sealed with the group key.
    let budget: BudgetID?

    /// Nil for a type this build cannot read.
    init?(_ payload: Data, type: RecordType) throws {
        let decoder = RecordCodec.decoder
        switch type {
        case .groupMeta:
            let value = try decoder.decode(BudgetGroup.self, from: payload)
            (id, group, budget) = (value.id.uuid, value.id, nil)
        case .budget:
            let value = try decoder.decode(Budget.self, from: payload)
            (id, group, budget) = (value.id.uuid, value.groupID, value.id)
        case .transaction:
            let value = try decoder.decode(Transaction.self, from: payload)
            (id, group, budget) = (value.id.uuid, value.groupID, value.budgetID)
        case .receipt:
            let value = try decoder.decode(Receipt.self, from: payload)
            (id, group, budget) = (value.id.uuid, value.groupID, value.budgetID)
        case .statement:
            let value = try decoder.decode(ImportedStatement.self, from: payload)
            (id, group, budget) = (value.id.uuid, value.groupID, nil)
        case .memberProfile:
            let value = try decoder.decode(MemberProfile.self, from: payload)
            (id, group, budget) = (value.id.uuid, value.groupID, nil)
        default:
            return nil
        }
    }

    func matches(_ envelope: RecordEnvelope) -> Bool {
        id == envelope.recordID.uuid && group == envelope.groupID && budget == envelope.budgetID
    }
}
