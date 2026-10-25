import Foundation
import Fluent
import SQLKit
import Vapor
import WarTableCore

/// Extension-owned persistence. Financial records remain untouched. State
/// changes serialize on one installation row; messages/events are paged tables.
final class WTInstallationRow: Model, @unchecked Sendable {
    static let schema = "wartable_installations"
    @ID(key: .id) var id: UUID?
    @Field(key: "payload") var payload: String
    @Field(key: "revision") var revision: Int
    init() {}
    init(id: UUID, payload: String) { self.id = id; self.payload = payload; revision = 1 }
}

final class WTCredentialRow: Model, @unchecked Sendable {
    static let schema = "wartable_credentials"
    @ID(key: .id) var id: UUID?
    @Field(key: "group_id") var groupID: UUID
    @Field(key: "agent_id") var agentID: UUID
    @Field(key: "token_hash") var tokenHash: String
    @Field(key: "kind") var kind: String
    @OptionalField(key: "expires_at") var expiresAt: Date?
    @Field(key: "revoked") var revoked: Bool
    init() {}
    init(group: UUID, agent: UUID, hash: String, kind: String, expires: Date? = nil) {
        id = UUID(); groupID = group; agentID = agent; tokenHash = hash
        self.kind = kind; expiresAt = expires; revoked = false
    }
}

final class WTMessageRow: Model, @unchecked Sendable {
    static let schema = "wartable_messages"
    @ID(key: .id) var id: UUID?
    @Field(key: "group_id") var groupID: UUID
    @Field(key: "conversation_id") var conversationID: UUID
    @Field(key: "sequence") var sequence: Int
    @Field(key: "sender_id") var senderID: UUID
    @Field(key: "client_message_id") var clientMessageID: UUID
    @Field(key: "payload") var payload: String
    @Field(key: "created_at") var createdAt: Date
    @Field(key: "expired") var expired: Bool
    init() {}
    init(group: UUID, message: WTMessage) throws {
        id = message.id; groupID = group; conversationID = message.conversationID
        sequence = message.sequence; senderID = message.senderID; clientMessageID = message.clientMessageID
        payload = try wtEncode(message)
        createdAt = message.createdAt; expired = false
    }
}

final class WTEventRow: Model, @unchecked Sendable {
    static let schema = "wartable_events"
    @ID(key: .id) var id: UUID?
    @Field(key: "group_id") var groupID: UUID
    @Field(key: "sequence") var sequence: Int
    @OptionalField(key: "conversation_id") var conversationID: UUID?
    @Field(key: "overseers_only") var overseersOnly: Bool
    @Field(key: "payload") var payload: String
    @Field(key: "created_at") var createdAt: Date
    init() {}
    init(group: UUID, event: WTEvent, overseersOnly: Bool = false) throws {
        id = event.id; groupID = group; sequence = event.sequence
        conversationID = event.conversationID; self.overseersOnly = overseersOnly
        payload = try wtEncode(event)
        createdAt = event.createdAt
    }
}

struct WTChain: Codable, Sendable { var id: UUID; var count: Int; var originID: UUID }
struct WTStoredReceipt: Codable, Sendable { var principalID: UUID; var conversationID: UUID; var sequence: Int }
struct WTRunDeadline: Codable, Sendable { var runID: UUID; var deadline: Date }
struct WTPersistedState: Codable, Sendable {
    var installation: WTInstallation
    var people: [WTPerson]
    var agents: [WTAgent] = []
    var conversations: [WTConversation]
    var contextSources: [WTContextSource] = []
    var retainedSourceIDs: Set<UUID> = []
    var conversationSources: [UUID: Set<UUID>] = [:]
    var grants: [WTGrant] = []
    var tasks: [WTTask] = []
    var runs: [WTRun] = []
    var evidence: [WTEvidence] = []
    var reviews: [WTReview] = []
    var chains: [WTChain] = []
    var receipts: [WTStoredReceipt] = []
    var deadlines: [WTRunDeadline] = []
    var eventCursor = 0
    var nextFence = 0
    var storedMessages = 0
    var lastPrunedAt: Date? = nil
}

func wtEncode<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}
func wtDecode<T: Decodable>(_ type: T.Type, _ value: String) throws -> T {
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: Data(value.utf8))
}

struct CreateWarTable: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(WTInstallationRow.schema).id()
            .field("payload", .string, .required).field("revision", .int, .required).create()
        try await db.schema(WTCredentialRow.schema).id()
            .field("group_id", .uuid, .required).field("agent_id", .uuid, .required)
            .field("token_hash", .string, .required).field("kind", .string, .required)
            .field("expires_at", .datetime).field("revoked", .bool, .required)
            .unique(on: "token_hash").create()
        try await db.schema(WTMessageRow.schema).id()
            .field("group_id", .uuid, .required).field("conversation_id", .uuid, .required)
            .field("sequence", .int, .required).field("sender_id", .uuid, .required)
            .field("client_message_id", .uuid, .required).field("payload", .string, .required)
            .field("created_at", .datetime, .required).field("expired", .bool, .required)
            .unique(on: "group_id", "sender_id", "client_message_id")
            .unique(on: "conversation_id", "sequence").create()
        try await db.schema(WTEventRow.schema).id()
            .field("group_id", .uuid, .required).field("sequence", .int, .required)
            .field("conversation_id", .uuid).field("overseers_only", .bool, .required)
            .field("payload", .string, .required).unique(on: "group_id", "sequence").create()
        try await db.schema(WTEventRow.schema).field("created_at", .datetime, .required).update()
        if let sql = db as? any SQLDatabase {
            try await sql.raw("CREATE INDEX wartable_message_retention ON wartable_messages (group_id, expired, created_at)").run()
            try await sql.raw("CREATE INDEX wartable_event_retention ON wartable_events (group_id, created_at)").run()
        }
    }
    func revert(on db: any Database) async throws {
        for schema in [WTEventRow.schema, WTMessageRow.schema, WTCredentialRow.schema, WTInstallationRow.schema] {
            try await db.schema(schema).delete()
        }
    }
}

/// Narrow host seam: extension code consumes verified IDs and current
/// membership, not the host's account rows or human bearer credentials.
enum WarTableHost {
    static func verifiedHuman(_ request: Request, on database: (any Database)? = nil) async throws -> UUID {
        let id = try request.auth.require(AuthenticatedUser.self).id
        guard let user = try await UserRow.find(id, on: database ?? request.db), user.emailVerifiedAt != nil else {
            throw Abort(.forbidden, reason: "Confirm your email before using WarTable.")
        }
        return id
    }
    static func members(_ group: UUID, on db: any Database) async throws -> Set<UUID> {
        Set(try await MembershipRow.query(on: db).filter(\.$groupID == group)
            .filter(\.$level > 0).all().map(\.userID))
    }
    static func founder(_ group: UUID, on db: any Database) async throws -> UUID {
        guard let row = try await GroupRow.find(group, on: db), row.deletedAt == nil else {
            throw Abort(.notFound)
        }
        return row.founderID
    }
    static func lockGroup(_ group: UUID, on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
        try await sql.update(GroupRow.schema).set("last_seq", to: SQLColumn("last_seq"))
            .where("id", .equal, SQLBind(group)).run()
    }
    /// Called by the host inside its membership-removal transaction. Rejoining
    /// the budget group must not resurrect an old extension admin assignment.
    static func memberRemoved(_ user: UUID, group: UUID, on db: any Database) async throws {
        guard let row = try await WTInstallationRow.find(group, on: db) else { return }
        var state = try wtDecode(WTPersistedState.self, row.payload)
        state.people.removeAll { $0.id == user }
        state.installation.revision += 1
        if state.installation.ownerID == user { state.installation.isEnabled = false; wtStopTasks({ _ in true }, state: &state) }
        else { wtStopTasks({ $0.reviewerID == user }, state: &state) }
        for index in state.grants.indices where state.grants[index].subjectID == user { state.grants[index].isRevoked = true }
        try await wtEvent("hostMemberRemoved", summary: "A removed group member lost extension access and grants", subject: user, overseersOnly: true, state: &state, on: db)
        row.payload = try wtEncode(state); row.revision += 1; try await row.save(on: db)
    }
}

struct WTAuthenticatedAgent: Authenticatable, Sendable {
    var id: UUID; var groupID: UUID; var credentialID: UUID
}
struct WTAgentAuthenticator: AsyncBearerAuthenticator {
    func authenticate(bearer: BearerAuthorization, for request: Request) async throws {
        guard bearer.token.hasPrefix("wt_"),
              let row = try await WTCredentialRow.query(on: request.db)
                .filter(\.$tokenHash == tokenDigest(bearer.token)).filter(\.$kind == "access").first()
        else { return }
        // A revoked credential can only acknowledge cancellation; every
        // domain route checks current state again inside the transaction.
        request.auth.login(WTAuthenticatedAgent(id: row.agentID, groupID: row.groupID,
                                               credentialID: try row.requireID()))
    }
}

struct WTScope: Sendable {
    var me: WTPerson
    var activeHumans: [WTPerson]
    var activeAgents: [WTAgent]
    var isOwner: Bool { me.role == .owner }
    var oversees: Bool { WTPolicy.oversees(me.role) }
    func audience(_ conversation: WTConversation) -> Set<UUID> {
        let all = Set(activeHumans.map(\.id) + activeAgents.filter { $0.status != .revoked }.map(\.id))
        if conversation.kind == .everyone { return all }
        return Set(conversation.participantIDs).intersection(all)
            .union(activeHumans.filter { WTPolicy.oversees($0.role) }.map(\.id))
    }
    func conversation(_ id: UUID, in state: WTPersistedState) throws -> WTConversation {
        guard let conversation = state.conversations.first(where: { $0.id == id }),
              canRead(conversation, in: state) else { throw Abort(.notFound) }
        return conversation
    }
    func canRead(_ conversation: WTConversation, in state: WTPersistedState) -> Bool {
        audience(conversation).contains(me.id) && (state.conversationSources[conversation.id] ?? []).allSatisfy { id in
            state.contextSources.first(where: { $0.id == id })?.audienceIDs.contains(me.id) == true
        }
    }
    func source(_ id: UUID, in state: WTPersistedState) throws -> WTContextSource {
        guard let source = state.contextSources.first(where: { $0.id == id }),
              source.audienceIDs.contains(me.id) else { throw Abort(.notFound) }
        return source
    }
}

func wtScope(_ request: Request, group: UUID, state: WTPersistedState,
             on db: any Database, allowDisabled: Bool = false, cleanup: Bool = false, work: Bool = false) async throws -> WTScope {
    _ = try await WarTableHost.founder(group, on: db)
    let members = try await WarTableHost.members(group, on: db)
    guard members.contains(state.installation.ownerID),
          let owner = try await UserRow.find(state.installation.ownerID, on: db),
          owner.emailVerifiedAt != nil else {
        throw Abort(.forbidden, reason: "WarTable needs an eligible human owner before it can resume.")
    }
    let people = state.people.filter { members.contains($0.id) }
    let me: WTPerson
    if let agent = request.auth.get(WTAuthenticatedAgent.self) {
        guard agent.groupID == group,
              let credential = try await WTCredentialRow.find(agent.credentialID, on: db),
              credential.groupID == group,
              let record = state.agents.first(where: { $0.id == agent.id }),
              cleanup || (!credential.revoked && (work || record.status != .paused) && record.status != .revoked)
        else { throw Abort(.forbidden, reason: "This agent is paused or revoked.") }
        me = WTPerson(id: agent.id, displayName: record.name, kind: .agent)
    } else {
        let id = try await WarTableHost.verifiedHuman(request, on: db)
        guard let human = people.first(where: { $0.id == id }) else { throw Abort(.notFound) }
        me = human
    }
    guard state.installation.isEnabled || (allowDisabled && me.role == .owner) || cleanup else {
        throw Abort(.forbidden, reason: "WarTable is disabled.")
    }
    return WTScope(me: me, activeHumans: people, activeAgents: state.agents)
}

func withWarTable<T: Sendable>(_ request: Request, allowDisabled: Bool = false, cleanup: Bool = false, work: Bool = false,
    _ body: @escaping @Sendable (WTScope, inout WTPersistedState, any Database) async throws -> T) async throws -> T {
    let group = try request.parameters.require("groupID", as: UUID.self)
    return try await request.db.transaction { db in
        try await WarTableHost.lockGroup(group, on: db)
        guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
        try await sql.update(WTInstallationRow.schema).set("revision", to: SQLColumn("revision"))
            .where("id", .equal, SQLBind(group)).run()
        guard let row = try await WTInstallationRow.find(group, on: db) else { throw Abort(.notFound) }
        var state = try wtDecode(WTPersistedState.self, row.payload)
        let scope = try await wtScope(request, group: group, state: state, on: db,
                                      allowDisabled: allowDisabled, cleanup: cleanup, work: work)
        if request.method != .GET && !cleanup {
            guard await request.application.rateLimiter.allow("wartable-mutation:\(group):\(scope.me.id)", limit: .warTableMutation) else {
                throw Abort(.tooManyRequests, reason: "WarTable mutation limit reached. Retry after one minute.")
            }
        }
        if (state.lastPrunedAt ?? .distantPast) < Date().addingTimeInterval(-86400) {
            let days = min(3650, max(1, Int(Environment.get("WARTABLE_RETENTION_DAYS") ?? "90") ?? 90))
            let caughtUp = try await wtPrune(group: group, on: db, days: days)
            if caughtUp { state.lastPrunedAt = Date() }
        }
        let result = try await body(scope, &state, db)
        let encoded = try wtEncode(state)
        if encoded != row.payload { row.payload = encoded; row.revision += 1; try await row.save(on: db) }
        return result
    }
}

/// Bodies expire, while stable sequence/author/idempotency metadata remains.
/// Source-disclosure restrictions intentionally survive expiry: an audit event
/// and a backup may still contain context. Backup expiry is an operator duty.
@discardableResult
func wtPrune(group: UUID, on db: any Database, days: Int, now: Date = Date()) async throws -> Bool {
    let cutoff = now.addingTimeInterval(-TimeInterval(days) * 86400)
    let rows = try await WTMessageRow.query(on: db).filter(\.$groupID == group).filter(\.$expired == false)
        .filter(\.$createdAt < cutoff).sort(\.$createdAt).limit(256).all()
    for row in rows {
        var message = try wtDecode(WTMessage.self, row.payload)
        message.text = "Message expired"; message.isRedacted = true
        row.payload = try wtEncode(message); row.expired = true; try await row.save(on: db)
    }
    try await WTEventRow.query(on: db).filter(\.$groupID == group).filter(\.$createdAt < cutoff).delete()
    return rows.count < 256
}

func wtEvent(_ kind: String, summary: String, subject: UUID? = nil, conversation: UUID? = nil,
             overseersOnly: Bool = false, state: inout WTPersistedState, on db: any Database) async throws {
    state.eventCursor += 1
    let event = WTEvent(id: UUID(), sequence: state.eventCursor, kind: kind, subjectID: subject,
                       conversationID: conversation, createdAt: Date(), summary: summary)
    try await WTEventRow(group: state.installation.groupID, event: event, overseersOnly: overseersOnly).create(on: db)
}
