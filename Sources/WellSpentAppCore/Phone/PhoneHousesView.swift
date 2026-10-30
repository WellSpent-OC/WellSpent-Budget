// The iPhone's Houses screen, for the Properties extension. Layout only:
// every number and word comes from the package's HousesScreen, and each
// house's wheel from its group, since a house is a group.
#if os(iOS) && canImport(WellSpentProperties)
import SwiftUI
import WellSpentProperties

/// The Houses tab: the shared feed, the screen it draws, and the key sheet.
/// Bookings come in when the tab opens and on a pull down.
struct PhoneHousesTab: View {
    @State private var feed: HousesFeed

    init(model: AppModel) {
        _feed = State(initialValue: HousesFeed(model: model))
    }

    var body: some View {
        PhoneHousesView(screen: feed.screen, wheels: feed.wheels, broughtInLine: feed.connectionLine,
                        offersReconnect: feed.connection.offersReconnect,
                        addItems: [(HousesScreen.Words.connectPriceLabs, { feed.openKeySheet() })],
                        reconnect: { feed.openKeySheet() },
                        refresh: { await feed.refresh() })
            .onAppear { feed.rebuild() }
            .task { await feed.refresh() }
            .sheet(isPresented: Binding(get: { feed.keySheet != nil }, set: { if !$0 { feed.closeKeySheet() } })) {
                PhonePriceLabsKeySheet(feed: feed)
            }
    }
}

/// Houses (PROP-04 to PROP-08): when PriceLabs last brought bookings in,
/// Needs you, the three tiles, and a row per house with its small wheel.
/// With no houses, one empty state that says how a group becomes a house.
struct PhoneHousesView: View {
    let screen: HousesScreen
    /// Each house's wheel, by house id. A house with none draws no wheel.
    let wheels: [String: MoneyWheel]
    /// "PriceLabs brought in 4 bookings 9 minutes ago", the paused line, or
    /// nothing before the first time.
    let broughtInLine: String?
    /// Paused: Reconnect sits beside the line (PROP-17).
    let offersReconnect: Bool
    /// The Add House menu's items, by their words, in the order shown.
    let addItems: [(title: String, action: () -> Void)]
    let reconnect: () -> Void
    let refresh: () async -> Void

    var body: some View {
        List {
            if let broughtInLine {
                HStack {
                    Text(broughtInLine)
                        .font(.footnote)
                        .foregroundStyle(offersReconnect ? Palette.warning : Palette.muted)
                        .accessibilityIdentifier(AccessibilityID.housesBroughtIn)
                    if offersReconnect {
                        Spacer(minLength: 8)
                        Button(PriceLabsConnection.Words.reconnect, action: reconnect)
                            .font(.footnote.weight(.semibold))
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier(AccessibilityID.housesReconnect)
                    }
                }
                .listRowBackground(Color.clear)
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
        .refreshable { await refresh() }
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
        } actions: {
            ForEach(addItems.indices, id: \.self) { index in
                Button(addItems[index].title, action: addItems[index].action)
                    .buttonStyle(.bordered)
            }
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

/// Connect PriceLabs (PROP-14, PROP-15): paste the owner's key, PriceLabs
/// checks it, then choose which listings are houses. Every word and step
/// comes from `PriceLabsKeySheet`.
private struct PhonePriceLabsKeySheet: View {
    let feed: HousesFeed
    @State private var chosen: Set<PriceLabsListing.ID> = []

    private var sheet: PriceLabsKeySheet { feed.keySheet ?? PriceLabsKeySheet() }
    private typealias Words = PriceLabsKeySheet.Words

    var body: some View {
        NavigationStack {
            Group {
                if case .choosing(let listings) = sheet.step {
                    choose(listings)
                } else {
                    enter
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.ground)
            .navigationTitle(Words.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Words.cancel) { feed.closeKeySheet() }
                        .accessibilityIdentifier(AccessibilityID.keySheetCancel)
                }
            }
        }
    }

    private var enter: some View {
        Form {
            Section {
                SecureField(Words.field, text: Binding(get: { sheet.key }, set: { feed.keySheet?.key = $0 }))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier(AccessibilityID.keySheetField)
                if let failure = sheet.failure {
                    Text(failure)
                        .foregroundStyle(Palette.warning)
                        .accessibilityIdentifier(AccessibilityID.keySheetFailure)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Words.whereToFind)
                    Text(Words.noKeyYet)
                    Text(Words.cost)
                    Text(Words.onlyReads)
                    Text(Words.staysYours)
                }
            }
            .listRowBackground(Palette.surface)
            Section {
                Button {
                    Task { await feed.connect() }
                } label: {
                    if sheet.step == .checking {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(Words.checking)
                        }
                    } else {
                        Text(Words.connect)
                    }
                }
                .disabled(!sheet.mayConnect)
                .accessibilityIdentifier(AccessibilityID.keySheetConnect)
            }
            .listRowBackground(Palette.surface)
        }
    }

    private func choose(_ listings: [PriceLabsListing]) -> some View {
        Form {
            Section {
                ForEach(listings) { listing in
                    Toggle(listing.name, isOn: Binding(
                        get: { chosen.contains(listing.id) },
                        set: { on in
                            if on { chosen.insert(listing.id) } else { chosen.remove(listing.id) }
                        }))
                    .accessibilityIdentifier(AccessibilityID.keySheetListing(listing.name))
                }
            } header: {
                Text(Words.chooseTitle)
            } footer: {
                Text(Words.chooseLine)
            }
            .listRowBackground(Palette.surface)
            Section {
                Button(Words.addHouses) {
                    let picked = listings.filter { chosen.contains($0.id) }
                    Task { await feed.addHouses(picked) }
                }
                .disabled(chosen.isEmpty)
                .accessibilityIdentifier(AccessibilityID.keySheetAddHouses)
            }
            .listRowBackground(Palette.surface)
        }
        // Every listing starts chosen: most hosts' listings are all houses.
        .onAppear { chosen = Set(listings.map(\.id)) }
    }
}
#endif
