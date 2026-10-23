// The iPhone's screens, built the iPhone's way. Layout only.
#if os(iOS)
import SwiftUI
import WellSpentCrypto
import WellSpentModel

/// Home: the groups and their budgets, and the bar at the foot with
/// Account, the sync line and +. Pull
/// down to sync. Draws `MainScreen`. Layout only.
struct PhoneHomeView: View {
    let screen: MainScreen
    let perform: (MainScreen.Action) -> Void
    @Binding var showingAccount: Bool

    var body: some View {
        List {
            if screen.detail == .noBudgets {
                empty
            }
            ForEach(screen.sections) { section in
                // The group's name is a row of its own above its budgets, not
                // the section's header: a list's header takes no long press,
                // so the group's menu could never open there.
                Section {
                    header(section)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 6, leading: 4, bottom: 0, trailing: 4))
                }
                Section {
                    if let note = section.note {
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(Palette.muted)
                    }
                    // A list sets up a row's long-press menu once, when the
                    // row first comes in. So a budget whose menu goes from
                    // none to some, as when the owner moves this person up to
                    // Manage, comes in as a new row. Otherwise a long press
                    // still opens it.
                    ForEach(section.budgets, id: \.budget.id) { summary in
                        let menu = screen.budgetMenu(summary.budget)
                        NavigationLink(value: PhoneRoute.budget(summary.budget.id)) {
                            PhoneBudgetRow(summary: summary)
                        }
                        .accessibilityIdentifier(AccessibilityID.sidebarBudget(summary.budget.name))
                        .contextMenu { PhoneMenu(parts: menu, perform: perform) }
                        .id(RowKey(budget: summary.budget.id, hasMenu: !menu.isEmpty))
                        // Filled as far as it is used: PhoneRowFill.swift.
                        .phoneRowFill(summary)
                    }
                    if !section.isCollapsed, let newBudget = newBudget(in: section.group) {
                        Button {
                            perform(newBudget)
                        } label: {
                            Label(BudgetEditor.Words.newTitle, systemImage: "plus")
                                .font(.subheadline)
                        }
                    }
                }
                .listRowBackground(Palette.surface)
            }
            if let note = screen.waitingNote {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .scrollContentBackground(.hidden)
        .background(Palette.ground)
        .foregroundStyle(Palette.ink)
        .refreshable { await screen.syncNow() }
        .safeAreaInset(edge: .bottom) { foot }
        .navigationTitle(AppEnvironment.current.appName)
    }

    /// A tap on a group's name opens its page, and the arrow beside it hides
    /// or shows its budgets. A long press holds the group's menu, with hiding
    /// in it too. The name is not a Button, which takes a long press as a tap.
    private func header(_ section: MainScreen.Section) -> some View {
        HStack(spacing: 4) {
            // In capitals, as on the Mac and in the design.
            Text(section.title.uppercased())
                .contentShape(Rectangle())
                .onTapGesture { screen.openPage(of: section.group.id) }
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier(AccessibilityID.sidebarGroup(section.group.name))
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { screen.toggle(section.group.id) }
            } label: {
                Image(systemName: section.isCollapsed ? "chevron.down" : "chevron.up")
                    .font(.caption2.weight(.semibold))
                    .frame(width: 32, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(section.toggleHelp)
            .accessibilityIdentifier(AccessibilityID.sidebarGroupToggle(section.group.name))
            Spacer()
        }
        .foregroundStyle(Palette.muted)
        .contentShape(Rectangle())
        .contextMenu {
            PhoneMenu(parts: screen.groupMenu(section.group), perform: perform)
            Divider()
            Button(section.toggleHelp) { screen.toggle(section.group.id) }
        }
    }

    /// A budget row's identity in the list: its budget, and whether it has a
    /// long-press menu.
    private struct RowKey: Hashable {
        let budget: BudgetID
        let hasMenu: Bool
    }

    /// The group's New Budget, when its menu offers one.
    private func newBudget(in group: BudgetGroup) -> MainScreen.Action? {
        screen.groupMenu(group).joined().first { item in
            if case .newBudget = item.action { return true }
            return false
        }?.action
    }

    private var empty: some View {
        ContentUnavailableView {
            Label(MainScreen.Words.noBudgetsTitle, systemImage: "tray")
        } description: {
            Text(MainScreen.Words.noBudgetsText)
        } actions: {
            Button {
                perform(screen.addButton.action)
            } label: {
                Text(screen.addButton.title)
                    .foregroundStyle(Palette.ground)
            }
            .buttonStyle(.borderedProminent)
        }
        .listRowBackground(Color.clear)
    }

    /// Account on the left, the sync line in the middle, and + on the right in
    /// thumb reach.
    private var foot: some View {
        HStack(spacing: 12) {
            Button(screen.accountTitle) { showingAccount = true }
                .buttonStyle(.bordered)
                .disabled(screen.isBusy)
                .accessibilityIdentifier(screen.showsSync ? AccessibilityID.toolbarAccount
                                                          : AccessibilityID.sidebarSignIn)
            Text(syncLine)
                .font(.caption)
                .foregroundStyle(screen.syncFailure == nil ? Palette.muted : Palette.warning)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            Menu {
                ForEach(addItems) { item in
                    Button(PhoneWording.button(item.title)) { perform(item.action) }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.title3.weight(.semibold))
                    // White would not read on the dark mode green.
                    .foregroundStyle(Palette.ground)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Palette.accent))
            }
            // In the order written, Add Budget first, as the design lists them.
            // Left to itself, iOS turns a menu opened from the bottom upside down.
            .menuOrder(.fixed)
            .accessibilityLabel(screen.addButton.title)
            .accessibilityIdentifier(AccessibilityID.sidebarAdd)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// Add Budget first, then the rarer ones.
    private var addItems: [MainScreen.MenuItem] {
        [screen.addButton] + screen.addMenu
    }

    /// Why the last sync failed, or that one is running, or where the budgets
    /// are kept.
    private var syncLine: String {
        screen.syncFailure ?? (screen.syncShowsProgress ? screen.syncTitle : screen.footer)
    }
}

/// One budget on Home: its colour, its name and what is left, or how far over
/// it is, in words that read on the row's fill in light and dark.
struct PhoneBudgetRow: View {
    let summary: BudgetSummary

    var body: some View {
        let fill = RowFill(summary)
        HStack(spacing: 10) {
            Circle()
                .fill(summary.isOverspent ? Palette.warning : Palette.budgetColor(summary.budget.colorIndex))
                .frame(width: 8, height: 8)
            Text(summary.budget.name)
                .lineLimit(1)
                .foregroundStyle(Color(PaletteValues.rowWords))
            Spacer(minLength: 8)
            Text(fill.amount)
                .font(.body.monospacedDigit())
                .fontWeight(fill.isOver ? .semibold : .regular)
                .foregroundStyle(Color(PaletteValues.rowAmount))
        }
    }
}

#endif
