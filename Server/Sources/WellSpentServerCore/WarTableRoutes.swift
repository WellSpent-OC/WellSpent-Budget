import Foundation
import Fluent
import Vapor
import WarTableCore

func wtText(_ value: String, maximum: Int = 100) throws -> String {
    let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty, clean.utf8.count <= maximum,
          !clean.unicodeScalars.contains(where: { $0.properties.generalCategory == .control && $0 != "\n" && $0 != "\t" })
    else { throw Abort(.badRequest, reason: "The supplied text is empty, too long or contains control characters.") }
    return clean
}

func wtSnapshot(_ scope: WTScope, _ state: WTPersistedState) -> WTSnapshot {
    let conversations = state.conversations.filter { scope.canRead($0, in: state) }.map { value in
        var result = value
        result.audienceIDs = scope.audience(value).sorted { $0.uuidString < $1.uuidString }
        result.readSequence = state.receipts.first { $0.principalID == scope.me.id && $0.conversationID == value.id }?.sequence ?? 0
        return result
    }
    let sources = state.contextSources.filter { $0.audienceIDs.contains(scope.me.id) }
    let tasks = state.tasks.filter { task in
        conversations.contains { $0.id == task.conversationID } && sources.contains { $0.id == task.sourceID }
    }
    let ids = Set(tasks.map(\.id))
    let grants = state.grants.filter { scope.isOwner || $0.subjectID == scope.me.id }
    var permissions = WTPolicy.permissions(scope.me.role)
    for grant in grants where grant.subjectID == scope.me.id && !grant.isRevoked && grant.expiresAt > Date() {
        permissions += grant.capabilities.filter { !permissions.contains($0) }
    }
    let agents = state.agents.map { value in
        var result = value
        if [.connected, .busy].contains(value.status), (value.lastSeen ?? .distantPast) < Date().addingTimeInterval(-90) {
            result.status = .disconnected
        }
        return result
    }
    return WTSnapshot(installation: state.installation, me: scope.me, permissions: permissions,
        people: scope.activeHumans, agents: agents, conversations: conversations, contextSources: sources,
        grants: grants, tasks: tasks, runs: state.runs.filter { ids.contains($0.taskID) },
        evidence: state.evidence.filter { ids.contains($0.taskID) }, reviews: state.reviews.filter { ids.contains($0.taskID) },
        eventCursor: state.eventCursor)
}

func wtStopTasks(_ predicate: (WTTask) -> Bool, state: inout WTPersistedState) {
    for index in state.tasks.indices where predicate(state.tasks[index]) {
        if state.tasks[index].state == .running { state.tasks[index].state = .stopping }
        else if [.ready, .proposed, .awaitingReview].contains(state.tasks[index].state) { state.tasks[index].state = .paused }
    }
}

func registerWarTableRoutes(_ app: Application) throws {
    let base = app.grouped("extensions", "wartable", "v1")
    let small: HTTPBodyStreamStrategy = .collect(maxSize: "32kb")
    let authed = base.grouped(SessionAuthenticator(), WTAgentAuthenticator())
    let groups = authed.grouped("groups", ":groupID")

    groups.get { request async throws -> WTSnapshot in
        try await withWarTable(request, allowDisabled: true, work: true) { scope, state, _ in wtSnapshot(scope, state) }
    }
    groups.on(.PUT, body: small) { request async throws -> WTSnapshot in
        let body = try request.content.decode(WTConfigureRequest.self)
        let group = try request.parameters.require("groupID", as: UUID.self)
        let name = try wtText(body.displayName)
        return try await request.db.transaction { db in
            let user = try await WarTableHost.verifiedHuman(request, on: db)
            guard await request.application.rateLimiter.allow("wartable-mutation:\(group):\(user)", limit: .warTableMutation) else {
                throw Abort(.tooManyRequests, reason: "WarTable mutation limit reached. Retry after one minute.")
            }
            try await WarTableHost.lockGroup(group, on: db)
            let founder = try await WarTableHost.founder(group, on: db)
            if let row = try await WTInstallationRow.find(group, on: db) {
                var state = try wtDecode(WTPersistedState.self, row.payload)
                let scope = try await wtScope(request, group: group, state: state, on: db, allowDisabled: true)
                guard scope.isOwner else { throw Abort(.forbidden) }
                state.installation.isEnabled = body.enabled
                state.installation.revision += 1
                if !body.enabled { wtStopTasks({ _ in true }, state: &state) }
                try await wtEvent(body.enabled ? "enabled" : "disabled", summary: body.enabled ? "WarTable enabled" : "WarTable disabled", state: &state, on: db)
                row.payload = try wtEncode(state); row.revision += 1; try await row.save(on: db)
                return wtSnapshot(scope, state)
            }
            guard user == founder, try await WarTableHost.members(group, on: db).contains(user) else { throw Abort(.forbidden) }
            let owner = WTPerson(id: user, displayName: name, kind: .human, role: .owner)
            var state = WTPersistedState(installation: WTInstallation(id: UUID(), groupID: group, ownerID: user,
                isEnabled: body.enabled, revision: 1), people: [owner], conversations: [WTConversation(id: UUID(),
                title: "Everyone", kind: .everyone, participantIDs: [], audienceIDs: [user])])
            try await wtEvent("installed", summary: "WarTable installed", state: &state, on: db)
            try await WTInstallationRow(id: group, payload: wtEncode(state)).create(on: db)
            return wtSnapshot(WTScope(me: owner, activeHumans: [owner], activeAgents: []), state)
        }
    }
    groups.on(.POST, "roles", body: small) { request async throws -> WTSnapshot in
        let body = try request.content.decode(WTSetRoleRequest.self)
        let name = try wtText(body.displayName)
        return try await withWarTable(request) { scope, state, db in
            guard scope.isOwner || scope.me.role == .admin else { throw Abort(.forbidden) }
            guard body.userID != state.installation.ownerID, body.role != .owner,
                  scope.isOwner || body.role != .admin else { throw Abort(.forbidden, reason: "Only the owner can assign admins; ownership cannot be changed here.") }
            guard scope.isOwner || state.people.first(where: { $0.id == body.userID })?.role != .admin else { throw Abort(.forbidden) }
            if let role = body.role {
                guard try await WarTableHost.members(state.installation.groupID, on: db).contains(body.userID),
                      let user = try await UserRow.find(body.userID, on: db), user.emailVerifiedAt != nil else { throw Abort(.forbidden, reason: "Choose a verified current group member.") }
                // A promotion cannot retroactively expose retained private source content.
                for source in state.contextSources where state.retainedSourceIDs.contains(source.id) {
                    if WTPolicy.oversees(role) && !source.audienceIDs.contains(body.userID) {
                        throw Abort(.conflict, reason: "Approve this person's access to retained context before assigning an oversight role.")
                    }
                }
                state.people.removeAll { $0.id == body.userID }
                state.people.append(WTPerson(id: body.userID, displayName: name, kind: .human, role: role))
            } else { state.people.removeAll { $0.id == body.userID } }
            state.installation.revision += 1
            try await wtEvent("roleChanged", summary: "A human's WarTable role changed", subject: body.userID, overseersOnly: true, state: &state, on: db)
            let updated = try await wtScope(request, group: state.installation.groupID, state: state, on: db)
            return wtSnapshot(updated, state)
        }
    }
    groups.on(.POST, "owner", body: small) { request async throws -> WTSnapshot in
        let body = try request.content.decode(WTTransferOwner.self)
        return try await withWarTable(request, allowDisabled: true) { scope, state, db in
            guard scope.isOwner, body.userID != scope.me.id,
                  let index = state.people.firstIndex(where: { $0.id == body.userID }),
                  scope.activeHumans.contains(where: { $0.id == body.userID }),
                  let user = try await UserRow.find(body.userID, on: db), user.emailVerifiedAt != nil else { throw Abort(.forbidden) }
            guard state.contextSources.allSatisfy({ !state.retainedSourceIDs.contains($0.id) || $0.audienceIDs.contains(body.userID) }) else {
                throw Abort(.conflict, reason: "Approve the new owner's access to all retained source content first.")
            }
            if let previous = state.people.firstIndex(where: { $0.id == scope.me.id }) { state.people[previous].role = .admin }
            state.people[index].role = .owner; state.installation.ownerID = body.userID; state.installation.revision += 1
            wtStopTasks({ _ in true }, state: &state)
            try await wtEvent("ownerTransferred", summary: "Ownership transferred; existing work must be reauthorized", subject: body.userID, state: &state, on: db)
            let people = state.people.filter { person in scope.activeHumans.contains { $0.id == person.id } }
            let updated = WTScope(me: state.people.first { $0.id == scope.me.id }!, activeHumans: people, activeAgents: state.agents)
            return wtSnapshot(updated, state)
        }
    }
    groups.on(.POST, "recover-owner", body: small) { request async throws -> WTInstallation in
        let body = try request.content.decode(WTTransferOwner.self)
        let group = try request.parameters.require("groupID", as: UUID.self)
        return try await request.db.transaction { db in
            let human = try await WarTableHost.verifiedHuman(request, on: db)
            try await WarTableHost.lockGroup(group, on: db)
            guard try await WarTableHost.founder(group, on: db) == human else { throw Abort(.forbidden) }
            let members = try await WarTableHost.members(group, on: db)
            guard members.contains(human), let row = try await WTInstallationRow.find(group, on: db) else { throw Abort(.notFound) }
            var state = try wtDecode(WTPersistedState.self, row.payload)
            let oldOwner = try await UserRow.find(state.installation.ownerID, on: db)
            let ownerHasRole = state.people.contains { $0.id == state.installation.ownerID && $0.role == .owner && $0.kind == .human }
            guard !members.contains(state.installation.ownerID) || oldOwner?.emailVerifiedAt == nil || !ownerHasRole else {
                throw Abort(.conflict, reason: "The current owner is eligible. Ask them to transfer ownership explicitly.")
            }
            guard members.contains(body.userID), let candidate = try await UserRow.find(body.userID, on: db), candidate.emailVerifiedAt != nil else { throw Abort(.forbidden) }
            guard state.contextSources.allSatisfy({ !state.retainedSourceIDs.contains($0.id) || $0.audienceIDs.contains(body.userID) }) else {
                throw Abort(.forbidden, reason: "Recovery cannot bypass retained source disclosure permissions.")
            }
            guard await request.application.rateLimiter.allow("wartable-recovery:\(group):\(human)", limit: .warTableMutation) else { throw Abort(.tooManyRequests) }
            for index in state.people.indices where state.people[index].role == .owner { state.people[index].role = .admin }
            if let index = state.people.firstIndex(where: { $0.id == body.userID }) { state.people[index].role = .owner }
            else { state.people.append(WTPerson(id: body.userID, displayName: "Owner", kind: .human, role: .owner)) }
            state.installation.ownerID = body.userID; state.installation.isEnabled = false; state.installation.revision += 1
            wtStopTasks({ _ in true }, state: &state)
            for index in state.grants.indices { state.grants[index].isRevoked = true }
            try await wtEvent("ownerRecovered", summary: "The verified group founder recovered ownership. Work grants were revoked; the new owner must explicitly enable WarTable.", subject: body.userID, state: &state, on: db)
            row.payload = try wtEncode(state); row.revision += 1; try await row.save(on: db)
            // The founder may have no WarTable role. Return installation status,
            // never a privileged chat snapshot, to that recovery caller.
            return state.installation
        }
    }
    groups.on(.POST, "agents", "enroll", body: small) { request async throws -> WTEnrollment in
        let body = try request.content.decode(WTEnrollAgentRequest.self)
        let name = try wtText(body.name), provider = try wtText(body.provider), machine = try wtText(body.machine)
        guard ["chat-only", "read-only", "enforced-local"].contains(body.executionProfile) else { throw Abort(.badRequest) }
        return try await withWarTable(request) { scope, state, db in
            guard scope.isOwner || scope.me.role == .admin else { throw Abort(.forbidden) }
            guard state.agents.count < 100, !state.agents.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.status != .revoked }) else {
                throw Abort(.conflict, reason: "Choose a unique agent name; each installation supports up to 100 identities.")
            }
            let agent = WTAgent(id: UUID(), name: name, provider: provider, machine: machine, status: .disconnected, executionProfile: body.executionProfile)
            let code = "wte_" + urlSafeToken(), expiry = Date().addingTimeInterval(600)
            state.agents.append(agent)
            try await WTCredentialRow(group: state.installation.groupID, agent: agent.id, hash: tokenDigest(code), kind: "enrollment", expires: expiry).create(on: db)
            try await wtEvent("agentEnrolled", summary: "An agent was enrolled", subject: agent.id, overseersOnly: true, state: &state, on: db)
            return WTEnrollment(agent: agent, code: code, expiresAt: expiry)
        }
    }
    base.on(.POST, "agents", "connect", body: .collect(maxSize: "4kb")) { request async throws -> WTCredential in
        try await request.enforceRateLimit(.warTableEnrollment, scope: "wartable-enrollment")
        let body = try request.content.decode(WTConnectRequest.self)
        guard body.code.utf8.count <= 128,
              let found = try await WTCredentialRow.query(on: request.db).filter(\.$tokenHash == tokenDigest(body.code)).filter(\.$kind == "enrollment").first() else { throw Abort(.unauthorized) }
        let group = found.groupID, credentialID = try found.requireID()
        return try await request.db.transaction { db in
            try await WarTableHost.lockGroup(group, on: db)
            _ = try await WarTableHost.founder(group, on: db)
            guard let code = try await WTCredentialRow.find(credentialID, on: db), !code.revoked, (code.expiresAt ?? .distantPast) > Date(),
                  let row = try await WTInstallationRow.find(group, on: db) else { throw Abort(.unauthorized) }
            var state = try wtDecode(WTPersistedState.self, row.payload)
            guard state.installation.isEnabled,
                  try await WarTableHost.members(group, on: db).contains(state.installation.ownerID),
                  let owner = try await UserRow.find(state.installation.ownerID, on: db), owner.emailVerifiedAt != nil,
                  let index = state.agents.firstIndex(where: { $0.id == code.agentID }), state.agents[index].status != .revoked else { throw Abort(.forbidden) }
            code.revoked = true; try await code.save(on: db)
            let token = "wt_" + urlSafeToken()
            try await WTCredentialRow(group: group, agent: code.agentID, hash: tokenDigest(token), kind: "access").create(on: db)
            state.agents[index].status = .connected; state.agents[index].lastSeen = Date()
            try await wtEvent("agentConnected", summary: "An agent connected", subject: code.agentID, state: &state, on: db)
            row.payload = try wtEncode(state); row.revision += 1; try await row.save(on: db)
            return WTCredential(groupID: group, agentID: code.agentID, token: token)
        }
    }
    groups.on(.POST, "agents", ":agentID", "control", body: small) { request async throws -> WTAgent in
        let body = try request.content.decode(WTAgentControl.self)
        let id = try request.parameters.require("agentID", as: UUID.self)
        return try await withWarTable(request) { scope, state, db in
            guard scope.oversees, let index = state.agents.firstIndex(where: { $0.id == id }) else { throw Abort(.forbidden) }
            guard state.agents[index].status != .revoked else { throw Abort(.conflict, reason: "A revoked identity must be enrolled again.") }
            switch body.action {
            case .pause: state.agents[index].status = .paused
            case .resume: state.agents[index].status = .disconnected
            case .revoke:
                state.agents[index].status = .revoked
                try await WTCredentialRow.query(on: db).filter(\.$groupID == state.installation.groupID).filter(\.$agentID == id).set(\.$revoked, to: true).update()
                wtStopTasks({ $0.assigneeID == id }, state: &state)
            }
            try await wtEvent("agentControl", summary: "Agent \(body.action.rawValue)", subject: id, overseersOnly: true, state: &state, on: db)
            return state.agents[index]
        }
    }
    groups.on(.POST, "presence", body: small) { request async throws -> WTAgent in
        let body = try request.content.decode(WTPresenceRequest.self)
        return try await withWarTable(request) { scope, state, _ in
            guard scope.me.kind == .agent, let index = state.agents.firstIndex(where: { $0.id == scope.me.id }) else { throw Abort(.forbidden) }
            state.agents[index].status = body.busy ? .busy : .connected; state.agents[index].lastSeen = Date()
            return state.agents[index]
        }
    }
    groups.on(.POST, "conversations", body: small) { request async throws -> WTConversation in
        let body = try request.content.decode(WTCreateConversation.self), title = try wtText(body.title)
        return try await withWarTable(request) { scope, state, db in
            let valid = Set(scope.activeHumans.map(\.id) + scope.activeAgents.filter { $0.status != .revoked }.map(\.id))
            let participants = Set(body.participantIDs).union([scope.me.id])
            guard participants.isSubset(of: valid), participants.count >= 2, participants.count <= 30, state.conversations.count < 1000 else { throw Abort(.badRequest) }
            var conversation = WTConversation(id: UUID(), title: title, kind: .direct, participantIDs: participants.sorted { $0.uuidString < $1.uuidString }, audienceIDs: [])
            conversation.audienceIDs = Array(scope.audience(conversation))
            state.conversations.append(conversation)
            try await wtEvent("conversationCreated", summary: "A direct conversation was created", subject: conversation.id, conversation: conversation.id, state: &state, on: db)
            return conversation
        }
    }
    groups.get("messages") { request async throws -> WTMessagePage in
        let conversation = try request.query.get(UUID.self, at: "conversationID")
        let after = try request.query.get(Int?.self, at: "after"), before = try request.query.get(Int?.self, at: "before")
        let limit = min(100, max(1, (try request.query.get(Int?.self, at: "limit")) ?? 100))
        guard after == nil || before == nil else { throw Abort(.badRequest) }
        return try await withWarTable(request) { scope, state, db in
            _ = try scope.conversation(conversation, in: state)
            let query = WTMessageRow.query(on: db).filter(\.$groupID == state.installation.groupID).filter(\.$conversationID == conversation)
            if let after { query.filter(\.$sequence > after) }
            if let before { query.filter(\.$sequence < before) }
            let rows = try await query.sort(\.$sequence, after == nil ? .descending : .ascending).limit(limit + 1).all()
            var messages = try rows.prefix(limit).map { try wtDecode(WTMessage.self, $0.payload) }
            if after == nil { messages.reverse() }
            return WTMessagePage(messages: messages, nextCursor: messages.last?.sequence ?? after ?? 0, hasMore: rows.count > limit)
        }
    }
    groups.on(.POST, "messages", body: .collect(maxSize: "128kb")) { request async throws -> WTMessage in
        let body = try request.content.decode(WTPostMessage.self)
        let text = try wtText(body.text, maximum: WTPolicy.messageByteLimit)
        return try await withWarTable(request) { scope, state, db in
            let conversation = try scope.conversation(body.conversationID, in: state)
            if let existing = try await WTMessageRow.query(on: db).filter(\.$groupID == state.installation.groupID).filter(\.$senderID == scope.me.id).filter(\.$clientMessageID == body.clientMessageID).first() {
                let message = try wtDecode(WTMessage.self, existing.payload)
                guard message.conversationID == body.conversationID,
                      message.isRedacted || (message.text == text && message.replyTo == body.replyTo && Set(message.sourceIDs) == Set(body.sourceIDs)) else {
                    throw Abort(.conflict, reason: "This retry ID was already used for a different message.")
                }
                return message
            }
            guard state.storedMessages < 100_000 else { throw Abort(.insufficientStorage, reason: "This installation reached its retained message metadata limit. Ask the server operator to archive it.") }
            let audience = scope.audience(conversation)
            for id in Set(body.sourceIDs) {
                let source = try scope.source(id, in: state)
                guard audience.isSubset(of: Set(source.audienceIDs)) else { throw Abort(.forbidden, reason: "This context is not approved for every participant and overseer.") }
            }
            let chain: UUID
            if scope.me.kind == .agent {
                guard let parentID = body.replyTo, let chainID = body.chainID,
                      let parentRow = try await WTMessageRow.find(parentID, on: db), parentRow.groupID == state.installation.groupID,
                      let chainIndex = state.chains.firstIndex(where: { $0.id == chainID }) else {
                    throw Abort(.forbidden, reason: "Agent replies require a human-started causal chain.")
                }
                let parent = try wtDecode(WTMessage.self, parentRow.payload)
                let parentConversation = try scope.conversation(parent.conversationID, in: state)
                guard parent.chainID == chainID,
                      state.chains[chainIndex].count < WTPolicy.replyLimit else { throw Abort(.conflict, reason: "This conversation reached its agent reply limit. Ask a human to continue.") }
                guard Set(parent.sourceIDs).isSubset(of: Set(body.sourceIDs)) else {
                    throw Abort(.forbidden, reason: "A reply must retain its parent's context restrictions.")
                }
                guard parentConversation.kind == .direct || WTPolicy.mentions(scope.me.displayName, in: parent.text) else {
                    throw Abort(.forbidden, reason: "A human must address this agent before it replies in Everyone.")
                }
                state.chains[chainIndex].count += 1; chain = chainID
            } else {
                if let replyID = body.replyTo {
                    guard let reply = try await WTMessageRow.find(replyID, on: db), reply.groupID == state.installation.groupID, reply.conversationID == conversation.id else { throw Abort(.badRequest) }
                }
                chain = UUID()
            }
            guard let index = state.conversations.firstIndex(where: { $0.id == conversation.id }) else { throw Abort(.notFound) }
            state.conversations[index].lastSequence += 1
            let message = WTMessage(id: UUID(), conversationID: conversation.id, sequence: state.conversations[index].lastSequence,
                senderID: scope.me.id, senderName: scope.me.displayName, text: text, createdAt: Date(), clientMessageID: body.clientMessageID,
                replyTo: body.replyTo, chainID: chain, sourceIDs: Array(Set(body.sourceIDs)))
            if scope.me.kind == .human { state.chains.append(WTChain(id: chain, count: 0, originID: message.id)) }
            state.retainedSourceIDs.formUnion(body.sourceIDs)
            state.conversationSources[conversation.id, default: []].formUnion(body.sourceIDs)
            try await WTMessageRow(group: state.installation.groupID, message: message).create(on: db)
            state.storedMessages += 1
            try await wtEvent("message", summary: "A message was sent", subject: message.id, conversation: conversation.id, state: &state, on: db)
            return message
        }
    }
    groups.on(.POST, "messages", ":messageID", "redact", body: small) { request async throws -> WTMessage in
        let body = try request.content.decode(WTRedactRequest.self), reason = try wtText(body.reason, maximum: 500)
        let id = try request.parameters.require("messageID", as: UUID.self)
        return try await withWarTable(request) { scope, state, db in
            guard scope.isOwner || scope.me.role == .admin else { throw Abort(.forbidden) }
            guard let row = try await WTMessageRow.find(id, on: db), row.groupID == state.installation.groupID else { throw Abort(.notFound) }
            var message = try wtDecode(WTMessage.self, row.payload)
            _ = try scope.conversation(message.conversationID, in: state)
            message.text = "Message redacted"; message.isRedacted = true
            row.payload = try wtEncode(message); try await row.save(on: db)
            try await wtEvent("redacted", summary: reason, subject: id, conversation: message.conversationID, state: &state, on: db)
            return message
        }
    }
    groups.on(.POST, "receipts", body: small) { request async throws -> HTTPStatus in
        let body = try request.content.decode(WTReadReceipt.self)
        return try await withWarTable(request) { scope, state, _ in
            let conversation = try scope.conversation(body.conversationID, in: state)
            guard body.sequence >= 0, body.sequence <= conversation.lastSequence else { throw Abort(.badRequest) }
            if let index = state.receipts.firstIndex(where: { $0.principalID == scope.me.id && $0.conversationID == conversation.id }) {
                state.receipts[index].sequence = max(body.sequence, state.receipts[index].sequence)
            } else { state.receipts.append(WTStoredReceipt(principalID: scope.me.id, conversationID: conversation.id, sequence: body.sequence)) }
            return .noContent
        }
    }
    groups.get("events") { request async throws -> WTEventPage in
        let after = max(0, (try request.query.get(Int?.self, at: "after")) ?? 0)
        let limit = min(100, max(1, (try request.query.get(Int?.self, at: "limit")) ?? 100))
        return try await withWarTable(request) { scope, state, db in
            let visible = Set(state.conversations.filter { scope.canRead($0, in: state) }.map(\.id))
            // Scan a bounded raw page; advance past hidden rows without disclosing them.
            let rows = try await WTEventRow.query(on: db).filter(\.$groupID == state.installation.groupID).filter(\.$sequence > after).sort(\.$sequence).limit(limit).all()
            let events = try rows.filter { (!$0.overseersOnly || scope.oversees) && ($0.conversationID == nil || visible.contains($0.conversationID!)) }.map { try wtDecode(WTEvent.self, $0.payload) }
            let cursor = rows.last?.sequence ?? max(after, state.eventCursor)
            return WTEventPage(events: events, nextCursor: cursor, hasMore: cursor < state.eventCursor)
        }
    }
    try registerWarTableWorkRoutes(groups)
}
