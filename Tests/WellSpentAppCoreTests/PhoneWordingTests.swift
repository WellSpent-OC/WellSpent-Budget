import Testing
import WellSpentAppCore

/// The iPhone's buttons and menus end without the desktop's "…".
@Suite("iPhone words")
@MainActor
struct PhoneWordingTests {
    @Test func aButtonDropsTheEllipsisAtItsEnd() {
        #expect(PhoneWording.button("Delete\u{2026}") == "Delete")
        #expect(PhoneWording.button("New Budget in Household\u{2026}") == "New Budget in Household")
    }

    @Test func aTitleWithNoEllipsisAtItsEndStaysAsItIs() {
        #expect(PhoneWording.button("Save") == "Save")
        #expect(PhoneWording.button("") == "")
        #expect(PhoneWording.button("Wait\u{2026} then save") == "Wait\u{2026} then save")
    }

    /// The words an entry's sheet and its row's menu use on the iPhone.
    @Test func anEntrysEditAndDeleteHaveNoEllipsis() {
        #expect(PhoneWording.button(EntryEditor.Words.delete) == "Delete")
        #expect(PhoneWording.button(MainScreen.Words.edit) == "Edit")
        #expect(PhoneWording.button(MainScreen.Words.delete) == "Delete")
    }

    /// A tap on any row of a budget's list opens it, and VoiceOver says so
    /// after the row's words.
    @Test func aRowSaysWhatATapOnItDoes() {
        #expect(BudgetScreen.Words.rowHelp == "Opens the transaction.")
    }
}
