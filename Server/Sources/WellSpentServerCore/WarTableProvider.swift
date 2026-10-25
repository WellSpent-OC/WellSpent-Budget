import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Vapor
import WarTableCore

/// An operator, separately from a chat owner, grants provider read authority.
/// No user-controlled host or redirect ever receives the provider credential.
private final class WTNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct WTProviderAuthority: Sendable {
    var repositories: Set<String>
    var token: String
    static func configured() throws -> WTProviderAuthority {
        let repositories = Set((Environment.get("WARTABLE_GITHUB_REPOSITORIES") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
        let token: String
        if let file = Environment.get("WARTABLE_GITHUB_TOKEN_FILE") {
            let attributes = try FileManager.default.attributesOfItem(atPath: file)
            guard let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0,
                  attributes[.type] as? FileAttributeType == .typeRegular else { throw Abort(.serviceUnavailable, reason: "Provider credential file must be a private regular file.") }
            token = try String(contentsOfFile: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        } else { token = Environment.get("WARTABLE_GITHUB_TOKEN") ?? "" }
        guard !token.isEmpty, !repositories.isEmpty else { throw Abort(.serviceUnavailable, reason: "The server operator must configure a GitHub read credential and repository allowlist before provider checks are available.") }
        return WTProviderAuthority(repositories: repositories, token: token)
    }
}

struct WTProviderState: Sendable {
    var head: String; var base: String; var merged: Bool; var mergeCommit: String?
    var checksPassed: Bool; var independentApproval: Bool
}
protocol WTProviderVerifier: Sendable {
    func verify(repository: String, number: Int, expectedChecks: [String], authority: WTProviderAuthority) async throws -> WTProviderState
}
struct WTProviderVerifierKey: StorageKey { typealias Value = any WTProviderVerifier }
struct WTProviderAuthorityKey: StorageKey { typealias Value = WTProviderAuthority }
private struct WTPendingProviderCheck: Sendable {
    var task: WTTask; var sourceRevision: Int; var sourceReference: String; var policyRevision: Int
}
private func wtProviderReviewer(_ scope: WTScope, task: WTTask, state: WTPersistedState) throws {
    guard scope.isOwner || scope.me.id == task.reviewerID else { throw Abort(.forbidden) }
    if scope.me.kind == .agent {
        guard scope.me.id != task.assigneeID, state.grants.contains(where: {
            $0.subjectID == scope.me.id && $0.sourceID == task.sourceID && $0.capabilities.contains(.review)
                && !$0.isRevoked && $0.expiresAt > Date()
        }) else { throw Abort(.forbidden, reason: "The designated reviewer no longer has a current review grant.") }
    }
}

struct WTGitHubVerifier: WTProviderVerifier {
    /// Test transport exercises real request construction and response checks
    /// without giving a test suite network access or provider credentials.
    var transport: (@Sendable (URLRequest) async throws -> (Data, HTTPURLResponse))? = nil
    private struct User: Decodable { var login: String }
    private struct Ref: Decodable { var sha: String }
    private struct Pull: Decodable { var head: Ref; var base: Ref; var merged: Bool; var merge_commit_sha: String?; var user: User }
    private struct Check: Decodable { var name: String; var status: String; var conclusion: String?; var head_sha: String }
    private struct Checks: Decodable { var total_count: Int; var check_runs: [Check] }
    private struct Status: Decodable { var context: String; var state: String }
    private struct Statuses: Decodable { var statuses: [Status]; var total_count: Int; var sha: String }
    private struct Review: Decodable { var id: Int; var user: User; var state: String; var commit_id: String }

    func verify(repository: String, number: Int, expectedChecks: [String], authority: WTProviderAuthority) async throws -> WTProviderState {
        guard authority.repositories.contains(repository.lowercased()) else { throw Abort(.forbidden, reason: "This repository is not in the server operator's allowlist.") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 45
        let session = URLSession(configuration: configuration, delegate: WTNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        func fetch<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
            guard let url = URL(string: "https://api.github.com/repos/" + repository + path) else { throw Abort(.badRequest) }
            var request = URLRequest(url: url)
            request.setValue("Bearer " + authority.token, forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("WellSpent-WarTable", forHTTPHeaderField: "User-Agent")
            let data: Data
            let response: HTTPURLResponse
            if let transport {
                (data, response) = try await transport(request)
            } else {
                let (received, receivedResponse) = try await session.data(for: request)
                guard let http = receivedResponse as? HTTPURLResponse else { throw Abort(.badGateway) }
                data = received; response = http
            }
            guard response.statusCode == 200, data.count <= 4 * 1024 * 1024 else {
                throw Abort(.badGateway, reason: "GitHub did not return a complete authorized provider response.")
            }
            return try JSONDecoder().decode(type, from: data)
        }
        let pull = try await fetch("/pulls/\(number)", as: Pull.self)
        guard wtCommit(pull.head.sha), wtCommit(pull.base.sha) else { throw Abort(.badGateway) }
        let checks = try await fetch("/commits/\(pull.head.sha)/check-runs?per_page=100", as: Checks.self)
        let statuses = try await fetch("/commits/\(pull.head.sha)/status?per_page=100", as: Statuses.self)
        let reviews = try await fetch("/pulls/\(number)/reviews?per_page=100", as: [Review].self)
        // Fail closed when pagination could hide a later failure or withdrawn review.
        guard checks.total_count <= 100, statuses.total_count <= 100, reviews.count < 100, statuses.sha == pull.head.sha else {
            throw Abort(.conflict, reason: "Provider evidence exceeds the bounded verifier. Review it on GitHub.")
        }
        let checksPassed = !expectedChecks.isEmpty && expectedChecks.allSatisfy { name in
            let named = checks.check_runs.filter { $0.name == name }
            if !named.isEmpty { return named.allSatisfy { $0.head_sha == pull.head.sha && $0.status == "completed" && $0.conclusion == "success" } }
            let namedStatuses = statuses.statuses.filter { $0.context == name }
            return !namedStatuses.isEmpty && namedStatuses.allSatisfy { $0.state == "success" }
        }
        var latest: [String: Review] = [:]
        for review in reviews.sorted(by: { $0.id < $1.id }) where review.state != "COMMENTED" && review.state != "PENDING" { latest[review.user.login] = review }
        let independent = latest.values.contains { $0.user.login != pull.user.login && $0.state == "APPROVED" && $0.commit_id == pull.head.sha }
            && !latest.values.contains { $0.state == "CHANGES_REQUESTED" }
        // Read the PR again after checks/reviews to reject a moving target.
        let current = try await fetch("/pulls/\(number)", as: Pull.self)
        guard current.head.sha == pull.head.sha, current.base.sha == pull.base.sha, current.merged == pull.merged else {
            throw Abort(.conflict, reason: "The PR changed during verification. Refresh and review its current commits.")
        }
        return WTProviderState(head: pull.head.sha, base: pull.base.sha, merged: pull.merged,
            mergeCommit: pull.merge_commit_sha, checksPassed: checksPassed, independentApproval: independent)
    }
}

func registerWarTableProviderRoutes(_ routes: any RoutesBuilder) throws {
    routes.post("tasks", ":taskID", "provider-check") { request async throws -> WTProviderCheck in
        let id = try request.parameters.require("taskID", as: UUID.self)
        // Network requests happen outside the installation transaction. The
        // authority and exact task head are checked again when applying results.
        let pending = try await withWarTable(request) { scope, state, _ in
            let index = try wtTaskIndex(id, scope: scope, state: state), task = state.tasks[index]
            try wtProviderReviewer(scope, task: task, state: state)
            guard task.state == .awaitingReview || task.state == .done else { throw Abort(.conflict) }
            let source = try scope.source(task.sourceID, in: state)
            guard source.kind == .repository, let url = task.prURL else { throw Abort(.conflict) }
            let pr = try wtGitHubPR(url)
            guard source.reference == "https://github.com/" + pr.repository else { throw Abort(.forbidden, reason: "The PR must belong to the exact canonical source repository.") }
            return WTPendingProviderCheck(task: task, sourceRevision: source.revision, sourceReference: source.reference, policyRevision: state.installation.revision)
        }
        let task = pending.task
        let pr = try wtGitHubPR(task.prURL!)
        let authority = try request.application.storage[WTProviderAuthorityKey.self] ?? WTProviderAuthority.configured()
        guard authority.repositories.contains(pr.repository.lowercased()) else { throw Abort(.forbidden) }
        let verifier = request.application.storage[WTProviderVerifierKey.self] ?? WTGitHubVerifier()
        let result = try await verifier.verify(repository: pr.repository, number: pr.number, expectedChecks: task.expectedChecks, authority: authority)
        return try await withWarTable(request) { scope, state, db in
            let index = try wtTaskIndex(id, scope: scope, state: state), current = state.tasks[index]
            guard state.evidence.count < 10_000 else { throw Abort(.insufficientStorage, reason: "Archive work evidence before recording more provider checks.") }
            let source = try scope.source(current.sourceID, in: state)
            try wtProviderReviewer(scope, task: current, state: state)
            guard (current.state == .awaitingReview || current.state == .done),
                  source.reference == pending.sourceReference, source.revision == pending.sourceRevision,
                  state.installation.revision == pending.policyRevision,
                  current.headCommit == task.headCommit, current.prURL == task.prURL,
                  current.expectedChecks == task.expectedChecks, current.headCommit == result.head else {
                throw Abort(.conflict, reason: "The task or PR commit changed. Approval must be repeated for its exact current head.")
            }
            let check = WTProviderCheck(taskID: id, headCommit: result.head, baseCommit: result.base,
                isMerged: result.merged, mergeCommit: result.mergeCommit, checksPassed: result.checksPassed,
                hasIndependentApproval: result.independentApproval, checkedAt: Date())
            // This records provider facts. It cannot approve or merge a PR.
            let summary = "GitHub: head \(result.head); base \(result.base); expected checks \(result.checksPassed ? "passed" : "not satisfied"); independent approval \(result.independentApproval); merged \(result.merged)."
            if let run = state.runs.last(where: { $0.taskID == id }) {
                state.evidence.append(WTEvidence(id: UUID(), taskID: id, runID: run.id, kind: "providerVerified", summary: summary, commit: result.head, url: current.prURL, createdAt: Date()))
            }
            if result.merged, result.checksPassed, result.independentApproval, let merge = result.mergeCommit, wtCommit(merge) {
                state.tasks[index].state = .done
            }
            try await wtEvent("providerChecked", summary: summary, subject: id, conversation: current.conversationID, state: &state, on: db)
            return check
        }
    }
}
