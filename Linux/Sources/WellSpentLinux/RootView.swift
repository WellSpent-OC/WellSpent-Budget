import Foundation
import Observation
import SwiftCrossUI
import WellSpentAppCore
import WellSpentCrypto
import WellSpentModel

/// The window, drawn from MainScreen: groups and budgets on the left, the
/// chosen budget, a group's page or an invite link's page on the right, and
/// the sheets over them. The rules and words are the Mac's, from the shared
/// code. This is layout only.
struct RootView: View {
    var workspace: Workspace
    @State var screen: MainScreen
    @State var showingAccount = false
    /// The sheet a menu or a button asked for.
    @State var sheet: MainScreen.Action?
    @State var showingEntry = false
    /// An entry opened from the budget's list, to change, move or delete.
    @State var openedEntry: EntryEditor?
    /// The people on the group's page, while one shows.
    @State var openPage = OpenGroupPage()
    @State var warTable: WarTableScreen
    @State var runway: RunwayScreen
    @State var activeExtension: ActiveExtension = .budgets
    @State var isWarTableInstalled = false
    @State var isRunwayInstalled = false

    private var isWarTableActive: Bool {
        workspace.features.isWarTableEnabled &&
            (isWarTableInstalled || (warTable.snapshot?.installation.isEnabled ?? false))
    }

    private var isRunwayActive: Bool {
        workspace.features.isRunwayEnabled && isRunwayInstalled
    }

    init(workspace: Workspace) {
        self.workspace = workspace
        _screen = State(wrappedValue: MainScreen(workspace: workspace))
        _warTable = State(wrappedValue: WarTableScreen(workspace: workspace))
        _runway = State(wrappedValue: RunwayScreen(isConfigured: true))
    }

    private var model: AppModel { workspace.model }
    private var sync: SyncCoordinator { workspace.sync }

    var body: some View {
        // Read here, so a change to any of them redraws the window: a binding's
        // getter runs outside the redraw's tracking. The alert's buttons keep
        // these copies too, because GTK closes the alert, which clears the
        // question, before the button's action runs.
        let pendingDelete = screen.pendingDelete
        let importing = model.pendingImport != nil
        let problem = model.errorMessage
        let invitation = screen.invitation
        let openGroup = screen.openGroup
        let people = openPage.screen(for: openGroup, sync: sync)
        VStack(spacing: 0) {
            if workspace.environment == .staging {
                StagingBanner()
            }
            HStack(alignment: .center) {
                Text("WELLSPENT")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Palette.goldLight)
                Spacer()
                Text("\(screen.openGroup?.name ?? "Demo Team") · Linux desktop")
                    .font(.system(size: 11))
                    .foregroundColor(Palette.sidebarHeader)
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(Palette.titlebarBackground)

            if workspace.features.areExtensionsEnabled {
                HStack(spacing: 0) {
                    ActivityRailView(
                        active: $activeExtension,
                        isRunwayInstalled: isRunwayActive,
                        isWarTableInstalled: isWarTableActive,
                        showsSync: screen.showsSync,
                        syncTitle: screen.syncTitle,
                        syncHelp: screen.syncHelp,
                        isSyncing: screen.syncShowsProgress,
                        isBusy: screen.isBusy,
                        syncNow: { Task { await screen.syncNow() } },
                        openAccount: { showingAccount = true }
                    )
                    Palette.railBorder.frame(width: 1)
                    switch activeExtension {
                    case .budgets:
                        budgetSplitView(invitation: invitation, openGroup: openGroup, people: people)
                    case .runway:
                        if workspace.features.isRunwayEnabled {
                            RunwayView(screen: runway, openAccount: { showingAccount = true })
                        } else {
                            budgetSplitView(invitation: invitation, openGroup: openGroup, people: people)
                        }
                    case .warTable:
                        if workspace.features.isWarTableEnabled {
                            WarTableView(screen: warTable, openAccount: { showingAccount = true })
                        } else {
                            budgetSplitView(invitation: invitation, openGroup: openGroup, people: people)
                        }
                    case .catalog:
                        ExtensionsCatalogView(
                            isWarTableEnabled: isWarTableActive,
                            isWarTableAvailable: workspace.features.isWarTableEnabled,
                            isRunwayEnabled: isRunwayActive,
                            isRunwayAvailable: workspace.features.isRunwayEnabled,
                            installWarTable: {
                                isWarTableInstalled = true
                                activeExtension = .warTable
                                Task { await warTable.enable() }
                            },
                            openWarTable: {
                                activeExtension = .warTable
                            },
                            installRunway: {
                                isRunwayInstalled = true
                                activeExtension = .runway
                            },
                            openRunway: {
                                activeExtension = .runway
                            }
                        )
                    }
                }
            } else {
                budgetSplitView(invitation: invitation, openGroup: openGroup, people: people)
            }
        }
        .sheet(isPresented: $showingAccount) {
            AccountView(sync: sync, isPresented: $showingAccount)
                .tabMovesFocus()
        }
        .sheet(isPresented: Binding(get: { sheet != nil }, set: { if !$0 { sheet = nil } })) {
            if let sheet {
                sheetView(sheet)
                    .tabMovesFocus()
            }
        }
        .sheet(isPresented: $showingEntry) {
            EntryEditorView(model: model, close: { showingEntry = false })
                .tabMovesFocus()
        }
        .sheet(isPresented: Binding(get: { openedEntry != nil }, set: { if !$0 { openedEntry = nil } })) {
            if let openedEntry {
                EntryEditorView(editor: openedEntry, close: { self.openedEntry = nil })
                    .tabMovesFocus()
            }
        }
        .sheet(isPresented: Binding(get: { importing },
                                    set: { if !$0 { model.cancelImport() } })) {
            ImportReviewView(model: model)
                .tabMovesFocus()
        }
        // Signed out without asking, by the server: the sign-in opens with the
        // reason.
        .onAppear { if sync.signInPrompt != nil { showingAccount = true } }
        .onChange(of: sync.signInPrompt) {
            if sync.signInPrompt != nil { showingAccount = true }
        }
        .alert(question(pendingDelete), isPresented: Binding(get: { pendingDelete != nil },
                                                                   set: { if !$0 { screen.keepIt() } })) {
            // Cancel first: GTK focuses the first button, so Return keeps it.
            Button(MainScreen.Words.cancel) { screen.keepIt() }
            Button(pendingDelete?.confirmLabel ?? "Delete") {
                if let pendingDelete { screen.confirm(pendingDelete) }
            }
        }
        .alert(Binding(get: { problem.map { "Something went wrong: \($0)" } },
                       set: { if $0 == nil { model.dismissError() } })) {
            Button("OK") { model.dismissError() }
        }
    }

    private func budgetSplitView(invitation: JoinScreen?, openGroup: BudgetGroup?, people: MembersScreen?) -> some View {
        NavigationSplitView {
            SidebarView(screen: screen, perform: perform, showingAccount: $showingAccount)
        } detail: {
            if let invitation {
                InvitationPageView(screen: invitation, main: screen, openAccount: { showingAccount = true })
            } else if let openGroup, let people {
                GroupPageView(screen: people, group: openGroup, main: screen, sync: sync,
                              invite: { sheet = .share(openGroup) })
            } else {
                detail
            }
        }
    }

    /// GTK's alert has a title and no message, so the two go together. The
    /// message comes from MainScreen, which words a leave at View differently.
    private func question(_ pending: PendingDelete?) -> String {
        guard let pending else { return "" }
        return "\(pending.title)\n\n\(screen.message(for: pending))"
    }

    @ViewBuilder
    private var detail: some View {
        switch screen.detail {
        case .budget(let summary):
            BudgetDetailView(screen: BudgetScreen(summary: summary, model: model, me: sync.userID),
                             model: model, menu: screen.budgetMenu(summary.budget), perform: perform,
                             addEntry: { showingEntry = true }, openEntry: open(entry:))
        case .noBudgets:
            ContentUnavailableView {
                Text(MainScreen.Words.noBudgetsTitle)
            } description: {
                Text(MainScreen.Words.noBudgetsText)
            } actions: {
                Button(screen.addButton.title) { perform(screen.addButton.action) }
            }
        case .noneSelected:
            ContentUnavailableView {
                Text(MainScreen.Words.noneSelectedTitle)
            } description: {
                Text(MainScreen.Words.noneSelectedText)
            }
        }
    }

    /// A click on a row opens it. The editor is made here, once, because
    /// opening it is what marks its note seen.
    private func open(entry id: RecordID) {
        openedEntry = EntryEditor(model: model, entry: id)
    }

    /// A delete or a leave asks first. People… opens the group's page, and
    /// anything else opens its sheet.
    private func perform(_ action: MainScreen.Action) {
        activeExtension = .budgets
        if action.asksFirst {
            screen.ask(action)
        } else if case .people(let group) = action {
            screen.openPage(of: group.id)
        } else {
            sheet = action
        }
    }

    private func closeSheet() { sheet = nil }

    @ViewBuilder
    private func sheetView(_ action: MainScreen.Action) -> some View {
        switch action {
        case .newBudget(let group):
            BudgetEditorView(editor: BudgetEditor(model: model, group: group, groups: screen.groupsForNewBudget),
                             close: closeSheet)
        case .editBudget(let budget):
            BudgetEditorView(editor: BudgetEditor(model: model, editing: budget), close: closeSheet)
        case .newGroup:
            GroupEditorView(editor: GroupEditor(model: model), close: closeSheet)
        case .renameGroup(let group):
            GroupEditorView(editor: GroupEditor(model: model, renaming: group), close: closeSheet)
        case .share(let group):
            ShareView(screen: EmailInviteScreen(actions: sync, group: group.id, groupName: group.name), close: closeSheet)
        case .join:
            JoinView(screen: JoinScreen(actions: sync), close: closeSheet, openAccount: {
                // One sheet at a time: the join closes, then the account opens.
                sheet = nil
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    showingAccount = true
                }
            })
        case .people, .deleteBudget, .deleteGroup:
            EmptyView()
        }
    }
}

/// Across the top of every staging window, so a test build is never mistaken
/// for the real app. A live build has none.
struct StagingBanner: View {
    var body: some View {
        HStack {
            Spacer()
            Text("STAGING")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
            Spacer()
        }
        .padding(.vertical, 4)
        .background(Color.orange)
    }
}

// MARK: - Sidebar

/// One line of the sidebar. A flat list, because each group's name is a row
/// of its own above its budgets: clicking it opens the group's page.
enum SidebarRow: Identifiable {
    case group(MainScreen.Section)
    case budget(BudgetSummary)
    case note(String)

    var id: String {
        switch self {
        case .group(let section): "group:\(section.id.uuid)"
        case .budget(let summary): "budget:\(summary.budget.id.uuid)"
        case .note(let text): "note:\(text)"
        }
    }
}

/// The groups and their budgets, drawn by hand rather than as a GTK list,
/// whose highlight would cover each budget's fill. Each budget's row and each
/// group's name is a plain button, as on the Mac, so Tab reaches it, and Space
/// or Return opens it as a click does. The open budget's row is outlined, and
/// a group's name is marked while its page shows.
struct SidebarView: View {
    var screen: MainScreen
    var perform: (MainScreen.Action) -> Void
    @Binding var showingAccount: Bool

    var rows: [SidebarRow] {
        var rows: [SidebarRow] = []
        for section in screen.sections {
            rows.append(.group(section))
            if let note = section.note { rows.append(.note(note)) }
            rows += section.budgets.map(SidebarRow.budget)
        }
        if let note = screen.waitingNote { rows.append(.note(note)) }
        return rows
    }

    var body: some View {
        // Read here, so opening a budget or a page elsewhere redraws the
        // outline and the group's mark.
        _ = screen.selectedBudget
        _ = screen.openGroup
        _ = screen.sections
        return VStack(spacing: 0) {
            // The rows at the top and the footer at the bottom, as on the Mac.
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(screen.incomingInvitations) { invitation in
                        IncomingInvitationRow(invitation: invitation, main: screen)
                    }
                    ForEach(rows) { row in
                        rowView(row)
                    }
                }
                .padding(8)
            }
            Palette.sidebarDivider.frame(height: 1)
            addMenu
            Palette.sidebarDivider.frame(height: 1)
            footer
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 180, maxWidth: 220, maxHeight: .infinity)
        .background(Palette.sidebarDark)
    }

    @ViewBuilder
    private func rowView(_ row: SidebarRow) -> some View {
        switch row {
        case .group(let section):
            groupRow(section)
        case .budget(let summary):
            // A button, not a tap, so the keyboard reaches the row. The plain
            // style adds no padding or background, so the row looks the same.
            // No row is outlined while a group's page or an invitation shows,
            // since no budget is picked then.
            Button(action: { screen.selectedBudget = summary.budget.id }) {
                BudgetRow(summary: summary, isPicked: screen.selectedBudget == summary.budget.id)
            }
            // How much is used, and whether it's the open one, as the Mac's
            // row tells VoiceOver. Before the style, which wraps the button.
            .accessibility(value: RowFill(summary).spokenValue,
                           selected: screen.selectedBudget == summary.budget.id)
            .buttonStyle(.plain)
        case .note(let text):
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(Palette.muted)
        }
    }

    /// A group's name, marked while its page is open, then its menu.
    @ViewBuilder
    private func groupRow(_ section: MainScreen.Section) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if section.id != screen.sections.first?.id {
                Palette.sidebarDivider
                    .frame(height: 1)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 6)
            }
            HStack {
                Button(action: { screen.toggle(section.id) }) {
                    HStack {
                        Text(section.title.uppercased())
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundColor(Palette.sidebarHeader)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4)
                                .fill(section.isPageOpen ? Palette.railButtonActive : Color.clear))
                        Spacer()
                    }
                    .frame(maxWidth: Self.widestLine)
                }
                .accessibility(label: section.toggleHelp)
                .help(section.toggleHelp)
                .buttonStyle(.plain)
                // GTK has no right-click menu here, so each group has a button
                // that opens the menu the Mac shows on a right-click.
                Menu("⋯") {
                    menuItems(screen.groupMenu(section.group))
                }
            }
        }
    }

    /// How wide the button with a group's name may grow. SwiftCrossUI 0.10.0's
    /// Button turns its label's width into a whole number. A stack first asks
    /// each part how wide it would grow with no limit, and the Spacer's answer
    /// has no end, which crashes the app. This limit is far wider than any
    /// sidebar, so the line is laid out as before.
    private static let widestLine: Double = 10_000

    /// A menu's parts, with a divider between each.
    @ViewBuilder
    private func menuItems(_ parts: [[MainScreen.MenuItem]]) -> some View {
        ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
            if index > 0 {
                Divider()
            }
            ForEach(part) { item in
                Button(item.title) { perform(item.action) }
            }
        }
    }

    /// Like Add List in Reminders: the common action is the button, the
    /// rarer ones are in its menu.
    private var addMenu: some View {
        HStack {
            Button(screen.addButton.title) { perform(screen.addButton.action) }
            Menu("More") {
                ForEach(screen.addMenu) { item in
                    Button(item.title) { perform(item.action) }
                }
            }
            Spacer()
        }
        .padding(8)
    }

    /// Whether budgets go through the server or stay on this computer.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(screen.footer)
                .font(.system(size: 11))
                .foregroundColor(Palette.muted)
            if let failure = screen.syncFailure {
                Text(failure)
                    .font(.system(size: 11))
                    .foregroundColor(Palette.warning)
            }
        }
        .padding(10)
    }
}

// MARK: - Budget

/// Draws BudgetScreen: the chosen budget's name and actions, its wheel, and
/// its entries.
struct BudgetDetailView: View {
    let screen: BudgetScreen
    var model: AppModel
    let menu: [[MainScreen.MenuItem]]
    var perform: (MainScreen.Action) -> Void
    var addEntry: () -> Void
    /// A click on a row: opens the entry to change, move or delete it.
    var openEntry: (RecordID) -> Void
    @Environment(\.chooseFile) var chooseFile

    private typealias Words = BudgetScreen.Words

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                HStack(spacing: 4) {
                    Text(screen.title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(Palette.ink)
                    Text("Budget")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(Palette.ink)
                }
                Spacer()
                Text("Current month")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Palette.ink)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5).stroke(Palette.line, style: StrokeStyle(width: 1)))
                if screen.mayAdd {
                    Button(Words.importStatement) {
                        Task {
                            if let url = await chooseFile(title: Words.importStatement) {
                                model.prepareImport(from: url)
                            }
                        }
                    }
                    Button(Words.add) { addEntry() }.newEntryShortcut()
                }
                ForEach(menu.flatMap { $0 }) { item in
                    Button(item.title) { perform(item.action) }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            Palette.line.frame(height: 1)
            if let undo = screen.undo {
                HStack(spacing: 10) {
                    Text(undo.message).font(.system(size: 12))
                    Spacer()
                    Button(undo.button) { model.undoDelete() }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Palette.sidebar)
                Palette.line.frame(height: 1)
            }
            BudgetWheelPanel(screen: screen, editBudget: { perform(.editBudget(screen.summary.budget)) })
                .padding(20)
            Palette.line.frame(height: 1)
            EntryColumns(showsAddedBy: screen.showsAddedBy)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
            Palette.line.frame(height: 1)
            if screen.rows.isEmpty {
                Text(Words.empty)
                    .foregroundColor(Palette.muted)
                    .padding(20)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(screen.rows.enumerated()), id: \.element.id) { index, row in
                            Button(action: { openEntry(row.id) }) {
                                EntryRow(row: row, showsAddedBy: screen.showsAddedBy)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: Self.widestRow)
                                    .background(RoundedRectangle(cornerRadius: 5)
                                        .fill(index.isMultiple(of: 2) ? Color.clear : Palette.ground))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundColor(Palette.ink)
        .background(Palette.surface)
    }

    /// How wide a row's button may grow. As in the sidebar, SwiftCrossUI
    /// 0.10.0's Button needs a finite width for a label holding a Spacer, and
    /// this is far wider than any window.
    private static let widestRow: Double = 10_000
}

struct EntryRow: View {
    let row: BudgetScreen.Row
    let showsAddedBy: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(BudgetScreen.shortDate(row.date))
                .font(.money(12, weight: .regular))
                .foregroundColor(Palette.muted)
                .frame(width: 70, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.merchant).font(.system(size: 13))
                if !row.note.isEmpty {
                    Text(row.note)
                        .font(.system(size: 11))
                        .foregroundColor(Palette.muted)
                }
                // This computer's last change to it didn't go through, until
                // it is opened.
                if let notice = row.notice {
                    Text(notice)
                        .font(.system(size: 11))
                        .foregroundColor(Palette.warning)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showsAddedBy {
                Text(row.addedBy)
                    .font(.system(size: 11))
                    .foregroundColor(Palette.muted)
                    .frame(width: 90, alignment: .leading)
            }
            Text(row.source)
                .font(.system(size: 11))
                .foregroundColor(Palette.muted)
                .frame(width: 70, alignment: .leading)
            Text(row.amount)
                .font(.money(12))
                .frame(width: 90, alignment: .trailing)
        }
    }
}

/// Keep headings and rows on the same fixed columns; the description takes
/// the remaining width. The author appears only on a shared budget.
private struct EntryColumns: View {
    let showsAddedBy: Bool
    private typealias Words = BudgetScreen.Words

    var body: some View {
        HStack(spacing: 12) {
            Text(Words.date).frame(width: 70, alignment: .leading)
            Text(Words.description).frame(maxWidth: .infinity, alignment: .leading)
            if showsAddedBy {
                Text(Words.addedBy).frame(width: 90, alignment: .leading)
            }
            Text(Words.source).frame(width: 70, alignment: .leading)
            Text(Words.amount).frame(width: 90, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(Palette.muted)
    }
}
