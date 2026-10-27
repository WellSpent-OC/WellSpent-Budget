#if canImport(SwiftUI)
import Foundation
import SwiftUI
import Testing
import ViewInspector
@testable import WellSpentAppCore

@Suite("Extension views")
@MainActor
struct ExtensionViewTests {
    @Test func activeExtensionCases() {
        #expect(ActiveExtension.allCases == [.budgets, .runway, .warTable, .catalog])
        #expect(ActiveExtension.budgets.rawValue == "budgets")
        #expect(ActiveExtension.runway.rawValue == "runway")
        #expect(ActiveExtension.warTable.rawValue == "warTable")
        #expect(ActiveExtension.catalog.rawValue == "catalog")
    }

    @Test func activityRailRendersStandardButtons() throws {
        var active = ActiveExtension.budgets
        var accountOpened = false

        let rail = ActivityRailView(
            active: Binding(get: { active }, set: { active = $0 }),
            isWarTableInstalled: false,
            openAccount: { accountOpened = true }
        )

        let buttons = try rail.inspect().findAll(ViewType.Button.self)
        // Budget, Extensions, Account
        #expect(buttons.count == 3)

        // Tap Extensions button
        try buttons[1].tap()
        #expect(active == .catalog)

        // Tap Account button
        try buttons[2].tap()
        #expect(accountOpened)
    }

    @Test func activityRailIncludesWarTableWhenInstalled() throws {
        var active = ActiveExtension.budgets

        let rail = ActivityRailView(
            active: Binding(get: { active }, set: { active = $0 }),
            isWarTableInstalled: true,
            openAccount: {}
        )

        let buttons = try rail.inspect().findAll(ViewType.Button.self)
        // Budget, WarTable, Extensions, Account
        #expect(buttons.count == 4)

        // Tap WarTable
        try buttons[1].tap()
        #expect(active == .warTable)
    }

    @Test func extensionsCatalogRendersCardsAndTogglesWarTable() throws {
        var toggled = false
        var opened = false

        let catalog = ExtensionsCatalogView(
            isWarTableInstalled: false,
            isWarTableAvailable: true,
            toggleWarTable: { toggled = true },
            openWarTable: { opened = true }
        )

        let text = try catalog.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(text.contains("Extensions"))
        #expect(text.contains("WarTable"))
        #expect(text.contains(where: { $0.contains("Properties") }))
        #expect(text.contains("Available"))

        // Tap Turn on
        let turnOnButton = try catalog.inspect().find(button: "Turn on")
        try turnOnButton.tap()
        #expect(toggled)

        // Installed view
        let installedCatalog = ExtensionsCatalogView(
            isWarTableInstalled: true,
            isWarTableAvailable: true,
            toggleWarTable: { toggled = true },
            openWarTable: { opened = true }
        )
        let installedText = try installedCatalog.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(installedText.contains("Turned on"))
        let openButton = try installedCatalog.inspect().find(button: "Open")
        try openButton.tap()
        #expect(opened)
    }

    @Test func warTablePlaceholderInvokesActions() throws {
        var catalogOpened = false
        var turnedOff = false

        let placeholder = WarTablePlaceholderView(
            openCatalog: { catalogOpened = true },
            turnOff: { turnedOff = true }
        )

        let text = try placeholder.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(text.contains("WarTable"))
        #expect(text.contains("STAGING PREVIEW · IN DEVELOPMENT"))

        let openCatalogButton = try placeholder.inspect().find(button: "Open Catalog")
        try openCatalogButton.tap()
        #expect(catalogOpened)

        let turnOffButton = try placeholder.inspect().find(button: "Turn Off Extension")
        try turnOffButton.tap()
        #expect(turnedOff)
    }
}
#endif

