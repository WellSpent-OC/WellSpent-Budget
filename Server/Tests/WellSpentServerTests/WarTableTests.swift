import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Fluent
import Vapor
import VaporTesting
import WarTableCore
@testable import WellSpentServerCore

private let wtBase = "extensions/wartable/v1"
private func wtCall<T: Content>(_ type: T.Type, _ method: HTTPMethod, _ path: String,
                               token: String, body: (any Content)? = nil, on app: Application) async throws -> T {
    var value: T?
    try await app.testing().test(method, path, headers: v2Bearer(token), beforeRequest: { request in
        if let body { try request.content.encode(body) }
    }, afterResponse: { response async throws in
        #expect(response.status == .ok, "\(method) \(path): \(response.body.string)")
        if response.status == .ok { value = try response.content.decode(T.self) }
    })
    return try #require(value)
}
private struct WTFixture {
    var owner: V2Session; var group: UUID; var snapshot: WTSnapshot
    var path: String { "\(wtBase)/groups/\(group)" }
    var room: UUID { snapshot.conversations[0].id }
}
private func wtFixture(_ app: Application) async throws -> WTFixture {
    let owner = try await v2SignUpConfirmed("wt-\(UUID())@example.com", on: app), group = UUID()
    try await GroupRow(id: group, founderID: owner.userID).create(on: app.db)
    try await MembershipRow(groupID: group, userID: owner.userID, level: 13, joinedAtSequence: 0).create(on: app.db)
    let snapshot = try await wtCall(WTSnapshot.self, .PUT, "\(wtBase)/groups/\(group)", token: owner.token,
        body: WTConfigureRequest(enabled: true, displayName: "Owner"), on: app)
    return WTFixture(owner: owner, group: group, snapshot: snapshot)
}
private func wtHuman(_ fixture: WTFixture, role: WTRole, app: Application) async throws -> V2Session {
    let person = try await v2SignUpConfirmed("wt-\(UUID())@example.com", on: app)
    try await MembershipRow(groupID: fixture.group, userID: person.userID, level: 3, joinedAtSequence: 0).create(on: app.db)
    _ = try await wtCall(WTSnapshot.self, .POST, fixture.path + "/roles", token: fixture.owner.token,
        body: WTSetRoleRequest(userID: person.userID, role: role, displayName: role.rawValue), on: app)
    return person
}
private func wtAgent(_ fixture: WTFixture, name: String = "Atlas", profile: String = "enforced-local", app: Application) async throws -> WTCredential {
    let enrollment = try await wtCall(WTEnrollment.self, .POST, fixture.path + "/agents/enroll", token: fixture.owner.token,
        body: WTEnrollAgentRequest(name: name, provider: "Test", machine: "Fixture", executionProfile: profile), on: app)
    let result = try await wtCall(WTCredential.self, .POST, wtBase + "/agents/connect", token: "", body: WTConnectRequest(code: enrollment.code), on: app)
    #expect(try await v2Status(.POST, wtBase + "/agents/connect", body: WTConnectRequest(code: enrollment.code), on: app) == .unauthorized)
    return result
}
private func wtSource(_ fixture: WTFixture, audience: [UUID], app: Application) async throws -> WTContextSource {
    try await wtCall(WTContextSource.self, .POST, fixture.path + "/context-sources", token: fixture.owner.token,
        body: WTCreateSource(name: "Example", kind: .repository, reference: "https://github.com/example/demo", allowedPaths: ["Sources"], audienceIDs: audience, isPublic: true), on: app)
}
private func wtWork(_ fixture: WTFixture, agent: WTCredential, app: Application) async throws -> (WTContextSource, WTGrant, WTTask, WTRun) {
    let source = try await wtSource(fixture, audience: [fixture.owner.userID, agent.agentID], app: app)
    let grant = try await wtCall(WTGrant.self, .POST, fixture.path + "/grants", token: fixture.owner.token,
        body: WTCreateGrant(subjectID: agent.agentID, sourceID: source.id, capabilities: [.readContext, .editBranch, .runChecks, .openPR], allowedPaths: ["Sources"], expiresAt: Date().addingTimeInterval(3600)), on: app)
    let task = try await wtCall(WTTask.self, .POST, fixture.path + "/tasks", token: fixture.owner.token,
        body: WTCreateTask(conversationID: fixture.room, sourceID: source.id, title: "Bounded work", details: "Update one source file", assigneeID: agent.agentID, grantID: grant.id, reviewerID: fixture.owner.userID, expectedChecks: ["Unit tests"]), on: app)
    let receipt = WTContextReceipt(sourceID: source.id, sourceRevision: source.revision, revision: String(repeating: "a", count: 40), rulesRevision: "rules-1")
    let run = try await wtCall(WTRun.self, .POST, fixture.path + "/runs", token: agent.token,
        body: WTClaimRun(taskID: task.id, requestID: UUID(), workerID: "fixture-worker", contextReceipt: receipt), on: app)
    return (source, grant, task, run)
}

@Suite("WarTable installation, chat and work authority", .serialized)
struct WarTableTests {
    // Scenario WARTABLE-04, WARTABLE-09
    @Test func enrollmentIsSingleUseAndNeverCreatesBudgetMembership() async throws {
        try await withV2App { app, _ in
            let fixture = try await wtFixture(app), agent = try await wtAgent(fixture, app: app)
            let snapshot = try await wtCall(WTSnapshot.self, .GET, fixture.path, token: agent.token, on: app)
            #expect(snapshot.me.id == agent.agentID && snapshot.me.kind == .agent && snapshot.me.role == nil)
            #expect(try await MembershipRow.query(on: app.db).filter(\.$userID == agent.agentID).count() == 0)
            #expect(try await v2Status(.GET, "api/v2/groups", token: agent.token, on: app) == .unauthorized)
            #expect(try await v2Status(.POST, fixture.path + "/roles", token: agent.token,
                body: WTSetRoleRequest(userID: agent.agentID, role: .admin), on: app) == .forbidden)
            _ = try await wtCall(WTSnapshot.self, .PUT, fixture.path, token: fixture.owner.token,
                body: WTConfigureRequest(enabled: false), on: app)
            #expect(try await v2Status(.GET, fixture.path, token: agent.token, on: app) == .forbidden)
            let disabled = try await wtCall(WTSnapshot.self, .GET, fixture.path, token: fixture.owner.token, on: app)
            #expect(!disabled.installation.isEnabled)
        }
    }

    // Scenario WARTABLE-03
    @Test func directAudienceAlwaysIncludesOverseersButNotOtherMembersOrGroups() async throws {
        try await withV2App { app, _ in
            let f = try await wtFixture(app), manager = try await wtHuman(f, role: .manager, app: app)
            let member = try await wtHuman(f, role: .member, app: app), other = try await wtHuman(f, role: .member, app: app)
            let agent = try await wtAgent(f, app: app)
            let direct = try await wtCall(WTConversation.self, .POST, f.path + "/conversations", token: member.token,
                body: WTCreateConversation(title: "Direct", participantIDs: [agent.agentID]), on: app)
            #expect(Set(direct.audienceIDs) == Set([f.owner.userID, manager.userID, member.userID, agent.agentID]))
            let message = try await wtCall(WTMessage.self, .POST, f.path + "/messages", token: member.token,
                body: WTPostMessage(conversationID: direct.id, clientMessageID: UUID(), text: "Visible to overseers"), on: app)
            let managerPage = try await wtCall(WTMessagePage.self, .GET, f.path + "/messages?conversationID=\(direct.id)", token: manager.token, on: app)
            #expect(managerPage.messages.map(\.id) == [message.id])
            let hidden = try await wtCall(WTSnapshot.self, .GET, f.path, token: other.token, on: app)
            #expect(!hidden.conversations.contains { $0.id == direct.id })
            #expect(try await v2Status(.GET, f.path + "/messages?conversationID=\(direct.id)", token: other.token, on: app) == .notFound)
            #expect(try await v2Status(.POST, f.path + "/agents/enroll", token: manager.token,
                body: WTEnrollAgentRequest(name: "Other", provider: "Test", machine: "Test"), on: app) == .forbidden)
            let otherGroup = try await wtFixture(app)
            #expect(try await v2Status(.GET, otherGroup.path, token: agent.token, on: app) == .forbidden)
            let membership = try #require(try await MembershipRow.query(on: app.db).filter(\.$groupID == f.group).filter(\.$userID == manager.userID).first())
            try await membership.delete(on: app.db)
            #expect(try await v2Status(.GET, f.path, token: manager.token, on: app) == .notFound)
        }
    }

    // Scenario WARTABLE-02, WARTABLE-08
    @Test func idempotentRepliesShareOneCapAcrossAnAgentToAgentDirectHandoff() async throws {
        try await withV2App { app, _ in
            let f = try await wtFixture(app), atlas = try await wtAgent(f, app: app), nova = try await wtAgent(f, name: "Nova", app: app)
            let origin = try await wtCall(WTMessage.self, .POST, f.path + "/messages", token: f.owner.token,
                body: WTPostMessage(conversationID: f.room, clientMessageID: UUID(), text: "@Atlas please ask Nova to help"), on: app)
            let direct = try await wtCall(WTConversation.self, .POST, f.path + "/conversations", token: atlas.token,
                body: WTCreateConversation(title: "Handoff", participantIDs: [nova.agentID]), on: app)
            let body = WTPostMessage(conversationID: direct.id, clientMessageID: UUID(), text: "Nova, a bounded question", replyTo: origin.id, chainID: origin.chainID)
            var parent = try await wtCall(WTMessage.self, .POST, f.path + "/messages", token: atlas.token, body: body, on: app)
            let retry = try await wtCall(WTMessage.self, .POST, f.path + "/messages", token: atlas.token, body: body, on: app)
            #expect(parent.id == retry.id && parent.sequence == retry.sequence)
            for index in 1..<5 {
                parent = try await wtCall(WTMessage.self, .POST, f.path + "/messages", token: index % 2 == 1 ? nova.token : atlas.token,
                    body: WTPostMessage(conversationID: direct.id, clientMessageID: UUID(), text: "Reply \(index)", replyTo: parent.id, chainID: origin.chainID), on: app)
            }
            #expect(try await v2Status(.POST, f.path + "/messages", token: nova.token,
                body: WTPostMessage(conversationID: direct.id, clientMessageID: UUID(), text: "One too many", replyTo: parent.id, chainID: origin.chainID), on: app) == .conflict)
            #expect(try await v2Status(.POST, f.path + "/messages", token: atlas.token,
                body: WTPostMessage(conversationID: direct.id, clientMessageID: UUID(), text: "Invented chain", replyTo: parent.id, chainID: UUID()), on: app) == .forbidden)
            let page = try await wtCall(WTMessagePage.self, .GET, f.path + "/messages?conversationID=\(direct.id)&limit=2", token: f.owner.token, on: app)
            #expect(page.messages.map(\.sequence) == [4, 5] && page.hasMore)
            let older = try await wtCall(WTMessagePage.self, .GET, f.path + "/messages?conversationID=\(direct.id)&before=4&limit=2", token: f.owner.token, on: app)
            #expect(older.messages.map(\.sequence) == [2, 3] && older.hasMore)
        }
    }

    // Scenario WARTABLE-06
    @Test func contextAudienceBlocksForwardingAndRetroactiveOversightPromotion() async throws {
        try await withV2App { app, _ in
            let f = try await wtFixture(app), member = try await wtHuman(f, role: .member, app: app), agent = try await wtAgent(f, app: app)
            let source = try await wtSource(f, audience: [f.owner.userID, agent.agentID], app: app)
            #expect(try await v2Status(.POST, f.path + "/messages", token: f.owner.token,
                body: WTPostMessage(conversationID: f.room, clientMessageID: UUID(), text: "Restricted", sourceIDs: [source.id]), on: app) == .forbidden)
            let direct = try await wtCall(WTConversation.self, .POST, f.path + "/conversations", token: f.owner.token,
                body: WTCreateConversation(title: "Approved context", participantIDs: [agent.agentID]), on: app)
            let origin = try await wtCall(WTMessage.self, .POST, f.path + "/messages", token: f.owner.token,
                body: WTPostMessage(conversationID: direct.id, clientMessageID: UUID(), text: "Restricted", sourceIDs: [source.id]), on: app)
            #expect(try await v2Status(.POST, f.path + "/roles", token: f.owner.token,
                body: WTSetRoleRequest(userID: member.userID, role: .manager), on: app) == .conflict)
            #expect(try await v2Status(.POST, f.path + "/messages", token: agent.token,
                body: WTPostMessage(conversationID: f.room, clientMessageID: UUID(), text: "Dropped restrictions", replyTo: origin.id, chainID: origin.chainID), on: app) == .forbidden)
            let hidden = try await wtCall(WTSnapshot.self, .GET, f.path, token: member.token, on: app)
            #expect(hidden.contextSources.isEmpty)
        }
    }

    // Scenario WARTABLE-06
    @Test func grantsFenceEditsAndRevocationAllowsOnlyCleanup() async throws {
        try await withV2App { app, _ in
            let f = try await wtFixture(app), agent = try await wtAgent(f, app: app)
            let (_, grant, task, run) = try await wtWork(f, agent: agent, app: app)
            let checkpoint = f.path + "/runs/\(run.id)/checkpoint"
            #expect(try await v2Status(.POST, checkpoint, token: agent.token,
                body: WTRunCheckpoint(fence: run.fence, operation: .editBranch, path: "Secrets/key"), on: app) == .forbidden)
            #expect(try await v2Status(.POST, checkpoint, token: agent.token,
                body: WTRunCheckpoint(fence: run.fence + 1, operation: .readContext), on: app) == .conflict)
            _ = try await wtCall(WTRun.self, .POST, checkpoint, token: agent.token,
                body: WTRunCheckpoint(fence: run.fence, operation: .editBranch, path: "Sources/Feature.swift"), on: app)
            _ = try await wtCall(WTGrant.self, .POST, f.path + "/grants/\(grant.id)/revoke", token: f.owner.token, on: app)
            #expect(try await v2Status(.POST, checkpoint, token: agent.token, body: WTRunCheckpoint(fence: run.fence, operation: .readContext), on: app) == .conflict)
            _ = try await wtCall(WTAgent.self, .POST, f.path + "/agents/\(agent.agentID)/control", token: f.owner.token,
                body: WTAgentControl(action: .revoke), on: app)
            #expect(try await v2Status(.GET, f.path, token: agent.token, on: app) == .forbidden)
            let stopped = try await wtCall(WTTask.self, .POST, f.path + "/runs/\(run.id)/finish", token: agent.token,
                body: WTRunFinish(fence: run.fence, state: .cancelled, summary: "Cleanup complete"), on: app)
            #expect(stopped.id == task.id && stopped.state == .cancelled)
        }
    }

    @Test func expiredWorkerCannotBeReplacedUntilCleanupIsAcknowledged() async throws {
        try await withV2App { app, _ in
            let f = try await wtFixture(app), agent = try await wtAgent(f, app: app)
            let (_, grant, task, run) = try await wtWork(f, agent: agent, app: app)
            let row = try #require(try await WTInstallationRow.find(f.group, on: app.db))
            var state = try wtDecode(WTPersistedState.self, row.payload)
            state.runs[0].leaseExpiresAt = Date().addingTimeInterval(-1)
            row.payload = try wtEncode(state); try await row.save(on: app.db)
            let authorize = WTAuthorizeTask(grantID: grant.id, assigneeID: agent.agentID, reviewerID: f.owner.userID)
            #expect(try await v2Status(.POST, f.path + "/tasks/\(task.id)/authorize", token: f.owner.token, body: authorize, on: app) == .conflict)
            #expect(try await v2Status(.POST, f.path + "/runs/\(run.id)/checkpoint", token: agent.token,
                body: WTRunCheckpoint(fence: run.fence, operation: .readContext), on: app) == .conflict)
            _ = try await wtCall(WTTask.self, .POST, f.path + "/runs/\(run.id)/finish", token: agent.token,
                body: WTRunFinish(fence: run.fence, state: .blocked, summary: "Expired worker stopped"), on: app)
            let ready = try await wtCall(WTTask.self, .POST, f.path + "/tasks/\(task.id)/authorize", token: f.owner.token, body: authorize, on: app)
            #expect(ready.state == .ready)
        }
    }

    // Scenario WARTABLE-07
    @Test func selfReviewAndStaleHeadAreRejectedAndHumanReviewIsAdvisory() async throws {
        try await withV2App { app, _ in
            let f = try await wtFixture(app), agent = try await wtAgent(f, app: app)
            let (_, _, task, run) = try await wtWork(f, agent: agent, app: app)
            let head = String(repeating: "b", count: 40), base = String(repeating: "a", count: 40)
            _ = try await wtCall(WTTask.self, .POST, f.path + "/runs/\(run.id)/finish", token: agent.token,
                body: WTRunFinish(fence: run.fence, state: .awaitingReview, summary: "Checks passed", headCommit: head, prURL: "https://github.com/example/demo/pull/1"), on: app)
            let review = WTRecordReview(headCommit: head, baseCommit: base, decision: .approve, summary: "Reviewed exact commit")
            let changes = WTRecordReview(headCommit: head, baseCommit: base, decision: .requestChanges, summary: "Provider submission may need a retry")
            #expect(try await v2Status(.POST, f.path + "/tasks/\(task.id)/reviews/authorize", token: agent.token, body: changes, on: app) == .forbidden)
            for _ in 0..<2 {
                #expect(try await v2Status(.POST, f.path + "/tasks/\(task.id)/reviews/authorize", token: f.owner.token, body: changes, on: app) == .ok)
            }
            let unchanged = try await wtCall(WTSnapshot.self, .GET, f.path, token: f.owner.token, on: app)
            #expect(unchanged.tasks.first?.state == .awaitingReview && unchanged.reviews.isEmpty)
            #expect(try await v2Status(.POST, f.path + "/tasks/\(task.id)/reviews", token: agent.token, body: review, on: app) == .forbidden)
            #expect(try await v2Status(.POST, f.path + "/tasks/\(task.id)/reviews", token: f.owner.token,
                body: WTRecordReview(headCommit: base, baseCommit: base, decision: .approve, summary: "Stale"), on: app) == .forbidden)
            let recorded = try await wtCall(WTReview.self, .POST, f.path + "/tasks/\(task.id)/reviews", token: f.owner.token, body: review, on: app)
            #expect(!recorded.providerConfirmed && recorded.headCommit == head)
            let row = try #require(try await WTInstallationRow.find(f.group, on: app.db))
            var state = try wtDecode(WTPersistedState.self, row.payload)
            state.reviews = Array(repeating: recorded, count: 10_000)
            row.payload = try wtEncode(state); try await row.save(on: app.db)
            #expect(try await v2Status(.POST, f.path + "/tasks/\(task.id)/reviews", token: f.owner.token, body: review, on: app) == .insufficientStorage)
        }
    }

    @Test func ownerMembershipAndGroupDeletionFailClosedForAgentCredentials() async throws {
        try await withV2App { app, _ in
            let f = try await wtFixture(app), agent = try await wtAgent(f, app: app)
            let membership = try #require(try await MembershipRow.query(on: app.db).filter(\.$groupID == f.group).filter(\.$userID == f.owner.userID).first())
            try await membership.delete(on: app.db)
            #expect(try await v2Status(.GET, f.path, token: agent.token, on: app) == .forbidden)
            let group = try #require(try await GroupRow.find(f.group, on: app.db))
            group.deletedAt = Date(); try await group.save(on: app.db)
            #expect(try await v2Status(.GET, f.path, token: agent.token, on: app) == .notFound)
        }
    }

    @Test func providerVerificationRequiresAllowlistAndExactCurrentHead() async throws {
        try await withV2App { app, _ in
            let f = try await wtFixture(app), agent = try await wtAgent(f, app: app)
            let (_, _, task, run) = try await wtWork(f, agent: agent, app: app)
            let head = String(repeating: "b", count: 40)
            _ = try await wtCall(WTTask.self, .POST, f.path + "/runs/\(run.id)/finish", token: agent.token,
                body: WTRunFinish(fence: run.fence, state: .awaitingReview, summary: "Ready", headCommit: head, prURL: "https://github.com/example/demo/pull/1"), on: app)
            app.storage[WTProviderAuthorityKey.self] = WTProviderAuthority(repositories: ["different/repo"], token: "fixture-only")
            app.storage[WTProviderVerifierKey.self] = WTProviderFixture(head: head)
            #expect(try await v2Status(.POST, f.path + "/tasks/\(task.id)/provider-check", token: f.owner.token, on: app) == .forbidden)
            app.storage[WTProviderAuthorityKey.self] = WTProviderAuthority(repositories: ["example/demo"], token: "fixture-only")
            app.storage[WTProviderVerifierKey.self] = WTProviderFixture(head: String(repeating: "c", count: 40))
            #expect(try await v2Status(.POST, f.path + "/tasks/\(task.id)/provider-check", token: f.owner.token, on: app) == .conflict)
            app.storage[WTProviderVerifierKey.self] = WTProviderFixture(head: head)
            let result = try await wtCall(WTProviderCheck.self, .POST, f.path + "/tasks/\(task.id)/provider-check", token: f.owner.token, on: app)
            #expect(result.isMerged && result.checksPassed && result.hasIndependentApproval)
            let snapshot = try await wtCall(WTSnapshot.self, .GET, f.path, token: f.owner.token, on: app)
            #expect(snapshot.tasks.first?.state == .done)
        }
    }

    @Test func chatPauseDoesNotStopAuthorizedWorkButExplicitStopDoes() async throws {
        try await withV2App { app, _ in
            let f = try await wtFixture(app), agent = try await wtAgent(f, app: app)
            let (_, _, task, run) = try await wtWork(f, agent: agent, app: app)
            _ = try await wtCall(WTAgent.self, .POST, f.path + "/agents/\(agent.agentID)/control", token: f.owner.token,
                body: WTAgentControl(action: .pause), on: app)
            #expect(try await v2Status(.GET, f.path + "/messages?conversationID=\(f.room)", token: agent.token, on: app) == .forbidden)
            _ = try await wtCall(WTSnapshot.self, .GET, f.path, token: agent.token, on: app)
            _ = try await wtCall(WTRun.self, .POST, f.path + "/runs/\(run.id)/checkpoint", token: agent.token,
                body: WTRunCheckpoint(fence: run.fence, operation: .readContext), on: app)
            let stopping = try await wtCall(WTTask.self, .POST, f.path + "/tasks/\(task.id)/stop", token: f.owner.token, on: app)
            #expect(stopping.state == .stopping)
            #expect(try await v2Status(.POST, f.path + "/runs/\(run.id)/checkpoint", token: agent.token,
                body: WTRunCheckpoint(fence: run.fence, operation: .readContext), on: app) == .conflict)
            _ = try await wtCall(WTTask.self, .POST, f.path + "/runs/\(run.id)/finish", token: agent.token,
                body: WTRunFinish(fence: run.fence, state: .cancelled, summary: "Worker stopped"), on: app)
        }
    }

    @Test func rateLimitsAreSeparateForEnrollmentAndAuthenticatedMutations() async throws {
        try await withV2App { app, _ in
            let f = try await wtFixture(app)
            for _ in 0..<RateLimiter.Limit.warTableEnrollment.attempts {
                #expect(await app.rateLimiter.allow("wartable-enrollment:unknown", limit: .warTableEnrollment))
            }
            #expect(try await v2Status(.POST, wtBase + "/agents/connect", body: WTConnectRequest(code: "invalid"), on: app) == .tooManyRequests)
            for _ in 0..<RateLimiter.Limit.warTableMutation.attempts {
                _ = await app.rateLimiter.allow("wartable-mutation:\(f.group):\(f.owner.userID)", limit: .warTableMutation)
            }
            #expect(try await v2Status(.POST, f.path + "/messages", token: f.owner.token,
                body: WTPostMessage(conversationID: f.room, clientMessageID: UUID(), text: "Limited"), on: app) == .tooManyRequests)
            #expect(try await v2Status(.PUT, f.path, token: f.owner.token, body: WTConfigureRequest(enabled: false), on: app) == .tooManyRequests)
            #expect(try await v2Status(.GET, f.path, token: f.owner.token, on: app) == .ok)
        }
    }

    // Scenario WARTABLE-11
    @Test func retentionExpiresBodiesBeforeCutoffWithoutChangingSequenceOrSourceRestrictions() async throws {
        try await withV2App { app, _ in
            let f = try await wtFixture(app), agent = try await wtAgent(f, app: app)
            let source = try await wtSource(f, audience: [f.owner.userID, agent.agentID], app: app)
            let now = Date(timeIntervalSince1970: 1_800_000_000), cutoff = now.addingTimeInterval(-90 * 86400)
            let old = WTMessage(id: UUID(), conversationID: f.room, sequence: 1, senderID: f.owner.userID, senderName: "Owner", text: "Expired sensitive body", createdAt: cutoff.addingTimeInterval(-1), clientMessageID: UUID(), sourceIDs: [source.id])
            let boundary = WTMessage(id: UUID(), conversationID: f.room, sequence: 2, senderID: f.owner.userID, senderName: "Owner", text: "At the cutoff", createdAt: cutoff, clientMessageID: UUID())
            try await WTMessageRow(group: f.group, message: old).create(on: app.db)
            try await WTMessageRow(group: f.group, message: boundary).create(on: app.db)
            #expect(try await wtPrune(group: f.group, on: app.db, days: 90, now: now))
            let expired = try #require(try await WTMessageRow.find(old.id, on: app.db))
            let message = try wtDecode(WTMessage.self, expired.payload)
            #expect(message.id == old.id && message.sequence == 1 && message.sourceIDs == [source.id])
            #expect(message.text == "Message expired" && message.isRedacted && expired.expired)
            let retained = try #require(try await WTMessageRow.find(boundary.id, on: app.db))
            let retainedMessage = try wtDecode(WTMessage.self, retained.payload)
            #expect(!retained.expired && retainedMessage.text == "At the cutoff")
        }
    }

    // Scenario WARTABLE-10
    @Test func ownershipTransfersExplicitlyAndLeavingCannotResurrectOldRoles() async throws {
        try await withV2App { app, _ in
            let f = try await wtFixture(app), successor = try await wtHuman(f, role: .manager, app: app)
            let transferred = try await wtCall(WTSnapshot.self, .POST, f.path + "/owner", token: f.owner.token,
                body: WTTransferOwner(userID: successor.userID), on: app)
            #expect(transferred.installation.ownerID == successor.userID && transferred.me.role == .admin)
            #expect(try await v2Status(.PUT, f.path, token: f.owner.token, body: WTConfigureRequest(enabled: false), on: app) == .forbidden)
            #expect(try await v2Status(.DELETE, "api/v2/groups/\(f.group)/members/\(successor.userID)", token: successor.token, on: app) == .noContent)
            try await MembershipRow(groupID: f.group, userID: successor.userID, level: 3, joinedAtSequence: 0).create(on: app.db)
            #expect(try await v2Status(.GET, f.path, token: successor.token, on: app) == .notFound)
            let row = try #require(try await WTInstallationRow.find(f.group, on: app.db))
            let state = try wtDecode(WTPersistedState.self, row.payload)
            #expect(!state.installation.isEnabled && !state.people.contains { $0.id == successor.userID })
        }
    }

    // Scenario WARTABLE-10
    @Test func onlyEligibleHostFounderRecoversOrphanWithoutBypassingRetainedContext() async throws {
        try await withV2App { app, _ in
            let f = try await wtFixture(app), successor = try await wtHuman(f, role: .manager, app: app)
            let outsider = try await wtHuman(f, role: .member, app: app), agent = try await wtAgent(f, app: app)
            let source = try await wtSource(f, audience: [f.owner.userID, successor.userID, agent.agentID], app: app)
            let direct = try await wtCall(WTConversation.self, .POST, f.path + "/conversations", token: f.owner.token,
                body: WTCreateConversation(title: "Retained context", participantIDs: [agent.agentID]), on: app)
            _ = try await wtCall(WTMessage.self, .POST, f.path + "/messages", token: f.owner.token,
                body: WTPostMessage(conversationID: direct.id, clientMessageID: UUID(), text: "Restricted source", sourceIDs: [source.id]), on: app)
            let grant = try await wtCall(WTGrant.self, .POST, f.path + "/grants", token: f.owner.token,
                body: WTCreateGrant(subjectID: agent.agentID, sourceID: source.id, capabilities: [.readContext], allowedPaths: ["Sources"], expiresAt: Date().addingTimeInterval(3600)), on: app)
            #expect(try await v2Status(.POST, f.path + "/recover-owner", token: f.owner.token,
                body: WTTransferOwner(userID: f.owner.userID), on: app) == .conflict)
            _ = try await wtCall(WTSnapshot.self, .POST, f.path + "/owner", token: f.owner.token,
                body: WTTransferOwner(userID: successor.userID), on: app)
            #expect(try await v2Status(.DELETE, "api/v2/groups/\(f.group)/members/\(successor.userID)", token: successor.token, on: app) == .noContent)
            try await MembershipRow(groupID: f.group, userID: successor.userID, level: 3, joinedAtSequence: 0).create(on: app.db)
            #expect(try await v2Status(.GET, f.path, token: successor.token, on: app) == .notFound)
            #expect(try await v2Status(.POST, f.path + "/recover-owner", token: outsider.token,
                body: WTTransferOwner(userID: outsider.userID), on: app) == .forbidden)
            #expect(try await v2Status(.POST, f.path + "/recover-owner", token: f.owner.token,
                body: WTTransferOwner(userID: outsider.userID), on: app) == .forbidden)
            let recovered = try await wtCall(WTInstallation.self, .POST, f.path + "/recover-owner", token: f.owner.token,
                body: WTTransferOwner(userID: f.owner.userID), on: app)
            #expect(recovered.ownerID == f.owner.userID && !recovered.isEnabled)
            let snapshot = try await wtCall(WTSnapshot.self, .GET, f.path, token: f.owner.token, on: app)
            #expect(snapshot.grants.first { $0.id == grant.id }?.isRevoked == true)
            _ = try await wtCall(WTSnapshot.self, .PUT, f.path, token: f.owner.token, body: WTConfigureRequest(enabled: true), on: app)
            let events = try await wtCall(WTEventPage.self, .GET, f.path + "/events?after=0", token: f.owner.token, on: app)
            #expect(events.events.contains { $0.kind == "ownerRecovered" })
        }
    }

    // Scenario WARTABLE-07
    @Test func providerReplyCannotOverridePolicyChangesWhileNetworkRequestIsInFlight() async throws {
        try await withV2App { app, _ in
            let f = try await wtFixture(app), agent = try await wtAgent(f, app: app)
            let (_, _, task, run) = try await wtWork(f, agent: agent, app: app)
            let head = String(repeating: "b", count: 40)
            _ = try await wtCall(WTTask.self, .POST, f.path + "/runs/\(run.id)/finish", token: agent.token,
                body: WTRunFinish(fence: run.fence, state: .awaitingReview, summary: "Ready", headCommit: head, prURL: "https://github.com/example/demo/pull/1"), on: app)
            app.storage[WTProviderAuthorityKey.self] = WTProviderAuthority(repositories: ["example/demo"], token: "fixture-only")
            app.storage[WTProviderVerifierKey.self] = WTProviderRaceFixture(head: head, app: app, group: f.group)
            #expect(try await v2Status(.POST, f.path + "/tasks/\(task.id)/provider-check", token: f.owner.token, on: app) == .conflict)
            let snapshot = try await wtCall(WTSnapshot.self, .GET, f.path, token: f.owner.token, on: app)
            #expect(snapshot.tasks.first?.state == .awaitingReview && snapshot.evidence.allSatisfy { $0.kind != "providerVerified" })
        }
    }

    @Test func presenceReceiptsRedactionAndEventFilteringRemainAuthorized() async throws {
        try await withV2App { app, _ in
            let f = try await wtFixture(app), member = try await wtHuman(f, role: .member, app: app), agent = try await wtAgent(f, app: app)
            let busy = try await wtCall(WTAgent.self, .POST, f.path + "/presence", token: agent.token, body: WTPresenceRequest(busy: true), on: app)
            #expect(busy.status == .busy && busy.lastSeen != nil)
            let direct = try await wtCall(WTConversation.self, .POST, f.path + "/conversations", token: f.owner.token,
                body: WTCreateConversation(title: "Direct", participantIDs: [agent.agentID]), on: app)
            let message = try await wtCall(WTMessage.self, .POST, f.path + "/messages", token: f.owner.token,
                body: WTPostMessage(conversationID: direct.id, clientMessageID: UUID(), text: "Sensitive text"), on: app)
            #expect(try await v2Status(.POST, f.path + "/receipts", token: agent.token, body: WTReadReceipt(conversationID: direct.id, sequence: 1), on: app) == .noContent)
            #expect(try await v2Status(.POST, f.path + "/receipts", token: agent.token, body: WTReadReceipt(conversationID: direct.id, sequence: 0), on: app) == .noContent)
            #expect(try await v2Status(.POST, f.path + "/receipts", token: member.token, body: WTReadReceipt(conversationID: direct.id, sequence: 1), on: app) == .notFound)
            #expect(try await v2Status(.POST, f.path + "/messages/\(message.id)/redact", token: agent.token, body: WTRedactRequest(reason: "Not allowed"), on: app) == .forbidden)
            let redacted = try await wtCall(WTMessage.self, .POST, f.path + "/messages/\(message.id)/redact", token: f.owner.token,
                body: WTRedactRequest(reason: "Remove sensitive text"), on: app)
            #expect(redacted.isRedacted && redacted.senderID == f.owner.userID && redacted.sequence == 1)
            let snapshot = try await wtCall(WTSnapshot.self, .GET, f.path, token: agent.token, on: app)
            #expect(snapshot.conversations.first { $0.id == direct.id }?.readSequence == 1)
            let events = try await wtCall(WTEventPage.self, .GET, f.path + "/events?after=0", token: member.token, on: app)
            #expect(!events.events.contains { $0.conversationID == direct.id })
            #expect(!events.events.isEmpty)
            let visible = try await wtCall(WTEventPage.self, .GET, f.path + "/events?after=0", token: f.owner.token, on: app)
            #expect(visible.events.contains { $0.kind == "redacted" })
            _ = try await wtCall(WTAgent.self, .POST, f.path + "/agents/\(agent.agentID)/control", token: f.owner.token,
                body: WTAgentControl(action: .pause), on: app)
            let resumed = try await wtCall(WTAgent.self, .POST, f.path + "/agents/\(agent.agentID)/control", token: f.owner.token,
                body: WTAgentControl(action: .resume), on: app)
            #expect(resumed.status == .disconnected)
            let escaped = String(repeating: "\"", count: WTPolicy.messageByteLimit)
            let large = try await wtCall(WTMessage.self, .POST, f.path + "/messages", token: f.owner.token,
                body: WTPostMessage(conversationID: f.room, clientMessageID: UUID(), text: escaped), on: app)
            #expect(large.text == escaped)
        }
    }

    @Test func sourceRevisionStopsActiveWorkAndCannotWidenAnExistingGrant() async throws {
        try await withV2App { app, _ in
            let f = try await wtFixture(app), agent = try await wtAgent(f, app: app)
            let (source, _, task, run) = try await wtWork(f, agent: agent, app: app)
            _ = try await wtCall(WTEvidence.self, .POST, f.path + "/tasks/\(task.id)/evidence", token: agent.token,
                body: WTRecordEvidence(runID: run.id, fence: run.fence, kind: "test", summary: "One scoped check", commit: String(repeating: "a", count: 40)), on: app)
            #expect(try await v2Status(.POST, f.path + "/grants", token: f.owner.token,
                body: WTCreateGrant(subjectID: agent.agentID, sourceID: source.id, capabilities: [.editBranch], allowedPaths: ["Private"], expiresAt: Date().addingTimeInterval(3600)), on: app) == .badRequest)
            let changed = try await wtCall(WTContextSource.self, .PUT, f.path + "/context-sources/\(source.id)", token: f.owner.token,
                body: WTCreateSource(name: source.name, kind: source.kind, reference: source.reference, allowedPaths: ["Sources/Feature"], audienceIDs: source.audienceIDs, isPublic: source.isPublic), on: app)
            #expect(changed.revision == source.revision + 1)
            #expect(try await v2Status(.POST, f.path + "/runs/\(run.id)/checkpoint", token: agent.token,
                body: WTRunCheckpoint(fence: run.fence, operation: .readContext), on: app) == .conflict)
            #expect(try await v2Status(.PUT, f.path + "/context-sources/\(source.id)", token: f.owner.token,
                body: WTCreateSource(name: source.name, kind: source.kind, reference: "https://github.com/other/private", allowedPaths: ["Sources"], audienceIDs: source.audienceIDs), on: app) == .conflict)
        }
    }

    @Test(arguments: ["normal", "failure", "status", "pagination", "redirect", "moved"])
    func githubVerifierChecksAuthoritativeResponsesWithoutFollowingRedirects(_ mode: String) async throws {
        let fixture = WTGitHubResponses(mode: mode)
        let verifier = WTGitHubVerifier(transport: { request in try await fixture.respond(request) })
        let authority = WTProviderAuthority(repositories: ["example/demo"], token: "synthetic-read-credential")
        if ["pagination", "redirect", "moved"].contains(mode) {
            do {
                _ = try await verifier.verify(repository: "example/demo", number: 1, expectedChecks: ["Unit tests"], authority: authority)
                Issue.record("Incomplete or changed provider evidence must be refused")
            } catch let error as Abort { #expect(error.status == .conflict || error.status == .badGateway) }
        } else {
            let result = try await verifier.verify(repository: "example/demo", number: 1, expectedChecks: ["Unit tests"], authority: authority)
            #expect(result.checksPassed == (mode != "failure") && result.independentApproval && result.merged)
        }
        #expect(WTPolicy.mentions("Atlas", in: "@Atlas, please help") && !WTPolicy.mentions("Atlas", in: "@AtlasExtra please help"))
    }
}

private struct WTProviderFixture: WTProviderVerifier {
    var head: String
    func verify(repository: String, number: Int, expectedChecks: [String], authority: WTProviderAuthority) async throws -> WTProviderState {
        WTProviderState(head: head, base: String(repeating: "a", count: 40), merged: true,
            mergeCommit: String(repeating: "d", count: 40), checksPassed: true, independentApproval: true)
    }
}
private struct WTProviderRaceFixture: WTProviderVerifier {
    var head: String; var app: Application; var group: UUID
    func verify(repository: String, number: Int, expectedChecks: [String], authority: WTProviderAuthority) async throws -> WTProviderState {
        let row = try #require(try await WTInstallationRow.find(group, on: app.db))
        var state = try wtDecode(WTPersistedState.self, row.payload)
        state.installation.revision += 1; state.contextSources[0].revision += 1
        row.payload = try wtEncode(state); try await row.save(on: app.db)
        return WTProviderState(head: head, base: String(repeating: "a", count: 40), merged: true,
            mergeCommit: String(repeating: "d", count: 40), checksPassed: true, independentApproval: true)
    }
}

private actor WTGitHubResponses {
    let mode: String
    var pullReads = 0
    init(mode: String) { self.mode = mode }
    func respond(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        #expect(url.host == "api.github.com" && url.scheme == "https")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-read-credential")
        let head = String(repeating: "b", count: 40), base = String(repeating: "a", count: 40)
        let json: Any
        if url.path.hasSuffix("/reviews") {
            json = [["id": 1, "user": ["login": "independent-reviewer"], "state": "APPROVED", "commit_id": head]]
        } else if url.path.hasSuffix("/check-runs") {
            let runs: [[String: Any]] = mode == "status" ? [] : [["name": "Unit tests", "status": "completed", "conclusion": mode == "failure" ? "failure" : "success", "head_sha": head]]
            json = ["total_count": mode == "pagination" ? 101 : runs.count, "check_runs": runs]
        } else if url.path.hasSuffix("/status") {
            json = ["sha": head, "total_count": mode == "status" ? 1 : 0,
                    "statuses": mode == "status" ? [["context": "Unit tests", "state": "success"]] : []]
        } else {
            pullReads += 1
            json = ["head": ["sha": mode == "moved" && pullReads > 1 ? String(repeating: "c", count: 40) : head],
                    "base": ["sha": base], "merged": true, "merge_commit_sha": String(repeating: "d", count: 40), "user": ["login": "author"]]
        }
        let response = try #require(HTTPURLResponse(url: url, statusCode: mode == "redirect" ? 302 : 200, httpVersion: "HTTP/1.1", headerFields: nil))
        return (try JSONSerialization.data(withJSONObject: json), response)
    }
}
