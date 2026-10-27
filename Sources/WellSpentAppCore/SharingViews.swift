// The Mac screens. SwiftUI exists only on Apple systems; the Linux app draws
// the same shared logic with its own screens.
#if canImport(SwiftUI)
import SwiftUI
import WellSpentCrypto
import WellSpentModel
import WellSpentSync

// MARK: - Words

// MARK: - Share

/// Draws the shared email invitation form. The server sends the invitation.
struct ShareSheet: View {
    @State private var screen: EmailInviteScreen
    @Environment(\.dismiss) private var dismiss
    @FocusState private var emailFocused: Bool
    private typealias Words = EmailInviteScreen.Words

    init(sync: SyncCoordinator, group: BudgetGroup) {
        _screen = State(initialValue: EmailInviteScreen(actions: sync, group: group.id,
                                                       groupName: group.name))
    }

    init(screen: EmailInviteScreen) {
        _screen = State(initialValue: screen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(screen.title)
                .font(.system(size: 17, weight: .semibold))
            if screen.sent != nil {
                Text(screen.sentMessage ?? screen.note)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button(Words.done) { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier(AccessibilityID.shareDone)
                }
            } else {
                form
            }
        }
        .padding(20)
        .frame(width: 440)
        .interactiveDismissDisabled(screen.isWorking)
        .onAppear { emailFocused = true }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            Form {
                TextField(Words.email, text: Bindable(screen).email, prompt: Text(Words.emailPrompt))
                    .focused($emailFocused)
                    .accessibilityIdentifier(AccessibilityID.shareEmail)
                TextField(Words.inviteeName, text: Bindable(screen).inviteeName,
                          prompt: Text(Words.inviteeNamePrompt))
                    .accessibilityIdentifier(AccessibilityID.shareInviteeName)
                TextField(Words.name, text: Bindable(screen).myName, prompt: Text(Words.namePrompt))
                    .accessibilityIdentifier(AccessibilityID.shareName)
                if !screen.roles.isEmpty {
                    Picker(Words.role, selection: Bindable(screen).role) {
                        ForEach(screen.roles) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier(AccessibilityID.shareRole)
                }
                Picker(Words.history, selection: Bindable(screen).history) {
                    Text(Words.historyAll).tag(HistoryAccess.all)
                    Text(Words.historyFromNow).tag(HistoryAccess.fromNow)
                }
                .accessibilityIdentifier(AccessibilityID.shareHistory)
            }
            .formStyle(.grouped)
            .disabled(screen.isWorking)

            Text(screen.role.explanation)
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
            if let notice = screen.notice ?? screen.failure {
                note(notice, warning: true)
            }
            Text(screen.note)
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(Words.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(screen.isWorking)
                    .accessibilityIdentifier(AccessibilityID.shareCancel)
                Button(screen.sendLabel) { Task { await screen.send() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!screen.canSend)
                    .accessibilityIdentifier(AccessibilityID.shareCreate)
            }
        }
    }
}

// MARK: - Join

/// Draws JoinScreen; layout only.
struct JoinSheet: View {
    @Bindable var sync: SyncCoordinator
    /// Opens the account sheet, to confirm the email.
    let openAccount: () -> Void
    @State private var screen: JoinScreen
    @Environment(\.dismiss) private var dismiss
    private typealias Words = JoinScreen.Words

    /// `linkText` opens the sheet with a link already pasted, for tests.
    init(sync: SyncCoordinator, linkText: String = "", openAccount: @escaping () -> Void = {}) {
        self.sync = sync
        self.openAccount = openAccount
        _screen = State(initialValue: JoinScreen(actions: sync, linkText: linkText))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(screen.title)
                .font(.system(size: 17, weight: .semibold))

            Form {
                TextField(Words.link, text: Bindable(screen).linkText, prompt: Text(Words.linkPrompt))
                    .font(.money(12, weight: .regular))
                    .accessibilityIdentifier(AccessibilityID.joinLink)
                TextField(Words.name, text: Bindable(screen).myName, prompt: Text(Words.namePrompt))
                    .accessibilityIdentifier(AccessibilityID.joinName)
                    .disabled(screen.isAddressedInvitation)
            }
            .formStyle(.grouped)

            if let invitation = screen.invitation {
                Text(invitation)
                    .font(.system(size: 13))
            } else if let problem = screen.linkProblem {
                note(problem, warning: true)
            }

            if let notice = screen.notice {
                note(notice, warning: true)
                if screen.offersEmailConfirmation {
                    Button(Words.confirmEmail) { openAccount() }
                }
            }
            if let failure = screen.failure, failure != screen.notice {
                note(failure, warning: true)
            }

            HStack {
                Spacer()
                Button(Words.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(AccessibilityID.joinCancel)
                Button(screen.joinLabel) {
                    Task { if await screen.join() { dismiss() } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!screen.canJoin)
                .accessibilityIdentifier(AccessibilityID.joinJoin)
            }
        }
        .padding(20)
        .frame(width: 440)
        .task(id: screen.linkText) { await screen.lookUp() }
    }
}

// MARK: - The invitation page

/// Draws the page a clicked invite link opens (JoinScreen, from
/// `Workspace.open(_:)`), on the right where a budget opens. Who invited
/// them and to what, the level and what it lets them do, how much they
/// would see, Your name, and Join. Signed out or not confirmed yet, the
/// notice and its button stand in place of Join. No Decline: a link has no
/// invite to decline. Layout only.
struct InvitationPage: View {
    @Bindable var sync: SyncCoordinator
    @Bindable var screen: JoinScreen
    /// The window's rules. Join goes through them, so the group's page
    /// opens once in.
    let main: MainScreen
    @Binding var showingAccount: Bool
    private typealias Words = JoinScreen.Words

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let invitation = screen.invitation {
                    offer(invitation)
                    answer
                } else {
                    Text(screen.title)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    if let problem = screen.linkProblem {
                        note(problem, warning: true)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .environment(\.colorScheme, .light)
        .background(Palette.surface)
        .foregroundStyle(Palette.ink)
        .toolbar {
            ToolbarItemGroup {
                if main.showsSync {
                    SyncButton(sync: sync, showingAccount: $showingAccount)
                }
                AccountButton(sync: sync, showingAccount: $showingAccount)
            }
        }
        .navigationTitle(screen.title)
    }

    /// Who invited them and to what, then what the server says it offers,
    /// once it has said.
    private func offer(_ invitation: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(invitation)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let line = screen.levelLine {
                Text(marking(screen.levelTitle, in: line))
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.ink)
            }
            if let explanation = screen.levelExplanation {
                Text(explanation)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let history = screen.historyLine {
                Text(history)
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Your name, then Join, or what stands in its way and the button that
    /// deals with it.
    private var answer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(Words.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.ink)
                TextField(Words.name, text: $screen.myName, prompt: Text(Words.namePrompt))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(maxWidth: 260)
                    .accessibilityIdentifier(AccessibilityID.invitationName)
                    .disabled(screen.isAddressedInvitation)
            }
            if let notice = screen.notice {
                note(notice, warning: true)
                if screen.offersSignIn {
                    Button(Words.signIn) { showingAccount = true }
                        .accessibilityIdentifier(AccessibilityID.invitationSignIn)
                } else if screen.offersEmailConfirmation {
                    Button(Words.confirmEmail) { showingAccount = true }
                        .accessibilityIdentifier(AccessibilityID.invitationConfirmEmail)
                }
            } else {
                Button(screen.joinLabel) { Task { await main.joinInvitation() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!screen.canJoin)
                    .accessibilityIdentifier(AccessibilityID.invitationJoin)
            }
            if let failure = screen.failure, failure != screen.notice {
                note(failure, warning: true)
            }
        }
    }

    /// The line with the level's name in bold, so it stands out.
    private func marking(_ level: String?, in line: String) -> AttributedString {
        var text = AttributedString(line)
        if let level, let range = text.range(of: level) {
            text[range].font = .system(size: 13, weight: .semibold)
        }
        return text
    }
}

// MARK: - A group's page

/// Draws a group's page, on the right where a budget opens: its name, the
/// line under it, its money for the month, and its people, with what this
/// person may change. A click on the group's name opens it, and so does
/// People… in its menu. The people and the words are MembersScreen's, the
/// money is MainScreen's, and Leave Group… asks the window's own question.
/// Layout only.
struct GroupPage: View {
    @Bindable var sync: SyncCoordinator
    let group: BudgetGroup
    /// The window's rules, and its question before a leave.
    let main: MainScreen
    @Binding var showingAccount: Bool
    /// Opens the Share sheet for this group.
    let invite: () -> Void
    /// Opens the New Budget sheet for this group.
    let addBudget: () -> Void
    @State private var screen: MembersScreen
    private typealias Words = MembersScreen.Words

    /// `screen` opens the page on one made already, for tests.
    init(sync: SyncCoordinator, group: BudgetGroup, main: MainScreen, showingAccount: Binding<Bool>,
         invite: @escaping () -> Void = {}, addBudget: @escaping () -> Void = {}, screen: MembersScreen? = nil) {
        self.sync = sync
        self.group = group
        self.main = main
        _showingAccount = showingAccount
        self.invite = invite
        self.addBudget = addBudget
        _screen = State(initialValue: screen ?? MembersScreen(actions: sync, group: group.id, groupName: group.name))
    }

    var body: some View {
        VStack(spacing: 0) {
            // After a removal, a quiet line at the top, where the Undo bar
            // sits on a budget. No pop-up.
            if let removed = screen.removedNote {
                HStack {
                    Text(removed)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Palette.sidebar)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(AccessibilityID.groupRemoved)
                Divider()
                    .overlay(Palette.line)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    // Every budget in the group added up for the month, above
                    // its people. None for a group with no budgets.
                    if let money = main.money(of: group.id) {
                        GroupMoneySection(money: money)
                    }
                    if !screen.rows.isEmpty {
                        people
                    }
                    if let failure = screen.failure {
                        note(failure, warning: true)
                    }
                    if screen.mayLeave {
                        Button(Words.leave) { main.askToLeave(group) }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Palette.warning)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.line, lineWidth: 1))
                            .disabled(screen.isWorking)
                            .accessibilityIdentifier(AccessibilityID.groupLeave)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .environment(\.colorScheme, .light)
        .background(Palette.surface)
        .toolbar {
            ToolbarItemGroup {
                if sync.mayManageBudgets(in: group.id) {
                    Button {
                        addBudget()
                    } label: {
                        Label(MainScreen.Words.addBudget, systemImage: "plus")
                    }
                    .keyboardShortcut("n", modifiers: .command)
                    .accessibilityIdentifier(AccessibilityID.groupAddBudget)
                }
                if main.showsSync {
                    SyncButton(sync: sync, showingAccount: $showingAccount)
                }
                AccountButton(sync: sync, showingAccount: $showingAccount)
            }
        }
        .navigationTitle(group.name)
        // Whoever joined since the last sync shows as the page opens, and
        // after each sync while it stays open.
        .task { await screen.refresh() }
        .onChange(of: sync.lastSyncedAt) { screen.reload() }
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
    }

    /// The name, with Invite Someone… on the right, and the line under it.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(group.name)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Palette.ink)
                Spacer()
                if screen.mayInvite {
                    Button(Words.invite) { invite() }
                        .buttonStyle(.bordered)
                        .tint(Palette.accent)
                        .font(.system(size: 13, weight: .medium))
                        .accessibilityIdentifier(AccessibilityID.groupInvite)
                }
            }
            Text(screen.summary)
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
                .accessibilityIdentifier(AccessibilityID.groupSummary)
        }
        .padding(.bottom, 2)
    }

    private var people: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Words.people.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Palette.muted)
            VStack(spacing: 0) {
                ForEach(screen.rows) { row in
                    person(row)
                    if row.id != screen.rows.last?.id || !screen.pendingInvites.isEmpty {
                        Divider()
                            .overlay(Palette.line)
                    }
                }
                ForEach(Array(screen.pendingInvites.enumerated()), id: \.element.id) { index, invitation in
                    OutgoingInvitationRow(screen: screen, invitation: invitation)
                    if index < screen.pendingInvites.count - 1 {
                        Divider()
                            .overlay(Palette.line)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line, lineWidth: 1))
            .foregroundStyle(Palette.ink)
        }
    }

    /// One person: their name, what their level lets them do, and the level.
    /// The picker and Remove… show only where this person may change them.
    /// Anyone else's level is a small label.
    private func person(_ row: MembersScreen.Row) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text(Words.levelExplanation(row.level))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if row.levelChoices.isEmpty {
                Text(row.levelTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Palette.surface, in: Capsule())
                    .overlay(Capsule().stroke(Palette.line, lineWidth: 1))
            } else {
                Picker(Words.level, selection: Binding(get: { row.level }, set: { level in
                    Task { await screen.setLevel(level, for: row.id) }
                })) {
                    ForEach(row.levelChoices, id: \.self) { Text(Words.levelTitle($0)).tag($0) }
                }
                .labelsHidden()
                .frame(width: 110)
                .disabled(screen.isWorking)
            }
            if row.mayRemove {
                Button(Words.remove) { screen.askToRemove(row.id) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Palette.warning)
                    .disabled(screen.isWorking)
                    .accessibilityIdentifier(AccessibilityID.groupRemove(row.name))
            }
        }
        .padding(.vertical, 10)
    }
}

// MARK: - Bits

@ViewBuilder
private func note(_ text: String, warning: Bool) -> some View {
    Label(text, systemImage: warning ? "exclamationmark.triangle" : "info.circle")
        .font(.system(size: 12))
        .foregroundStyle(warning ? Palette.warning : Palette.muted)
        .fixedSize(horizontal: false, vertical: true)
}

enum Clipboard {
    static func copy(_ text: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }
}


#endif
