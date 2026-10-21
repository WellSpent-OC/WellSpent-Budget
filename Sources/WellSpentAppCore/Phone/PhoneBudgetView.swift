// The iPhone's screens, built the iPhone's way. Layout only.
#if os(iOS)
import SwiftUI
import WellSpentCrypto
import WellSpentModel

/// One budget: its day, its wheel and figures, the count and its entries,
/// with Add at the foot in thumb reach and the budget's menu under ⋯: Import
/// statement, Edit and Delete. Draws `BudgetScreen`. Layout only.
struct PhoneBudgetView: View {
    @Bindable var model: AppModel
    @Bindable var sync: SyncCoordinator
    let summary: BudgetSummary
    /// The window's rules: the budget's menu and the question a delete asks.
    let main: MainScreen
    let perform: (MainScreen.Action) -> Void
    @Binding var addingEntry: Bool

    /// The budget's words and rows, shared with every app.
    private var screen: BudgetScreen { BudgetScreen(summary: summary, model: model, me: sync.userID) }

    var body: some View {
        let screen = self.screen
        let menu = main.budgetMenu(summary.budget)
        List {
            // The day, the wheel, its figures and the pace words:
            // PhoneBudgetWheel.swift.
            PhoneBudgetWheelSections(screen: screen) { perform(.editBudget(summary.budget)) }
            Section {
                if screen.rows.isEmpty {
                    Text(BudgetScreen.Words.empty)
                        .font(.subheadline)
                        .foregroundStyle(Palette.muted)
                }
                ForEach(screen.rows) { row in
                    PhoneEntryRow(row: row, showsAddedBy: screen.showsAddedBy)
                        // A tap, a swipe and a long press: PhoneEntryEditing.swift.
                        .phoneEntryActions(row, main: main)
                }
            }
            .listRowBackground(Palette.surface)
        }
        // The opened entry's sheet and the Undo bar: PhoneEntryEditing.swift.
        .phoneEntryEditing(model: model, undo: screen.undo)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Palette.ground)
        .foregroundStyle(Palette.ink)
        .navigationTitle(screen.title)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            // Import statement takes Add, as Add does. Edit and Delete take
            // Manage. PhoneImportStatement.swift
            if screen.mayAdd || !menu.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if screen.mayAdd { PhoneImportMenuItem() }
                        PhoneMenu(parts: menu, perform: perform)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityIdentifier(AccessibilityID.budgetMenu)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            // Adding takes Add, as the server decides. At View there is none.
            if screen.mayAdd {
                Button {
                    addingEntry = true
                } label: {
                    Text(BudgetScreen.Words.add)
                        .font(.headline)
                        // White would not read on the dark mode green.
                        .foregroundStyle(Palette.ground)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .accessibilityIdentifier(AccessibilityID.budgetAdd)
            }
        }
    }
}

/// One entry, in two lines: what and how much, then when and how it was
/// added, with who added it once someone else is in the group.
struct PhoneEntryRow: View {
    let row: BudgetScreen.Row
    let showsAddedBy: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.merchant)
                Text(row.detailLine)
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
                if !row.note.isEmpty {
                    Text(row.note)
                        .font(.footnote)
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                }
                if let notice = row.notice {
                    Text(notice)
                        .font(.footnote)
                        .italic()
                        .foregroundStyle(Palette.muted)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(row.amount)
                    .font(.body.monospacedDigit())
                if showsAddedBy {
                    Text(row.addedBy)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .overlay(Capsule().stroke(Palette.muted, lineWidth: 1))
                }
            }
        }
        // One element, read as its words in order. A tap opens it, so it is
        // read as a button: PhoneEntryEditing.swift.
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.entryRow(row.merchant))
    }
}

#endif
