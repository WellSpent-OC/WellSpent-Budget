// The Mac screens. SwiftUI exists only on Apple systems; the Linux app draws
// the same shared logic with its own screens.
#if canImport(SwiftUI)
import SwiftUI
import WellSpentCrypto
import WellSpentModel
import WellSpentSync

// MARK: - Words

// MARK: - Share

/// Draws ShareScreen. What it checks and says lives there, shared with every
/// desktop; this is layout only.
struct ShareSheet: View {
    @Bindable var sync: SyncCoordinator
    let group: BudgetGroup
    @State private var screen: ShareScreen
    @Environment(\.dismiss) private var dismiss
    private typealias Words = ShareScreen.Words

    /// `created` opens the sheet showing a link already made, for tests.
    init(sync: SyncCoordinator, group: BudgetGroup, created: InviteLink? = nil) {
        self.sync = sync
        self.group = group
        _screen = State(initialValue: ShareScreen(actions: sync, group: group.id, groupName: group.name,
                                                  created: created))
    }

    static func canCreate(myName: String, signedIn: Bool) -> Bool {
        SharingRules.canCreate(myName: myName, signedIn: signedIn)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(screen.title)
                .font(.system(size: 17, weight: .semibold))

            if let link = screen.link {
                created(link)
            } else {
                form
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            Form {
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

            Text(screen.role.explanation)
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)

            if let notice = screen.notice {
                note(notice, warning: true)
            } else if let failure = screen.failure {
                note(failure, warning: true)
            }

            HStack {
                Text(Words.linkNote)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                Spacer()
                Button(Words.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(AccessibilityID.shareCancel)
                Button(screen.createLabel) { Task { await screen.create() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!screen.canCreate)
                    .accessibilityIdentifier(AccessibilityID.shareCreate)
            }
        }
    }

    private func created(_ link: InviteLink) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(link.url)
                .font(.money(11, weight: .regular))
                .textSelection(.enabled)
                .accessibilityIdentifier(AccessibilityID.shareLink)
                .lineLimit(3)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 8))

            Text(SyncWording.inviteNote)
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                ShareLink(item: link.url) { Label(Words.send, systemImage: "square.and.arrow.up") }
                Button {
                    Clipboard.copy(link.url)
                } label: {
                    Label(Words.copyLink, systemImage: "doc.on.doc")
                }
                .accessibilityIdentifier(AccessibilityID.shareCopyLink)
                Spacer()
                Button(Words.done) { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(AccessibilityID.shareDone)
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

    static func canJoin(linkText: String, myName: String, signedIn: Bool) -> Bool {
        SharingRules.canJoin(linkText: linkText, myName: myName, signedIn: signedIn)
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
    }
}

// MARK: - A group's page

/// Draws a group's page, on the right where a budget opens: its name, the
/// line under it, and its people, with what this person may change. A click
/// on the group's name opens it, and so does People… in its menu. The
/// people and the words are MembersScreen's, and Leave Group… asks the
/// window's own question. Layout only.
struct GroupPage: View {
    @Bindable var sync: SyncCoordinator
    let group: BudgetGroup
    /// The window's rules, and its question before a leave.
    let main: MainScreen
    @Binding var showingAccount: Bool
    /// Opens the Share sheet for this group.
    let invite: () -> Void
    @State private var screen: MembersScreen
    private typealias Words = MembersScreen.Words

    /// `screen` opens the page on one made already, for tests.
    init(sync: SyncCoordinator, group: BudgetGroup, main: MainScreen, showingAccount: Binding<Bool>,
         invite: @escaping () -> Void = {}, screen: MembersScreen? = nil) {
        self.sync = sync
        self.group = group
        self.main = main
        _showingAccount = showingAccount
        self.invite = invite
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
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Palette.sidebar)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(AccessibilityID.groupRemoved)
                Divider()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if !screen.rows.isEmpty {
                        people
                    }
                    if let failure = screen.failure {
                        note(failure, warning: true)
                    }
                    if screen.mayLeave {
                        Button(Words.leave) { main.askToLeave(group) }
                            .disabled(screen.isWorking)
                            .accessibilityIdentifier(AccessibilityID.groupLeave)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Palette.surface)
        .toolbar {
            ToolbarItemGroup {
                if sync.account != nil {
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(group.name)
                    .font(.system(size: 22, weight: .semibold))
                Spacer()
                if screen.mayInvite {
                    Button(Words.invite) { invite() }
                        .accessibilityIdentifier(AccessibilityID.groupInvite)
                }
            }
            Text(screen.summary)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .accessibilityIdentifier(AccessibilityID.groupSummary)
        }
    }

    private var people: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Words.people.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(Palette.muted)
            VStack(spacing: 0) {
                ForEach(screen.rows) { row in
                    person(row)
                    if row.id != screen.rows.last?.id { Divider() }
                }
            }
            .padding(.horizontal, 12)
            .background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// One person: their name, what their level lets them do, and the level.
    /// The picker and Remove… show only where this person may change them.
    /// Anyone else's level is a small label.
    private func person(_ row: MembersScreen.Row) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.label)
                    .font(.system(size: 13))
                Text(Words.levelExplanation(row.level))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if row.levelChoices.isEmpty {
                Text(row.levelTitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.muted.opacity(0.4)))
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
                    .disabled(screen.isWorking)
            }
        }
        .padding(.vertical, 8)
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
