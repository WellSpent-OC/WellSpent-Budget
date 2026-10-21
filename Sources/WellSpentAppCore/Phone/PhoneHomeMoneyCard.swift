// The iPhone's screens, built the iPhone's way. Layout only.
#if os(iOS)
import SwiftUI
import WellSpentModel

/// The card at the top of Home: the first group's wheel for the month, with
/// the group and the month, the day, and what is spent of what is budgeted.
/// Draws `GroupMoney`. Not a button yet: the money view a tap would open
/// comes in a later step. Layout only.
struct PhoneHomeMoneyCard: View {
    let money: GroupMoney

    var body: some View {
        Section {
            HStack(spacing: 12) {
                MoneyWheelView(wheel: money.wheel, geometry: .homeCard, middle: .compact)
                VStack(alignment: .leading, spacing: 3) {
                    Text(money.title)
                        .font(.headline)
                    Group {
                        if let day = money.wheel.day {
                            Text(day.shortLine)
                        }
                        Text(money.spentLine)
                    }
                    .font(.subheadline)
                    .foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityID.homeMoney)
        }
        .listRowBackground(Palette.surface)
    }
}

#endif
