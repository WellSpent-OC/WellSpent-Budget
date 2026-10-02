import Testing
import Foundation
import SwiftUI
import ViewInspector
@testable import WellSpentAppCore
import WellSpentCrypto
import WellSpentKeyStore
import WellSpentModel
import WellSpentStore
import WellSpentSync

/// The editing and sharing sheets, drawn, and what they say in each state.
@Suite("Sheets", .serialized)
@MainActor
struct SheetTests {
    private func model() throws -> (AppModel, BudgetGroup, Budget) {
        let model = AppModel(store: Store(database: try WellSpentDatabase.inMemory()))
        let group = try #require(model.addGroup(named: "Household").flatMap(model.group(named:)))
        let id = try #require(model.addBudget(named: "Groceries", limit: Money(minorUnits: 50_000),
                                              in: group.id))
        return (model, group, try #require(model.budget(for: id)))
    }

    private func sync(_ model: AppModel) -> SyncCoordinator {
        SyncCoordinator(store: model.store, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    }

    private func texts(_ view: some View) throws -> [String] {
        try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
    }

    // MARK: - Budgets and groups

    @Test func newBudgetAsksForNameAmountAndGroup() throws {
        let (model, group, _) = try model()
        let shown = try texts(BudgetSheet(model: model, group: group.id))
        #expect(shown.contains("New Budget"))
        #expect(shown.contains("Starts again on the 1st of each month."))
        #expect(shown.contains("Add"))
        #expect(try BudgetSheet(model: model).inspect().find(ViewType.Picker.self) != nil,
                "a group to put it in")
    }

    /// A new budget can only go in a group this person manages. With none of
    /// those, it gets a new group of its own.
    @Test func aNewBudgetIsOfferedOnlyTheGroupsGiven() throws {
        let (model, group, _) = try model()
        let other = try #require(model.addGroup(named: "Book Club").flatMap(model.group(named:)))
        let picker = try BudgetSheet(model: model, groups: [other]).inspect().find(ViewType.Picker.self)
        let names = try picker.findAll(ViewType.Text.self).map { try $0.string() }
        #expect(names.contains("Book Club"))
        #expect(!names.contains(group.name))

        let none = BudgetSheet(model: model, groups: [])
        #expect((try? none.inspect().find(ViewType.Picker.self)) == nil)
        #expect(try texts(none).contains("New Budget"))
    }

    @Test func editingABudgetSaysSoAndOffersNoGroupChoice() throws {
        let (model, _, budget) = try model()
        let sheet = BudgetSheet(model: model, editing: budget)
        let shown = try texts(sheet)
        #expect(shown.contains("Edit Budget"))
        #expect(shown.contains("Save"))
        #expect((try? sheet.inspect().find(ViewType.Picker.self)) == nil,
                "budgets do not move between groups")
    }

    @Test func aBudgetWithNoGroupsYetAsksForOne() throws {
        let model = AppModel(store: Store(database: try WellSpentDatabase.inMemory()))
        let sheet = BudgetSheet(model: model)
        #expect(try texts(sheet).contains("New Budget"))
        #expect((try? sheet.inspect().find(ViewType.Picker.self)) == nil)
    }

    @Test func groupSheetsSayWhatAGroupIsFor() throws {
        let (model, group, _) = try model()
        let adding = try texts(GroupSheet(model: model))
        #expect(adding.contains("New Group"))
        #expect(adding.contains { $0.contains("what you will share") })
        #expect(try texts(GroupSheet(model: model, renaming: group)).contains("Rename Group"))
    }

    // MARK: - Sharing

    @Test func shareAsksWhatTheyCanDoAndWhatTheySee() throws {
        let (model, group, _) = try model()
        let shown = try texts(ShareSheet(sync: sync(model), group: group))
        #expect(shown.contains("Share \u{201C}Household\u{201D}"))
        for word in ["View", "Add", "Manage", "Everything so far", "Only from now on", "Create Link"] {
            #expect(shown.contains(word), "missing \(word) in \(shown)")
        }
        #expect(shown.contains(InviteRole.add.explanation), "Add is the default")
        #expect(shown.contains { $0.contains("Sign in first") }, "nobody is signed in here")
    }

    @Test func aCreatedLinkIsShownWithWhatToDoWithIt() throws {
        let (model, group, _) = try model()
        let link = InviteLink(secret: Data(repeating: 3, count: 32), groupName: "Household",
                              inviterName: "Robin")
        let shown = try texts(ShareSheet(sync: sync(model), group: group, created: link))
        #expect(shown.contains(link.url))
        #expect(shown.contains { $0.contains("works once and expires in 7 days") })
        #expect(shown.contains("Copy Link"))
        #expect(shown.contains("Done"))
    }

    @Test func joinSaysWhoInvitedYouOnceALinkIsPasted() throws {
        let (model, _, _) = try model()
        let empty = try texts(JoinSheet(sync: sync(model)))
        #expect(empty.contains("Join a Group"))
        #expect(!empty.contains { $0.contains("invited you") })

        let link = InviteLink(secret: Data(repeating: 4, count: 32), groupName: "Household",
                              inviterName: "Robin").url
        let pasted = try texts(JoinSheet(sync: sync(model), linkText: link))
        #expect(pasted.contains("Robin invited you to \u{201C}Household\u{201D}."))

        let anonymous = InviteLink(secret: Data(repeating: 4, count: 32), groupName: "",
                                   inviterName: "").url
        #expect(try texts(JoinSheet(sync: sync(model), linkText: anonymous))
                    .contains("Someone invited you to a group."))

        let wrong = try texts(JoinSheet(sync: sync(model), linkText: "https://example.com"))
        #expect(wrong.contains("That is not a WellSpent invite link."))
    }

    @Test func theInviteProblemsAreWords() {
        #expect(SyncCoordinator.inviteProblem(404).contains("not found"))
        #expect(SyncCoordinator.inviteProblem(409).contains("already been used"))
        #expect(SyncCoordinator.inviteProblem(410).contains("expired"))
        #expect(InviteRole.describing(.read) == "view this group")
        #expect(InviteRole.describing(.write) == "add transactions")
        #expect(InviteRole.describing(.manage) == "manage this group")
    }
}
