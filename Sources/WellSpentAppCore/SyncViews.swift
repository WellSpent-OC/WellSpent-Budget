// The Mac screens. SwiftUI exists only on Apple systems; the Linux app draws
// the same shared logic with its own screens.
#if canImport(SwiftUI)
import SwiftUI
import WellSpentCrypto

// MARK: - The toolbar buttons

/// Opens the account sheet: signing in when signed out, the account when
/// signed in. Signing out is in the sheet, so a stray click never does it.
struct AccountButton: View {
    @Bindable var sync: SyncCoordinator
    @Binding var showingAccount: Bool

    var body: some View {
        Button {
            showingAccount = true
        } label: {
            Label(Self.title(account: sync.account), systemImage: Self.icon(account: sync.account))
        }
        .disabled(sync.isBusy)
        .help(Self.help(account: sync.account))
        .accessibilityIdentifier(AccessibilityID.toolbarAccount)
    }

    static func title(account: String?) -> String {
        SyncWording.accountTitle(signedIn: account != nil)
    }

    static func icon(account: String?) -> String {
        account == nil ? "person.crop.circle.badge.plus" : "person.crop.circle"
    }

    static func help(account: String?) -> String {
        SyncWording.accountHelp(account: account)
    }
}

/// Syncs, and while it is working it says so. Shown only while signed in: signed
/// out, the account button beside it is the way in.
struct SyncButton: View {
    @Bindable var sync: SyncCoordinator
    @Binding var showingAccount: Bool

    var body: some View {
        Button {
            // A session, not the signed-in state: a failed sync is retried.
            if sync.account != nil {
                Task { await sync.syncAll() }
            } else {
                showingAccount = true
            }
        } label: {
            Label {
                Text(title)
            } icon: {
                SpinningIcon(systemName: icon, spinning: Self.isSpinning(for: sync.state))
            }
        }
        .disabled(sync.isBusy)
        .help(help)
        .accessibilityIdentifier(AccessibilityID.toolbarSync)
    }

    static func isSpinning(for state: SyncCoordinator.State) -> Bool {
        SyncWording.showsProgress(for: state)
    }

    var title: String { Self.title(for: sync.state) }
    var icon: String { Self.icon(for: sync.state) }
    var help: String { Self.help(for: sync.state, lastSyncedAt: sync.lastSyncedAt) }

    static func title(for state: SyncCoordinator.State) -> String {
        SyncWording.syncTitle(for: state)
    }

    static func icon(for state: SyncCoordinator.State) -> String {
        switch state {
        case .signedOut: return "person.crop.circle.badge.plus"
        case .busy, .signedIn: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.triangle"
        }
    }

    static func help(for state: SyncCoordinator.State, lastSyncedAt: Date?) -> String {
        SyncWording.syncHelp(for: state, lastSyncedAt: lastSyncedAt)
    }
}

/// An SF Symbol that turns one full circle a second while `spinning`.
///
/// Driven by a clock rather than a repeating animation. A repeat-forever
/// animation keeps going after its condition turns false unless it is taken
/// apart carefully; a clock just stops, and the icon settles back upright.
struct SpinningIcon: View {
    let systemName: String
    let spinning: Bool

    var body: some View {
        TimelineView(.animation(paused: !spinning)) { context in
            Image(systemName: systemName)
                .rotationEffect(.degrees(spinning ? Self.angle(at: context.date) : 0))
        }
    }

    /// Clockwise, one turn a second.
    static func angle(at date: Date) -> Double {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360
    }
}

// MARK: - The account sheet

/// Draws `AccountFlow`. What each step holds, checks and says lives there,
/// shared with every desktop; this is layout only.
struct AccountSheet: View {
    @Bindable var sync: SyncCoordinator
    @State private var flow: AccountFlow
    @Environment(\.dismiss) private var dismiss

    init(sync: SyncCoordinator) {
        self.sync = sync
        _flow = State(initialValue: AccountFlow(actions: sync, email: sync.signInPrompt?.email,
                                                reason: sync.signInPrompt?.reason,
                                                afterSigningIn: { await sync.syncAll() }))
    }

    private typealias Words = AccountFlow.Words

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(flow.step.title)
                .font(.system(size: 17, weight: .semibold))
            if let notice = flow.notice {
                note(notice)
            }
            step
            if let failure = flow.currentFailure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(Words.privacy)
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            buttons
        }
        .padding(20)
        .frame(width: 440)
        .onChange(of: flow.isFinished) { _, finished in
            if finished { dismiss() }
        }
        .confirmationDialog(Words.signOutEverywhereTitle,
                            isPresented: Binding(get: { flow.isAskingToSignOutEverywhere },
                                                 set: { if !$0 { flow.keepDevicesSignedIn() } })) {
            Button(Words.signOutEverywhereButton, role: .destructive) {
                flow.signOutEverywhere()
            }
            Button(Words.cancel, role: .cancel) { flow.keepDevicesSignedIn() }
        } message: {
            Text(Words.signOutEverywhereMessage)
        }
    }

    @ViewBuilder
    private var step: some View {
        switch flow.step {
        case .signIn:
            Form {
                field(Words.email, Bindable(flow.signIn).email, id: AccessibilityID.accountEmail,
                      problem: flow.signIn.problems[.email])
                field(Words.password, Bindable(flow.signIn).password, id: AccessibilityID.accountPassword,
                      secure: true)
                serverField
            }
            .formStyle(.grouped)
            HStack {
                Button(Words.createAccount) { flow.go(to: .signUp) }
                    .accessibilityIdentifier(AccessibilityID.accountCreateAccount)
                Spacer()
                Button(Words.forgotPassword) { flow.go(to: .forgotPassword) }
                    .accessibilityIdentifier(AccessibilityID.accountForgotPassword)
            }
            .buttonStyle(.link)
            .font(.system(size: 12))
            .disabled(flow.isWorking)

        case .signUp:
            Form {
                field(Words.email, Bindable(flow.signUp).email, id: AccessibilityID.accountEmail,
                      problem: flow.signUp.problems[.email])
                field(Words.password, Bindable(flow.signUp).password, id: AccessibilityID.accountPassword,
                      secure: true, problem: flow.signUp.problems[.password])
                field(Words.confirmation, Bindable(flow.signUp).confirmation, id: AccessibilityID.accountConfirmation,
                      secure: true, problem: flow.signUp.problems[.confirmation])
                serverField
            }
            .formStyle(.grouped)

        case .forgotPassword:
            if flow.reset.step == .enterEmail {
                Form {
                    field(Words.email, Bindable(flow.reset).email, id: AccessibilityID.accountEmail,
                          problem: flow.reset.problems[.email])
                    serverField
                }
                .formStyle(.grouped)
            } else {
                note(flow.resetCodeText)
                Form {
                    field(Words.code, Bindable(flow.reset).code, id: AccessibilityID.accountCode,
                          problem: flow.reset.problems[.code])
                    field(Words.newPassword, Bindable(flow.reset).password, id: AccessibilityID.accountNewPassword,
                          secure: true, problem: flow.reset.problems[.password])
                    field(Words.confirmation, Bindable(flow.reset).confirmation,
                          id: AccessibilityID.accountConfirmation, secure: true,
                          problem: flow.reset.problems[.confirmation])
                }
                .formStyle(.grouped)
                Button(Words.startOver) { flow.reset.startOver() }
                    .accessibilityIdentifier(AccessibilityID.accountStartOver)
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                    .disabled(flow.isWorking)
            }

        case .confirmEmail:
            note(flow.confirmText)
            Form {
                field(Words.code, Bindable(flow.confirm).code, id: AccessibilityID.accountCode)
            }
            .formStyle(.grouped)
            Button(flow.sendCodeLabel) { Task { await flow.sendCode() } }
                .disabled(!flow.confirm.canSendCode)
                .accessibilityIdentifier(AccessibilityID.accountSendCode)
            if let sent = flow.confirm.note {
                note(sent)
            }

        case .account:
            Text(flow.signedInAs)
                .font(.system(size: 13))
            if flow.needsConfirming {
                note(ConfirmEmailScreen.reason)
                Button(Words.confirmEmail) { flow.go(to: .confirmEmail) }
                    .disabled(flow.isWorking)
                    .accessibilityIdentifier(AccessibilityID.accountConfirmEmail)
            }
            HStack {
                Button(Words.changePassword) { flow.go(to: .changePassword) }
                    .accessibilityIdentifier(AccessibilityID.accountChangePassword)
                Button(Words.signOut) { Task { await flow.signOut() } }
                    .accessibilityIdentifier(AccessibilityID.accountSignOut)
                Button(Words.signOutEverywhere) { flow.askToSignOutEverywhere() }
                    .accessibilityIdentifier(AccessibilityID.accountSignOutEverywhere)
            }
            .disabled(flow.isWorking)

        case .changePassword:
            Form {
                field(Words.currentPassword, Bindable(flow.change).current,
                      id: AccessibilityID.accountCurrentPassword, secure: true)
                field(Words.newPassword, Bindable(flow.change).password, id: AccessibilityID.accountNewPassword,
                      secure: true, problem: flow.change.problems[.password])
                field(Words.confirmation, Bindable(flow.change).confirmation,
                      id: AccessibilityID.accountConfirmation, secure: true,
                      problem: flow.change.problems[.confirmation])
            }
            .formStyle(.grouped)
        }
    }

    private var buttons: some View {
        HStack {
            if let back = flow.back {
                Button(Words.back) { flow.go(to: back) }
                    .disabled(flow.isWorking)
                    .accessibilityIdentifier(AccessibilityID.accountBack)
            }
            Spacer()
            if let label = flow.submitLabel {
                Button(flow.closeLabel) { flow.close() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(flow.isWorking)
                    .accessibilityIdentifier(AccessibilityID.accountClose)
                Button(label) { Task { await flow.submit() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!flow.canSubmit)
                    .accessibilityIdentifier(AccessibilityID.accountSubmit)
            } else {
                // The account step has no main button: closing is the default.
                Button(flow.closeLabel) { flow.close() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(flow.isWorking)
                    .accessibilityIdentifier(AccessibilityID.accountClose)
            }
        }
    }

    private var serverField: some View {
        TextField(Words.server, text: Binding(get: { sync.serverAddress },
                                              set: { sync.serverAddress = $0 }))
            .accessibilityIdentifier(AccessibilityID.accountServer)
    }

    /// `id` is the name the UI test finds the field by. It goes on the field
    /// itself, not on the stack around it.
    private func field(_ label: String, _ text: Binding<String>, id: String, secure: Bool = false,
                       problem: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if secure {
                SecureField(label, text: text)
                    .accessibilityIdentifier(id)
            } else {
                TextField(label, text: text)
                    .accessibilityIdentifier(id)
            }
            if let problem {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.warning)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#endif
