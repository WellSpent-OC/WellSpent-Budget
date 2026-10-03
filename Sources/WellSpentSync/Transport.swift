import Foundation
import WellSpentCrypto

/// What the client needs from a server, and nothing more.
///
/// Note what is absent: no query endpoint, no reporting, no search. The server
/// cannot read any of it, so there is nothing for it to answer. It hands out
/// blobs in order and refuses writes from people who are not allowed to make them.
public protocol SyncTransport: Sendable {
    /// Send sealed records. The server checks each signature and each author's
    /// level before accepting.
    func push(_ envelopes: [RecordEnvelope], group: GroupID) async throws -> PushResult

    /// Everything after `since`, in server order.
    func pull(group: GroupID, since: UInt64, limit: Int) async throws -> PullResult

    /// The signed access history, which the client replays and verifies itself.
    func membershipLog(group: GroupID, since: UInt64) async throws -> [MembershipLogEntry]

    /// Group and budget keys sealed to this person.
    func wrappedKeys(group: GroupID, for user: UserID) async throws -> [WrappedKey]
}

public struct PushResult: Sendable, Equatable {
    public let accepted: [RecordID]
    /// Per record, so one bad row does not silently drop the rest of the batch.
    ///
    /// The old API used `break` on the first error inside a loop over the whole
    /// payload, so a client pushing two hundred records with one bad row got a
    /// single error and about a hundred and ninety nine records quietly ignored.
    public let rejected: [RecordID: String]
    public let serverSeq: UInt64

    public init(accepted: [RecordID], rejected: [RecordID: String], serverSeq: UInt64) {
        self.accepted = accepted
        self.rejected = rejected
        self.serverSeq = serverSeq
    }
}

public struct PullResult: Sendable, Equatable {
    public let envelopes: [RecordEnvelope]
    public let serverSeq: UInt64
    public let hasMore: Bool

    public init(envelopes: [RecordEnvelope], serverSeq: UInt64, hasMore: Bool) {
        self.envelopes = envelopes
        self.serverSeq = serverSeq
        self.hasMore = hasMore
    }
}

public enum SyncError: Error, Equatable, Sendable {
    case noKeyForEpoch(Epoch)
    case notAMember(GroupID)
    case unknownDevice(DeviceID)
    case membershipRefused(String)
    case transportFailure(String)
}

/// What one round of syncing did.
public struct SyncReport: Sendable, Equatable {
    public var pushed = 0
    public var rejected = 0
    public var pulled = 0
    public var applied = 0
    /// Edits that lost to another version, each kept as a conflict copy and
    /// never dropped. Usually an incoming record that lost to a newer local
    /// edit. Also a queued local edit that lost to a newer incoming one, or
    /// that the server refused as older.
    public var conflicts = 0
    /// Records we could not open: the key for that epoch has not arrived, or
    /// the one this Mac holds does not open them.
    public var undecryptable = 0
    /// Our own writes coming back to us. Normal, and not worth showing anyone.
    public var echoes = 0
    /// Refused: bad signature, unenrolled device, an author below write, or
    /// contents that do not decode as what the envelope says they are.
    public var ignored = 0
    /// Set aside: made by a newer version of the app, in a type or format this
    /// one cannot read yet, and applied after an update; or a transaction that
    /// arrived before its budget, applied once the budget is in. Records of a
    /// type or format this build cannot read are kept only up to a limit per
    /// sender (`SyncEngine.setAsideLimit`); past it they count as `ignored`.
    public var deferred = 0
    /// Records that passed every check and that this Mac's database would not
    /// save, for a reason that will repeat. Each is set aside and tried again
    /// on later pulls, its queued row waits meanwhile, and the sync goes on.
    public var unsaved = 0
    public var serverSeq: UInt64 = 0

    public init() {}
}
