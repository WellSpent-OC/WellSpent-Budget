// The iPhone's screens, built the iPhone's way. Layout only: every word and
// rule comes from Screens, shared with the Mac and Linux. The Mac's screens
// are in Views.swift.
#if os(iOS)
import SwiftUI
import WellSpentCrypto
import WellSpentModel

/// The iPhone's one stack of screens: Home, then a budget, a group's page or
/// the invitation page a clicked invite link opens. It holds the sheets, the
/// delete questions and the error alert, as the Mac's window does.
struct PhoneRootView: View {
    @State var workspace: Workspace
    /// The main window's rules and words, shared with every app.
    @State private var screen: MainScreen
    @State private var editor: EditorSheet?
    /// A question to ask once the sheet that asked for it has closed, such as
    /// Delete in the Edit Budget sheet.
    @State private var afterSheet: MainScreen.Action?
    /// The account sheet, to open once the sheet that asked for it has
    /// closed, such as Sign in… in Join a Group.
    @State private var accountAfterSheet = false
    @State private var showingAccount = false
    @State private var addingEntry = false
    @State private var activeExtension: ActiveExtension = .budgets
    @State private var isWarTableInstalled = false
    @State private var isPropertiesInstalled = false
    @State private var showingExtensionsCatalog = false
    /// The screen a staging build was asked to open on, applied once.
    private let start: StartingScreen?
    @State private var startApplied = false
    private var model: AppModel { workspace.model }
    private var sync: SyncCoordinator { workspace.sync }

    private var isWarTableActive: Bool {
        workspace.features.isWarTableEnabled && isWarTableInstalled
    }

    /// On when the flag allows it and this person turned it on, on this device.
    private var isPropertiesActive: Bool {
        workspace.features.isPropertiesEnabled &&
            (isPropertiesInstalled || workspace.extensionSwitches.isOn(PropertiesRegistration.id))
    }

    private var hasActiveExtensions: Bool {
        isWarTableActive || isPropertiesActive
    }

    /// Turns Properties on or off for this person on this device, and moves
    /// the tabs to Houses or back to Budgets.
    private func setProperties(on: Bool) {
        isPropertiesInstalled = on
        workspace.extensionSwitches.set(PropertiesRegistration.id, on: on)
        activeExtension = on ? .properties : .budgets
        if on { showingExtensionsCatalog = false }
    }

    init(workspace: Workspace, startingOn start: StartingScreen? = nil) {
        _workspace = State(initialValue: workspace)
        _screen = State(initialValue: MainScreen(workspace: workspace))
        self.start = start
    }

    var body: some View {
        mainContent
        .tint(Palette.accent)
        .stagingBanner(workspace.environment, syncedAt: sync.lastSyncedAt)
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
        .sheet(isPresented: $showingExtensionsCatalog) { extensionsCatalogSheet }
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

    @ViewBuilder
    private var mainContent: some View {
        if hasActiveExtensions {
            TabView(selection: $activeExtension) {
                budgetStack
                    .tabItem {
                        Label("Budgets", systemImage: "chart.pie.fill")
                    }
                    .tag(ActiveExtension.budgets)

                if isPropertiesActive {
                    NavigationStack {
                        #if canImport(WellSpentProperties)
                        PhoneHousesTab(model: model)
                        #else
                        HousesPlaceholderView(
                            openCatalog: { showingExtensionsCatalog = true },
                            turnOff: { setProperties(on: false) }
                        )
                        #endif
                    }
                    .tabItem {
                        Label("Houses", systemImage: "house.fill")
                    }
                    .tag(ActiveExtension.properties)
                }

                if isWarTableActive {
                    NavigationStack {
                        WarTablePlaceholderView(
                            openCatalog: { showingExtensionsCatalog = true },
                            turnOff: {
                                isWarTableInstalled = false
                                activeExtension = .budgets
                            }
                        )
                    }
                    .tabItem {
                        Label("WarTable", systemImage: "bubble.left.and.bubble.right.fill")
                    }
                    .tag(ActiveExtension.warTable)
                }
            }
        } else {
            budgetStack
        }
    }

    private var budgetStack: some View {
        NavigationStack(path: path) {
            PhoneHomeView(screen: screen, perform: perform, showingAccount: $showingAccount,
                          showingExtensionsCatalog: $showingExtensionsCatalog)
                .navigationDestination(for: PhoneRoute.self) { route in destination(route) }
        }
    }

    private var extensionsCatalogSheet: some View {
        ExtensionsCatalogView(
            isWarTableInstalled: isWarTableActive,
            isWarTableAvailable: workspace.features.isWarTableEnabled,
            toggleWarTable: {
                isWarTableInstalled.toggle()
                if isWarTableInstalled {
                    activeExtension = .warTable
                    showingExtensionsCatalog = false
                } else {
                    activeExtension = .budgets
                }
            },
            openWarTable: {
                showingExtensionsCatalog = false
                activeExtension = .warTable
            },
            isPropertiesInstalled: isPropertiesActive,
            isPropertiesAvailable: workspace.features.isPropertiesEnabled,
            toggleProperties: { setProperties(on: !isPropertiesActive) },
            openProperties: {
                showingExtensionsCatalog = false
                activeExtension = .properties
            },
            done: {
                showingExtensionsCatalog = false
            }
        )
    }

    /// The stack's one pushed screen: an invitation, a group's page or a
    /// budget, in that order, as `MainScreen` says which shows. Back closes
    /// it. A budget or group gone, here or on another device, takes the
    /// stack back to Home.
    private var path: Binding<[PhoneRoute]> {
        Binding(get: {
            if screen.invitation != nil { return [.invitation] }
            if let group = screen.openGroup { return [.group(group.id)] }
            return model.selectedBudget.map { [.budget($0)] } ?? []
        }, set: { path in
            switch path.last {
            case .budget(let id): screen.selectedBudget = id
            case .group(let id): screen.openPage(of: id)
            case .invitation: break
            case nil:
                workspace.closeInvitation()
                screen.closePage()
                model.selectedBudget = nil
            }
        })
    }

    @ViewBuilder
    private func destination(_ route: PhoneRoute) -> some View {
        switch route {
        case .budget:
            if case .budget(let summary) = screen.detail {
                PhoneBudgetView(model: model, sync: sync, summary: summary, main: screen, perform: perform,
                                addingEntry: $addingEntry)
            }
        case .group:
            if let group = screen.openGroup {
                PhoneGroupView(sync: sync, group: group, main: screen, perform: perform)
                    // A page of its own for each group, and again after a
                    // rename, so its words name the group as it is now.
                    .id([group.id.uuid.uuidString, group.name])
            }
        case .invitation:
            if let invitation = screen.invitation {
                PhoneInvitationView(screen: invitation, main: screen, showingAccount: $showingAccount)
                    // A page of its own for each link opened.
                    .id(ObjectIdentifier(invitation))
            }
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
        case .share(let group): editor = .share(group)
        case .people(let group): screen.openPage(of: group.id)
        case .join: editor = .join
        case .deleteBudget, .deleteGroup: break
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
        case .share(let group):
            PhoneShareSheet(sync: sync, group: group)
        case .join:
            PhoneJoinSheet(sync: sync, openAccount: {
                // One sheet at a time: Join a Group closes, then the account opens.
                accountAfterSheet = true
                editor = nil
            })
        case .entry:
            EmptyView()
        }
    }

    /// One sheet or question at a time: the sheet closes, then it asks.
    private func askAfterSheet() {
        if accountAfterSheet {
            accountAfterSheet = false
            showingAccount = true
        }
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

/// What the stack has pushed over Home.
enum PhoneRoute: Hashable {
    case budget(BudgetID)
    case group(GroupID)
    case invitation
}

/// A menu's parts, with a divider between each.
struct PhoneMenu: View {
    let parts: [[MainScreen.MenuItem]]
    let perform: (MainScreen.Action) -> Void

    var body: some View {
        let shown = parts.filter { !$0.isEmpty }
        ForEach(Array(shown.enumerated()), id: \.offset) { index, part in
            if index > 0 { Divider() }
            ForEach(part) { item in
                Button(PhoneWording.button(item.title), role: item.isDestructive ? .destructive : nil) { perform(item.action) }
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
