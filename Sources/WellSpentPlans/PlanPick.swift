import Foundation

/// What a person keeps open on the free plan: one group, one person in it,
/// and as many properties as the plan allows. Ids only, as the server wants.
public struct PlanPick: Codable, Equatable, Sendable {
    public let groupID: UUID?
    public let person: PlanAnswer.Person?
    public let houseIDs: [UUID]

    public init(groupID: UUID?, person: PlanAnswer.Person?, houseIDs: [UUID]) {
        self.groupID = groupID
        self.person = person
        self.houseIDs = houseIDs
    }
}

/// The server's calls for what's locked: saving a pick, and taking over
/// paying for a locked group. Each answers with the plan as it now stands.
public protocol PlanLockService: Sendable {
    /// `POST /api/v2/plan/pick`.
    func savePick(_ pick: PlanPick) async throws -> PlanAnswer
    /// `POST /api/v2/groups/{id}/pay`, once this person's own plan is live.
    func payForGroup(_ groupID: UUID) async throws -> PlanAnswer
}

/// Why the server refused a pick or a takeover.
public enum PlanLockError: Error, Equatable, Sendable {
    /// The open group changed under 30 days ago. The answer's
    /// `open.groupChangedAt` says when it can change.
    case pickTooSoon
    /// A group, person or property that isn't this person's to pick.
    case notYours
    /// More properties than the plan allows.
    case tooMany
    /// Their own plan doesn't cover the group they tried to pay for.
    case planDoesNotCover
    /// The group they tried to pay for is gone, or they left it.
    case groupGone
    /// No answer from the server.
    case unreachable
}
