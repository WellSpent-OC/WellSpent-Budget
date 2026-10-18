import Foundation
import WellSpentCrypto
import WellSpentModel
import WellSpentStore

/// Saving a pulled record, and reading one to send. Shared by the sealed
/// engine and the readable one, so the two treat this Mac's records alike.
extension Store {
    /// Decodes and saves a record pulled from the server, without queueing
    /// it. A record just received must not bounce straight back.
    func applyPulled(_ payload: Data, type: RecordType, isDeleted: Bool) throws {
        let decoder = RecordCodec.decoder
        switch type {
        case .groupMeta:
            var value = try decoder.decode(BudgetGroup.self, from: payload)
            value.isDeleted = isDeleted
            try save(value, queue: false)
        case .budget:
            var value = try decoder.decode(Budget.self, from: payload)
            value.isDeleted = isDeleted
            try save(value, queue: false)
        case .transaction:
            var value = try decoder.decode(Transaction.self, from: payload)
            value.isDeleted = isDeleted
            // This Mac holds one imported row per fingerprint in a group. Two
            // members who import the same statement each send theirs, and
            // saving the other's failed on every pull. It is kept without the
            // fingerprint, which only this Mac's next import reads.
            if let fingerprint = value.importFingerprint,
               let holder = try transaction(withFingerprint: fingerprint, in: value.groupID),
               holder != value.id {
                if !value.isDeleted, var held = try transaction(holder), try givesUpImportMark(held) {
                    // A row here that is deleted, or whose budget is, gives
                    // the fingerprint up to a live one coming in, as an
                    // import here does. Kept by the old row instead, the
                    // live one arrived without it, and the next import here
                    // counted the same bank line again.
                    held.importFingerprint = nil
                    try save(held, queue: false)
                    try holdFingerprint(fingerprint, for: holder)
                } else {
                    value.importFingerprint = nil
                    // Kept to one side, and sent with the row again, so the
                    // member who imported it still has it when this Mac saves
                    // the row again.
                    try holdFingerprint(fingerprint, for: value.id)
                }
            }
            try save(value, queue: false)
        case .receipt:
            var value = try decoder.decode(Receipt.self, from: payload)
            value.isDeleted = isDeleted
            try save(value, queue: false)
        case .statement:
            var value = try decoder.decode(ImportedStatement.self, from: payload)
            value.isDeleted = isDeleted
            try save(value, queue: false)
        case .memberProfile:
            var value = try decoder.decode(MemberProfile.self, from: payload)
            value.isDeleted = isDeleted
            try save(value, queue: false)
        default:
            // Unreachable: both engines set aside any type this build cannot
            // read before it gets here.
            break
        }
    }

    /// A queued record as it goes out, or nil when this Mac no longer holds it.
    ///
    /// A transaction with no owner yet is given `userID` first, and saved
    /// that way: whoever first sends it owns it, which on this device is
    /// this person.
    func outgoingPayload(for push: PendingPush, userID: UserID) throws -> Data? {
        let encoder = RecordCodec.encoder
        switch push.recordType {
        case .groupMeta:
            guard let value = try group(GroupID(push.recordID.uuid)) else { return nil }
            return try encoder.encode(value)
        case .budget:
            guard let value = try budget(BudgetID(push.recordID.uuid)) else { return nil }
            return try encoder.encode(value)
        case .transaction:
            guard var value = try transaction(push.recordID) else { return nil }
            if value.createdBy == nil {
                // Made before signing in, or before owners existed. Whoever first
                // pushes it owns it, which on this device is us.
                value.createdBy = userID
                try save(value, queue: false)
            }
            // A fingerprint this Mac cleared on arrival goes back out with the
            // row. Sent without it, the next overlapping import by the member
            // who made it added the line again.
            if value.importFingerprint == nil, let held = try heldFingerprint(for: push.recordID) {
                value.importFingerprint = held
            }
            return try encoder.encode(value)
        case .receipt:
            guard let value = try receipt(push.recordID) else { return nil }
            return try encoder.encode(value)
        case .statement:
            let all = try statements(in: push.groupID)
            guard let value = all.first(where: { $0.id == push.recordID }) else { return nil }
            return try encoder.encode(value)
        case .memberProfile:
            guard let value = try profile(push.recordID) else { return nil }
            return try encoder.encode(value)
        default:
            // This build only ever queues types it knows.
            return nil
        }
    }

    /// Whether this Mac already holds exactly what `payload` says, read the
    /// way it would be sent. Both sides are written out the same way, with
    /// dates to the second as the record codec sends them, so a copy saved
    /// here from an earlier pull matches the same record sent again. Keys are
    /// sorted: JSON's key order is not fixed on every platform.
    func holdsTheSame(_ payload: Data, type: RecordType, isDeleted: Bool) throws -> Bool {
        let decoder = RecordCodec.decoder, encoder = Self.comparing
        func same<T: SyncedRecord>(_ incoming: T.Type, held: (T) throws -> T?) throws -> Bool {
            guard var value = try? decoder.decode(T.self, from: payload),
                  let mine = try held(value) else { return false }
            value.isDeleted = isDeleted
            return try encoder.encode(value) == encoder.encode(mine)
        }
        switch type {
        case .groupMeta: return try same(BudgetGroup.self) { try group($0.id) }
        case .budget: return try same(Budget.self) { try budget($0.id) }
        case .transaction:
            // A mark set aside on arrival still belongs to the row.
            return try same(Transaction.self) { value in
                guard var mine = try transaction(value.id) else { return nil }
                if mine.importFingerprint == nil { mine.importFingerprint = try heldFingerprint(for: value.id) }
                return mine
            }
        case .receipt: return try same(Receipt.self) { try receipt($0.id) }
        case .statement:
            return try same(ImportedStatement.self) { value in
                try statements(in: value.groupID).first { $0.id == value.id }
            }
        case .memberProfile: return try same(MemberProfile.self) { try profile($0.id) }
        default: return false
        }
    }

    private static let comparing: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
}
