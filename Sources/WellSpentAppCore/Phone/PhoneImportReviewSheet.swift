// The iPhone's screens, built the iPhone's way. Layout only.
#if os(iOS)
import SwiftUI
import WellSpentCrypto
import WellSpentModel

/// The review before a statement goes in. The heading names the group, with
/// the file's name under it and the four counts below. Each line of the
/// statement follows, with what will happen to it and, when it needs one, a
/// list of the group's budgets. Nothing is added until Import, in the top bar
/// with Cancel. Draws `ImportReviewScreen`. Layout only.
struct PhoneImportReviewSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    private typealias Words = ImportReviewScreen.Words

    var body: some View {
        let screen = ImportReviewScreen(model: model)
        NavigationStack {
            List {
                // Only while there is a statement, as on the Mac. The sheet
                // can outlast it by a moment as it closes.
                if screen.isOpen {
                    Section {
                        heading(screen)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 8, trailing: 4))
                    }
                    Section {
                        ForEach(screen.rows) { row in
                            PhoneImportLine(row: row, choices: screen.budgetChoices) { screen.choose($0, for: row.id) }
                        }
                    } footer: {
                        Text(screen.note)
                    }
                    .listRowBackground(Palette.surface)
                }
            }
            .listStyle(.insetGrouped)
            .foregroundStyle(Palette.ink)
            // The heading is too long for the top bar, so the bar has no title.
            .phoneSheet(title: "")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Words.cancel) {
                        screen.cancel()
                        dismiss()
                    }
                    .accessibilityIdentifier(AccessibilityID.importCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(Words.importButton) {
                        screen.commit()
                        dismiss()
                    }
                    .accessibilityIdentifier(AccessibilityID.importConfirm)
                }
            }
        }
    }

    private func heading(_ screen: ImportReviewScreen) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(screen.title)
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(screen.filename)
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                      spacing: 10) {
                ForEach(screen.tiles) { tile in
                    PhoneImportTile(tile: tile)
                }
            }
        }
    }
}

/// One count across the top: the number in large type, with its label under
/// it in the colour of what it counts. VoiceOver reads the label, then the
/// number.
struct PhoneImportTile: View {
    let tile: ImportReviewScreen.Tile

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(tile.count)")
                .font(.title2.weight(.semibold).monospacedDigit())
            Text(tile.label)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(tile.tone.color))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tile.label)
        .accessibilityValue("\(tile.count)")
        .accessibilityIdentifier(AccessibilityID.importCount(tile.label))
    }
}

/// One line of the statement, in three lines: the date and the cleaned-up
/// name, with the amount; the bank's own words; then what will happen to it,
/// with the group's budgets to choose from when it needs one. A line that will
/// not be added is faded, and its words say so too.
struct PhoneImportLine: View {
    let row: ImportReviewScreen.Row
    let choices: [Budget]
    let choose: (BudgetID?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(row.dateAndName)
                Spacer(minLength: 8)
                Text(row.amount)
                    .font(.body.monospacedDigit())
            }
            Text(row.bankDescription)
                .font(.footnote)
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(row.tone.color))
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text(row.status)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color(row.tone.color))
                    .accessibilityIdentifier(AccessibilityID.importLineStatus(row.bankDescription))
                Spacer(minLength: 8)
                if row.needsBudget {
                    // "Budget" names the list for VoiceOver. On screen, the
                    // list shows only what is chosen.
                    Picker(ImportReviewScreen.Words.budget, selection: Binding(get: { row.chosenBudget },
                                                                               set: { choose($0) })) {
                        Text(ImportReviewScreen.Words.choose).tag(BudgetID?.none)
                        ForEach(choices) { budget in
                            Text(budget.name).tag(BudgetID?.some(budget.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .accessibilityIdentifier(AccessibilityID.importLineBudget(row.bankDescription))
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(row.isActionable ? 1 : 0.55)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.importLine(row.bankDescription))
    }
}

#endif
