// The Mac screens. SwiftUI exists only on Apple systems; the Linux app draws
// the same shared logic with its own screens.
#if canImport(SwiftUI)
import SwiftUI
#if canImport(Combine)
import Combine
#endif
#if os(iOS)
import UIKit
#endif
import WellSpentCrypto
import WellSpentImport
import WellSpentModel
import WellSpentStore
#if canImport(WellSpentPropertiesViews)
import WellSpentPropertiesViews
#endif

// MARK: - Look

// The colours (`Palette`, `PaletteValues`) and `Font.money` come from the
// Extension Kit, so an extension draws with the very same ones.

extension View {
    /// A button that reads as a link: the Mac's link style. iOS has no link
    /// style, so a phone shows a plain borderless button instead.
    @ViewBuilder
    func linkButtonStyle() -> some View {
        #if os(macOS)
        buttonStyle(.link)
        #else
        buttonStyle(.borderless)
        #endif
    }
}

// MARK: - Root

struct RootView: View {
    @State var workspace: Workspace
    /// The main window's rules and words, shared with every desktop.
    @State private var screen: MainScreen
    private var model: AppModel { workspace.model }
    private var sync: SyncCoordinator { workspace.sync }
    @State private var showingAddTransaction = false
    @State private var showingFileImporter = false
    @State private var showingAccount = false
    @State private var editor: EditorSheet?
    @State private var activeExtension: ActiveExtension = .budgets
    @State private var isWarTableInstalled = false
    @State private var isPropertiesInstalled = false

    private var isWarTableActive: Bool {
        workspace.features.isWarTableEnabled && isWarTableInstalled
    }

    /// On when the flag allows it and this person turned it on, on this device.
    private var isPropertiesActive: Bool {
        workspace.features.isPropertiesEnabled &&
            (isPropertiesInstalled || workspace.extensionSwitches.isOn(PropertiesRegistration.id))
    }

    init(workspace: Workspace) {
        _workspace = State(initialValue: workspace)
        _screen = State(initialValue: MainScreen(workspace: workspace))
    }

    /// Turns Properties on or off for this person on this device, and moves
    /// the rail to Houses or back to Budgets.
    private func setProperties(on: Bool) {
        isPropertiesInstalled = on
        workspace.extensionSwitches.set(PropertiesRegistration.id, on: on)
        workspace.installExtensionSlots()
        activeExtension = on ? .properties : .budgets
    }

    var body: some View {
        HStack(spacing: 0) {
            if workspace.features.areExtensionsEnabled {
                ActivityRailView(
                    active: $activeExtension,
                    isWarTableInstalled: isWarTableActive,
                    isPropertiesInstalled: isPropertiesActive,
                    openAccount: { showingAccount = true }
                )
                Divider()
                switch activeExtension {
                case .budgets:
                    budgetSplitView
                case .properties:
                    if isPropertiesActive {
                        #if canImport(WellSpentPropertiesViews) && os(macOS)
                        HousesTab(host: AppExtensionHost(model: workspace.model))
                        #else
                        HousesPlaceholderView(
                            openCatalog: { activeExtension = .catalog },
                            turnOff: { setProperties(on: false) }
                        )
                        #endif
                    } else {
                        budgetSplitView
                    }
                case .catalog:
                    ExtensionsCatalogView(
                        isWarTableInstalled: isWarTableActive,
                        isWarTableAvailable: workspace.features.isWarTableEnabled,
                        toggleWarTable: {
                            isWarTableInstalled.toggle()
                            if isWarTableInstalled {
                                activeExtension = .warTable
                            }
                        },
                        openWarTable: {
                            activeExtension = .warTable
                        },
                        isPropertiesInstalled: isPropertiesActive,
                        isPropertiesAvailable: workspace.features.isPropertiesEnabled,
                        toggleProperties: { setProperties(on: !isPropertiesActive) },
                        openProperties: { activeExtension = .properties }
                    )
                case .warTable:
                    if workspace.features.isWarTableEnabled {
                        WarTablePlaceholderView(
                            openCatalog: { activeExtension = .catalog },
                            turnOff: {
                                isWarTableInstalled = false
                                activeExtension = .budgets
                            }
                        )
                    } else {
                        budgetSplitView
                    }
                }
            } else {
                budgetSplitView
            }
        }
        .stagingBanner(workspace.environment)
        // The view preferences go where this build keeps its settings, so a
        // staging build never writes into live's.
        .defaultAppStorage(sync.defaults)
        .sheet(item: $editor) { sheet in editorView(sheet) }
        // A different account means different budgets: a fresh detail view, not
        // the last account's selection.
        .id(ObjectIdentifier(model))
        .sheet(isPresented: $showingAddTransaction) {
            EntrySheet(model: model)
        }
        .sheet(item: Binding(get: { model.entrySheetRequest }, set: { model.entrySheetRequest = $0 })) { request in
            EntrySheet(model: model, request: request)
        }
        .sheet(isPresented: $showingAccount) {
            AccountSheet(sync: sync)
        }
        // Signed out without asking, by the server or by the update to
        // readable sync: the sign-in opens with the reason.
        .onAppear { if sync.signInPrompt != nil { showingAccount = true } }
        .onChange(of: sync.signInPrompt) { _, prompt in
            if prompt != nil { showingAccount = true }
        }
        .sheet(item: Binding(get: { model.pendingImport },
                             set: { model.pendingImport = $0 })) { _ in
            ImportReviewSheet(model: model)
        }
        .fileImporter(isPresented: $showingFileImporter,
                      allowedContentTypes: ImportReviewScreen.fileTypes,
                      allowsMultipleSelection: false) { ImportReviewScreen(model: model).open($0) }
        .alert(MainScreen.Words.errorTitle,
               isPresented: Binding(get: { model.errorMessage != nil },
                                    set: { if !$0 { model.dismissError() } })) {
            Button(MainScreen.Words.ok) { model.dismissError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
        #if canImport(Combine) && canImport(AppKit)
        .onReceive(NotificationCenter.default.publisher(for: .wellSpentNewBudget)) { _ in
            editor = .newBudget(in: screen.openGroup?.id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .wellSpentNewGroup)) { _ in
            editor = .newGroup
        }
        .onReceive(NotificationCenter.default.publisher(for: .wellSpentJoinGroup)) { _ in
            editor = .join
        }
        .onReceive(NotificationCenter.default.publisher(for: .wellSpentAddTransaction)) { _ in
            showingAddTransaction = true
        }
        #endif
    }

    private var budgetSplitView: some View {
        NavigationSplitView {
            SidebarView(screen: screen, editor: $editor, showingAccount: $showingAccount)
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 320)
        } detail: {
            if let invitation = screen.invitation {
                InvitationPage(sync: sync, screen: invitation, main: screen, showingAccount: $showingAccount)
                    // A page of its own for each link opened.
                    .id(ObjectIdentifier(invitation))
            } else if let group = screen.openGroup {
                GroupPage(sync: sync, group: group, main: screen, showingAccount: $showingAccount,
                          invite: { editor = .share(group) },
                          addBudget: { editor = .newBudget(in: group.id) })
                    // A page of its own for each group, and again after a
                    // rename, so its words name the group as it is now.
                    .id([group.id.uuid.uuidString, group.name])
            } else {
                switch screen.detail {
                case .budget(let summary):
                    BudgetDetailView(model: model, sync: sync, summary: summary,
                                     showingAddTransaction: $showingAddTransaction,
                                     showingFileImporter: $showingFileImporter,
                                     showingAccount: $showingAccount,
                                     editor: $editor, main: screen)
                case .noBudgets:
                    noBudgets.toolbar { accountButtons }
                        // With nothing open, not the last budget's name.
                        .navigationTitle(AppEnvironment.current.appName)
                case .noneSelected:
                    ContentUnavailableView(MainScreen.Words.noneSelectedTitle,
                                           systemImage: "tray",
                                           description: Text(MainScreen.Words.noneSelectedText))
                        .toolbar { accountButtons }
                        // With nothing open, not the last budget's name.
                        .navigationTitle(AppEnvironment.current.appName)
                }
            }
        }
    }

    /// Every page has these, so someone with no budgets can still reach their
    /// account and sign out.
    private var accountButtons: some ToolbarContent {
        ToolbarItemGroup {
            if screen.showsSync {
                SyncButton(sync: sync, showingAccount: $showingAccount)
            }
            AccountButton(sync: sync, showingAccount: $showingAccount)
        }
    }

    private var noBudgets: some View {
        ContentUnavailableView {
            Label(MainScreen.Words.noBudgetsTitle, systemImage: "tray")
        } description: {
            Text(MainScreen.Words.noBudgetsText)
        } actions: {
            Button(screen.addButton.title) { editor = .newBudget(in: nil) }
        }
    }

    @ViewBuilder
    private func editorView(_ sheet: EditorSheet) -> some View {
        switch sheet {
        case .newBudget(let group):
            BudgetSheet(model: model, group: group, groups: screen.groupsForNewBudget)
        case .editBudget(let budget): BudgetSheet(model: model, editing: budget)
        case .newGroup: GroupSheet(model: model)
        case .renameGroup(let group): GroupSheet(model: model, renaming: group)
        case .share(let group): ShareSheet(sync: sync, group: group)
        case .join:
            JoinSheet(sync: sync, openAccount: {
                // One sheet at a time: the join sheet closes, then the account opens.
                editor = nil
                DispatchQueue.main.async { showingAccount = true }
            })
        case .entry(let opened):
            EntrySheet(editor: opened)
        }
    }
}

/// Across the top of every staging window, so a test build is never mistaken for
/// the real app. A live build has none.
struct StagingBanner: View {
    static let text = "STAGING"
    /// When the last sync ended, for the iPhone's UI tests: with a sheet open
    /// nothing else on screen says a sync has happened. Read as the banner's
    /// value, in seconds since 1970.
    var syncedAt: Date?

    var body: some View {
        let banner = Text(Self.text)
            .font(.system(size: 11, weight: .bold))
            .tracking(1.5)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(Color.orange)
            .help("A test build, with its own budgets. It never connects to the live server.")
            .accessibilityIdentifier(AccessibilityID.stagingBanner)
        if let syncedAt {
            banner.accessibilityValue(String(syncedAt.timeIntervalSince1970))
        } else {
            banner
        }
    }
}

extension View {
    /// The staging banner above this view, or this view unchanged in a live
    /// build. `syncedAt` is when the last sync ended (StagingBanner).
    @ViewBuilder
    func stagingBanner(_ environment: AppEnvironment, syncedAt: Date? = nil) -> some View {
        switch environment {
        case .live:
            self
        case .staging:
            VStack(spacing: 0) {
                StagingBanner(syncedAt: syncedAt)
                self
            }
        }
    }
}

// MARK: - Sidebar

/// Draws MainScreen's left side: the groups, their budgets, the menus, the
/// question a delete or a leave asks, and the footer. A click on a group's
/// name opens its page, and the arrow beside it hides or shows its budgets.
/// Layout only.
///
/// Each budget's row draws its own fill, so the list has no selection of
/// its own: its highlight would cover the fill. A click on a row opens the
/// budget, and the open budget's row is outlined instead.
struct SidebarView: View {
    let screen: MainScreen
    @Binding var editor: EditorSheet?
    /// The one account sheet, opened by the toolbar or by the foot's Sign in.
    /// It is presented outside the part of the window that is rebuilt when an
    /// account signs in, so the sheet keeps its step through signing in.
    @Binding var showingAccount: Bool
    /// How tall the invitations would like to be, up to where they scroll.
    @State private var invitationsHeight: CGFloat = 0

    init(screen: MainScreen, editor: Binding<EditorSheet?>, showingAccount: Binding<Bool>) {
        self.screen = screen
        _editor = editor
        _showingAccount = showingAccount
    }

    /// For tests: a sidebar of its own over a model and a coordinator.
    init(model: AppModel, sync: SyncCoordinator, editor: Binding<EditorSheet?>, showingAccount: Binding<Bool>) {
        self.init(screen: MainScreen(workspace: Workspace(model: model, sync: sync)), editor: editor,
                  showingAccount: showingAccount)
    }

    var body: some View {
        List {
            ForEach(screen.sections) { section in
                Section {
                    if let note = section.note {
                        Text(note)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.muted)
                    }
                    ForEach(section.budgets, id: \.budget.id) { summary in
                        budgetRow(summary)
                    }
                } header: {
                    header(section)
                }
                // The list's own hide and show control would be a second arrow.
                #if os(macOS)
                .collapsible(false)
                #endif
            }
            if let note = screen.waitingNote {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            if !screen.incomingInvitations.isEmpty {
                // Scrolling, so they can't make the window taller, off the
                // bottom of a small screen.
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(EmailInvitationWords.incomingTitle.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.7)
                            .foregroundStyle(Color.secondary)
                            .padding(.horizontal, 4)
                            .padding(.top, 4)
                        ForEach(screen.incomingInvitations, id: \.id) { invitation in
                            IncomingInvitationRow(screen: screen, invitation: invitation)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { invitationsHeight = $0 }
                }
                // Two whole invitations, and the top of a third to say there's more.
                .frame(height: min(invitationsHeight, 320))
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                addMenu
                Divider()
                footer
            }
            .background(.ultraThinMaterial)
        }
        .confirmationDialog(screen.pendingDelete?.title ?? "",
                            isPresented: Binding(get: { screen.pendingDelete != nil },
                                                 set: { if !$0 { screen.keepIt() } }),
                            presenting: screen.pendingDelete) { pending in
            Button(pending.confirmLabel, role: .destructive) { screen.confirm(pending) }
            if screen.offersStop(pending) {
                Button(PendingDelete.deleteAndStop, role: .destructive) { screen.confirmAndStop(pending) }
            }
            Button(MainScreen.Words.cancel, role: .cancel) { screen.keepIt() }
        } message: { pending in
            Text(screen.message(for: pending))
        }
    }

    /// One arrow in front of the group's name, as a folder in Finder. It hides or
    /// shows the budgets and no page opens or closes. A click on the name opens
    /// the page and nothing else (PAGE-05). The sidebar's list makes the line one
    /// element for VoiceOver and the UI tests, joining the identifiers of
    /// everything in it, so only the name has one.
    private func header(_ section: MainScreen.Section) -> some View {
        HStack(spacing: 2) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { screen.toggle(section.group.id) }
            } label: {
                Image(systemName: section.isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(section.toggleHelp)
            .accessibilityLabel(section.toggleHelp)
            Button {
                screen.openPage(of: section.group.id)
            } label: {
                HStack(spacing: 0) {
                    Text(section.title.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.7)
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(section.isPageOpen ? Palette.accent.opacity(0.15) : .clear,
                                    in: RoundedRectangle(cornerRadius: 4))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.sidebarGroup(section.group.name))
            .accessibilityAddTraits(section.isPageOpen ? .isSelected : [])
        }
        .contextMenu { menu(screen.groupMenu(section.group)) }
    }

    /// A budget's row: a click opens the budget, and a right-click shows its
    /// menu. Only the open budget's row is outlined (`MainScreen.isPicked`).
    private func budgetRow(_ summary: BudgetSummary) -> some View {
        let isPicked = screen.isPicked(summary.budget.id)
        return Button {
            screen.selectedBudget = summary.budget.id
        } label: {
            BudgetRow(summary: summary, isPicked: isPicked)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.sidebarBudget(summary.budget.name))
        .accessibilityValue(RowFill(summary).spokenValue)
        .accessibilityAddTraits(isPicked ? .isSelected : [])
        .contextMenu { menu(screen.budgetMenu(summary.budget)) }
    }

    /// A menu's parts, with a divider between each.
    @ViewBuilder
    private func menu(_ parts: [[MainScreen.MenuItem]]) -> some View {
        ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
            if index > 0 { Divider() }
            ForEach(part) { item in
                Button(item.title, role: item.isDestructive ? .destructive : nil) { perform(item.action) }
            }
        }
    }

    /// Like Add List in Reminders: the common action is the button, the rarer
    /// ones are in its menu. Offers Add Budget and New Group side by side.
    private var addMenu: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(screen.addMenu) { item in
                    Button(item.title) { perform(item.action) }
                }
            } label: {
                Label(screen.addButton.title, systemImage: "plus.circle")
                    .font(.system(size: 12))
            } primaryAction: {
                perform(screen.addButton.action)
            }
            .menuStyle(.borderlessButton)
            .accessibilityIdentifier(AccessibilityID.sidebarAdd)
            .fixedSize()

            Spacer()

            Menu {
                Button(MainScreen.Words.newGroup) { perform(.newGroup) }
                Button(MainScreen.Words.join) { perform(.join) }
            } label: {
                Label(MainScreen.Words.newGroup.replacingOccurrences(of: "…", with: ""), systemImage: "folder.badge.plus")
                    .font(.system(size: 12))
            } primaryAction: {
                perform(.newGroup)
            }
            .menuStyle(.borderlessButton)
            .accessibilityIdentifier(AccessibilityID.sidebarAddGroup)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// A delete or a leave asks first. People… opens the group's page, and
    /// anything else opens its sheet.
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

    private var footer: some View {
            HStack(spacing: 7) {
                Image(systemName: screen.showsSync ? "arrow.triangle.2.circlepath" : "internaldrive")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.accent)
                Text(screen.footer)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                Spacer()
                // Signed out, a way in that is always on screen, whatever the
                // window shows and whether or not a prompt was dismissed.
                if !screen.showsSync {
                    Button(screen.accountTitle) { showingAccount = true }
                        .accessibilityIdentifier(AccessibilityID.sidebarSignIn)
                        .linkButtonStyle()
                        .font(.system(size: 11))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
    }
}

/// A budget's row in the sidebar, drawn as its own bar: filled from the left
/// as far as the budget is used this period, with its name and what is left,
/// or how far over, on top. The open budget's row is outlined. What it says
/// is RowFill's. Layout only.
struct BudgetRow: View {
    let summary: BudgetSummary
    /// Whether this is the open budget.
    var isPicked = false

    var body: some View {
        let fill = RowFill(summary)
        HStack(spacing: 8) {
            Circle()
                .fill(summary.isOverspent ? Palette.warning : Palette.budgetColor(summary.budget.colorIndex))
                .frame(width: 7, height: 7)
            Text(summary.budget.name)
                .font(.system(size: 13))
                .foregroundStyle(Color(PaletteValues.rowWords))
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(fill.amount)
                .font(.money(11, weight: fill.isOver ? .semibold : .medium))
                .foregroundStyle(Color(PaletteValues.rowAmount))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RowFillBackground(fill: fill, cornerRadius: 4))
        .overlay {
            if isPicked { PickedRowOutline() }
        }
    }
}

// MARK: - Budget detail

struct BudgetDetailView: View {
    @State private var showingRepeats = false
    @Bindable var model: AppModel
    @Bindable var sync: SyncCoordinator
    let summary: BudgetSummary
    @Binding var showingAddTransaction: Bool
    @Binding var showingFileImporter: Bool
    @Binding var showingAccount: Bool
    /// The window's sheets: an entry opened from the list is one of them.
    @Binding var editor: EditorSheet?
    /// The window's rules and its delete question, which Delete… in a
    /// row's menu asks.
    let main: MainScreen
    /// The row the arrow keys move and Return opens.
    @State private var selection: RecordID?

    var body: some View {
        VStack(spacing: 0) {
            if let undo = screen.undo {
                UndoBar(offer: undo, undo: { model.undoDelete() })
                Divider()
            }
            BudgetWheelPanel(screen: screen, editBudget: { editor = .editBudget(summary.budget) },
                             openRepeats: { showingRepeats = true })
            Divider()
            transactionTable
        }
        .background(Palette.surface)
        .toolbar {
            ToolbarItemGroup {
                // Adding takes Add, as the server decides; at View, neither shows.
                if screen.mayAdd {
                    Button {
                        showingFileImporter = true
                    } label: {
                        Label(BudgetScreen.Words.importStatement, systemImage: "square.and.arrow.down")
                    }
                    .accessibilityIdentifier(AccessibilityID.budgetImport)
                    Button {
                        showingAddTransaction = true
                    } label: {
                        Label(BudgetScreen.Words.add, systemImage: "plus")
                    }
                    .keyboardShortcut("n", modifiers: .command)
                    .accessibilityIdentifier(AccessibilityID.budgetAdd)
                }
                if sync.account != nil {
                    SyncButton(sync: sync, showingAccount: $showingAccount)
                }
                AccountButton(sync: sync, showingAccount: $showingAccount)
            }
        }
        .navigationTitle(summary.budget.name)
        #if os(macOS)
        .sheet(isPresented: $showingRepeats) { RepeatsListSheet(budget: summary.budget, model: model) }
        #endif
    }

    /// The budget's words and rows, shared with every desktop.
    private var screen: BudgetScreen { BudgetScreen(summary: summary, model: model, me: sync.userID) }

    private var transactionTable: some View {
        let screen = self.screen
        let rows = screen.rows
        return Table(rows, selection: $selection, columnCustomization: columnVisibility(screen)) {
            TableColumn(BudgetScreen.Words.date) { row in
                Text(BudgetScreen.shortDate(row.date))
                    .font(.money(12, weight: .regular))
                    .modifier(MutedInARow())
            }
            .width(70)

            TableColumn(BudgetScreen.Words.description) { row in
                EntryDescription(row: row)
            }

            TableColumn(BudgetScreen.Words.addedBy) { row in
                Text(row.addedBy)
                    .font(.system(size: 11))
                    .modifier(MutedInARow())
            }
            .width(90)
            .customizationID("addedBy")

            TableColumn(BudgetScreen.Words.source) { row in
                Text(row.source)
                    .font(.system(size: 11))
                    .modifier(MutedInARow())
            }
            .width(70)

            TableColumn(BudgetScreen.Words.amount) { row in
                HStack {
                    Spacer()
                    Text(row.amount)
                        .font(.money(12))
                }
            }
            .width(90)
        }
        .tableStyle(.inset)
        // Right-click: Edit… and Delete…, or no menu for a row this person
        // may not change. Double-click and Return open the row.
        .contextMenu(forSelectionType: RecordID.self) { ids in
            if let row = rows.first(where: { ids.contains($0.id) }) {
                menu(main.entryMenu(row))
            }
        } primaryAction: { ids in
            if let id = ids.first { open(id) }
        }
        // Return opens the selected row, in case the table keeps the key.
        .onKeyPress(.return) {
            guard let selection, rows.contains(where: { $0.id == selection }) else { return .ignored }
            open(selection)
            return .handled
        }
        #if os(macOS)
        // A single click opens the row it lands on.
        .background(RowClicks { place in
            if rows.indices.contains(place) { open(rows[place].id) }
        })
        #endif
    }

    /// The row's menu, with a divider between its parts.
    @ViewBuilder
    private func menu(_ parts: [[MainScreen.EntryMenuItem]]) -> some View {
        ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
            if index > 0 { Divider() }
            ForEach(part) { item in
                Button(item.title, role: item.isDestructive ? .destructive : nil) { perform(item.action) }
            }
        }
    }

    /// Delete… asks the window's question first. Edit… opens the sheet.
    private func perform(_ action: MainScreen.EntryAction) {
        if action.asksFirst {
            main.ask(action)
        } else if case .open(let id) = action {
            open(id)
        }
    }

    /// Opens an entry in its sheet, unless a sheet is open already. Making
    /// the editor is what opens it, and marks its note seen.
    private func open(_ id: RecordID) {
        guard editor == nil, let opened = EntryEditor(model: model, entry: id) else { return }
        editor = .entry(opened)
    }

    /// "Added by" only means something once someone else is in the group, so it
    /// stays hidden until then. A conditional column would need macOS 14.4.
    private func columnVisibility(_ screen: BudgetScreen) -> Binding<TableColumnCustomization<BudgetScreen.Row>> {
        let shared = screen.showsAddedBy
        return Binding(get: {
            var columns = TableColumnCustomization<BudgetScreen.Row>()
            columns[visibility: "addedBy"] = shared ? .visible : .hidden
            return columns
        }, set: { _ in })
    }
}

/// Muted text in a table's row. On a selected row the list's colour is behind
/// it, and the muted colour can't be read there, so it goes the way the row's
/// other words go (ENTRY-14).
private struct MutedInARow: ViewModifier {
    @Environment(\.backgroundProminence) private var prominence

    func body(content: Content) -> some View {
        if prominence == .increased {
            content.foregroundStyle(.primary)
        } else {
            content.foregroundStyle(Palette.muted)
        }
    }
}

// MARK: - An entry

/// Draws EntryEditor: a new entry, or one opened from the list to change or
/// delete. Layout only. Read-only, the details are plain text, with a line
/// saying why, and the only button is Done.
struct EntrySheet: View {
    @State private var editor: EntryEditor
    @State private var confirmsStop = false
    @Environment(\.dismiss) private var dismiss
    private typealias Words = EntryEditor.Words

    /// A new entry, for the budget on screen.
    init(model: AppModel) {
        _editor = State(initialValue: EntryEditor(model: model))
    }

    /// An entry opened from the list.
    init(editor: EntryEditor) {
        _editor = State(initialValue: editor)
    }

    /// The sheet an extension asked for.
    init(model: AppModel, request: EntrySheetRequest) {
        switch request {
        case .add(let group, let link):
            _editor = State(initialValue: EntryEditor(model: model, addingIn: group, link: link))
        case .open(let id):
            _editor = State(initialValue: EntryEditor(model: model, entry: id) ?? EntryEditor(model: model))
        }
    }

    static func canAdd(merchant: String, amountText: String) -> Bool {
        EntryEditor.canAdd(merchant: merchant, amountText: amountText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading
            if editor.isReadOnly {
                details
            } else {
                fields
            }
            if let line = editor.readOnlyLine {
                Text(line)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(AccessibilityID.entryReadOnlyLine)
            }
            buttons
        }
        .padding(20)
        .frame(width: 420)
        .confirmationDialog(RepeatEditor.Words.stopTitle, isPresented: $confirmsStop) {
            Button(RepeatEditor.Words.stopConfirm, role: .destructive) {
                editor.stopRepeating()
                dismiss()
            }
            Button(Words.cancel, role: .cancel) {}
        } message: {
            Text(RepeatEditor.Words.stopMessage)
        }
        // The sheet asks its own delete question, so it shows over the sheet.
        .confirmationDialog(editor.pendingDelete?.title ?? "",
                            isPresented: Binding(get: { editor.pendingDelete != nil },
                                                 set: { if !$0 { editor.cancelDelete() } }),
                            presenting: editor.pendingDelete) { pending in
            Button(pending.confirmLabel, role: .destructive) {
                if editor.confirmDelete() { dismiss() }
            }
            if editor.offersStop(pending) {
                Button(PendingDelete.deleteAndStop, role: .destructive) {
                    if editor.confirmDeleteAndStop() { dismiss() }
                }
            }
            Button(Words.cancel, role: .cancel) { editor.cancelDelete() }
        } message: { pending in
            Text(pending.message)
        }
        #if os(macOS)
        // Escape closes the sheet without saving, as Cancel and Done do. Cancel
        // also carries Escape as its shortcut, but a focused text field can
        // take the key first, so the sheet answers it too.
        .onExitCommand { dismiss() }
        #endif
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(editor.title).font(.system(size: 17, weight: .semibold))
            if let top = editor.topLine {
                Text(top)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .accessibilityIdentifier(AccessibilityID.entryTopLine)
            }
            if let notice = editor.noticeLine {
                Text(notice)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(AccessibilityID.entryNoticeLine)
            }
        }
    }

    private var fields: some View {
        Form {
            TextField(Words.merchant, text: Bindable(editor).merchant)
                .accessibilityIdentifier(AccessibilityID.entryMerchant)
            TextField(Words.amount, text: Bindable(editor).amountText)
                .font(.money(13, weight: .regular))
                .accessibilityIdentifier(AccessibilityID.entryAmount)
            if let problem = editor.amountProblem {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.warning)
                    .accessibilityIdentifier(AccessibilityID.entryAmountProblem)
            }
            Toggle(Words.moneyIn, isOn: Bindable(editor).isMoneyIn)
                .toggleStyle(.switch)
                .accessibilityIdentifier(AccessibilityID.entryMoneyIn)
            DatePicker(Words.date, selection: Bindable(editor).date, displayedComponents: .date)
                .accessibilityIdentifier(AccessibilityID.entryDate)
            if let line = editor.periodLine {
                Text(line)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.warning)
                    .accessibilityIdentifier(AccessibilityID.entryPeriodLine)
            }
            TextField(Words.note, text: Bindable(editor).note)
                .accessibilityIdentifier(AccessibilityID.entryNote)
            if editor.offersBudgetChoice, editor.noBudgetLine == nil {
                Picker(Words.budget, selection: Bindable(editor).budgetSelection) {
                    ForEach(editor.budgetChoices) { budget in
                        Text(budget.name).tag(BudgetID?.some(budget.id))
                    }
                    if editor.offersNewBudget {
                        Text(Words.newBudget).tag(BudgetID?.none)
                    }
                }
                .accessibilityIdentifier(AccessibilityID.entryBudget)
            }
            if editor.isNewBudget {
                TextField(Words.newBudgetName, text: Bindable(editor).newBudgetName)
                    .accessibilityIdentifier(AccessibilityID.entryNewBudgetName)
                TextField(Words.newBudgetAmount, text: Bindable(editor).newBudgetAmountText)
                    .accessibilityIdentifier(AccessibilityID.entryNewBudgetAmount)
            }
            if let line = editor.noBudgetLine {
                Text(line)
                    .font(.system(size: 12))
                    .accessibilityIdentifier(AccessibilityID.entryNoBudgetLine)
            }
            if editor.showsLinkRow, let offered = editor.linkChoices {
                Picker(offered.label, selection: Bindable(editor).linkSelection) {
                    Text(Words.noLink).tag(RecordID?.none)
                    ForEach(offered.choices) { choice in
                        Text(choice.name).tag(RecordID?.some(choice.id))
                    }
                }
                .accessibilityIdentifier(AccessibilityID.entryLink)
            }
            if editor.showsRepeatRow {
                Toggle(Words.repeatsRow, isOn: Bindable(editor).repeats)
                    .disabled(!editor.repeatRowIsEnabled)
                    .accessibilityIdentifier(AccessibilityID.entryRepeats)
                if let line = editor.repeatLine {
                    Text(line)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                }
            }
            if editor.showsWhichMonths {
                Picker(Words.whichMonths, selection: Bindable(editor).reach) {
                    Text(Words.thisMonthOnly).tag(AppModel.RepeatReach.thisMonthOnly)
                    Text(Words.thisMonthAndLater).tag(AppModel.RepeatReach.thisMonthAndLater)
                }
                .accessibilityIdentifier(AccessibilityID.entryWhichMonths)
                if let line = editor.whichMonthsLine(editor.reach) {
                    Text(line)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var details: some View {
        Form {
            ForEach(editor.details) { detail in
                LabeledContent(detail.label) {
                    Text(detail.value)
                        .textSelection(.enabled)
                        .accessibilityIdentifier(AccessibilityID.entryDetail(detail.label))
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Delete… on the left, apart from Save, in the Warning colour. Cancel
    /// and Save, or Add, on the right, or Done alone when read-only.
    private var buttons: some View {
        HStack {
            if editor.offersStopRepeating {
                Button(Words.stopRepeating) { confirmsStop = true }
                    .accessibilityIdentifier(AccessibilityID.entryStopRepeating)
            }
            if editor.offersDelete {
                Button {
                    editor.askDelete()
                } label: {
                    Text(Words.delete).foregroundStyle(Palette.warning)
                }
                .accessibilityIdentifier(AccessibilityID.entryDelete)
            }
            Spacer()
            if editor.isReadOnly {
                Button(Words.done) { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(AccessibilityID.entryDone)
            } else {
                Button(Words.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(AccessibilityID.entryCancel)
                if editor.editing == nil {
                    // As before: the sheet closes, and a refusal shows in the window.
                    Button(Words.add) {
                        editor.add()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!editor.canAdd)
                    .accessibilityIdentifier(AccessibilityID.entryAdd)
                } else {
                    // Refused, the sheet stays open, read-only, and says why.
                    Button(editor.saveLabel) {
                        if editor.save() { dismiss() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!editor.canSave)
                    .accessibilityIdentifier(AccessibilityID.entrySave)
                }
            }
        }
    }
}

/// The budget's list, the Description column: the merchant, the note, and a
/// quiet line when this computer's last change to the entry didn't go
/// through. The cell carries the row's identifier, for the UI test.
struct EntryDescription: View {
    let row: BudgetScreen.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(row.merchant).font(.system(size: 13))
            if !row.note.isEmpty {
                Text(row.note)
                    .font(.system(size: 10))
                    .modifier(MutedInARow())
                    .lineLimit(1)
            }
            if let notice = row.notice {
                Text(notice)
                    .font(.system(size: 10))
                    .italic()
                    .modifier(MutedInARow())
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.entryRow(row.merchant))
    }
}

/// The bar at the top of the budget after a delete: what went, and Undo. A
/// row with words and a button, not a pop-up.
struct UndoBar: View {
    let offer: UndoOffer
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(offer.message)
                .font(.system(size: 12))
            Spacer()
            Button(offer.button, action: undo)
                .accessibilityIdentifier(AccessibilityID.undoButton)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Palette.sidebar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.undoBar)
    }
}

// MARK: - Import review

/// Draws ImportReviewScreen; layout only.
struct ImportReviewSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    private typealias Words = ImportReviewScreen.Words

    private var screen: ImportReviewScreen { ImportReviewScreen(model: model) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if screen.isOpen {
                header
                Divider()
                list
                Divider()
                footer
            }
        }
        .frame(width: 760, height: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(screen.title).font(.system(size: 17, weight: .semibold))
                Text(screen.filename)
                    .font(.money(11, weight: .regular))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 5))
                Spacer()
            }
            HStack(spacing: 10) {
                ForEach(screen.tiles) { tile in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tile.label).font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Self.color(tile.tone))
                        Text("\(tile.count)").font(.money(20))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Self.color(tile.tone).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(18)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(screen.rows) { row in
                    ImportRow(row: row, choices: screen.budgetChoices,
                              choose: { screen.choose($0, for: row.id) },
                              chooseKind: { screen.choose($0, for: row.id) })
                    Divider()
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Label(screen.note, systemImage: "doc.text.magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
            Spacer()
            Button(Words.cancel) {
                screen.cancel()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier(AccessibilityID.importCancel)
            Button(Words.importButton) {
                screen.commit()
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier(AccessibilityID.importConfirm)
        }
        .padding(16)
    }

    static func color(_ tone: ImportReviewScreen.Tone) -> Color {
        Color(tone.color)
    }
}

struct ImportRow: View {
    let row: ImportReviewScreen.Row
    let choices: [Budget]
    let choose: (BudgetID?) -> Void
    let chooseKind: (TransactionKind) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(BudgetScreen.shortDate(row.date))
                .font(.money(11, weight: .regular))
                .foregroundStyle(Palette.muted)
                .frame(width: 54, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(row.description).font(.system(size: 12, weight: .medium))
                Text(row.bankDescription)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)

            Text(row.amount)
                .font(.money(12, weight: .regular))
                .frame(width: 84, alignment: .trailing)

            HStack(spacing: 5) {
                Circle().fill(ImportReviewSheet.color(row.tone)).frame(width: 5, height: 5)
                Text(row.status).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ImportReviewSheet.color(row.tone))
                    .accessibilityIdentifier(AccessibilityID.importLineStatus(row.bankDescription))
            }
            .frame(width: 140, alignment: .leading)

            if let kind = row.kind {
                Picker(ImportReviewScreen.Words.kind, selection: Binding(get: { kind }, set: { chooseKind($0) })) {
                    ForEach(ImportReviewScreen.kindChoices, id: \.self) { choice in
                        Text(ImportReviewScreen.name(of: choice)).tag(choice)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
                .accessibilityIdentifier(AccessibilityID.importLineKind(row.bankDescription))
            } else {
                Spacer().frame(width: 110)
            }

            if row.needsBudget {
                Picker("", selection: Binding(get: { row.chosenBudget }, set: { choose($0) })) {
                    Text(ImportReviewScreen.Words.choose).tag(BudgetID?.none)
                    ForEach(choices) { budget in
                        Text(budget.name).tag(BudgetID?.some(budget.id))
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                .accessibilityIdentifier(AccessibilityID.importLineBudget(row.bankDescription))
            } else {
                Spacer().frame(width: 150)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .opacity(row.isActionable ? 1 : 0.55)
    }
}

// MARK: - Entry point

/// The one thing the executable needs from this library.
///
/// The views themselves stay internal. Tests reach them with `@testable import`,
/// which is the right level of access: they are implementation, not API, and
/// making a SwiftUI view public drags its `body` public with it for no benefit.
@MainActor
public func wellSpentRootView(model: AppModel, sync: SyncCoordinator) -> AnyView {
    wellSpentRootView(workspace: Workspace(model: model, sync: sync))
}

@MainActor
public func wellSpentRootView(workspace: Workspace) -> AnyView {
    AnyView(RootView(workspace: workspace))
}

extension SidebarView {
    /// What the delete dialog's Delete button does.
    ///
    /// The reach the dialog showed can be out of date by the time Delete is
    /// pressed. A sync may have finished a join while it was open, for one. So
    /// it is worked out again now, and the reading that sends less wins.
    static func confirm(_ pending: PendingDelete, model: AppModel, sync: SyncCoordinator) {
        pending.confirm(model: model, sync: sync)
    }

    /// Collapsed groups are stored as comma-separated IDs, because `@AppStorage`
    /// holds strings, not sets.
    static func isCollapsed(_ group: GroupID, in stored: String) -> Bool {
        SidebarRules.isCollapsed(group, in: stored)
    }

    static func toggling(_ group: GroupID, in stored: String) -> String {
        SidebarRules.toggling(group, in: stored)
    }

    /// What the footer says: whether budgets go through the server or stay on
    /// this computer.
    /// Groups waiting on their founder that this device holds nothing of,
    /// deleted or not, so no section speaks for them.
    static func unseenWaiting(_ waiting: Set<GroupID>, held: [BudgetGroup]) -> Int {
        SidebarRules.unseenWaiting(waiting, held: held)
    }

    static func footer(for sync: SyncCoordinator) -> String {
        // Whether there is a session, not the signed-in state, which is also
        // false while a sync runs or after one fails.
        SyncWording.footer(signedIn: sync.account != nil)
    }
}

#endif
