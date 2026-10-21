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

    init(workspace: Workspace) {
        self.workspace = workspace
        _screen = State(wrappedValue: MainScreen(workspace: workspace))
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
            ShareView(screen: ShareScreen(actions: sync, group: group.id, groupName: group.name), close: closeSheet)
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
        return VStack(spacing: 0) {
            // The rows at the top and the footer at the bottom, as on the Mac.
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(rows) { row in
                        rowView(row)
                    }
                }
                .padding(8)
            }
            Divider()
            addMenu
            Divider()
            footer
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 260, maxHeight: .infinity)
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
                .foregroundColor(.gray)
        }
    }

    /// A group's name, marked while its page is open, then its menu and the
    /// arrow. The name and the line up to the menu are one plain button that
    /// opens the page, by a click or by the keyboard. The menu and the arrow
    /// sit beside that button, not inside it, so each keeps its own click.
    private func groupRow(_ section: MainScreen.Section) -> some View {
        HStack {
            Button(action: { screen.openPage(of: section.id) }) {
                HStack {
                    Text(section.title.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4)
                            .fill(section.isPageOpen ? Color(PaletteValues.accent).opacity(0.15) : Color.clear))
                    Spacer()
                }
                .frame(maxWidth: Self.widestLine)
            }
            // Before the style, which wraps the button in a widget of its own.
            .accessibility(selected: section.isPageOpen)
            .buttonStyle(.plain)
            // GTK has no right-click menu here, so each group has a button
            // that opens the menu the Mac shows on a right-click.
            Menu("⋯") {
                menuItems(screen.groupMenu(section.group))
            }
            // The arrow at the end of the line hides or shows the budgets,
            // as on the Mac, which names it by its tooltip too.
            Button(section.isCollapsed ? "▾" : "▴") { screen.toggle(section.id) }
                .accessibility(label: section.toggleHelp)
                .help(section.toggleHelp)
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

    /// Whether budgets go through the server or stay on this computer, and
    /// the way in or the sync button.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(screen.footer)
                .font(.system(size: 11))
                .foregroundColor(.gray)
            HStack {
                Button(screen.accountTitle) { showingAccount = true }
                    .disabled(screen.isBusy)
                if screen.showsSync {
                    Button(screen.syncTitle) { Task { await screen.syncNow() } }
                        .disabled(screen.isBusy)
                }
            }
            if let failure = screen.syncFailure {
                Text(failure)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
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
        VStack(alignment: .leading, spacing: 12) {
            // After a delete: what went, and Undo, the only way to undo it.
            if let undo = screen.undo {
                HStack(spacing: 10) {
                    Text(undo.message)
                        .font(.system(size: 12))
                    Spacer()
                    Button(undo.button) { model.undoDelete() }
                }
                Divider()
            }
            HStack {
                Text(screen.title)
                    .font(.title2)
                Spacer()
                // Adding takes Add, as the server decides; at View, neither shows.
                if screen.mayAdd {
                    Button(Words.importStatement) {
                        Task {
                            if let url = await chooseFile(title: Words.importStatement) {
                                model.prepareImport(from: url)
                            }
                        }
                    }
                    Button(Words.add) { addEntry() }
                }
                // Edit and Delete, for someone who may change budgets here.
                ForEach(menu.flatMap { $0 }) { item in
                    Button(item.title) { perform(item.action) }
                }
            }
            // The day of the period, the wheel and its figures, in place of
            // the bar.
            BudgetWheelPanel(screen: screen, editBudget: { perform(.editBudget(screen.summary.budget)) })
            Divider()
            if screen.rows.isEmpty {
                Text(Words.empty)
                    .foregroundColor(.gray)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(screen.rows) { row in
                            // A button, not a tap, so the keyboard and a
                            // screen reader reach the row, as in the sidebar.
                            // The plain style adds no padding or background.
                            Button(action: { openEntry(row.id) }) {
                                EntryRow(row: row, showsAddedBy: screen.showsAddedBy)
                                    .frame(maxWidth: Self.widestRow)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                .foregroundColor(.gray)
                .frame(width: 70)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.merchant)
                if !row.note.isEmpty {
                    Text(row.note)
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                }
                // This computer's last change to it didn't go through, until
                // it is opened.
                if let notice = row.notice {
                    Text(notice)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                }
            }
            Spacer()
            if showsAddedBy {
                Text(row.addedBy)
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
                    .frame(width: 90)
            }
            Text(row.source)
                .font(.system(size: 11))
                .foregroundColor(.gray)
                .frame(width: 70)
            Text(row.amount)
                .frame(width: 90)
        }
    }
}
