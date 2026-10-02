import SwiftUI
import WellSpentCrypto
import WellSpentImport
import WellSpentModel
import WellSpentStore

// MARK: - Look

/// The tokens from the design canvas, in one place so a change lands everywhere.
public enum Palette {
    static let ground = Color(red: 0.965, green: 0.957, blue: 0.941)
    static let surface = Color(red: 0.992, green: 0.988, blue: 0.980)
    static let sidebar = Color(red: 0.937, green: 0.922, blue: 0.894)
    static let ink = Color(red: 0.098, green: 0.110, blue: 0.106)
    static let muted = Color(red: 0.369, green: 0.388, blue: 0.376)
    static let line = Color(red: 0.886, green: 0.871, blue: 0.843)
    static let accent = Color(red: 0.122, green: 0.373, blue: 0.294)
    static let warning = Color(red: 0.706, green: 0.325, blue: 0.165)

    static func budgetColor(_ index: Int) -> Color {
        [accent,
         Color(red: 0.169, green: 0.361, blue: 0.494),
         Color(red: 0.478, green: 0.290, blue: 0.549),
         Color(red: 0.706, green: 0.325, blue: 0.165)][abs(index) % 4]
    }
}

extension Font {
    /// Tabular figures, so columns of money line up.
    static func money(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Root

struct RootView: View {
    @State var workspace: Workspace
    private var model: AppModel { workspace.model }
    private var sync: SyncCoordinator { workspace.sync }
    @State private var showingAddTransaction = false
    @State private var showingFileImporter = false
    @State private var showingAccount = false
    @State private var editor: EditorSheet?

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model, sync: sync, editor: $editor)
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 320)
        } detail: {
            if let budgetID = model.selectedBudget, let summary = model.summary(for: budgetID) {
                BudgetDetailView(model: model, sync: sync, summary: summary,
                                 showingAddTransaction: $showingAddTransaction,
                                 showingFileImporter: $showingFileImporter,
                                 showingAccount: $showingAccount)
            } else if model.summaries.values.allSatisfy(\.isEmpty) {
                noBudgets
            } else {
                ContentUnavailableView("No budget selected",
                                       systemImage: "tray",
                                       description: Text("Pick a budget on the left."))
            }
        }
        .sheet(item: $editor) { sheet in editorView(sheet) }
        // A different account means different budgets: a fresh detail view, not
        // the last account's selection.
        .id(ObjectIdentifier(model))
        .sheet(isPresented: $showingAddTransaction) {
            AddTransactionSheet(model: model)
        }
        .sheet(isPresented: $showingAccount) {
            AccountSheet(sync: sync)
        }
        .sheet(item: Binding(get: { sync.pendingEnrolment.map(EnrolmentBox.init) },
                            set: { if $0 == nil { sync.pendingEnrolment = nil } })) { box in
            RecoveryWordsSheet(sync: sync, enrolment: box.enrolment)
        }
        .sheet(item: Binding(get: { model.pendingImport },
                             set: { model.pendingImport = $0 })) { _ in
            ImportReviewSheet(model: model)
        }
        .fileImporter(isPresented: $showingFileImporter,
                      allowedContentTypes: [.commaSeparatedText, .plainText, .data],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { model.prepareImport(from: url) }
            case .failure(let error):
                model.errorMessage = error.localizedDescription
            }
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { model.errorMessage != nil },
                                    set: { if !$0 { model.dismissError() } })) {
            Button("OK") { model.dismissError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var noBudgets: some View {
        ContentUnavailableView {
            Label("No budgets yet", systemImage: "tray")
        } description: {
            Text("A budget is an amount to spend each month.")
        } actions: {
            Button("Add Budget") { editor = .newBudget(in: nil) }
        }
    }

    @ViewBuilder
    private func editorView(_ sheet: EditorSheet) -> some View {
        switch sheet {
        case .newBudget(let group):
            BudgetSheet(model: model, group: group,
                        groups: model.groups.filter { sync.mayManageBudgets(in: $0.id) })
        case .editBudget(let budget): BudgetSheet(model: model, editing: budget)
        case .newGroup: GroupSheet(model: model)
        case .renameGroup(let group): GroupSheet(model: model, renaming: group)
        case .share(let group): ShareSheet(sync: sync, group: group)
        case .join: JoinSheet(sync: sync)
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Bindable var model: AppModel
    @Bindable var sync: SyncCoordinator
    @Binding var editor: EditorSheet?
    @State private var pendingDelete: PendingDelete?
    /// Collapsed groups, kept between launches. A view preference for this Mac,
    /// so it lives in defaults and never syncs.
    @AppStorage("sidebar.collapsedGroups") private var collapsedGroups = ""

    var body: some View {
        List(selection: Binding(get: { model.selectedBudget },
                                set: { model.selectedBudget = $0 })) {
            ForEach(model.groups) { group in
                let collapsed = Self.isCollapsed(group.id, in: collapsedGroups)
                Section {
                    if !collapsed { rows(for: group) }
                } header: {
                    header(for: group, collapsed: collapsed)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                addMenu
                Divider()
                footer
            }
            .background(.ultraThinMaterial)
        }
        .confirmationDialog(pendingDelete?.title ?? "",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { pending in
            Button("Delete", role: .destructive) {
                Self.confirm(pending, model: model, sync: sync)
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(pending.message)
        }
    }

    @ViewBuilder
    private func rows(for group: BudgetGroup) -> some View {
        if let join = sync.pendingJoins.first(where: { $0.groupID == group.id }) {
            Text(Self.waiting(for: join))
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .selectionDisabled()
        } else {
            ForEach(model.summaries[group.id] ?? [], id: \.budget.id) { summary in
                BudgetRow(summary: summary)
                    .tag(summary.budget.id)
                    .contextMenu { budgetMenu(summary.budget) }
            }
        }
    }

    private func header(for group: BudgetGroup, collapsed: Bool) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                collapsedGroups = Self.toggling(group.id, in: collapsedGroups)
            }
        } label: {
            HStack(spacing: 6) {
                Text(group.name.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.7)
                Spacer()
                Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.muted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Show budgets" : "Hide budgets")
        .contextMenu { groupMenu(group) }
    }

    /// Like Add List in Reminders: the common action is the button, the rarer one
    /// is in its menu.
    private var addMenu: some View {
        HStack {
            Menu {
                Button("New Group…") { editor = .newGroup }
                Button("Join a Group…") { editor = .join }
            } label: {
                Label("Add Budget", systemImage: "plus.circle")
                    .font(.system(size: 12))
            } primaryAction: {
                editor = .newBudget(in: nil)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// Changing or deleting a budget takes Manage. Below that, every other
    /// member's app and the server would refuse it, so it is not offered.
    @ViewBuilder
    private func budgetMenu(_ budget: Budget) -> some View {
        if sync.mayManageBudgets(in: budget.groupID) {
            Button("Edit…") { editor = .editBudget(budget) }
            Divider()
            Button("Delete…", role: .destructive) {
                pendingDelete = .budget(budget, transactions: model.transactionCount(inBudget: budget.id))
            }
        }
    }

    @ViewBuilder
    private func groupMenu(_ group: BudgetGroup) -> some View {
        if !sync.isWaitingToJoin(group.id) {
            Button("Share…") { editor = .share(group) }
            Divider()
        }
        if sync.mayManageBudgets(in: group.id) {
            Button("New Budget in \(group.name)…") { editor = .newBudget(in: group.id) }
        }
        Button("Rename…") { editor = .renameGroup(group) }
        Divider()
        Button("Delete…", role: .destructive) {
            pendingDelete = .group(group, budgets: model.summaries[group.id]?.count ?? 0,
                                   reach: sync.deleteReach(of: group.id))
        }
    }

    private var footer: some View {
            HStack(spacing: 7) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.accent)
                Text(Self.footer(for: sync))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
    }
}

struct BudgetRow: View {
    let summary: BudgetSummary

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(summary.isOverspent ? Palette.warning : Palette.budgetColor(summary.budget.colorIndex))
                .frame(width: 7, height: 7)
            Text(summary.budget.name)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(summary.remaining.display)
                .font(.money(11, weight: .regular))
                .foregroundStyle(summary.isOverspent ? Palette.warning : Palette.muted)
        }
        .padding(.vertical, 1)
    }
}

// MARK: - Budget detail

struct BudgetDetailView: View {
    @Bindable var model: AppModel
    @Bindable var sync: SyncCoordinator
    let summary: BudgetSummary
    @Binding var showingAddTransaction: Bool
    @Binding var showingFileImporter: Bool
    @Binding var showingAccount: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transactionTable
        }
        .background(Palette.surface)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    showingFileImporter = true
                } label: {
                    Label("Import statement", systemImage: "square.and.arrow.down")
                }
                Button {
                    showingAddTransaction = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
                if sync.account != nil {
                    SyncButton(sync: sync, showingAccount: $showingAccount)
                }
                AccountButton(sync: sync, showingAccount: $showingAccount)
            }
        }
        .navigationTitle(summary.budget.name)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text(summary.spent.display)
                    .font(.money(30, weight: .medium))
                Text("of \(summary.budget.limit.display) this period")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
                Spacer()
                if summary.isOverspent {
                    Text("\(summary.remaining.magnitude.display) over")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.warning)
                } else {
                    Text("\(summary.remaining.display) left")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.muted)
                }
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.line)
                    Capsule()
                        .fill(summary.isOverspent ? Palette.warning : Palette.accent)
                        .frame(width: max(2, geometry.size.width * summary.fraction))
                }
            }
            .frame(height: 7)

            Text("\(summary.transactionCount) transactions since \(summary.period.start, format: .dateTime.day().month(.abbreviated))")
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
        }
        .padding(20)
    }

    private var transactionTable: some View {
        Table(model.transactions, columnCustomization: columnVisibility) {
            TableColumn("Date") { transaction in
                Text(transaction.date, format: .dateTime.day().month(.abbreviated))
                    .font(.money(12, weight: .regular))
                    .foregroundStyle(Palette.muted)
            }
            .width(70)

            TableColumn("Description") { transaction in
                VStack(alignment: .leading, spacing: 1) {
                    Text(transaction.merchant).font(.system(size: 13))
                    if !transaction.note.isEmpty {
                        Text(transaction.note)
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                    }
                }
            }

            TableColumn("Added by") { transaction in
                Text(model.addedBy(transaction, me: sync.userID))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
            }
            .width(90)
            .customizationID("addedBy")

            TableColumn("Source") { transaction in
                Text(transaction.source.rawValue.capitalized)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
            }
            .width(70)

            TableColumn("Amount") { transaction in
                HStack {
                    Spacer()
                    Text(transaction.amount.magnitude.display)
                        .font(.money(12))
                }
            }
            .width(90)
        }
        .tableStyle(.inset)
    }

    /// "Added by" only means something once someone else is in the group, so it
    /// stays hidden until then. A conditional column would need macOS 14.4.
    private var columnVisibility: Binding<TableColumnCustomization<WellSpentModel.Transaction>> {
        let shared = model.isShared(summary.budget.groupID)
        return Binding(get: {
            var columns = TableColumnCustomization<WellSpentModel.Transaction>()
            columns[visibility: "addedBy"] = shared ? .visible : .hidden
            return columns
        }, set: { _ in })
    }
}

// MARK: - Add

struct AddTransactionSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var merchant = ""
    @State private var amountText = ""
    @State private var note = ""
    @State private var date = Date()

    private var amount: Money? {
        StatementParser.parseAmount(amountText, currency: .usd)
    }

    /// Whether the form can be submitted.
    ///
    /// Lifted out of the button's `disabled` expression so it can be tested
    /// without driving `@State`. The rule is the interesting part; the binding
    /// is not.
    static func canAdd(merchant: String, amountText: String) -> Bool {
        !merchant.trimmingCharacters(in: .whitespaces).isEmpty
            && StatementParser.parseAmount(amountText, currency: .usd) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New transaction").font(.system(size: 17, weight: .semibold))

            Form {
                TextField("Merchant", text: $merchant)
                TextField("Amount", text: $amountText)
                    .font(.money(13, weight: .regular))
                DatePicker("Date", selection: $date, displayedComponents: .date)
                TextField("Note", text: $note)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    if let amount { model.addTransaction(merchant: merchant, amount: amount,
                                                         date: date, note: note) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!Self.canAdd(merchant: merchant, amountText: amountText))
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: - Import review

struct ImportReviewSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let pending = model.pendingImport {
                header(pending)
                Divider()
                list(pending)
                Divider()
                footer
            }
        }
        .frame(width: 760, height: 560)
    }

    private func header(_ pending: AppModel.PendingImport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Import a statement").font(.system(size: 17, weight: .semibold))
                Text(pending.filename)
                    .font(.money(11, weight: .regular))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 5))
                Spacer()
            }
            HStack(spacing: 10) {
                tile("Matched", pending.summary.matched, Palette.accent)
                tile("To add", pending.summary.toAdd, Color(red: 0.169, green: 0.361, blue: 0.494))
                tile("Already imported", pending.summary.alreadyImported, Palette.muted)
                tile("Needs a budget", pending.summary.needBudget, Palette.warning)
            }
        }
        .padding(18)
    }

    private func tile(_ label: String, _ count: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
            Text("\(count)").font(.money(20))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func list(_ pending: AppModel.PendingImport) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(pending.proposals.enumerated()), id: \.offset) { index, proposal in
                    ImportRow(index: index, proposal: proposal, model: model)
                    Divider()
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Label("Read on this Mac. Nothing was uploaded.", systemImage: "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
            Spacer()
            Button("Cancel") {
                model.cancelImport()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button("Import") {
                model.commitImport()
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }
}

struct ImportRow: View {
    let index: Int
    let proposal: ImportProposal
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Text(proposal.line.date, format: .dateTime.day().month(.abbreviated))
                .font(.money(11, weight: .regular))
                .foregroundStyle(Palette.muted)
                .frame(width: 54, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(proposal.line.cleanedDescription).font(.system(size: 12, weight: .medium))
                Text(proposal.line.rawDescription)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)

            Text(proposal.line.amount.display)
                .font(.money(12, weight: .regular))
                .frame(width: 84, alignment: .trailing)

            statusLabel.frame(width: 140, alignment: .leading)

            if case .needsBudget = proposal.decision {
                Picker("", selection: Binding(
                    get: { model.pendingImport?.chosenBudgets[index] },
                    set: { model.pendingImport?.chosenBudgets[index] = $0 }
                )) {
                    Text("Choose").tag(BudgetID?.none)
                    ForEach(model.summaries.values.flatMap(\.self), id: \.budget.id) { summary in
                        Text(summary.budget.name).tag(BudgetID?.some(summary.budget.id))
                    }
                }
                .labelsHidden()
                .frame(width: 150)
            } else {
                Spacer().frame(width: 150)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .opacity(proposal.isActionable ? 1 : 0.55)
    }

    private var statusLabel: some View {
        let (text, color): (String, Color) = switch proposal.decision {
        case .alreadyImported: ("Already imported", Palette.muted)
        case .matchesReceipt: ("Matched to receipt", Palette.accent)
        case .matchesTransaction: ("Matched to entry", Palette.accent)
        case .add: ("Will be added", Color(red: 0.169, green: 0.361, blue: 0.494))
        case .needsBudget: ("Needs a budget", Palette.warning)
        }
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(color)
        }
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

/// `.sheet(item:)` needs something identifiable, and an enrolment is a value with
/// no identity of its own.
struct EnrolmentBox: Identifiable, Equatable {
    let enrolment: SyncCoordinator.Enrolment
    var id: String { enrolment.email }

    init(_ enrolment: SyncCoordinator.Enrolment) { self.enrolment = enrolment }
}

extension SidebarView {
    /// What the delete dialog's Delete button does.
    ///
    /// The reach the dialog showed can be out of date by the time Delete is
    /// pressed. A sync may have finished a join while it was open, for one. So
    /// it is worked out again now, and the reading that sends less wins.
    static func confirm(_ pending: PendingDelete, model: AppModel, sync: SyncCoordinator) {
        switch pending {
        case .budget(let budget, _): model.deleteBudget(budget.id)
        case .group(let group, _, let reach):
            model.deleteGroup(group.id, reach: reach.stricter(sync.deleteReach(of: group.id)))
        }
    }

    static func waiting(for join: PendingJoin) -> String {
        let who = join.inviterName.isEmpty ? "the person who invited you" : join.inviterName
        return "Waiting for \(who) to add you"
    }

    /// Collapsed groups are stored as comma-separated IDs, because `@AppStorage`
    /// holds strings, not sets.
    static func isCollapsed(_ group: GroupID, in stored: String) -> Bool {
        stored.split(separator: ",").contains { $0 == group.uuid.uuidString }
    }

    static func toggling(_ group: GroupID, in stored: String) -> String {
        var ids = stored.split(separator: ",").map(String.init)
        let id = group.uuid.uuidString
        if let index = ids.firstIndex(of: id) { ids.remove(at: index) } else { ids.append(id) }
        return ids.joined(separator: ",")
    }

    /// What the footer says, which depends on whether anything leaves this Mac.
    ///
    /// "Encrypted on this Mac" was true and incomplete once syncing existed. A
    /// person who has signed in should be told their data goes somewhere, and that
    /// it is sealed before it does.
    static func footer(for sync: SyncCoordinator) -> String {
        sync.isSignedIn ? "Encrypted here and on the server" : "Encrypted on this Mac"
    }
}
