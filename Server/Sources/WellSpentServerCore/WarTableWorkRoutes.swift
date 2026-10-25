import Foundation
import Fluent
import Vapor
import WarTableCore

func wtPaths(_ paths: [String]) throws -> [String] {
    guard !paths.isEmpty, paths.count <= 100, paths.allSatisfy({ $0.utf8.count <= 1024 && WTPolicy.validPath($0) }) else {
        throw Abort(.badRequest, reason: "Choose explicit relative paths without traversal.")
    }
    return Array(Set(paths)).sorted()
}
func wtTaskIndex(_ id: UUID, scope: WTScope, state: WTPersistedState) throws -> Int {
    guard let index = state.tasks.firstIndex(where: { $0.id == id }) else { throw Abort(.notFound) }
    _ = try scope.conversation(state.tasks[index].conversationID, in: state)
    _ = try scope.source(state.tasks[index].sourceID, in: state)
    return index
}
func wtGrant(_ id: UUID?, subject: UUID, source: UUID, state: WTPersistedState) throws -> WTGrant {
    guard let grant = state.grants.first(where: { $0.id == id }), grant.subjectID == subject,
          grant.sourceID == source, !grant.isRevoked, grant.expiresAt > Date() else {
        throw Abort(.forbidden, reason: "A current, explicit source grant is required.")
    }
    return grant
}
func wtAuthorize(_ body: WTAuthorizeTask, taskIndex: Int, scope: WTScope, state: inout WTPersistedState) throws {
    guard scope.isOwner else { throw Abort(.forbidden, reason: "Only the owner can authorize a task.") }
    let task = state.tasks[taskIndex], source = try scope.source(task.sourceID, in: state)
    let conversation = try scope.conversation(task.conversationID, in: state)
    guard let agent = state.agents.first(where: { $0.id == body.assigneeID }), agent.status != .revoked,
          source.audienceIDs.contains(agent.id), scope.audience(conversation).contains(agent.id) else { throw Abort(.forbidden) }
    let grant = try wtGrant(body.grantID, subject: agent.id, source: source.id, state: state)
    guard grant.capabilities.contains(.readContext) else { throw Abort(.forbidden) }
    if grant.capabilities.contains(where: { WTPolicy.isLocalWrite($0) || $0 == .openPR }), agent.executionProfile != "enforced-local" {
        throw Abort(.forbidden, reason: "Code work requires an enrolled, enforced local runner.")
    }
    if let reviewer = body.reviewerID {
        guard reviewer != agent.id, source.audienceIDs.contains(reviewer), scope.audience(conversation).contains(reviewer) else {
            throw Abort(.forbidden, reason: "Choose an independent reviewer with access to this source and conversation.")
        }
        if state.agents.contains(where: { $0.id == reviewer }) {
            guard state.grants.contains(where: { $0.subjectID == reviewer && $0.sourceID == source.id && $0.capabilities.contains(.review) && !$0.isRevoked && $0.expiresAt > Date() }) else {
                throw Abort(.forbidden, reason: "An agent reviewer needs a separate explicit review grant.")
            }
        } else if !scope.activeHumans.contains(where: { $0.id == reviewer }) { throw Abort(.forbidden) }
    }
    guard !state.runs.contains(where: { $0.taskID == task.id && $0.state == "active" }) else { throw Abort(.conflict, reason: "The previous worker must acknowledge cleanup before reauthorization.") }
    guard task.revisionCycles < grant.maxRevisionCycles else { throw Abort(.conflict, reason: "The task reached its revision budget. Create a new human-approved task.") }
    state.tasks[taskIndex].assigneeID = agent.id; state.tasks[taskIndex].grantID = grant.id
    state.tasks[taskIndex].reviewerID = body.reviewerID; state.tasks[taskIndex].state = .ready
}

func wtActiveRun(_ id: UUID, fence: Int, scope: WTScope, state: WTPersistedState) throws -> (Int, Int, WTGrant) {
    guard scope.me.kind == .agent, let runIndex = state.runs.firstIndex(where: { $0.id == id }),
          state.runs[runIndex].agentID == scope.me.id, state.runs[runIndex].fence == fence,
          state.runs[runIndex].state == "active", state.runs[runIndex].leaseExpiresAt > Date() else {
        throw Abort(.conflict, reason: "The worker lease is no longer current. Stop and acknowledge cleanup.")
    }
    let run = state.runs[runIndex], taskIndex = try wtTaskIndex(run.taskID, scope: scope, state: state)
    let task = state.tasks[taskIndex], source = try scope.source(task.sourceID, in: state)
    guard task.state == .running, task.assigneeID == scope.me.id,
          source.revision == run.contextReceipt.sourceRevision else {
        throw Abort(.conflict, reason: "Task authority or context changed. Stop and acknowledge cleanup.")
    }
    return (runIndex, taskIndex, try wtGrant(task.grantID, subject: scope.me.id, source: task.sourceID, state: state))
}

private struct WTReviewAuthorization: Content { var authorized = true }
private func wtReviewAuthority(_ body: WTRecordReview, taskID: UUID, scope: WTScope, state: WTPersistedState) throws -> Int {
    guard wtCommit(body.headCommit), wtCommit(body.baseCommit) else { throw Abort(.badRequest) }
    let index = try wtTaskIndex(taskID, scope: scope, state: state), task = state.tasks[index]
    guard scope.me.id != task.assigneeID, scope.me.id == task.reviewerID || (scope.isOwner && scope.me.kind == .human),
          task.headCommit == body.headCommit, task.state == .awaitingReview else { throw Abort(.forbidden, reason: "Reviews require an independent designated reviewer and the current task commit.") }
    if scope.me.kind == .agent {
        guard state.grants.contains(where: { $0.subjectID == scope.me.id && $0.sourceID == task.sourceID && $0.capabilities.contains(.review) && !$0.isRevoked && $0.expiresAt > Date() }) else { throw Abort(.forbidden) }
    }
    return index
}

func registerWarTableWorkRoutes(_ routes: any RoutesBuilder) throws {
    let small: HTTPBodyStreamStrategy = .collect(maxSize: "32kb")
    routes.on(.POST, "context-sources", body: small) { request async throws -> WTContextSource in
        let body = try request.content.decode(WTCreateSource.self)
        return try await withWarTable(request) { scope, state, db in
            guard scope.isOwner, state.contextSources.count < 200 else { throw Abort(.forbidden) }
            let source = try wtSource(body, id: UUID(), revision: 1, scope: scope)
            state.contextSources.append(source)
            try await wtEvent("sourceAdded", summary: "A context source was registered", subject: source.id, overseersOnly: true, state: &state, on: db)
            return source
        }
    }
    routes.on(.PUT, "context-sources", ":sourceID", body: small) { request async throws -> WTContextSource in
        let body = try request.content.decode(WTCreateSource.self), id = try request.parameters.require("sourceID", as: UUID.self)
        return try await withWarTable(request) { scope, state, db in
            guard scope.isOwner, let index = state.contextSources.firstIndex(where: { $0.id == id }) else { throw Abort(.forbidden) }
            let old = state.contextSources[index]
            let source = try wtSource(body, id: id, revision: old.revision + 1, scope: scope)
            if state.retainedSourceIDs.contains(id) {
                guard Set(old.audienceIDs).isSubset(of: Set(source.audienceIDs)), source.reference == old.reference,
                      source.kind == old.kind, source.isPublic == old.isPublic else {
                    throw Abort(.conflict, reason: "Retained context keeps its original source and audience. Register a new source for a different boundary.")
                }
            }
            state.contextSources[index] = source; state.installation.revision += 1
            wtStopTasks({ $0.sourceID == id }, state: &state)
            try await wtEvent("sourceChanged", summary: "Context authority changed; active work must stop", subject: id, overseersOnly: true, state: &state, on: db)
            return source
        }
    }
    routes.on(.POST, "grants", body: small) { request async throws -> WTGrant in
        let body = try request.content.decode(WTCreateGrant.self), paths = try wtPaths(body.allowedPaths)
        return try await withWarTable(request) { scope, state, db in
            guard scope.isOwner, state.grants.count < 2000 else { throw Abort(.forbidden) }
            let source = try scope.source(body.sourceID, in: state)
            guard source.audienceIDs.contains(body.subjectID),
                  scope.activeHumans.contains(where: { $0.id == body.subjectID }) || state.agents.contains(where: { $0.id == body.subjectID && $0.status != .revoked }),
                  paths.allSatisfy({ WTPolicy.permits($0, within: source.allowedPaths) }),
                  body.expiresAt > Date(), body.expiresAt <= Date().addingTimeInterval(30 * 86400),
                  (1...10).contains(body.maxRevisionCycles), (60...14400).contains(body.maxRuntimeSeconds) else { throw Abort(.badRequest) }
            let allowed: Set<WTCapability> = [.readContext, .editBranch, .runChecks, .openPR, .review, .writeHandoff]
            guard !body.capabilities.isEmpty, Set(body.capabilities).isSubset(of: allowed) else {
                throw Abort(.badRequest, reason: "Repository grants cannot grant chat administration or merge authority.")
            }
            let grant = WTGrant(id: UUID(), subjectID: body.subjectID, sourceID: source.id, capabilities: Array(Set(body.capabilities)), allowedPaths: paths,
                expiresAt: body.expiresAt, maxRevisionCycles: body.maxRevisionCycles, maxRuntimeSeconds: body.maxRuntimeSeconds)
            state.grants.append(grant)
            try await wtEvent("grantCreated", summary: "An explicit work grant was created", subject: grant.id, overseersOnly: true, state: &state, on: db)
            return grant
        }
    }
    routes.post("grants", ":grantID", "revoke") { request async throws -> WTGrant in
        let id = try request.parameters.require("grantID", as: UUID.self)
        return try await withWarTable(request) { scope, state, db in
            guard scope.isOwner, let index = state.grants.firstIndex(where: { $0.id == id }) else { throw Abort(.forbidden) }
            state.grants[index].isRevoked = true; state.installation.revision += 1
            wtStopTasks({ $0.grantID == id }, state: &state)
            try await wtEvent("grantRevoked", summary: "Work authority was revoked", subject: id, overseersOnly: true, state: &state, on: db)
            return state.grants[index]
        }
    }
    routes.on(.POST, "tasks", body: small) { request async throws -> WTTask in
        let body = try request.content.decode(WTCreateTask.self), title = try wtText(body.title, maximum: 200), details = try wtText(body.details, maximum: 8000)
        let checks = try body.expectedChecks.map { try wtText($0, maximum: 100) }
        guard checks.count <= 30 else { throw Abort(.badRequest) }
        return try await withWarTable(request) { scope, state, db in
            let conversation = try scope.conversation(body.conversationID, in: state), source = try scope.source(body.sourceID, in: state)
            guard state.tasks.count < 2000, scope.audience(conversation).isSubset(of: Set(source.audienceIDs)) else { throw Abort(.forbidden, reason: "Everyone in this conversation, including overseers, needs context access.") }
            let task = WTTask(id: UUID(), conversationID: conversation.id, sourceID: source.id, title: title, details: details,
                creatorID: scope.me.id, state: .proposed, expectedChecks: checks)
            state.tasks.append(task)
            let index = state.tasks.count - 1
            if let assignee = body.assigneeID, let grant = body.grantID, scope.isOwner {
                try wtAuthorize(WTAuthorizeTask(grantID: grant, assigneeID: assignee, reviewerID: body.reviewerID), taskIndex: index, scope: scope, state: &state)
            }
            state.retainedSourceIDs.insert(source.id); state.conversationSources[conversation.id, default: []].insert(source.id)
            try await wtEvent("taskCreated", summary: "A work task was proposed", subject: task.id, conversation: conversation.id, state: &state, on: db)
            return state.tasks[index]
        }
    }
    routes.on(.POST, "tasks", ":taskID", "authorize", body: small) { request async throws -> WTTask in
        let body = try request.content.decode(WTAuthorizeTask.self), id = try request.parameters.require("taskID", as: UUID.self)
        return try await withWarTable(request) { scope, state, db in
            let index = try wtTaskIndex(id, scope: scope, state: state)
            try wtAuthorize(body, taskIndex: index, scope: scope, state: &state)
            try await wtEvent("taskAuthorized", summary: "A human authorized scoped work", subject: id, conversation: state.tasks[index].conversationID, state: &state, on: db)
            return state.tasks[index]
        }
    }
    routes.post("tasks", ":taskID", "stop") { request async throws -> WTTask in
        let id = try request.parameters.require("taskID", as: UUID.self)
        return try await withWarTable(request, allowDisabled: true) { scope, state, db in
            guard scope.oversees else { throw Abort(.forbidden) }
            let index = try wtTaskIndex(id, scope: scope, state: state)
            state.tasks[index].state = state.runs.contains { $0.taskID == id && $0.state == "active" } ? .stopping : .cancelled
            try await wtEvent("stopRequested", summary: "Stop requested; an active worker must acknowledge cleanup", subject: id, conversation: state.tasks[index].conversationID, state: &state, on: db)
            return state.tasks[index]
        }
    }
    routes.on(.POST, "runs", body: small) { request async throws -> WTRun in
        let body = try request.content.decode(WTClaimRun.self), worker = try wtText(body.workerID, maximum: 200)
        _ = try wtText(body.contextReceipt.revision, maximum: 200); _ = try wtText(body.contextReceipt.rulesRevision, maximum: 200)
        return try await withWarTable(request) { scope, state, db in
            guard scope.me.kind == .agent else { throw Abort(.forbidden) }
            let index = try wtTaskIndex(body.taskID, scope: scope, state: state), task = state.tasks[index]
            if let previous = state.runs.first(where: { $0.agentID == scope.me.id && $0.requestID == body.requestID }) {
                guard previous.taskID == task.id, previous.workerID == worker, previous.contextReceipt == body.contextReceipt,
                      previous.state == "active", previous.leaseExpiresAt > Date() else { throw Abort(.conflict, reason: "This claim ID has already been used or expired.") }
                _ = try wtActiveRun(previous.id, fence: previous.fence, scope: scope, state: state)
                return previous
            }
            guard task.state == .ready, task.assigneeID == scope.me.id else { throw Abort(.conflict, reason: "This task is not authorized and ready for this agent.") }
            let source = try scope.source(task.sourceID, in: state), grant = try wtGrant(task.grantID, subject: scope.me.id, source: task.sourceID, state: state)
            guard body.contextReceipt.sourceID == source.id, body.contextReceipt.sourceRevision == source.revision,
                  grant.capabilities.contains(.readContext), task.revisionCycles < grant.maxRevisionCycles else { throw Abort(.conflict, reason: "Refresh context and check the work budget before starting.") }
            guard let agent = state.agents.first(where: { $0.id == scope.me.id }), agent.executionProfile != "chat-only",
                  !grant.capabilities.contains(where: { WTPolicy.isLocalWrite($0) || $0 == .openPR }) || agent.executionProfile == "enforced-local" else { throw Abort(.forbidden) }
            guard !state.runs.contains(where: { $0.taskID == task.id && $0.state == "active" }) else { throw Abort(.conflict, reason: "The previous worker must acknowledge cleanup; an expired lease cannot be stolen.") }
            state.nextFence += 1
            let deadline = min(grant.expiresAt, Date().addingTimeInterval(TimeInterval(grant.maxRuntimeSeconds)))
            let run = WTRun(id: UUID(), taskID: task.id, agentID: scope.me.id, workerID: worker, requestID: body.requestID,
                fence: state.nextFence, leaseExpiresAt: min(deadline, Date().addingTimeInterval(WTPolicy.leaseSeconds)), state: "active", contextReceipt: body.contextReceipt)
            state.runs.append(run); state.deadlines.append(WTRunDeadline(runID: run.id, deadline: deadline))
            state.tasks[index].state = .running; state.tasks[index].revisionCycles += 1
            try await wtEvent("runClaimed", summary: "An authorized worker claimed the task", subject: run.id, conversation: task.conversationID, state: &state, on: db)
            return run
        }
    }
    routes.on(.POST, "runs", ":runID", "checkpoint", body: small) { request async throws -> WTRun in
        let body = try request.content.decode(WTRunCheckpoint.self), id = try request.parameters.require("runID", as: UUID.self)
        return try await withWarTable(request, work: true) { scope, state, _ in
            let (index, _, grant) = try wtActiveRun(id, fence: body.fence, scope: scope, state: state)
            let source = try scope.source(grant.sourceID, in: state)
            guard grant.capabilities.contains(body.operation), body.operation != .merge else { throw Abort(.forbidden) }
            if let path = body.path {
                guard WTPolicy.permits(path, within: grant.allowedPaths), WTPolicy.permits(path, within: source.allowedPaths) else { throw Abort(.forbidden, reason: "This path is outside the source and grant boundary.") }
            } else if body.operation == .editBranch || body.operation == .writeHandoff { throw Abort(.badRequest, reason: "A file edit requires its relative path.") }
            guard let deadline = state.deadlines.first(where: { $0.runID == id })?.deadline, deadline > Date() else { throw Abort(.conflict, reason: "The task reached its runtime limit.") }
            state.runs[index].leaseExpiresAt = min(deadline, min(grant.expiresAt, Date().addingTimeInterval(WTPolicy.leaseSeconds)))
            return state.runs[index]
        }
    }
    routes.on(.POST, "runs", ":runID", "finish", body: small) { request async throws -> WTTask in
        let body = try request.content.decode(WTRunFinish.self), id = try request.parameters.require("runID", as: UUID.self)
        let summary = try wtText(body.summary, maximum: 4000)
        let cleanup = body.state == .cancelled || body.state == .blocked
        return try await withWarTable(request, cleanup: cleanup, work: true) { scope, state, db in
            guard scope.me.kind == .agent, let runIndex = state.runs.firstIndex(where: { $0.id == id }),
                  state.runs[runIndex].agentID == scope.me.id, state.runs[runIndex].fence == body.fence,
                  let index = state.tasks.firstIndex(where: { $0.id == state.runs[runIndex].taskID }) else { throw Abort(.forbidden) }
            if state.runs[runIndex].state != "active" {
                guard cleanup, [WTTaskState.cancelled, .blocked].contains(state.tasks[index].state) else { throw Abort(.conflict) }
                return state.tasks[index]
            }
            if !cleanup {
                guard state.evidence.count < 10_000 else { throw Abort(.insufficientStorage, reason: "Archive work evidence before recording more completions.") }
                let (_, _, grant) = try wtActiveRun(id, fence: body.fence, scope: scope, state: state)
                guard body.state == .awaitingReview || (body.state == .done && !grant.capabilities.contains(.editBranch) && !grant.capabilities.contains(.openPR)) else {
                    throw Abort(.badRequest, reason: "Code work finishes awaiting review. Merged status requires authoritative provider verification.")
                }
                if grant.capabilities.contains(.editBranch) || grant.capabilities.contains(.openPR) {
                    guard let head = body.headCommit, wtCommit(head) else { throw Abort(.badRequest, reason: "Code evidence needs the exact commit hash.") }
                }
                if let url = body.prURL { _ = try wtGitHubPR(url) }
                state.tasks[index].headCommit = body.headCommit; state.tasks[index].prURL = body.prURL
            }
            state.runs[runIndex].state = cleanup ? "stopped" : "finished"
            state.tasks[index].state = body.state
            // Cleanup may be acknowledged after revocation, but cannot upload arbitrary evidence.
            if !cleanup {
                state.evidence.append(WTEvidence(id: UUID(), taskID: state.tasks[index].id, runID: id, kind: "completion", summary: summary,
                    commit: body.headCommit, url: body.prURL, createdAt: Date()))
            }
            try await wtEvent(cleanup ? "workerStopped" : "runFinished", summary: cleanup ? "Worker acknowledged cleanup" : "Work evidence is ready for review",
                subject: id, conversation: state.tasks[index].conversationID, state: &state, on: db)
            return state.tasks[index]
        }
    }
    routes.on(.POST, "tasks", ":taskID", "evidence", body: small) { request async throws -> WTEvidence in
        let body = try request.content.decode(WTRecordEvidence.self), id = try request.parameters.require("taskID", as: UUID.self)
        let kind = try wtText(body.kind), summary = try wtText(body.summary, maximum: 8000)
        return try await withWarTable(request, work: true) { scope, state, db in
            let (_, index, _) = try wtActiveRun(body.runID, fence: body.fence, scope: scope, state: state)
            guard state.tasks[index].id == id, state.evidence.count < 10000 else { throw Abort(.badRequest) }
            if let commit = body.commit, !wtCommit(commit) { throw Abort(.badRequest) }
            if let url = body.url { guard URL(string: url)?.scheme == "https", url.utf8.count <= 2000 else { throw Abort(.badRequest) } }
            let evidence = WTEvidence(id: UUID(), taskID: id, runID: body.runID, kind: kind, summary: summary, commit: body.commit, url: body.url, createdAt: Date())
            state.evidence.append(evidence)
            try await wtEvent("evidence", summary: "A worker recorded evidence", subject: evidence.id, conversation: state.tasks[index].conversationID, state: &state, on: db)
            return evidence
        }
    }
    routes.on(.POST, "tasks", ":taskID", "reviews", "authorize", body: small) { request async throws -> WTReviewAuthorization in
        let body = try request.content.decode(WTRecordReview.self), id = try request.parameters.require("taskID", as: UUID.self)
        _ = try wtText(body.summary, maximum: 8000)
        return try await withWarTable(request) { scope, state, _ in
            _ = try wtReviewAuthority(body, taskID: id, scope: scope, state: state)
            return WTReviewAuthorization()
        }
    }
    routes.on(.POST, "tasks", ":taskID", "reviews", body: small) { request async throws -> WTReview in
        let body = try request.content.decode(WTRecordReview.self), id = try request.parameters.require("taskID", as: UUID.self)
        let summary = try wtText(body.summary, maximum: 8000)
        guard wtCommit(body.headCommit), wtCommit(body.baseCommit) else { throw Abort(.badRequest) }
        return try await withWarTable(request) { scope, state, db in
            let index = try wtReviewAuthority(body, taskID: id, scope: scope, state: state), task = state.tasks[index]
            guard state.reviews.count < 10_000 else { throw Abort(.insufficientStorage, reason: "Archive review history before recording more reviews.") }
            let review = WTReview(id: UUID(), taskID: id, reviewerID: scope.me.id, headCommit: body.headCommit, baseCommit: body.baseCommit,
                decision: body.decision, summary: summary, policyRevision: state.installation.revision, providerConfirmed: false, createdAt: Date())
            state.reviews.append(review)
            if body.decision == .requestChanges { state.tasks[index].state = .proposed }
            try await wtEvent("review", summary: "An advisory review was recorded; provider approval is checked separately", subject: review.id, conversation: task.conversationID, state: &state, on: db)
            return review
        }
    }
    try registerWarTableProviderRoutes(routes)
}

func wtSource(_ body: WTCreateSource, id: UUID, revision: Int, scope: WTScope) throws -> WTContextSource {
    let name = try wtText(body.name), reference = try wtText(body.reference, maximum: 2000), paths = try wtPaths(body.allowedPaths)
    let valid = Set(scope.activeHumans.map(\.id) + scope.activeAgents.filter { $0.status != .revoked }.map(\.id))
    let audience = Set(body.audienceIDs).union(scope.activeHumans.filter { WTPolicy.oversees($0.role) }.map(\.id))
    guard audience.isSubset(of: valid), audience.contains(scope.me.id) else { throw Abort(.badRequest) }
    return WTContextSource(id: id, name: name, kind: body.kind, reference: reference, allowedPaths: paths,
        audienceIDs: audience.sorted { $0.uuidString < $1.uuidString }, isPublic: body.isPublic, revision: revision, status: "Requires local access check")
}
func wtCommit(_ value: String) -> Bool { [40, 64].contains(value.count) && value.allSatisfy { $0.isHexDigit && $0.isASCII } }

func wtGitHubPR(_ value: String) throws -> (repository: String, number: Int) {
    guard let url = URLComponents(string: value), url.scheme == "https", url.host == "github.com",
          url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil else { throw Abort(.badRequest, reason: "Use a canonical https://github.com/owner/repository/pull/number URL.") }
    let parts = url.path.split(separator: "/")
    guard parts.count == 4, parts[2] == "pull", let number = Int(parts[3]), number > 0,
          parts.prefix(2).allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") } }) else { throw Abort(.badRequest) }
    return ("\(parts[0])/\(parts[1])", number)
}
