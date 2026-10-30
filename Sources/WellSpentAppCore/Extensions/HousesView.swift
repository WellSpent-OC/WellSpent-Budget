// The Mac's Houses screen, for the Properties extension. Layout only: every
// number and word comes from the package's HousesScreen through the shared
// HousesFeed, and each house's wheel from its group, since a house is a
// group. The iPhone draws the same feed in PhoneHousesView.
#if os(macOS) && canImport(WellSpentProperties)
import SwiftUI
import WellSpentProperties

/// Houses on the rail: the shared feed, the screen it draws, and the key
/// sheet. Bookings come in when Houses opens, and on Refresh.
struct HousesTab: View {
    @State private var feed: HousesFeed

    init(model: AppModel) {
        _feed = State(initialValue: HousesFeed(model: model))
    }

    var body: some View {
        HousesView(feed: feed)
            .onAppear { feed.rebuild() }
            .task { await feed.refresh() }
            .sheet(isPresented: Binding(get: { feed.keySheet != nil }, set: { if !$0 { feed.closeKeySheet() } })) {
                PriceLabsKeySheetView(feed: feed)
            }
    }
}

/// Houses (PROP-04 to PROP-08): the line saying when PriceLabs last brought
/// bookings in, Needs you, the three tiles, and a card per house with its
/// small wheel. With no houses, one empty state that says how to add one.
private struct HousesView: View {
    let feed: HousesFeed

    private var screen: HousesScreen { feed.screen }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    connectionLine
                    switch screen.state {
                    case .noHouses:
                        empty
                    case .houses:
                        needsYou
                        tiles
                        houses
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Palette.ground)
        .foregroundStyle(Palette.ink)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(HousesScreen.Words.title)
                .font(.system(size: 20, weight: .bold))
            Spacer()
            if feed.isRefreshing { ProgressView().controlSize(.small) }
            Button {
                Task { await feed.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")
            .disabled(feed.isRefreshing)
            Menu {
                Button(HousesScreen.Words.connectPriceLabs) { feed.openKeySheet() }
            } label: {
                Label(HousesScreen.Words.addHouse, systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier(AccessibilityID.housesAdd)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// "PriceLabs brought in 4 bookings 9 minutes ago", or the paused line
    /// with Reconnect beside it (PROP-17).
    @ViewBuilder
    private var connectionLine: some View {
        if let line = feed.connectionLine {
            HStack(spacing: 10) {
                Text(line)
                    .font(.system(size: 12))
                    .foregroundStyle(feed.connection.isPaused ? Palette.warning : Palette.muted)
                    .accessibilityIdentifier(AccessibilityID.housesBroughtIn)
                if feed.connection.offersReconnect {
                    Button(PriceLabsConnection.Words.reconnect) { feed.openKeySheet() }
                        .controlSize(.small)
                        .accessibilityIdentifier(AccessibilityID.housesReconnect)
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "house")
                .font(.system(size: 30))
                .foregroundStyle(Palette.accent)
            Text(HousesScreen.Words.noHousesYet)
                .font(.system(size: 17, weight: .semibold))
            Text(HousesScreen.Words.noHousesLine)
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button(HousesScreen.Words.connectPriceLabs) { feed.openKeySheet() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.housesEmpty)
    }

    private var needsYou: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(NeedsYou.Words.title)
            if screen.needsYou.isEmpty {
                Text(NeedsYou.Words.nothing)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
                    .accessibilityIdentifier(AccessibilityID.housesNothingNeedsYou)
            }
            ForEach(screen.needsYou.items) { item in
                HStack(spacing: 8) {
                    Circle().fill(Palette.warning).frame(width: 8, height: 8)
                    Text(item.text)
                        .font(.system(size: 13))
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AccessibilityID.housesNeedsYou(item.text))
            }
        }
    }

    /// Three across, each its value over its title and line.
    private var tiles: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(screen.tiles) { tile in
                VStack(alignment: .leading, spacing: 3) {
                    Text(tile.value)
                        .font(.system(size: 22, weight: .semibold).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(tile.title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(tile.line)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line, lineWidth: 1))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AccessibilityID.housesTile(tile.title))
            }
        }
    }

    private var houses: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(HousesScreen.Words.yourHouses)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12, alignment: .top)], spacing: 12) {
                ForEach(screen.rows) { row in
                    HouseCard(row: row, wheel: feed.wheels[row.houseID])
                }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Palette.muted)
    }
}

/// One house: its name, its small wheel saying the cash flow, and three
/// lines. Below break-even, the cash flow reads in rust (PROP-05).
private struct HouseCard: View {
    let row: HousesScreen.Row
    let wheel: MoneyWheel?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if let wheel {
                MoneyWheelView(wheel: wheel, geometry: .homeCard, middle: .compact)
                    .accessibilityIdentifier(AccessibilityID.housesRowWheel(row.name))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(row.name)
                    .font(.system(size: 15, weight: .semibold))
                Text(row.cashFlowWords)
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(row.isBelowBreakEven ? Palette.warning : Palette.ink)
                Group {
                    Text(row.coveredWords)
                    Text("\(row.bookedWords) \u{00B7} \(row.nextThirtyWords)")
                }
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.housesRow(row.name))
    }
}

/// Connect PriceLabs (PROP-14, 15, 17): paste the key, which PriceLabs
/// checks, then say which listings are houses. What it says is
/// PriceLabsKeySheet's.
private struct PriceLabsKeySheetView: View {
    let feed: HousesFeed
    @State private var chosen: Set<PriceLabsListing.ID> = []

    private var sheet: PriceLabsKeySheet { feed.keySheet ?? PriceLabsKeySheet() }
    private typealias Words = PriceLabsKeySheet.Words

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Words.title)
                .font(.system(size: 17, weight: .bold))
            if case .choosing(let listings) = sheet.step {
                choose(listings)
            } else {
                enter
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(Palette.ground)
        .foregroundStyle(Palette.ink)
    }

    private var enter: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(Words.whereToFind)
                Text(Words.noKeyYet)
                Text(Words.cost)
                Text(Words.onlyReads)
                Text(Words.staysYours)
            }
            .font(.system(size: 12))
            .foregroundStyle(Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
            SecureField(Words.field, text: Binding(get: { sheet.key }, set: { feed.keySheet?.key = $0 }))
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await feed.connect() } }
                .accessibilityIdentifier(AccessibilityID.keySheetField)
            if let failure = sheet.failure {
                Text(failure)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(AccessibilityID.keySheetFailure)
            }
            HStack {
                if sheet.step == .checking {
                    ProgressView().controlSize(.small)
                    Text(Words.checking)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                }
                Spacer()
                Button(Words.cancel) { feed.closeKeySheet() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(AccessibilityID.keySheetCancel)
                Button(Words.connect) { Task { await feed.connect() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!sheet.mayConnect)
                    .accessibilityIdentifier(AccessibilityID.keySheetConnect)
            }
        }
    }

    private func choose(_ listings: [PriceLabsListing]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Words.chooseTitle)
                .font(.system(size: 13, weight: .semibold))
            Text(Words.chooseLine)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
            ForEach(listings) { listing in
                Toggle(listing.name, isOn: Binding(
                    get: { chosen.contains(listing.id) },
                    set: { on in
                        if on { chosen.insert(listing.id) } else { chosen.remove(listing.id) }
                    }))
                .accessibilityIdentifier(AccessibilityID.keySheetListing(listing.name))
            }
            HStack {
                Spacer()
                Button(Words.cancel) { feed.closeKeySheet() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(AccessibilityID.keySheetCancel)
                Button(Words.addHouses) {
                    let picked = listings.filter { chosen.contains($0.id) }
                    Task { await feed.addHouses(picked) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
                .accessibilityIdentifier(AccessibilityID.keySheetAddHouses)
            }
        }
        // Every listing starts chosen: most hosts' listings are all houses.
        .onAppear { chosen = Set(listings.map(\.id)) }
    }
}
#endif
