// The iPhone's screens, built the iPhone's way. Layout only: every word and
// rule comes from Screens, shared with the Mac and Linux. The Mac's screens
// are in Views.swift.
#if os(iOS)
import SwiftUI
import WellSpentCrypto
import WellSpentModel

/// The iPhone's one stack of screens: Home, then a budget. It holds the
/// sheets, the delete questions and the error alert, as the Mac's window does.
struct PhoneRootView: View {
    @State var workspace: Workspace
    /// The main window's rules and words, shared with every app.
    @State private var screen: MainScreen
    @State private var editor: EditorSheet?
    /// A question to ask once the sheet that asked for it has closed, such as
    /// Delete in the Edit Budget sheet.
    @State private var afterSheet: MainScreen.Action?
    @State private var showingAccount = false
    @State private var addingEntry = false
    /// The screen a staging build was asked to open on, applied once.
    private let start: StartingScreen?
    @State private var startApplied = false
    private var model: AppModel { workspace.model }
    private var sync: SyncCoordinator { workspace.sync }

    init(workspace: Workspace, startingOn start: StartingScreen? = nil) {
        _workspace = State(initialValue: workspace)
        _screen = State(initialValue: MainScreen(workspace: workspace))
        self.start = start
    }

    var body: some View {
        NavigationStack(path: openBudget) {
            PhoneHomeView(screen: screen, perform: perform, showingAccount: $showingAccount)
                .navigationDestination(for: BudgetID.self) { _ in budget }
        }
        .tint(Palette.accent)
        .stagingBanner(workspace.environment)
        // The view preferences go where this build keeps its settings, so a
        // staging build never writes into live's.
        .defaultAppStorage(sync.defaults)
        .sheet(item: $editor, onDismiss: askAfterSheet) { sheet in editorView(sheet) }
        // Import statement: the Files picker and the review. PhoneImportStatement.swift
        .phoneStatementImport(model: model)
        // A different account means different budgets: a fresh stack, not the
        // last account's open budget.
        .id(ObjectIdentifier(model))
        .sheet(isPresented: $addingEntry) { PhoneEntrySheet(model: model) }
        // Outside the part rebuilt when an account signs in, so the sheet
        // keeps its step through signing in.
        .sheet(isPresented: $showingAccount) { PhoneAccountSheet(sync: sync) }
        .confirmationDialog(screen.pendingDelete?.title ?? "",
                            isPresented: Binding(get: { screen.pendingDelete != nil },
                                                 set: { if !$0 { screen.keepIt() } }),
                            titleVisibility: .visible,
                            presenting: screen.pendingDelete) { pending in
            Button(pending.confirmLabel, role: .destructive) { screen.confirm(pending) }
            Button(MainScreen.Words.cancel, role: .cancel) { screen.keepIt() }
        } message: { pending in
            Text(screen.message(for: pending))
        }
        .alert(MainScreen.Words.errorTitle,
               isPresented: Binding(get: { model.errorMessage != nil },
                                    set: { if !$0 { model.dismissError() } })) {
            Button(MainScreen.Words.ok) { model.dismissError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onAppear(perform: applyStart)
        // Signed out without asking, by the server: the sign-in opens with the
        // reason.
        .onAppear { if sync.signInPrompt != nil { showingAccount = true } }
        .onChange(of: sync.signInPrompt) { _, prompt in
            if prompt != nil { showingAccount = true }
        }
    }

    /// The open budget is the stack's one pushed screen. Back closes it, and
    /// a budget deleted here or on another device takes the stack back to
    /// Home.
    private var openBudget: Binding<[BudgetID]> {
        Binding(get: { model.selectedBudget.map { [$0] } ?? [] },
                set: { model.selectedBudget = $0.last })
    }

    @ViewBuilder
    private var budget: some View {
        if case .budget(let summary) = screen.detail {
            PhoneBudgetView(model: model, sync: sync, summary: summary, main: screen, perform: perform,
                            addingEntry: $addingEntry)
        }
    }

    /// A delete asks first. Anything else opens its sheet.
    private func perform(_ action: MainScreen.Action) {
        if action.asksFirst {
            screen.ask(action)
            return
        }
        switch action {
        case .newBudget(let group): editor = .newBudget(in: group)
        case .editBudget(let budget): editor = .editBudget(budget)
        case .newGroup: editor = .newGroup
        case .renameGroup(let group): editor = .renameGroup(group)
        case .share, .people, .join, .deleteBudget, .deleteGroup: break
        }
    }

    @ViewBuilder
    private func editorView(_ sheet: EditorSheet) -> some View {
        switch sheet {
        case .newBudget(let group):
            PhoneBudgetSheet(model: model, group: group, groups: screen.groupsForNewBudget)
        case .editBudget(let budget):
            PhoneBudgetSheet(model: model, editing: budget, delete: { afterSheet = .deleteBudget(budget) })
        case .newGroup:
            PhoneGroupSheet(model: model)
        case .renameGroup(let group):
            PhoneGroupSheet(model: model, renaming: group)
        case .share, .join, .entry:
            EmptyView()
        }
    }

    /// One sheet or question at a time: the sheet closes, then it asks.
    private func askAfterSheet() {
        guard let action = afterSheet else { return }
        afterSheet = nil
        perform(action)
    }

    /// A staging build asked to open on one screen opens on it, once, when
    /// the window first appears. Never in `init`, which SwiftUI may run many
    /// times.
    private func applyStart() {
        guard !startApplied else { return }
        startApplied = true
        guard let start else { return }
        if start.opensABudget { screen.openFirstBudget() }
        if start == .add { addingEntry = true }
        if start == .account { showingAccount = true }
    }
}

extension MainScreen.Action {
    /// Whether the iPhone has a screen for it yet. Sharing, joining and a
    /// group's people come with the iPhone's second milestone.
    var isOnThePhone: Bool {
        switch self {
        case .share, .people, .join: return false
        default: return true
        }
    }
}

/// A menu's parts, with a divider between each, holding only what the
/// iPhone has a screen for.
struct PhoneMenu: View {
    let parts: [[MainScreen.MenuItem]]
    let perform: (MainScreen.Action) -> Void

    var body: some View {
        let shown = parts.map { $0.filter(\.action.isOnThePhone) }.filter { !$0.isEmpty }
        ForEach(Array(shown.enumerated()), id: \.offset) { index, part in
            if index > 0 { Divider() }
            ForEach(part) { item in
                Button(item.title, role: item.isDestructive ? .destructive : nil) { perform(item.action) }
            }
        }
    }
}

/// The iPhone's screens. `start` is for a staging build asked to open on one
/// screen. See `StartingScreen`.
@MainActor
public func wellSpentPhoneRootView(workspace: Workspace, startingOn start: StartingScreen? = nil) -> AnyView {
    AnyView(PhoneRootView(workspace: workspace, startingOn: start))
}

#endif
