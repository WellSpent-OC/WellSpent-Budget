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
        #expect(ActiveExtension.allCases == [.budgets, .properties, .warTable, .catalog])
        #expect(ActiveExtension.budgets.rawValue == "budgets")
        #expect(ActiveExtension.properties.rawValue == "properties")
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

    @Test func activityRailIncludesHousesWhenPropertiesIsOn() throws {
        var active = ActiveExtension.budgets

        let rail = ActivityRailView(
            active: Binding(get: { active }, set: { active = $0 }),
            isWarTableInstalled: false,
            isPropertiesInstalled: true,
            openAccount: {}
        )

        let buttons = try rail.inspect().findAll(ViewType.Button.self)
        // Budget, Houses, Extensions, Account
        #expect(buttons.count == 4)
        try buttons[1].tap()
        #expect(active == .properties)
    }

    @Test func extensionsCatalogTurnsPropertiesOnWhenTheFlagAllows() throws {
        var toggled = false
        var opened = false

        // Off the flag: no switch, the card says it is coming.
        let planned = ExtensionsCatalogView(
            isWarTableInstalled: false, isWarTableAvailable: false,
            toggleWarTable: {}, openWarTable: {},
            isPropertiesInstalled: false, isPropertiesAvailable: false,
            toggleProperties: { toggled = true }, openProperties: { opened = true }
        )
        let plannedText = try planned.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(plannedText.contains("Properties"))
        #expect(plannedText.contains("$5 a house a month, billed yearly"))
        #expect(plannedText.contains("Coming later"))
        #expect(throws: (any Error).self) { try planned.inspect().find(button: "Turn on") }

        // On the flag: Turn on, then Open and Turn off.
        let offered = ExtensionsCatalogView(
            isWarTableInstalled: false, isWarTableAvailable: false,
            toggleWarTable: {}, openWarTable: {},
            isPropertiesInstalled: false, isPropertiesAvailable: true,
            toggleProperties: { toggled = true }, openProperties: { opened = true }
        )
        try offered.inspect().find(button: "Turn on").tap()
        #expect(toggled)

        let on = ExtensionsCatalogView(
            isWarTableInstalled: false, isWarTableAvailable: false,
            toggleWarTable: {}, openWarTable: {},
            isPropertiesInstalled: true, isPropertiesAvailable: true,
            toggleProperties: { toggled = true }, openProperties: { opened = true }
        )
        let onText = try on.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(onText.contains("Turned on"))
        try on.inspect().find(button: "Open").tap()
        #expect(opened)
    }

    @Test func housesPlaceholderInvokesActions() throws {
        var catalogOpened = false
        var turnedOff = false
        let placeholder = HousesPlaceholderView(openCatalog: { catalogOpened = true }, turnOff: { turnedOff = true })
        let text = try placeholder.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(text.contains("Houses"))
        try placeholder.inspect().find(button: "Open Catalog").tap()
        #expect(catalogOpened)
        try placeholder.inspect().find(button: "Turn Off Extension").tap()
        #expect(turnedOff)
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

