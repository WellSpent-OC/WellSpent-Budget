// The iPhone's screens, built the iPhone's way. Layout only.
#if os(iOS)
import SwiftUI
import WellSpentCrypto

/// The account, from the foot of Home: signing in, signing up, confirming the
/// email, a forgotten password, and once signed in a list of what can be done.
/// Draws `AccountFlow`. What each step holds, checks and says lives there,
/// shared with every app. Layout only.
struct PhoneAccountSheet: View {
    @Bindable var sync: SyncCoordinator
    @State private var flow: AccountFlow
    @Environment(\.dismiss) private var dismiss
    private typealias Words = AccountFlow.Words

    init(sync: SyncCoordinator) {
        self.sync = sync
        _flow = State(initialValue: AccountFlow(actions: sync, email: sync.signInPrompt?.email,
                                                reason: sync.signInPrompt?.reason,
                                                afterSigningIn: { await sync.syncAll() }))
    }

    var body: some View {
        NavigationStack {
            Form {
                if let notice = flow.notice {
                    Section { note(notice) }
                        .listRowBackground(Palette.surface)
                }
                step
                if let failure = flow.currentFailure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(Palette.warning)
                    }
                    .listRowBackground(Palette.surface)
                }
                Section {
                } footer: {
                    Text(Words.privacy)
                }
            }
            .phoneSheet(title: flow.step.title)
            .disabled(flow.isWorking)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { leadingButton }
                ToolbarItem(placement: .confirmationAction) { trailingButton }
            }
        }
        // Closing only ends the sheet, so a swipe down is the same as Cancel,
        // except while something is being sent.
        .interactiveDismissDisabled(flow.isWorking)
        .onChange(of: flow.isFinished) { _, finished in
            if finished { dismiss() }
        }
        .confirmationDialog(Words.signOutEverywhereTitle,
                            isPresented: Binding(get: { flow.isAskingToSignOutEverywhere },
                                                 set: { if !$0 { flow.keepDevicesSignedIn() } }),
                            titleVisibility: .visible) {
            Button(Words.signOutEverywhereButton, role: .destructive) { flow.signOutEverywhere() }
            Button(Words.cancel, role: .cancel) { flow.keepDevicesSignedIn() }
        } message: {
            Text(Words.signOutEverywhereMessage)
        }
    }

    /// Back to the step before, or else Cancel. The account step has only
    /// Done, on the right.
    @ViewBuilder
    private var leadingButton: some View {
        if let back = flow.back {
            Button(Words.back) { flow.go(to: back) }
                .disabled(flow.isWorking)
                .accessibilityIdentifier(AccessibilityID.accountBack)
        } else if flow.submitLabel != nil {
            Button(flow.closeLabel) { flow.close() }
                .disabled(flow.isWorking)
                .accessibilityIdentifier(AccessibilityID.accountClose)
        }
    }

    @ViewBuilder
    private var trailingButton: some View {
        if let label = flow.submitLabel {
            Button(label) { Task { await flow.submit() } }
                .disabled(!flow.canSubmit)
                .accessibilityIdentifier(AccessibilityID.accountSubmit)
        } else {
            Button(flow.closeLabel) { flow.close() }
                .disabled(flow.isWorking)
                .accessibilityIdentifier(AccessibilityID.accountClose)
        }
    }

    @ViewBuilder
    private var step: some View {
        switch flow.step {
        case .signIn:
            Section {
                field(Words.email, Bindable(flow.signIn).email, id: AccessibilityID.accountEmail, kind: .email,
                      problem: flow.signIn.problems[.email])
                field(Words.password, Bindable(flow.signIn).password, id: AccessibilityID.accountPassword,
                      kind: .password)
                serverField
            }
            .listRowBackground(Palette.surface)
            Section {
                Button(Words.createAccount) { flow.go(to: .signUp) }
                    .accessibilityIdentifier(AccessibilityID.accountCreateAccount)
                Button(Words.forgotPassword) { flow.go(to: .forgotPassword) }
                    .accessibilityIdentifier(AccessibilityID.accountForgotPassword)
            }
            .listRowBackground(Palette.surface)

        case .signUp:
            Section {
                field(Words.email, Bindable(flow.signUp).email, id: AccessibilityID.accountEmail, kind: .email,
                      problem: flow.signUp.problems[.email])
                field(Words.password, Bindable(flow.signUp).password, id: AccessibilityID.accountPassword,
                      kind: .newPassword, problem: flow.signUp.problems[.password])
                field(Words.confirmation, Bindable(flow.signUp).confirmation, id: AccessibilityID.accountConfirmation,
                      kind: .newPassword, problem: flow.signUp.problems[.confirmation])
                serverField
            }
            .listRowBackground(Palette.surface)

        case .forgotPassword:
            if flow.reset.step == .enterEmail {
                Section {
                    field(Words.email, Bindable(flow.reset).email, id: AccessibilityID.accountEmail, kind: .email,
                          problem: flow.reset.problems[.email])
                    serverField
                }
                .listRowBackground(Palette.surface)
            } else {
                Section {
                    note(flow.resetCodeText)
                    field(Words.code, Bindable(flow.reset).code, id: AccessibilityID.accountCode, kind: .code,
                          problem: flow.reset.problems[.code])
                    field(Words.newPassword, Bindable(flow.reset).password, id: AccessibilityID.accountNewPassword,
                          kind: .newPassword, problem: flow.reset.problems[.password])
                    field(Words.confirmation, Bindable(flow.reset).confirmation,
                          id: AccessibilityID.accountConfirmation, kind: .newPassword,
                          problem: flow.reset.problems[.confirmation])
                }
                .listRowBackground(Palette.surface)
                Section {
                    Button(Words.startOver) { flow.reset.startOver() }
                        .accessibilityIdentifier(AccessibilityID.accountStartOver)
                }
                .listRowBackground(Palette.surface)
            }

        case .confirmEmail:
            Section {
                note(flow.confirmText)
                field(Words.code, Bindable(flow.confirm).code, id: AccessibilityID.accountCode, kind: .code)
            }
            .listRowBackground(Palette.surface)
            Section {
                Button(flow.sendCodeLabel) { Task { await flow.sendCode() } }
                    .disabled(!flow.confirm.canSendCode)
                    .accessibilityIdentifier(AccessibilityID.accountSendCode)
                if let sent = flow.confirm.note {
                    note(sent)
                }
            }
            .listRowBackground(Palette.surface)

        case .account:
            Section {
                Text(flow.signedInAs)
                if flow.needsConfirming {
                    note(ConfirmEmailScreen.reason)
                    Button(Words.confirmEmail) { flow.go(to: .confirmEmail) }
                        .accessibilityIdentifier(AccessibilityID.accountConfirmEmail)
                }
            }
            .listRowBackground(Palette.surface)
            Section {
                Button(Words.changePassword) { flow.go(to: .changePassword) }
                    .accessibilityIdentifier(AccessibilityID.accountChangePassword)
                Button(Words.signOut) { Task { await flow.signOut() } }
                    .accessibilityIdentifier(AccessibilityID.accountSignOut)
                Button(Words.signOutEverywhere, role: .destructive) { flow.askToSignOutEverywhere() }
                    .accessibilityIdentifier(AccessibilityID.accountSignOutEverywhere)
            }
            .listRowBackground(Palette.surface)

        case .changePassword:
            Section {
                field(Words.currentPassword, Bindable(flow.change).current,
                      id: AccessibilityID.accountCurrentPassword, kind: .password)
                field(Words.newPassword, Bindable(flow.change).password, id: AccessibilityID.accountNewPassword,
                      kind: .newPassword, problem: flow.change.problems[.password])
                field(Words.confirmation, Bindable(flow.change).confirmation,
                      id: AccessibilityID.accountConfirmation, kind: .newPassword,
                      problem: flow.change.problems[.confirmation])
            }
            .listRowBackground(Palette.surface)
        }
    }

    private var serverField: some View {
        field(Words.server, Binding(get: { sync.serverAddress }, set: { sync.serverAddress = $0 }),
              id: AccessibilityID.accountServer, kind: .server)
    }

    /// What a field holds, for the phone's keyboard and its password filling.
    private enum Kind {
        case email, password, newPassword, code, server
    }

    /// `id` is the name the UI test finds the field by. It goes on the field
    /// itself, not on the stack around it.
    private func field(_ label: String, _ text: Binding<String>, id: String, kind: Kind,
                       problem: String? = nil) -> some View {
        PhoneField(label) {
            VStack(alignment: .leading, spacing: 4) {
                switch kind {
                case .password, .newPassword:
                    SecureField(label, text: text)
                        .textContentType(kind == .password ? .password : .newPassword)
                        .accessibilityIdentifier(id)
                case .email:
                    TextField(label, text: text)
                        .keyboardType(.emailAddress)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier(id)
                case .code:
                    // A code is eight letters and numbers, so the keyboard has
                    // both, in capitals.
                    TextField(label, text: text)
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .textContentType(.oneTimeCode)
                        .accessibilityIdentifier(id)
                case .server:
                    TextField(label, text: text)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier(id)
                }
                if let problem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(Palette.warning)
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Palette.muted)
    }
}

#endif
