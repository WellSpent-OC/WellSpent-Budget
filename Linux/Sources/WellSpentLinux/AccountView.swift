import Foundation
import Observation
import SwiftCrossUI
import WellSpentAppCore

/// Draws `AccountFlow`: sign in, create an account, reset or change the
/// password, confirm the email, sign out. What each step holds, checks and
/// says lives in the shared flow, the same one the Mac's account sheet draws;
/// this is layout only.
struct AccountView: View {
    var sync: SyncCoordinator
    @Binding var isPresented: Bool
    @State var flow: AccountFlow

    private typealias Words = AccountFlow.Words

    init(sync: SyncCoordinator, isPresented: Binding<Bool>) {
        self.sync = sync
        _isPresented = isPresented
        _flow = State(wrappedValue: AccountFlow(actions: sync, email: sync.signInPrompt?.email,
                                                reason: sync.signInPrompt?.reason,
                                                afterSigningIn: { await sync.syncAll() }))
    }

    var body: some View {
        // Read here, so the question redraws the sheet: a binding's getter
        // runs outside the redraw's tracking.
        let askingEverywhere = flow.isAskingToSignOutEverywhere
        VStack(alignment: .leading, spacing: 12) {
            Text(flow.step.title)
                .font(.title3)
            if let notice = flow.notice {
                note(notice)
            }
            step
            if let failure = flow.currentFailure {
                Text(failure)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
            }
            note(Words.privacy)
            buttons
        }
        .padding(20)
        // Wider than the Mac's 440: GTK's buttons are roomier, and the account
        // step puts three in a row.
        .frame(width: 520)
        .onChange(of: flow.isFinished) {
            if flow.isFinished { isPresented = false }
        }
        // GTK's alert has a title and no message, so the two go together.
        .alert("\(Words.signOutEverywhereTitle)\n\n\(Words.signOutEverywhereMessage)",
               isPresented: Binding(get: { askingEverywhere },
                                    set: { if !$0 { flow.keepDevicesSignedIn() } })) {
            // Cancel first: GTK focuses the first button, so Return keeps it.
            Button(Words.cancel) { flow.keepDevicesSignedIn() }
            Button(Words.signOutEverywhereButton) { flow.signOutEverywhere() }
        }
    }

    @ViewBuilder
    private var step: some View {
        switch flow.step {
        case .signIn:
            field(Words.email, Binding(get: { flow.signIn.email }, set: { flow.signIn.email = $0 }),
                  problem: flow.signIn.problems[.email])
            field(Words.password, Binding(get: { flow.signIn.password }, set: { flow.signIn.password = $0 }),
                  secure: true)
            serverField
            HStack {
                Button(Words.createAccount) { flow.go(to: .signUp) }
                Spacer()
                Button(Words.forgotPassword) { flow.go(to: .forgotPassword) }
            }
            .disabled(flow.isWorking)

        case .signUp:
            field(Words.email, Binding(get: { flow.signUp.email }, set: { flow.signUp.email = $0 }),
                  problem: flow.signUp.problems[.email])
            field(Words.password, Binding(get: { flow.signUp.password }, set: { flow.signUp.password = $0 }),
                  secure: true, problem: flow.signUp.problems[.password])
            field(Words.confirmation,
                  Binding(get: { flow.signUp.confirmation }, set: { flow.signUp.confirmation = $0 }),
                  secure: true, problem: flow.signUp.problems[.confirmation])
            serverField

        case .forgotPassword:
            if flow.reset.step == .enterEmail {
                field(Words.email, Binding(get: { flow.reset.email }, set: { flow.reset.email = $0 }),
                      problem: flow.reset.problems[.email])
                serverField
            } else {
                note(flow.resetCodeText)
                field(Words.code, Binding(get: { flow.reset.code }, set: { flow.reset.code = $0 }),
                      problem: flow.reset.problems[.code])
                field(Words.newPassword, Binding(get: { flow.reset.password }, set: { flow.reset.password = $0 }),
                      secure: true, problem: flow.reset.problems[.password])
                field(Words.confirmation,
                      Binding(get: { flow.reset.confirmation }, set: { flow.reset.confirmation = $0 }),
                      secure: true, problem: flow.reset.problems[.confirmation])
                Button(Words.startOver) { flow.reset.startOver() }
                    .disabled(flow.isWorking)
            }

        case .confirmEmail:
            note(flow.confirmText)
            field(Words.code, Binding(get: { flow.confirm.code }, set: { flow.confirm.code = $0 }))
            Button(flow.sendCodeLabel) { Task { await flow.sendCode() } }
                .disabled(!flow.confirm.canSendCode)
            if let sent = flow.confirm.note {
                note(sent)
            }

        case .account:
            Text(flow.signedInAs)
            if flow.needsConfirming {
                note(ConfirmEmailScreen.reason)
                Button(Words.confirmEmail) { flow.go(to: .confirmEmail) }
                    .disabled(flow.isWorking)
            }
            HStack {
                Button(Words.changePassword) { flow.go(to: .changePassword) }
                Button(Words.signOut) { Task { await flow.signOut() } }
                Button(Words.signOutEverywhere) { flow.askToSignOutEverywhere() }
            }
            .disabled(flow.isWorking)

        case .changePassword:
            field(Words.currentPassword, Binding(get: { flow.change.current }, set: { flow.change.current = $0 }),
                  secure: true)
            field(Words.newPassword, Binding(get: { flow.change.password }, set: { flow.change.password = $0 }),
                  secure: true, problem: flow.change.problems[.password])
            field(Words.confirmation,
                  Binding(get: { flow.change.confirmation }, set: { flow.change.confirmation = $0 }),
                  secure: true, problem: flow.change.problems[.confirmation])
        }
    }

    private var buttons: some View {
        HStack {
            if let back = flow.back {
                Button(Words.back) { flow.go(to: back) }
                    .disabled(flow.isWorking)
            }
            Spacer()
            Button(flow.closeLabel) { flow.close() }
                .disabled(flow.isWorking)
            if let label = flow.submitLabel {
                Button(label) { Task { await flow.submit() } }
                    .disabled(!flow.canSubmit)
            }
        }
    }

    private var serverField: some View {
        field(Words.server, Binding(get: { sync.serverAddress }, set: { sync.serverAddress = $0 }))
    }

    private func field(_ label: String, _ text: Binding<String>, secure: Bool = false,
                       problem: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 12))
            if secure {
                SecureField(label, text: text)
            } else {
                TextField(label, text: text)
            }
            if let problem {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(.gray)
    }
}
