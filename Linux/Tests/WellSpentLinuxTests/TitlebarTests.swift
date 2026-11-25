import Testing
@testable import WellSpentLinux

/// What the titlebar says beside WELLSPENT (ops#408).
struct TitlebarTests {
    @Test func aGroupsPageShowsItsNameAlone() {
        #expect(Titlebar.subtitle(openGroup: "Household") == "Household")
    }

    @Test func noGroupsPageShowsNothing() {
        #expect(Titlebar.subtitle(openGroup: nil) == "")
    }
}
