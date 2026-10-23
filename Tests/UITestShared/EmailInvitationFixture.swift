import Foundation
import WellSpentAppCore
import WellSpentCrypto
import WellSpentModel
import WellSpentSync

/// A sender without a window prepares data for recipient-side UI scenarios.
/// Sending in the app itself is checked by each platform's form scenario.
@MainActor
enum EmailInvitationFixture {
    static func makeGroup(sender: SecondAccount, named name: String,
                          budgets: [String]) async throws -> GroupID {
        let model = AppModel(store: sender.sync.store)
        guard let group = model.addGroup(named: name) else {
            throw UITestError("the invitation fixture could not create its group")
        }
        for name in budgets {
            guard let budget = model.addBudget(named: name, limit: Money(minorUnits: 50_000), in: group) else {
                throw UITestError("the invitation fixture could not create a budget")
            }
            model.selectedBudget = budget
            model.addTransaction(merchant: "Existing purchase", amount: Money(minorUnits: 1250),
                                 date: Date(), note: "")
            if model.errorMessage != nil {
                throw UITestError("the invitation fixture could not create its existing purchase")
            }
        }
        try await sender.syncAll()
        return group
    }

    static func send(sender: SecondAccount, group: GroupID, groupName: String,
                     to email: String) async throws -> SentEmailInvite {
        try await sender.sync.sendEmailInvitation(group: group, groupName: groupName, email: email,
            inviteeName: "Robin", myName: "Leslie", level: .write, history: .all)
    }
}
