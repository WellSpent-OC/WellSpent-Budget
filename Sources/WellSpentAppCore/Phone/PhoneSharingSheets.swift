// The iPhone's screens, built the iPhone's way. Layout only.
#if os(iOS)
import SwiftUI
import UIKit
import WellSpentCrypto
import WellSpentModel
import WellSpentSync

/// Share: your name, what they can do, what they see, and Create Link, which
/// opens the iPhone's own share sheet with the link in it. No extra screen
/// with the link. Closed without sending, the sheet stays, says the link
/// works once, and Send… opens the share sheet again for the same link.
/// Draws `ShareScreen`. Layout only.
struct PhoneShareSheet: View {
    @State private var screen: ShareScreen
    @Environment(\.dismiss) private var dismiss
    private typealias Words = ShareScreen.Words

    init(sync: SyncCoordinator, group: BudgetGroup) {
        _screen = State(initialValue: ShareScreen(actions: sync, group: group.id, groupName: group.name))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PhoneField(Words.name) {
                        TextField(Words.name, text: Bindable(screen).myName, prompt: Text(Words.namePrompt))
                            .textInputAutocapitalization(.words)
                            .accessibilityIdentifier(AccessibilityID.shareName)
                    }
                    .disabled(screen.link != nil)
                }
                .listRowBackground(Palette.surface)
                if !screen.roles.isEmpty {
                    Section {
                        PhoneField(Words.role) {
                            Picker(Words.role, selection: Bindable(screen).role) {
                                ForEach(screen.roles) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .accessibilityIdentifier(AccessibilityID.shareRole)
                        }
                        .disabled(screen.link != nil)
                    } footer: {
                        Text(screen.role.explanation)
                    }
                    .listRowBackground(Palette.surface)
                }
                Section {
                    Picker(Words.history, selection: Bindable(screen).history) {
                        Text(Words.historyAll).tag(HistoryAccess.all)
                        Text(Words.historyFromNow).tag(HistoryAccess.fromNow)
                    }
                    .pickerStyle(.menu)
                    .disabled(screen.link != nil)
                    .accessibilityIdentifier(AccessibilityID.shareHistory)
                }
                .listRowBackground(Palette.surface)
                if let notice = screen.notice ?? screen.failure {
                    Section {
                        PhoneNote(notice)
                    }
                    .listRowBackground(Color.clear)
                }
                Section {
                    Button(action: createOrSend) {
                        Text(screen.link == nil ? screen.createLabel : Words.send)
                            .font(.headline)
                            // White would not read on the dark mode green.
                            .foregroundStyle(Palette.ground)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(screen.link == nil && !screen.canCreate)
                    .accessibilityIdentifier(AccessibilityID.shareCreate)
                } footer: {
                    Text(screen.note)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            .phoneSheet(title: screen.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(screen.link == nil ? Words.cancel : Words.done) { dismiss() }
                        .disabled(screen.isWorking)
                        .accessibilityIdentifier(AccessibilityID.shareCancel)
                }
            }
        }
        // While the link is being made, the sheet stays: the share sheet
        // opens over it once the link is there, and never over what is left.
        .interactiveDismissDisabled(screen.isWorking)
    }

    /// Makes the link the first time, then hands it to the share sheet.
    private func createOrSend() {
        Task {
            if screen.link == nil {
                guard await screen.create() else { return }
            }
            guard let link = screen.link else { return }
            PhoneSystemShare.present(link.url) { sent in
                if sent { dismiss() }
            }
        }
    }
}

/// The iPhone's own share sheet: Messages, Mail, Copy and the rest. It goes
/// over whatever shows, here the Share sheet, so it is presented by UIKit:
/// SwiftUI has no way to open it without a link made beforehand.
@MainActor
enum PhoneSystemShare {
    /// `finished` hears whether the link went somewhere, after the share
    /// sheet has closed.
    static func present(_ text: String, finished: @escaping (Bool) -> Void) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow),
              var top = window.rootViewController else { return }
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        let controller = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            DispatchQueue.main.async { finished(completed) }
        }
        top.present(controller, animated: true)
    }
}

/// Join a Group: a link someone sent, pasted, and the name the group will see.
/// Draws `JoinScreen`. Layout only.
struct PhoneJoinSheet: View {
    /// Opens the account sheet, to sign in or confirm the email.
    let openAccount: () -> Void
    @State private var screen: JoinScreen
    @Environment(\.dismiss) private var dismiss
    private typealias Words = JoinScreen.Words

    init(sync: SyncCoordinator, openAccount: @escaping () -> Void) {
        self.openAccount = openAccount
        _screen = State(initialValue: JoinScreen(actions: sync))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PhoneField(Words.link) {
                        TextField(Words.link, text: Bindable(screen).linkText, prompt: Text(Words.linkPrompt))
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier(AccessibilityID.joinLink)
                    }
                    PhoneField(Words.name) {
                        TextField(Words.name, text: Bindable(screen).myName, prompt: Text(Words.namePrompt))
                            .textInputAutocapitalization(.words)
                            .accessibilityIdentifier(AccessibilityID.joinName)
                    }
                }
                .listRowBackground(Palette.surface)
                if let invitation = screen.invitation {
                    Section {
                        Text(invitation)
                    }
                    .listRowBackground(Color.clear)
                } else if let problem = screen.linkProblem {
                    Section {
                        PhoneNote(problem)
                    }
                    .listRowBackground(Color.clear)
                }
                if let notice = screen.notice {
                    Section {
                        PhoneNote(notice)
                        if screen.offersSignIn {
                            Button(Words.signIn, action: openAccount)
                        } else if screen.offersEmailConfirmation {
                            Button(Words.confirmEmail, action: openAccount)
                        }
                    }
                    .listRowBackground(Color.clear)
                }
                if let failure = screen.failure, failure != screen.notice {
                    Section {
                        PhoneNote(failure)
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .phoneSheet(title: screen.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Words.cancel) { dismiss() }
                        .accessibilityIdentifier(AccessibilityID.joinCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(screen.joinLabel) {
                        Task { if await screen.join() { dismiss() } }
                    }
                    .disabled(!screen.canJoin)
                    .accessibilityIdentifier(AccessibilityID.joinJoin)
                }
            }
        }
    }
}

/// The page a clicked invite link opens (`Workspace.open(_:)`): who invited
/// them and to what, the level and what it lets them do, how much they would
/// see, Your name, and Join. Signed out or not confirmed yet, the notice and
/// its button stand in place of Join. No Decline: a link has no invite to
/// decline, and Back takes the page down. Draws `JoinScreen`. Layout only.
struct PhoneInvitationView: View {
    @Bindable var screen: JoinScreen
    /// The window's rules. Join goes through them, so the group's page
    /// opens once in.
    let main: MainScreen
    @Binding var showingAccount: Bool
    private typealias Words = JoinScreen.Words

    var body: some View {
        List {
            if let invitation = screen.invitation {
                Section {
                    offer(invitation)
                }
                .listRowBackground(Palette.surface)
                Section {
                    PhoneField(Words.name) {
                        TextField(Words.name, text: $screen.myName, prompt: Text(Words.namePrompt))
                            .textInputAutocapitalization(.words)
                            .accessibilityIdentifier(AccessibilityID.invitationName)
                    }
                }
                .listRowBackground(Palette.surface)
                answer
            } else if let problem = screen.linkProblem {
                Section {
                    PhoneNote(problem)
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Palette.ground)
        .foregroundStyle(Palette.ink)
        .navigationTitle(screen.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Who invited them and to what, then what the server says it offers,
    /// once it has said.
    private func offer(_ invitation: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(invitation)
                .font(.title2.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            if let line = screen.levelLine {
                Text(marking(screen.levelTitle, in: line))
            }
            if let explanation = screen.levelExplanation {
                Text(explanation)
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let history = screen.historyLine {
                Text(history)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    /// Join, or what stands in its way and the button that deals with it.
    @ViewBuilder
    private var answer: some View {
        if let notice = screen.notice {
            Section {
                PhoneNote(notice)
                if screen.offersSignIn {
                    Button(Words.signIn) { showingAccount = true }
                        .accessibilityIdentifier(AccessibilityID.invitationSignIn)
                } else if screen.offersEmailConfirmation {
                    Button(Words.confirmEmail) { showingAccount = true }
                        .accessibilityIdentifier(AccessibilityID.invitationConfirmEmail)
                }
            }
            .listRowBackground(Color.clear)
        } else {
            Section {
                Button {
                    Task { await main.joinInvitation() }
                } label: {
                    Text(screen.joinLabel)
                        .font(.headline)
                        // White would not read on the dark mode green.
                        .foregroundStyle(Palette.ground)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!screen.canJoin)
                .accessibilityIdentifier(AccessibilityID.invitationJoin)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
        if let failure = screen.failure, failure != screen.notice {
            Section {
                PhoneNote(failure)
            }
            .listRowBackground(Color.clear)
        }
    }

    /// The line with the level's name in bold, so it stands out.
    private func marking(_ level: String?, in line: String) -> AttributedString {
        var text = AttributedString(line)
        if let level, let range = text.range(of: level) {
            text[range].font = .body.weight(.semibold)
        }
        return text
    }
}

#endif
