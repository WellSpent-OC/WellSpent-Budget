// SPDX-License-Identifier: MIT
import Foundation

public enum WTPrincipalKind: String, Codable, Sendable, CaseIterable { case human, agent }
public enum WTRole: String, Codable, Sendable, CaseIterable { case owner, admin, manager, member }
public enum WTAgentStatus: String, Codable, Sendable, CaseIterable { case connected, busy, disconnected, paused, revoked }
public enum WTConversationKind: String, Codable, Sendable, CaseIterable { case everyone, direct }
public enum WTSourceKind: String, Codable, Sendable, CaseIterable { case repository, kb }
public enum WTTaskState: String, Codable, Sendable, CaseIterable { case proposed, ready, running, awaitingReview, done, blocked, stopping, paused, cancelled }
public enum WTReviewDecision: String, Codable, Sendable, CaseIterable { case approve, requestChanges, comment }
public enum WTAgentAction: String, Codable, Sendable, CaseIterable { case pause, resume, revoke }
public enum WTCapability: String, Codable, Sendable, CaseIterable { case readChat, sendMessage, manageInstallation, managePeople, manageAgents, enrollAgents, redact, readContext, proposeTask, authorizeTask, editBranch, runChecks, openPR, review, merge, writeHandoff }

public struct WTInstallation: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var groupID: UUID
    public var ownerID: UUID
    public var isEnabled: Bool
    public var revision: Int
    public var oversightNotice: String
    public init(id: UUID, groupID: UUID, ownerID: UUID, isEnabled: Bool, revision: Int, oversightNotice: String =  "The owner, extension admins and managers can read every conversation.") {
        self.id = id
        self.groupID = groupID
        self.ownerID = ownerID
        self.isEnabled = isEnabled
        self.revision = revision
        self.oversightNotice = oversightNotice
    }
}

public struct WTPerson: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var displayName: String
    public var kind: WTPrincipalKind
    public var role: WTRole?
    public init(id: UUID, displayName: String, kind: WTPrincipalKind, role: WTRole? = nil) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.role = role
    }
}

public struct WTAgent: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var provider: String
    public var machine: String
    public var status: WTAgentStatus
    public var lastSeen: Date?
    public var executionProfile: String
    public init(id: UUID, name: String, provider: String, machine: String, status: WTAgentStatus, lastSeen: Date? = nil, executionProfile: String = "chat-only") {
        self.id = id
        self.name = name
        self.provider = provider
        self.machine = machine
        self.status = status
        self.lastSeen = lastSeen
        self.executionProfile = executionProfile
    }
}

public struct WTConversation: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var kind: WTConversationKind
    public var participantIDs: [UUID]
    public var audienceIDs: [UUID]
    public var lastSequence: Int
    public var readSequence: Int
    public init(id: UUID, title: String, kind: WTConversationKind, participantIDs: [UUID], audienceIDs: [UUID], lastSequence: Int = 0, readSequence: Int = 0) {
        self.id = id
        self.title = title
        self.kind = kind
        self.participantIDs = participantIDs
        self.audienceIDs = audienceIDs
        self.lastSequence = lastSequence
        self.readSequence = readSequence
    }
}

public struct WTMessage: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var conversationID: UUID
    public var sequence: Int
    public var senderID: UUID
    public var senderName: String
    public var text: String
    public var createdAt: Date
    public var clientMessageID: UUID
    public var replyTo: UUID?
    public var chainID: UUID?
    public var sourceIDs: [UUID]
    public var isRedacted: Bool
    public init(id: UUID, conversationID: UUID, sequence: Int, senderID: UUID, senderName: String, text: String, createdAt: Date, clientMessageID: UUID, replyTo: UUID? = nil, chainID: UUID? = nil, sourceIDs: [UUID] = [], isRedacted: Bool = false) {
        self.id = id
        self.conversationID = conversationID
        self.sequence = sequence
        self.senderID = senderID
        self.senderName = senderName
        self.text = text
        self.createdAt = createdAt
        self.clientMessageID = clientMessageID
        self.replyTo = replyTo
        self.chainID = chainID
        self.sourceIDs = sourceIDs
        self.isRedacted = isRedacted
    }
}

public struct WTMessagePage: Codable, Sendable, Equatable {
    public var messages: [WTMessage]
    public var nextCursor: Int
    public var hasMore: Bool
    public init(messages: [WTMessage], nextCursor: Int, hasMore: Bool) {
        self.messages = messages
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}

public struct WTEvent: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var sequence: Int
    public var kind: String
    public var subjectID: UUID?
    public var conversationID: UUID?
    public var createdAt: Date
    public var summary: String
    public init(id: UUID, sequence: Int, kind: String, subjectID: UUID? = nil, conversationID: UUID? = nil, createdAt: Date, summary: String) {
        self.id = id
        self.sequence = sequence
        self.kind = kind
        self.subjectID = subjectID
        self.conversationID = conversationID
        self.createdAt = createdAt
        self.summary = summary
    }
}

public struct WTEventPage: Codable, Sendable, Equatable {
    public var events: [WTEvent]
    public var nextCursor: Int
    public var hasMore: Bool
    public init(events: [WTEvent], nextCursor: Int, hasMore: Bool) {
        self.events = events
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}

public struct WTContextSource: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: WTSourceKind
    public var reference: String
    public var allowedPaths: [String]
    public var audienceIDs: [UUID]
    public var isPublic: Bool
    public var revision: Int
    public var status: String
    public init(id: UUID, name: String, kind: WTSourceKind, reference: String, allowedPaths: [String], audienceIDs: [UUID], isPublic: Bool, revision: Int, status: String = "Needs access") {
        self.id = id
        self.name = name
        self.kind = kind
        self.reference = reference
        self.allowedPaths = allowedPaths
        self.audienceIDs = audienceIDs
        self.isPublic = isPublic
        self.revision = revision
        self.status = status
    }
}

public struct WTGrant: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var subjectID: UUID
    public var sourceID: UUID
    public var capabilities: [WTCapability]
    public var allowedPaths: [String]
    public var expiresAt: Date
    public var maxRevisionCycles: Int
    public var maxRuntimeSeconds: Int
    public var isRevoked: Bool
    public init(id: UUID, subjectID: UUID, sourceID: UUID, capabilities: [WTCapability], allowedPaths: [String], expiresAt: Date, maxRevisionCycles: Int = 3, maxRuntimeSeconds: Int = 3600, isRevoked: Bool = false) {
        self.id = id
        self.subjectID = subjectID
        self.sourceID = sourceID
        self.capabilities = capabilities
        self.allowedPaths = allowedPaths
        self.expiresAt = expiresAt
        self.maxRevisionCycles = maxRevisionCycles
        self.maxRuntimeSeconds = maxRuntimeSeconds
        self.isRevoked = isRevoked
    }
}

public struct WTContextReceipt: Codable, Sendable, Equatable {
    public var sourceID: UUID
    public var sourceRevision: Int
    public var revision: String
    public var rulesRevision: String
    public var handoffReference: String
    public var patchFingerprint: String?
    public init(sourceID: UUID, sourceRevision: Int, revision: String, rulesRevision: String, handoffReference: String = "", patchFingerprint: String? = nil) {
        self.sourceID = sourceID
        self.sourceRevision = sourceRevision
        self.revision = revision
        self.rulesRevision = rulesRevision
        self.handoffReference = handoffReference
        self.patchFingerprint = patchFingerprint
    }
}

public struct WTTask: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var conversationID: UUID
    public var sourceID: UUID
    public var title: String
    public var details: String
    public var creatorID: UUID
    public var state: WTTaskState
    public var assigneeID: UUID?
    public var grantID: UUID?
    public var reviewerID: UUID?
    public var expectedChecks: [String]
    public var headCommit: String?
    public var prURL: String?
    public var revisionCycles: Int
    public init(id: UUID, conversationID: UUID, sourceID: UUID, title: String, details: String, creatorID: UUID, state: WTTaskState, assigneeID: UUID? = nil, grantID: UUID? = nil, reviewerID: UUID? = nil, expectedChecks: [String] = [], headCommit: String? = nil, prURL: String? = nil, revisionCycles: Int = 0) {
        self.id = id
        self.conversationID = conversationID
        self.sourceID = sourceID
        self.title = title
        self.details = details
        self.creatorID = creatorID
        self.state = state
        self.assigneeID = assigneeID
        self.grantID = grantID
        self.reviewerID = reviewerID
        self.expectedChecks = expectedChecks
        self.headCommit = headCommit
        self.prURL = prURL
        self.revisionCycles = revisionCycles
    }
}

public struct WTRun: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var taskID: UUID
    public var agentID: UUID
    public var workerID: String
    public var requestID: UUID
    public var fence: Int
    public var leaseExpiresAt: Date
    public var state: String
    public var contextReceipt: WTContextReceipt
    public init(id: UUID, taskID: UUID, agentID: UUID, workerID: String, requestID: UUID, fence: Int, leaseExpiresAt: Date, state: String, contextReceipt: WTContextReceipt) {
        self.id = id
        self.taskID = taskID
        self.agentID = agentID
        self.workerID = workerID
        self.requestID = requestID
        self.fence = fence
        self.leaseExpiresAt = leaseExpiresAt
        self.state = state
        self.contextReceipt = contextReceipt
    }
}

public struct WTEvidence: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var taskID: UUID
    public var runID: UUID
    public var kind: String
    public var summary: String
    public var commit: String?
    public var url: String?
    public var createdAt: Date
    public init(id: UUID, taskID: UUID, runID: UUID, kind: String, summary: String, commit: String? = nil, url: String? = nil, createdAt: Date) {
        self.id = id
        self.taskID = taskID
        self.runID = runID
        self.kind = kind
        self.summary = summary
        self.commit = commit
        self.url = url
        self.createdAt = createdAt
    }
}

public struct WTReview: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var taskID: UUID
    public var reviewerID: UUID
    public var headCommit: String
    public var baseCommit: String
    public var decision: WTReviewDecision
    public var summary: String
    public var policyRevision: Int
    public var providerConfirmed: Bool
    public var createdAt: Date
    public init(id: UUID, taskID: UUID, reviewerID: UUID, headCommit: String, baseCommit: String, decision: WTReviewDecision, summary: String, policyRevision: Int, providerConfirmed: Bool = false, createdAt: Date) {
        self.id = id
        self.taskID = taskID
        self.reviewerID = reviewerID
        self.headCommit = headCommit
        self.baseCommit = baseCommit
        self.decision = decision
        self.summary = summary
        self.policyRevision = policyRevision
        self.providerConfirmed = providerConfirmed
        self.createdAt = createdAt
    }
}

public struct WTSnapshot: Codable, Sendable, Equatable {
    public var installation: WTInstallation
    public var me: WTPerson
    public var permissions: [WTCapability]
    public var people: [WTPerson]
    public var agents: [WTAgent]
    public var conversations: [WTConversation]
    public var contextSources: [WTContextSource]
    public var grants: [WTGrant]
    public var tasks: [WTTask]
    public var runs: [WTRun]
    public var evidence: [WTEvidence]
    public var reviews: [WTReview]
    public var eventCursor: Int
    public init(installation: WTInstallation, me: WTPerson, permissions: [WTCapability], people: [WTPerson], agents: [WTAgent], conversations: [WTConversation], contextSources: [WTContextSource], grants: [WTGrant], tasks: [WTTask], runs: [WTRun], evidence: [WTEvidence], reviews: [WTReview], eventCursor: Int) {
        self.installation = installation
        self.me = me
        self.permissions = permissions
        self.people = people
        self.agents = agents
        self.conversations = conversations
        self.contextSources = contextSources
        self.grants = grants
        self.tasks = tasks
        self.runs = runs
        self.evidence = evidence
        self.reviews = reviews
        self.eventCursor = eventCursor
    }
}

public struct WTConfigureRequest: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var displayName: String
    public init(enabled: Bool, displayName: String = "Owner") {
        self.enabled = enabled
        self.displayName = displayName
    }
}

public struct WTSetRoleRequest: Codable, Sendable, Equatable {
    public var userID: UUID
    public var role: WTRole?
    public var displayName: String
    public init(userID: UUID, role: WTRole? = nil, displayName: String = "Member") {
        self.userID = userID
        self.role = role
        self.displayName = displayName
    }
}

public struct WTCreateConversation: Codable, Sendable, Equatable {
    public var title: String
    public var participantIDs: [UUID]
    public init(title: String, participantIDs: [UUID]) {
        self.title = title
        self.participantIDs = participantIDs
    }
}

public struct WTPostMessage: Codable, Sendable, Equatable {
    public var conversationID: UUID
    public var clientMessageID: UUID
    public var text: String
    public var replyTo: UUID?
    public var chainID: UUID?
    public var sourceIDs: [UUID]
    public init(conversationID: UUID, clientMessageID: UUID, text: String, replyTo: UUID? = nil, chainID: UUID? = nil, sourceIDs: [UUID] = []) {
        self.conversationID = conversationID
        self.clientMessageID = clientMessageID
        self.text = text
        self.replyTo = replyTo
        self.chainID = chainID
        self.sourceIDs = sourceIDs
    }
}

public struct WTReadReceipt: Codable, Sendable, Equatable {
    public var conversationID: UUID
    public var sequence: Int
    public init(conversationID: UUID, sequence: Int) {
        self.conversationID = conversationID
        self.sequence = sequence
    }
}

public struct WTRedactRequest: Codable, Sendable, Equatable {
    public var reason: String
    public init(reason: String) {
        self.reason = reason
    }
}

public struct WTEnrollAgentRequest: Codable, Sendable, Equatable {
    public var name: String
    public var provider: String
    public var machine: String
    public var executionProfile: String
    public init(name: String, provider: String, machine: String, executionProfile: String = "chat-only") {
        self.name = name
        self.provider = provider
        self.machine = machine
        self.executionProfile = executionProfile
    }
}

public struct WTEnrollment: Codable, Sendable, Equatable {
    public var agent: WTAgent
    public var code: String
    public var expiresAt: Date
    public init(agent: WTAgent, code: String, expiresAt: Date) {
        self.agent = agent
        self.code = code
        self.expiresAt = expiresAt
    }
}

public struct WTConnectRequest: Codable, Sendable, Equatable {
    public var code: String
    public init(code: String) {
        self.code = code
    }
}

public struct WTCredential: Codable, Sendable, Equatable {
    public var groupID: UUID
    public var agentID: UUID
    public var token: String
    public init(groupID: UUID, agentID: UUID, token: String) {
        self.groupID = groupID
        self.agentID = agentID
        self.token = token
    }
}

public struct WTAgentControl: Codable, Sendable, Equatable {
    public var action: WTAgentAction
    public init(action: WTAgentAction) {
        self.action = action
    }
}

public struct WTPresenceRequest: Codable, Sendable, Equatable {
    public var busy: Bool
    public init(busy: Bool = false) {
        self.busy = busy
    }
}

public struct WTCreateSource: Codable, Sendable, Equatable {
    public var name: String
    public var kind: WTSourceKind
    public var reference: String
    public var allowedPaths: [String]
    public var audienceIDs: [UUID]
    public var isPublic: Bool
    public init(name: String, kind: WTSourceKind, reference: String, allowedPaths: [String], audienceIDs: [UUID], isPublic: Bool = false) {
        self.name = name
        self.kind = kind
        self.reference = reference
        self.allowedPaths = allowedPaths
        self.audienceIDs = audienceIDs
        self.isPublic = isPublic
    }
}

public struct WTCreateGrant: Codable, Sendable, Equatable {
    public var subjectID: UUID
    public var sourceID: UUID
    public var capabilities: [WTCapability]
    public var allowedPaths: [String]
    public var expiresAt: Date
    public var maxRevisionCycles: Int
    public var maxRuntimeSeconds: Int
    public init(subjectID: UUID, sourceID: UUID, capabilities: [WTCapability], allowedPaths: [String], expiresAt: Date, maxRevisionCycles: Int = 3, maxRuntimeSeconds: Int = 3600) {
        self.subjectID = subjectID
        self.sourceID = sourceID
        self.capabilities = capabilities
        self.allowedPaths = allowedPaths
        self.expiresAt = expiresAt
        self.maxRevisionCycles = maxRevisionCycles
        self.maxRuntimeSeconds = maxRuntimeSeconds
    }
}

public struct WTCreateTask: Codable, Sendable, Equatable {
    public var conversationID: UUID
    public var sourceID: UUID
    public var title: String
    public var details: String
    public var assigneeID: UUID?
    public var grantID: UUID?
    public var reviewerID: UUID?
    public var expectedChecks: [String]
    public init(conversationID: UUID, sourceID: UUID, title: String, details: String, assigneeID: UUID? = nil, grantID: UUID? = nil, reviewerID: UUID? = nil, expectedChecks: [String] = []) {
        self.conversationID = conversationID
        self.sourceID = sourceID
        self.title = title
        self.details = details
        self.assigneeID = assigneeID
        self.grantID = grantID
        self.reviewerID = reviewerID
        self.expectedChecks = expectedChecks
    }
}

public struct WTAuthorizeTask: Codable, Sendable, Equatable {
    public var grantID: UUID
    public var assigneeID: UUID
    public var reviewerID: UUID?
    public init(grantID: UUID, assigneeID: UUID, reviewerID: UUID? = nil) {
        self.grantID = grantID
        self.assigneeID = assigneeID
        self.reviewerID = reviewerID
    }
}

public struct WTClaimRun: Codable, Sendable, Equatable {
    public var taskID: UUID
    public var requestID: UUID
    public var workerID: String
    public var contextReceipt: WTContextReceipt
    public init(taskID: UUID, requestID: UUID, workerID: String, contextReceipt: WTContextReceipt) {
        self.taskID = taskID
        self.requestID = requestID
        self.workerID = workerID
        self.contextReceipt = contextReceipt
    }
}

public struct WTRunCheckpoint: Codable, Sendable, Equatable {
    public var fence: Int
    public var operation: WTCapability
    public var path: String?
    public init(fence: Int, operation: WTCapability, path: String? = nil) {
        self.fence = fence
        self.operation = operation
        self.path = path
    }
}

public struct WTRunFinish: Codable, Sendable, Equatable {
    public var fence: Int
    public var state: WTTaskState
    public var summary: String
    public var headCommit: String?
    public var prURL: String?
    public init(fence: Int, state: WTTaskState, summary: String, headCommit: String? = nil, prURL: String? = nil) {
        self.fence = fence
        self.state = state
        self.summary = summary
        self.headCommit = headCommit
        self.prURL = prURL
    }
}

public struct WTRecordEvidence: Codable, Sendable, Equatable {
    public var runID: UUID
    public var fence: Int
    public var kind: String
    public var summary: String
    public var commit: String?
    public var url: String?
    public init(runID: UUID, fence: Int, kind: String, summary: String, commit: String? = nil, url: String? = nil) {
        self.runID = runID
        self.fence = fence
        self.kind = kind
        self.summary = summary
        self.commit = commit
        self.url = url
    }
}

public struct WTRecordReview: Codable, Sendable, Equatable {
    public var headCommit: String
    public var baseCommit: String
    public var decision: WTReviewDecision
    public var summary: String
    public init(headCommit: String, baseCommit: String, decision: WTReviewDecision, summary: String) {
        self.headCommit = headCommit
        self.baseCommit = baseCommit
        self.decision = decision
        self.summary = summary
    }
}

/// Fetched by the host from GitHub, never accepted as an agent's assertion.
public struct WTProviderCheck: Codable, Sendable, Equatable {
    public var taskID: UUID
    public var headCommit: String
    public var baseCommit: String
    public var isMerged: Bool
    public var mergeCommit: String?
    public var checksPassed: Bool
    public var hasIndependentApproval: Bool
    public var checkedAt: Date
    public init(taskID: UUID, headCommit: String, baseCommit: String, isMerged: Bool,
                mergeCommit: String? = nil, checksPassed: Bool, hasIndependentApproval: Bool, checkedAt: Date) {
        self.taskID = taskID; self.headCommit = headCommit; self.baseCommit = baseCommit
        self.isMerged = isMerged; self.mergeCommit = mergeCommit; self.checksPassed = checksPassed
        self.hasIndependentApproval = hasIndependentApproval; self.checkedAt = checkedAt
    }
}

public struct WTTransferOwner: Codable, Sendable, Equatable {
    public var userID: UUID
    public init(userID: UUID) { self.userID = userID }
}
