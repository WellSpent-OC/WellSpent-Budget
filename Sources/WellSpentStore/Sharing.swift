import Foundation
import GRDB
import WellSpentCrypto

/// An invite this device sent and is waiting on.
///
/// The secret stays here because it is what proves the answer came from whoever
/// got the link. It never syncs and never goes to the server.
public struct SentInvite: Sendable, Equatable {
    public let id: Data
    public let groupID: GroupID
    public let secret: Data
    public let level: AccessLevel
    public let historyAccess: HistoryAccess
    public let expiresAt: Date
    public let createdAt: Date

    public init(id: Data, groupID: GroupID, secret: Data, level: AccessLevel,
                historyAccess: HistoryAccess, expiresAt: Date, createdAt: Date = Date()) {
        self.id = id
        self.groupID = groupID
        self.secret = secret
        self.level = level
        self.historyAccess = historyAccess
        self.expiresAt = expiresAt
        self.createdAt = createdAt
    }
}

/// A group this person asked to join, until the inviter's app adds them.
public struct PendingJoin: Sendable, Equatable {
    public let groupID: GroupID
    public let groupName: String
    public let inviterName: String
    /// The name to show the group once in. Written as their member profile then,
    /// because only a member can write one.
    public let displayName: String
    public let level: AccessLevel
    public let requestedAt: Date

    public init(groupID: GroupID, groupName: String, inviterName: String, displayName: String,
                level: AccessLevel, requestedAt: Date = Date()) {
        self.groupID = groupID
        self.groupName = groupName
        self.inviterName = inviterName
        self.displayName = displayName
        self.level = level
        self.requestedAt = requestedAt
    }
}

struct SentInviteRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "sentInvite"

    var id: Data
    var budgetGroupId: String
    var secret: Data
    var level: Int
    var historyAccess: String
    var expiresAt: Date
    var createdAt: Date

    init(_ model: SentInvite) {
        id = model.id
        budgetGroupId = model.groupID.dbValue
        secret = model.secret
        level = model.level.rawValue
        historyAccess = model.historyAccess.rawValue
        expiresAt = model.expiresAt
        createdAt = model.createdAt
    }

    func model() throws -> SentInvite {
        guard let level = AccessLevel(rawValue: level),
              let history = HistoryAccess(rawValue: historyAccess) else {
            throw StoreError.corruptRow("unknown level or history on a sent invite")
        }
        return SentInvite(id: id, groupID: GroupID(try RowCoding.uuid(budgetGroupId)),
                          secret: secret, level: level, historyAccess: history,
                          expiresAt: expiresAt, createdAt: createdAt)
    }
}

struct PendingJoinRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "pendingJoin"

    var budgetGroupId: String
    var groupName: String
    var inviterName: String
    var displayName: String
    var level: Int
    var requestedAt: Date

    init(_ model: PendingJoin) {
        budgetGroupId = model.groupID.dbValue
        groupName = model.groupName
        inviterName = model.inviterName
        displayName = model.displayName
        level = model.level.rawValue
        requestedAt = model.requestedAt
    }

    func model() throws -> PendingJoin {
        PendingJoin(groupID: GroupID(try RowCoding.uuid(budgetGroupId)), groupName: groupName,
                    inviterName: inviterName, displayName: displayName,
                    level: AccessLevel(rawValue: level) ?? .read, requestedAt: requestedAt)
    }
}

extension Store {
    public func save(_ invite: SentInvite) throws {
        try database.write { db in try SentInviteRow(invite).save(db) }
    }

    public func sentInvite(_ id: Data) throws -> SentInvite? {
        try database.read { db in try SentInviteRow.fetchOne(db, key: id)?.model() }
    }

    public func sentInvites(in group: GroupID) throws -> [SentInvite] {
        try database.read { db in
            try SentInviteRow.filter(Column("budgetGroupId") == group.dbValue)
                .order(Column("createdAt")).fetchAll(db).map { try $0.model() }
        }
    }

    public func deleteSentInvite(_ id: Data) throws {
        _ = try database.write { db in try SentInviteRow.deleteOne(db, key: id) }
    }

    public func save(_ join: PendingJoin) throws {
        try database.write { db in try PendingJoinRow(join).save(db) }
    }

    public func pendingJoins() throws -> [PendingJoin] {
        try database.read { db in
            try PendingJoinRow.order(Column("requestedAt")).fetchAll(db).map { try $0.model() }
        }
    }

    public func pendingJoin(_ group: GroupID) throws -> PendingJoin? {
        try database.read { db in try PendingJoinRow.fetchOne(db, key: group.dbValue)?.model() }
    }

    public func deletePendingJoin(_ group: GroupID) throws {
        _ = try database.write { db in try PendingJoinRow.deleteOne(db, key: group.dbValue) }
    }
}
