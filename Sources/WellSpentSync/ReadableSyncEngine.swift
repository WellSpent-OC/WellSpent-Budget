import Foundation
import WellSpentCrypto
import WellSpentModel
import WellSpentStore

/// One round of readable sync for one group: take in what others changed,
/// then send what is queued here.
///
/// The server stores records as they are and decides who may change what,
/// so there is nothing to seal, sign or verify. What carries over from the
/// sealed engine:
/// - Pull before push, so this Mac's clock has passed what it saw before it
///   sends anything.
/// - Last writer wins, by the rule the server applies, so every device and
///   the server pick the same winner.
/// - Nothing is dropped silently. An edit that loses is kept as a conflict
///   copy, and a record this build cannot use yet is set aside.
public actor ReadableSyncEngine {
    private let store: Store
    private let transport: any ReadableSyncTransport
    private let clientID: DeviceID
    private let userID: UserID
    /// Records whose pulled version this round could not save. Their queued
    /// rows wait for a later round rather than go out over that version.
    private var heldBack: Set<RecordID> = []
    /// Set when this round's send had a change refused, by the server or by
    /// this Mac's own reading of the server's rules.
    private var refused = false

    /// The most records of a type this build cannot read that are kept from
    /// one sender in one group, waiting for an update. Past it, more from
    /// them are passed over and the pull moves on.
    static let setAsideLimit = 10_000
    /// Records asked for, and sent, in one request.
    static let pageSize = 200

    public init(store: Store, transport: any ReadableSyncTransport, clientID: DeviceID, userID: UserID) {
        self.store = store
        self.transport = transport
        self.clientID = clientID
        self.userID = userID
    }

    /// Takes in, then sends if `level` may write. `level` is this person's
    /// level in the group as the server last said; the server checks again.
    ///
    /// A change refused while sending is kept as a conflict copy, and only
    /// the server's copy can replace it here. So the group is read again
    /// before the round ends. Left to the next round, up to two minutes
    /// later, the refused change was what showed meanwhile, under a note
    /// saying it didn't go through.
    @discardableResult
    public func sync(group: GroupID, level: AccessLevel) async throws -> SyncReport {
        heldBack = []
        refused = false
        var report = try await pull(group: group, level: level, into: SyncReport())
        if level.allows(.write) {
            report = try await push(group: group, level: level, into: report)
            if refused { report = try await pull(group: group, level: level, into: report) }
        }
        return report
    }

    /// Takes in only. Also how the move checks the server's copy, into a
    /// scratch store.
    @discardableResult
    public func pull(group: GroupID, level: AccessLevel = .read) async throws -> SyncReport {
        heldBack = []
        return try await pull(group: group, level: level, into: SyncReport())
    }

    /// Sends what is queued without taking anything in first, or after.
    public func pushWithoutPulling(group: GroupID, level: AccessLevel) async throws -> SyncReport {
        heldBack = []
        guard level.allows(.write) else { return SyncReport() }
        return try await push(group: group, level: level, into: SyncReport())
    }

    // MARK: - Pull

    private func pull(group: GroupID, level: AccessLevel, into report: SyncReport) async throws -> SyncReport {
        var report = report
        var cursor = try store.readableCursor(in: group)
        var highestLamport = try store.syncState(for: group).lamport

        var more = true
        while more {
            let page = try await transport.pull(group: group, since: cursor, limit: Self.pageSize)
            more = page.hasMore
            report.pulled += page.records.count

            for record in page.records {
                // A server refuses a value at or above the ceiling, so this
                // came from one that did not. Taken in, it would leave this
                // Mac's clock no room to grow.
                guard record.lamport < RecordEnvelope.lamportCeiling else {
                    report.ignored += 1
                    continue
                }
                highestLamport = max(highestLamport, record.lamport)
                count(try apply(record, group: group, level: level, serverSeq: record.serverSeq ?? page.serverSeq),
                      into: &report)
            }
            cursor = page.serverSeq
            report.serverSeq = page.serverSeq
            if page.records.isEmpty { more = false }
        }

        // Once per pull, after it: a transaction set aside because its budget
        // had not arrived usually finds it later in the same pull.
        report = try replaySetAside(group: group, level: level, into: report)
        try store.recordReadablePull(group: group, serverSeq: cursor, observedLamport: highestLamport)
        return report
    }

    private func count(_ outcome: Outcome, into report: inout SyncReport) {
        switch outcome {
        case .applied: report.applied += 1
        case .conflict: report.conflicts += 1
        case .echo: report.echoes += 1
        case .ignored: report.ignored += 1
        case .deferred: report.deferred += 1
        case .unsaved: report.unsaved += 1
        }
    }

    /// Records set aside, applied now that they can be. One that still
    /// cannot stays: a type this build cannot read, or a transaction whose
    /// budget is still missing.
    private func replaySetAside(group: GroupID, level: AccessLevel, into report: SyncReport) throws -> SyncReport {
        var report = report
        for aside in try store.setAsideRecords(in: group) {
            guard aside.recordType.isKnown, !heldBack.contains(aside.recordID),
                  let record = try? JSONDecoder().decode(WireRecord.self, from: Data(aside.recordJSON.utf8)) else {
                continue
            }
            if record.type == .transaction, let budget = record.budgetID, try store.budget(budget) == nil { continue }
            let outcome = try apply(record, group: group, level: level, serverSeq: aside.serverSeq)
            count(outcome, into: &report)
            if outcome != .deferred && outcome != .unsaved {
                try store.deleteSetAside(record.id)
            }
        }
        return report
    }

    enum Outcome: Equatable {
        case applied
        /// The losing side was kept as a conflict copy.
        case conflict
        /// Nothing to do: this device's own record coming back, or the same
        /// content this Mac already holds.
        case echo
        /// Set aside: a type this build cannot read yet, or a transaction
        /// whose budget has not arrived.
        case deferred
        /// Refused: it does not match where it came from.
        case ignored
        /// This Mac's database would not save it, for a reason that will
        /// repeat. Set aside, to be tried again.
        case unsaved
    }

    private func apply(_ record: WireRecord, group: GroupID, level: AccessLevel,
                       serverSeq: UInt64) throws -> Outcome {
        // This device's own record coming back, already here. Ours means
        // this person on this device.
        if record.clientID == clientID, record.updatedBy == userID,
           try store.recordVersion(record.id) != nil || store.isQueued(record.id) {
            return .echo
        }
        // The group's own record uses the group's ID, and nothing else may.
        guard (record.type == .groupMeta) == (record.id.uuid == group.uuid) else { return .ignored }

        // A type a newer version of the app makes is kept, so an update can
        // apply it. Only so many from each sender.
        if !record.type.isKnown {
            guard let author = record.updatedBy ?? record.createdBy,
                  try store.unreadableSetAsideCount(in: group, from: author, except: record.id) < Self.setAsideLimit
            else { return .ignored }
            try setAside(record, group: group, serverSeq: serverSeq, unreadable: true)
            return .deferred
        }

        let payload = Data(record.body.utf8)
        guard try belongsHere(payload, record: record, group: group) else { return .ignored }

        // A transaction is saved under its budget, so the budget must be here
        // first. Set aside, it is applied once the budget is in.
        if record.type == .transaction, let budget = record.budgetID, try store.budget(budget) == nil {
            try setAside(record, group: group, serverSeq: serverSeq, unreadable: false)
            return .deferred
        }

        // A save this Mac's database refuses for a reason that will repeat
        // is set aside and counted, and the pull goes on. Anything else, such
        // as a full disk, is thrown, so the cursor stays and the record comes
        // again.
        let outcome: Outcome
        do {
            outcome = try store.inOneTransaction { store in
                try settle(record, payload: payload, group: group, level: level, serverSeq: serverSeq, in: store)
            }
        } catch where Store.isLastingFailure(error) {
            try setAside(record, group: group, serverSeq: serverSeq, unreadable: false)
            heldBack.insert(record.id)
            return .unsaved
        }
        // A copy set aside earlier is older than this one, or is this one.
        try store.deleteSetAside(record.id)
        return outcome
    }

    private func setAside(_ record: WireRecord, group: GroupID, serverSeq: UInt64, unreadable: Bool) throws {
        let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        try store.setAside(SetAsideRecord(recordID: record.id, groupID: group, recordType: record.type,
                                          recordJSON: json, serverSeq: serverSeq,
                                          authorUserID: record.updatedBy ?? record.createdBy,
                                          unreadable: unreadable))
    }

    /// Weighs a pulled record against what this Mac holds and keeps the
    /// winner, as one database transaction.
    nonisolated private func settle(_ record: WireRecord, payload: Data, group: GroupID, level: AccessLevel,
                                    serverSeq: UInt64, in store: Store) throws -> Outcome {
        // The clock passes this version now, in the same transaction, so an
        // edit made before the pull ends is still newer than what it saw.
        try store.observeLamport(record.lamport, in: group)
        let queued = try store.queuedPush(record.id)

        // The same content this Mac holds, and no edit of its own waiting:
        // only the version changes. Without this, every record a founder
        // sends up once after the switch came back to each member as a
        // conflict, because both sides hold it at the same Lamport value.
        if queued?.isReseal != false,
           try store.holdsTheSame(payload, type: record.type, isDeleted: record.isDeleted) {
            if let queued { try store.clearOutbox([queued]) }
            try store.setRecordVersion(record.id, lamport: record.lamport, device: record.clientID,
                                       author: record.updatedBy, serverSeq: serverSeq)
            return .echo
        }
        // The very version on file, sent again: the same Lamport value,
        // device and author. Whatever differs here was changed on this Mac
        // without a new version (an import mark set aside on arrival, or an
        // edit made since, which stays queued), and the copy coming back is
        // not news. Weighed as usual, it became a conflict copy every pull.
        if let held = try store.recordVersion(record.id),
           held.lamport == record.lamport, held.device == record.clientID,
           held.author != nil, held.author == record.updatedBy {
            if let queued, queued.isReseal { try store.clearOutbox([queued]) }
            try store.setRecordVersion(record.id, lamport: record.lamport, device: record.clientID,
                                       author: record.updatedBy, serverSeq: serverSeq)
            return .echo
        }

        // Deleting a group is final, so a group deleted here is weighed as deleted.
        let groupIsDeletedHere = try record.type == .groupMeta
            && store.group(GroupID(record.id.uuid))?.isDeleted == true
        // An edit made here, still queued, that this Mac will send, is the
        // version it holds, and what the server will weigh this record
        // against. A row that only sends the version on file again gives way,
        // and the version on file decides.
        let rival = try queued.flatMap { try willSend($0, level: level, in: store) ? $0 : nil }
        let incomingWins: Bool
        if let rival {
            incomingWins = record.replaces(lamport: rival.weighedLamport, client: clientID,
                                           isDeleted: groupIsDeletedHere || rival.isDeleted, author: userID)
        } else {
            incomingWins = try store.recordVersion(record.id).map {
                record.replaces(lamport: $0.lamport, client: $0.device, isDeleted: groupIsDeletedHere,
                                author: $0.author ?? ($0.device == clientID ? userID : nil))
            } ?? (record.isDeleted || !groupIsDeletedHere)
        }
        if !incomingWins {
            try store.recordConflict(recordID: record.id, recordType: record.type, payloadJSON: record.body,
                                     lamport: record.lamport, device: record.clientID)
            return .conflict
        }

        var outcome = Outcome.applied
        if let queued {
            // An edit made here that loses, or that this Mac would never
            // send, is kept as a conflict copy. A row that only sends the
            // version on file again has nothing of its own to keep.
            if !queued.isReseal, let mine = try store.outgoingPayload(for: queued, userID: userID) {
                try store.recordConflict(recordID: queued.recordID, recordType: queued.recordType,
                                         payloadJSON: String(decoding: mine, as: UTF8.self),
                                         lamport: queued.weighedLamport, device: clientID)
                outcome = .conflict
            }
            try store.clearOutbox([queued])
        }
        try store.applyPulled(payload, type: record.type, isDeleted: record.isDeleted)
        try store.setRecordVersion(record.id, lamport: record.lamport, device: record.clientID,
                                   author: record.updatedBy, serverSeq: serverSeq)
        return outcome
    }

    /// Whether the record inside is the one the server says it is, in the
    /// group it came from, and nothing this Mac already holds as something
    /// else. The server checks this too; a Mac does not rely on that.
    private func belongsHere(_ payload: Data, record: WireRecord, group: GroupID) throws -> Bool {
        guard let inside = try? RecordBinding(payload, type: record.type),
              inside.id == record.id.uuid, inside.group == group, inside.budget == record.budgetID else {
            return false
        }
        if let held = try store.holder(of: record.id), held.type != record.type || held.group != group {
            return false
        }
        if record.type != .budget, let budget = record.budgetID,
           let home = try store.budget(budget)?.groupID, home != group {
            return false
        }
        return true
    }

    // MARK: - Push

    /// Sends what is queued for a group, a page at a time, in (Lamport,
    /// record) order. A page that comes back short is the last one.
    private func push(group: GroupID, level: AccessLevel, into report: SyncReport) async throws -> SyncReport {
        var report = report
        var cursor: Store.OutboxCursor?
        while true {
            let page = try store.pendingPushes(in: group, following: cursor, limit: Self.pageSize)
            guard let last = page.last else { break }
            report = try await push(page, group: group, level: level, into: report)
            guard page.count == Self.pageSize else { break }
            cursor = Store.OutboxCursor(after: last)
        }
        return report
    }

    private func push(_ pending: [PendingPush], group: GroupID, level: AccessLevel,
                      into report: SyncReport) async throws -> SyncReport {
        var report = report
        var records: [WireRecord] = []
        var sent: [PendingPush] = []
        var gone: [PendingPush] = []
        // Set when a record this Mac changed is refused, so the next pull
        // starts over and brings back the server's copy.
        var startOver = false

        for item in pending where !heldBack.contains(item.recordID) {
            // A type this build does not know: a newer build queued it and will send it.
            guard item.recordType.isKnown else { continue }
            guard let payload = try store.outgoingPayload(for: item, userID: userID) else {
                // No longer in this Mac's database, so nothing to send.
                gone.append(item)
                continue
            }
            // Sent under the IDs the record carries now. One that is not what
            // its row says cannot be sent at all; reaching here means a bug,
            // so count it.
            guard let inside = try? RecordBinding(payload, type: item.recordType),
                  inside.id == item.recordID.uuid, inside.group == item.groupID else {
                try store.clearOutbox([item])
                report.rejected += 1
                continue
            }
            // One the server would refuse, for where it is filed or for who
            // sends it (a member demoted since the edit, say), is treated as a
            // refusal without asking: the edit is kept as a conflict copy and
            // the server's copy comes back on the next pull. Dropped quietly,
            // this Mac kept showing an edit nobody else would ever see.
            guard try budgetIsInItsGroup(inside, type: item.recordType),
                  try mayPush(item, level: level, in: store) else {
                if !item.isReseal {
                    try keepAsConflict(item, body: String(decoding: payload, as: UTF8.self), into: &report)
                }
                try store.clearOutbox([item])
                try store.forgetVersion(item.recordID)
                startOver = true
                report.rejected += 1
                continue
            }
            records.append(WireRecord(id: item.recordID, type: item.recordType, budgetID: inside.budget,
                                      lamport: item.lamport, clientID: clientID, isDeleted: item.isDeleted,
                                      body: String(decoding: payload, as: UTF8.self)))
            sent.append(item)
        }
        try store.clearOutbox(gone)
        guard !records.isEmpty else {
            if startOver { try startPullOver(in: group) }
            return report
        }

        let result = try await transport.push(records, group: group)
        report.pushed += result.accepted.count
        report.rejected += result.rejected.count
        report.serverSeq = max(report.serverSeq, result.serverSeq)

        // Only what the server took is cleared, and only the row that was
        // sent: a record saved again while the push was out has a newer row.
        let accepted = Set(result.accepted)
        let taken = sent.filter { accepted.contains($0.recordID) }
        try store.clearOutbox(taken)
        for item in taken {
            try store.setRecordVersion(item.recordID, lamport: item.lamport, device: clientID, author: userID,
                                       serverSeq: result.serverSeq)
        }

        for (item, record) in zip(sent, records) {
            guard let reason = result.rejected[item.recordID] else { continue }
            switch reason {
            case RecordEnvelope.lamportTooFarAheadRefusal, RecordEnvelope.lamportTooLargeRefusal:
                // Stays queued. The group's highest value moves on as others
                // write, and a later round gets it in.
                continue
            case RecordEnvelope.olderVersionRefusal:
                // It can never be taken. An edit is kept as a conflict copy; a
                // row that only sent the version on file again has nothing to
                // keep. The next pull starts over without the version on
                // file, so the server's newer copy replaces this Mac's, even
                // where this Mac had marked that version as already seen.
                if !item.isReseal { try keepAsConflict(item, body: record.body, into: &report) }
                try store.clearOutbox([item])
                try store.forgetVersion(item.recordID)
                startOver = true
            default:
                // Refused for who sent it or where it was sent. Sending it again
                // would be refused again. An edit is kept as a conflict copy,
                // and the next pull starts over, so whatever the server holds
                // replaces what only this Mac has.
                if !item.isReseal { try keepAsConflict(item, body: record.body, into: &report) }
                try store.clearOutbox([item])
                try store.forgetVersion(item.recordID)
                startOver = true
            }
        }
        if startOver { try startPullOver(in: group) }
        return report
    }

    /// After a refusal: the next pull starts from the beginning, so the
    /// server's copy replaces the refused change.
    private func startPullOver(in group: GroupID) throws {
        try store.resetPullCursor(in: group)
        refused = true
    }

    private func keepAsConflict(_ item: PendingPush, body: String, into report: inout SyncReport) throws {
        try store.recordConflict(recordID: item.recordID, recordType: item.recordType, payloadJSON: body,
                                 lamport: item.lamport, device: clientID)
        report.conflicts += 1
    }

    /// Whether a queued row is an edit made here that this Mac will send.
    nonisolated private func willSend(_ item: PendingPush, level: AccessLevel, in store: Store) throws -> Bool {
        guard !item.isReseal, level.allows(.write) else { return false }
        return try mayPush(item, level: level, in: store)
    }

    /// The server's rules on who may send what, as far as this Mac can tell:
    /// a budget, or a change to the group, needs a manager; deleting the
    /// group needs its founder or an admin; someone else's transaction needs
    /// a manager.
    nonisolated private func mayPush(_ item: PendingPush, level: AccessLevel, in store: Store) throws -> Bool {
        switch item.recordType {
        case .budget:
            return level.allows(.manage)
        case .groupMeta:
            return level.allows(item.isDeleted ? .admin : .manage)
        case .transaction:
            guard let owner = try store.transaction(item.recordID)?.createdBy else { return true }
            return owner == userID || level.allows(.manage)
        default:
            return true
        }
    }

    /// Whether a transaction or receipt names a budget in the group it is
    /// sent to, when this Mac holds that budget.
    private func budgetIsInItsGroup(_ inside: RecordBinding, type: RecordType) throws -> Bool {
        guard type != .budget, let budget = inside.budget,
              let home = try store.budget(budget)?.groupID else { return true }
        return home == inside.group
    }
}

extension WireRecord {
    /// Whether this version replaces a stored one, by the rule the server
    /// applies (`replacesV2`). Deleting a group is final; otherwise the higher
    /// Lamport value wins, then the higher device ID, then the higher author.
    func replaces(lamport stored: UInt64, client storedClient: DeviceID, isDeleted storedIsDeleted: Bool,
                  author storedAuthor: UserID?) -> Bool {
        if type == .groupMeta, isDeleted != storedIsDeleted { return isDeleted }
        if lamport != stored { return lamport > stored }
        if clientID != storedClient { return clientID.uuid.uuidString > storedClient.uuid.uuidString }
        guard let storedAuthor, let author = updatedBy, storedAuthor != author else { return false }
        return author.uuid.uuidString > storedAuthor.uuid.uuidString
    }
}
