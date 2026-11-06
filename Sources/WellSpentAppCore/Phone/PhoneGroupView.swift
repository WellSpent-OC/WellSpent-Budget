// The iPhone's screens, built the iPhone's way. Layout only.
#if os(iOS)
import SwiftUI
import WellSpentCrypto
import WellSpentExtensionKit
import WellSpentModel
import WellSpentSync

/// A group's page: its money for the month and its people as a list,
/// each with their level. A tap on someone this person may change opens
/// their page. Leave Group… is a row at the end, Invite Someone… is at the
/// foot in thumb reach, and the group's menu is under ⋯. A tap on the
/// group's name on Home opens it. An extension may add a section below the
/// money, and a line at the top that scrolls to it, since the section is
/// below the first screen. Draws `MembersScreen`. Layout only.
struct PhoneGroupView: View {
    @Bindable var sync: SyncCoordinator
    let group: BudgetGroup
    /// The window's rules: the group's menu and the question a leave asks.
    let main: MainScreen
    let perform: (MainScreen.Action) -> Void
    @State private var screen: MembersScreen
    private typealias Words = MembersScreen.Words

    init(sync: SyncCoordinator, group: BudgetGroup, main: MainScreen,
         perform: @escaping (MainScreen.Action) -> Void) {
        self.sync = sync
        self.group = group
        self.main = main
        self.perform = perform
        _screen = State(initialValue: MembersScreen(actions: sync, group: group.id, groupName: group.name))
    }

    var body: some View {
        let menu = self.menu
        ScrollViewReader { proxy in page(scrollingWith: proxy) }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Palette.ground)
        .foregroundStyle(Palette.ink)
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.large)
        // Nothing scrolled shows behind the bar's title. Left automatic, not
        // forced visible: forced, the bar covers the large title at rest.
        .toolbarBackground(Palette.ground, for: .navigationBar)
        .toolbar {
            if !menu.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        PhoneMenu(parts: menu, perform: perform)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityIdentifier(AccessibilityID.groupMenu)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if screen.mayInvite {
                Button {
                    perform(.share(group))
                } label: {
                    Text(PhoneWording.button(Words.invite))
                        .font(.headline)
                        // White would not read on the dark mode green.
                        .foregroundStyle(Palette.ground)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .accessibilityIdentifier(AccessibilityID.groupInvite)
            }
        }
        // Whoever joined since the last sync shows as the page opens, and
        // after each sync while it stays open.
        .task { await screen.refresh() }
        .onChange(of: sync.lastSyncedAt) { screen.reload() }
        // Pulling down syncs, as on Home, so the group's menu knows this
        // person's level as the server says it now, then reads who is in it.
        .refreshable {
            await main.syncNow()
            await screen.refresh()
        }
    }

    /// The page's rows. The proxy is what the extension's top line scrolls with.
    private func page(scrollingWith proxy: ScrollViewProxy) -> some View {
        List {
            Section {
                Text(screen.summary)
                    .font(.subheadline)
                    .foregroundStyle(Palette.muted)
                    .accessibilityIdentifier(AccessibilityID.groupSummary)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 4, trailing: 4))
                // After a removal, a quiet line under it. No pop-up.
                if let removed = screen.removedNote {
                    Text(removed)
                        .font(.subheadline)
                        .accessibilityIdentifier(AccessibilityID.groupRemoved)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 4, trailing: 4))
                }
            }
            if let line = slots?.groupPageTopLine(for: slotGroup) {
                Section {
                    PhoneExtensionTopLine(line: line) {
                        withAnimation { proxy.scrollTo(HostScrollID.groupPageSection, anchor: .top) }
                    }
                }
                .listRowBackground(Palette.surface)
            }
            if let money = main.money(of: group.id) {
                PhoneGroupMoneySections(money: money)
            }
            // What an extension adds, below the money and above the people.
            // Nothing with no extension on.
            if let section = slots?.groupPageSection(for: slotGroup) {
                section
            }
            if !screen.rows.isEmpty {
                Section(Words.people) {
                    ForEach(screen.rows) { row in
                        if mayChange(row) {
                            NavigationLink {
                                PhonePersonView(screen: screen, id: row.id)
                            } label: {
                                PhonePersonRow(row: row)
                            }
                            .accessibilityIdentifier(AccessibilityID.groupPerson(row.name))
                        } else {
                            PhonePersonRow(row: row)
                                .accessibilityIdentifier(AccessibilityID.groupPerson(row.name))
                        }
                    }
                }
                .listRowBackground(Palette.surface)
            }
            if !screen.pendingInvites.isEmpty {
                Section(EmailInvitationWords.incomingTitle) {
                    ForEach(screen.pendingInvites, id: \.id) { invitation in
                        OutgoingInvitationRow(screen: screen, invitation: invitation)
                    }
                }
                .listRowBackground(Palette.surface)
            }
            if let failure = screen.failure {
                Section {
                    PhoneNote(failure)
                }
                .listRowBackground(Color.clear)
            }
            if screen.mayLeave {
                Section {
                    Button(PhoneWording.button(Words.leave), role: .destructive) { main.askToLeave(group) }
                        .frame(maxWidth: .infinity)
                        // The page's ink would otherwise replace the role's colour.
                        .foregroundStyle(Palette.warning)
                        .disabled(screen.isWorking)
                        .accessibilityIdentifier(AccessibilityID.groupLeave)
                }
                .listRowBackground(Palette.surface)
            }
        }
    }

    private var slots: (any ExtensionSlots)? { main.extensionSlots }
    private var slotGroup: String { group.id.uuid.uuidString }

    /// The group's menu, without People…, which is this page.
    private var menu: [[MainScreen.MenuItem]] {
        main.groupMenu(group).map { part in
            part.filter { item in
                if case .people = item.action { return false }
                return true
            }
        }
    }

    /// Whether this person may change anything about them: their level, or
    /// whether they stay.
    private func mayChange(_ row: MembersScreen.Row) -> Bool {
        !row.levelChoices.isEmpty || row.mayRemove
    }
}

/// An extension's line at the top of a group's page: its words, then its
/// amount. A tap scrolls to the extension's section.
private struct PhoneExtensionTopLine: View {
    let line: HostTopLine
    let scroll: () -> Void

    var body: some View {
        Button(action: scroll) {
            HStack(spacing: 8) {
                Text(line.text)
                    .font(.footnote)
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 8)
                Text(line.amount)
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(line.isWarning ? Palette.warning : Palette.ink)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.groupTopLine)
    }
}

/// One person: their name, what their level lets them do, and the level.
struct PhonePersonRow: View {
    let row: MembersScreen.Row

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.label)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Palette.ink)
                Text(MembersScreen.Words.levelExplanation(row.level))
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            PhoneLevelBadge(title: row.levelTitle, isOwner: row.level == .superadmin)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A person's level, in a small capsule.
struct PhoneLevelBadge: View {
    let title: String
    let isOwner: Bool

    var body: some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Palette.ground, in: Capsule())
            .overlay(Capsule().stroke(Palette.line, lineWidth: 1))
    }
}

/// One person's page: the levels this person may move them to, each with
/// what it lets them do and a tick on theirs, and Remove… at the end, apart.
/// Remove asks from the bottom of the screen first. The page closes once they
/// are out of the group. Layout only.
struct PhonePersonView: View {
    let screen: MembersScreen
    let id: UserID
    @Environment(\.dismiss) private var dismiss
    private typealias Words = MembersScreen.Words

    var body: some View {
        List {
            if let row = screen.rows.first(where: { $0.id == id }) {
                Section(Words.level) {
                    ForEach(levels(of: row), id: \.self) { level in
                        Button {
                            Task { await screen.setLevel(level, for: id) }
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(Words.levelTitle(level))
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(Palette.ink)
                                    Text(Words.levelExplanation(level))
                                        .font(.footnote)
                                        .foregroundStyle(Palette.muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 8)
                                if level == row.level {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Palette.accent)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        .disabled(screen.isWorking || row.levelChoices.isEmpty)
                        .accessibilityAddTraits(level == row.level ? .isSelected : [])
                    }
                }
                .listRowBackground(Palette.surface)
                if let failure = screen.failure {
                    Section {
                        PhoneNote(failure)
                    }
                    .listRowBackground(Color.clear)
                }
                if row.mayRemove {
                    Section {
                        Button(PhoneWording.button(Words.remove), role: .destructive) { screen.askToRemove(id) }
                            .frame(maxWidth: .infinity)
                            // The page's ink would otherwise replace the role's colour.
                            .foregroundStyle(Palette.warning)
                            .disabled(screen.isWorking)
                            .accessibilityIdentifier(AccessibilityID.groupRemove(row.name))
                    }
                    .listRowBackground(Palette.surface)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Palette.ground)
        .foregroundStyle(Palette.ink)
        .navigationTitle(screen.rows.first(where: { $0.id == id })?.name ?? "")
        .navigationBarTitleDisplayMode(.large)
        .confirmationDialog(screen.removeQuestion ?? "",
                            isPresented: Binding(get: { screen.removing != nil },
                                                 set: { if !$0 { screen.keepThem() } }),
                            titleVisibility: .visible,
                            presenting: screen.removing) { row in
            Button(Words.removeButton, role: .destructive) { screen.remove(row.id) }
            Button(Words.cancel, role: .cancel) { screen.keepThem() }
        } message: { _ in
            Text(screen.removeMessage ?? "")
        }
        // Once they are out of the group, removed here or gone by themselves,
        // back to the group's page. It says they were removed, or why a
        // change to them failed. A removal that fails keeps this page, saying why.
        .onChange(of: screen.rows.contains { $0.id == id }) { _, isThere in
            if !isThere { dismiss() }
        }
    }

    /// The levels they may be moved to, or only theirs when it cannot change.
    private func levels(of row: MembersScreen.Row) -> [AccessLevel] {
        row.levelChoices.isEmpty ? [row.level] : row.levelChoices
    }
}

/// What stands in the way, or why something failed, in the warning colour.
struct PhoneNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundStyle(Palette.warning)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#endif
