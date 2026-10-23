// The iPhone's group money layout. Totals and words come from GroupMoney.
#if os(iOS)
import SwiftUI

/// The same group summary as the desktop, stacked to fit a phone.
struct PhoneGroupMoneySections: View {
    let money: GroupMoney

    var body: some View {
        Section(GroupMoney.Words.section) {
            VStack(spacing: 12) {
                Text(GroupMoney.Words.card)
                    .font(.subheadline)
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                MoneyWheelView(wheel: money.wheel, geometry: .budgetPhone, middle: .full(amountSize: 26))
                    .accessibilityIdentifier(AccessibilityID.groupWheel)
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 10, leading: 4, bottom: 4, trailing: 4))
        }
        Section {
            ForEach(money.wheel.figures) { figure in
                PhoneFigureRow(figure: figure)
            }
        } footer: {
            Text(money.note)
                .font(.footnote)
                .foregroundStyle(Palette.muted)
        }
        .listRowBackground(Palette.surface)
    }
}
#endif
