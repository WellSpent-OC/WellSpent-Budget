// The iPhone's Houses screen, for the Properties extension. Layout only:
// every number and word comes from the package's HousesScreen, and each
// house's wheel from its group, since a house is a group.
#if os(iOS) && canImport(WellSpentProperties)
import SwiftUI
import WellSpentProperties

/// Houses (PROP-04 to PROP-08): when PriceLabs last brought bookings in,
/// Needs you, the three tiles, and a row per house with its small wheel.
/// With no houses, one empty state that says how a group becomes a house.
struct PhoneHousesView: View {
    let screen: HousesScreen
    /// Each house's wheel, by house id. A house with none draws no wheel.
    let wheels: [String: MoneyWheel]
    /// "PriceLabs brought in 4 bookings 9 minutes ago", or nothing before
    /// the first time.
    let broughtInLine: String?
    /// The Add House menu's items, by their words, in the order shown.
    let addItems: [(title: String, action: () -> Void)]

    var body: some View {
        List {
            if let broughtInLine {
                Text(broughtInLine)
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier(AccessibilityID.housesBroughtIn)
            }
            switch screen.state {
            case .noHouses:
                empty
            case .houses:
                needsYou
                tiles
                Section(HousesScreen.Words.yourHouses) {
                    ForEach(screen.rows) { row in
                        PhoneHouseRow(row: row, wheel: wheels[row.houseID])
                    }
                }
                .listRowBackground(Palette.surface)
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .scrollContentBackground(.hidden)
        .background(Palette.ground)
        .foregroundStyle(Palette.ink)
        .navigationTitle(HousesScreen.Words.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { addMenu }
        }
    }

    private var needsYou: some View {
        Section(NeedsYou.Words.title) {
            if screen.needsYou.isEmpty {
                Text(NeedsYou.Words.nothing)
                    .foregroundStyle(Palette.muted)
                    .accessibilityIdentifier(AccessibilityID.housesNothingNeedsYou)
            }
            ForEach(screen.needsYou.items) { item in
                Label {
                    Text(item.text)
                } icon: {
                    Circle().fill(Palette.warning).frame(width: 10, height: 10)
                }
                .accessibilityIdentifier(AccessibilityID.housesNeedsYou(item.text))
            }
        }
        .listRowBackground(Palette.surface)
    }

    /// Three across, each its value over its title and line.
    private var tiles: some View {
        Section {
            HStack(alignment: .top, spacing: 8) {
                ForEach(screen.tiles) { tile in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tile.value)
                            .font(.title3.weight(.semibold).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text(tile.title)
                            .font(.caption.weight(.semibold))
                        Text(tile.line)
                            .font(.caption2)
                            .foregroundStyle(Palette.muted)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Palette.surface))
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(AccessibilityID.housesTile(tile.title))
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
        }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label(HousesScreen.Words.noHousesYet, systemImage: "house")
        } description: {
            Text(HousesScreen.Words.noHousesLine)
        }
        .listRowBackground(Color.clear)
        .accessibilityIdentifier(AccessibilityID.housesEmpty)
    }

    private var addMenu: some View {
        Menu {
            ForEach(addItems.indices, id: \.self) { index in
                Button(addItems[index].title, action: addItems[index].action)
            }
        } label: {
            Image(systemName: "plus")
        }
        .menuOrder(.fixed)
        .accessibilityLabel(HousesScreen.Words.addHouse)
        .accessibilityIdentifier(AccessibilityID.housesAdd)
    }
}

/// One house: its name, its small wheel saying the cash flow, and three lines.
/// Below break-even, the cash flow line reads in rust (PROP-05).
private struct PhoneHouseRow: View {
    let row: HousesScreen.Row
    let wheel: MoneyWheel?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(row.name)
                .font(.headline)
            HStack(spacing: 14) {
                if let wheel {
                    MoneyWheelView(wheel: wheel, geometry: .homeCard, middle: .compact)
                        .accessibilityIdentifier(AccessibilityID.housesRowWheel(row.name))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.cashFlowWords)
                        .font(.body.weight(.semibold).monospacedDigit())
                        .foregroundStyle(row.isBelowBreakEven ? Palette.warning : Palette.ink)
                    Text(row.coveredWords)
                    Text("\(row.bookedWords) · \(row.nextThirtyWords)")
                }
                .font(.subheadline)
                .foregroundStyle(Palette.muted)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.housesRow(row.name))
    }
}
#endif
