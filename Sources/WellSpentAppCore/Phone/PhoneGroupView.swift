// The iPhone's screens, built the iPhone's way. Layout only.
#if os(iOS)
import SwiftUI
import WellSpentCrypto
import WellSpentModel
import WellSpentSync

/// A group's page: its name, the line under it, and its people as a list,
/// each with their level. A tap on someone this person may change opens
/// their page. Leave Group… is a row at the end, Invite Someone… is at the
/// foot in thumb reach, and the group's menu is under ⋯. A tap on the
/// group's name on Home opens it. Draws `MembersScreen`. Layout only.
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
            if let failure = screen.failure {
                Section {
                    PhoneNote(failure)
                }
                .listRowBackground(Color.clear)
            }
            if screen.mayLeave {
                Section {
                    Button(Words.leave, role: .destructive) { main.askToLeave(group) }
                        .frame(maxWidth: .infinity)
                        .disabled(screen.isWorking)
                        .accessibilityIdentifier(AccessibilityID.groupLeave)
                }
                .listRowBackground(Palette.surface)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Palette.ground)
        .foregroundStyle(Palette.ink)
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.large)
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
                    Text(Words.invite)
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
        .refreshable { await screen.refresh() }
    }

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

/// One person: their name, what their level lets them do, and the level.
struct PhonePersonRow: View {
    let row: MembersScreen.Row

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.label)
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

/// A person's level, in a small capsule. The owner's is filled.
struct PhoneLevelBadge: View {
    let title: String
    let isOwner: Bool

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(isOwner ? Palette.ground : Palette.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(isOwner ? Palette.ink : Color.clear))
            .overlay(Capsule().stroke(Palette.ink, lineWidth: 1))
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
                        Button(Words.remove, role: .destructive) { screen.askToRemove(id) }
                            .frame(maxWidth: .infinity)
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
