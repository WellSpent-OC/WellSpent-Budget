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

/// Where a pick is saved. The server's request plugs in here.
public protocol PlanPickSaving: Sendable {
    func savePick(_ pick: PlanPick) async throws
}
