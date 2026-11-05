// SwiftUI and ViewInspector exist only on Apple systems.
#if canImport(SwiftUI)
import Testing
import Foundation
import SwiftUI
import ViewInspector
@testable import WellSpentAppCore
import WellSpentCrypto
import WellSpentExtensionKit
import WellSpentModel
import WellSpentStore

/// Home with Bills, and Other with no budgets, with the test extension on.
@MainActor
private struct Slotted {
    let model: AppModel
    let home: GroupID
    let empty: GroupID
    let bills: BudgetID

    init() throws {
        model = AppModel(store: Store(database: try WellSpentDatabase.inMemory()))
        home = try #require(model.addGroup(named: "Home"))
        empty = try #require(model.addGroup(named: "Other"))
        bills = try #require(model.addBudget(named: "Bills", limit: .dollars(500), in: home))
        model.install(TestExtensionSlots())
        model.reload()
    }

    func has(_ id: String, in sheet: EntrySheet) -> Bool {
        (try? sheet.inspect().find(viewWithAccessibilityIdentifier: id)) != nil
    }
}

@Suite("The entry sheet an extension asks for")
@MainActor
struct EntrySheetSlotTests {
    @Test func addingInAGroupDrawsTheBudgetAndLinkRows() throws {
        let setup = try Slotted()
        let sheet = EntrySheet(model: setup.model, request: .add(group: setup.home, link: nil))
        #expect(setup.has(AccessibilityID.entryBudget, in: sheet))
        #expect(setup.has(AccessibilityID.entryLink, in: sheet))
        #expect(!setup.has(AccessibilityID.entryNewBudgetName, in: sheet))
    }

    @Test func aGroupWithNoBudgetsDrawsTheNewBudgetFields() throws {
        let setup = try Slotted()
        let sheet = EntrySheet(model: setup.model, request: .add(group: setup.empty, link: nil))
        #expect(setup.has(AccessibilityID.entryNewBudgetName, in: sheet))
        #expect(setup.has(AccessibilityID.entryNewBudgetAmount, in: sheet))
        #expect(!setup.has(AccessibilityID.entryNoBudgetLine, in: sheet))
    }

    @Test func belowManageAGroupWithNoBudgetsDrawsTheLineOnly() throws {
        let setup = try Slotted()
        setup.model.mayManageEntries = { _ in false }
        let sheet = EntrySheet(model: setup.model, request: .add(group: setup.empty, link: nil))
        #expect(setup.has(AccessibilityID.entryNoBudgetLine, in: sheet))
        #expect(!setup.has(AccessibilityID.entryBudget, in: sheet))
    }

    @Test func openingAnEntryDrawsItsLinkRow() throws {
        let setup = try Slotted()
        let bill = Transaction(budgetID: setup.bills, groupID: setup.home, date: Date(), merchant: "Water",
                               amount: Money(minorUnits: -900))
        try setup.model.store.save(bill, queue: false)
        let sheet = EntrySheet(model: setup.model, request: .open(bill.id))
        #expect(setup.has(AccessibilityID.entryLink, in: sheet))
    }

    @Test func aRequestsIDSaysWhatItAsks() {
        let group = GroupID(), link = RecordID()
        #expect(EntrySheetRequest.add(group: group, link: link).id != EntrySheetRequest.add(group: group, link: nil).id)
        #expect(EntrySheetRequest.open(link).id.hasPrefix("open-"))
    }
}

@Suite("The host, for an extension")
@MainActor
struct AppExtensionHostSlotTests {
    @Test func budgetsGroupsAndANewPlainGroup() throws {
        let setup = try Slotted()
        let host = AppExtensionHost(model: setup.model)
        let budgets = host.budgets(in: setup.home.uuid.uuidString)
        #expect(budgets.map(\.name) == ["Bills"])
        #expect(budgets.first?.limitMinorUnits == 50_000)
        #expect(host.budgets(in: "not an id").isEmpty)
        let added = try #require(host.addGroup(named: "Cabin"))
        #expect(host.groups().contains { $0.id == added && $0.name == "Cabin" })
        #expect(host.budgets(in: added).isEmpty, "a new group starts with no budgets")
    }

    @Test func entriesFollowingHistorySaveAndRemoveToo() throws {
        let setup = try Slotted()
        let host = AppExtensionHost(model: setup.model)
        let group = setup.home.uuid.uuidString
        let id = try #require(host.saveRecord(kind: "stay", .followsHistory, sourceKey: "s1", id: nil, body: "{}",
                                              in: group, extensionID: "e"))
        #expect(host.records(kind: "stay", .followsHistory, in: group, extensionID: "e").map(\.sourceKey) == ["s1"])
        host.removeRecord(id, .followsHistory)
        #expect(host.records(kind: "stay", .followsHistory, in: group, extensionID: "e").isEmpty)
    }

    /// A record with no source key keeps the ID it was saved under.
    @Test func aRecordWithNoSourceKeyKeepsItsID() throws {
        let setup = try Slotted()
        let host = AppExtensionHost(model: setup.model)
        let group = setup.home.uuid.uuidString
        let id = try #require(host.saveRecord(kind: "note", .everyMember, sourceKey: nil, id: nil, body: "1", in: group,
                                              extensionID: "e"))
        #expect(host.saveRecord(kind: "note", .everyMember, sourceKey: nil, id: id, body: "2", in: group,
                                extensionID: "e") == id)
        #expect(host.records(kind: "note", .everyMember, in: group, extensionID: "e").map(\.body) == ["2"])
    }

    @Test func aWheelIsDrawnFromPlainValuesAtEachSize() throws {
        let setup = try Slotted()
        let host = AppExtensionHost(model: setup.model)
        let values = HostWheel(currency: "USD", plannedMinorUnits: 555_000, coversMinorUnits: 400_000)
        for size in [HostWheelSize.homeCard, .budgetPage, .budgetPhone] {
            #expect(host.wheel(values, size: size) != nil)
        }
        #expect(host.wheel(HostWheel(currency: "nope", plannedMinorUnits: 0, coversMinorUnits: 0), size: .homeCard) == nil)
    }

    @Test func theTestExtensionFillsEverySlot() throws {
        let slots = TestExtensionSlots()
        #expect(slots.linkChoices(in: "g")?.label == TestExtensionSlots.label)
        #expect(slots.groupPageTopLine(for: "g")?.amount == "$1")
        #expect(slots.groupPageSection(for: "g") != nil)
    }

    @Test func withoutSlotsTheLinkRowIsGoneAgain() throws {
        let setup = try Slotted()
        setup.model.install(nil)
        #expect(setup.model.linkChoices(setup.home) == nil)
    }
}
#endif
