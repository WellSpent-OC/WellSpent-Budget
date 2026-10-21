// The iPhone's screens, built the iPhone's way. Layout only.
#if os(iOS)
import SwiftUI
import WellSpentModel

extension View {
    /// Fills a budget's row on Home as far as the budget is used, and says so
    /// to a screen reader: "25 percent used", or "Over budget". The fill is
    /// the row's whole background, in plain rectangles: the inset list rounds
    /// the section's corners. Its colours follow the phone's light or dark
    /// setting.
    func phoneRowFill(_ summary: BudgetSummary) -> some View {
        let fill = RowFill(summary)
        return listRowBackground(RowFillBackground(fill: fill, cornerRadius: 0))
            .accessibilityValue(fill.spokenValue)
    }
}

#endif
