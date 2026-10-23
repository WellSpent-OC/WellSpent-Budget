import Foundation
import Observation
import SwiftCrossUI
import WellSpentAppCore
import WellSpentCrypto
import WellSpentModel
import WellSpentSync

// Sharing on Linux: the shared email invitation and legacy join screens.
// A group's people are on its page (GroupPageView). What each holds, checks
// and says is the Mac's; this is layout only.

// MARK: - Share

struct ShareView: View {
    @State var screen: EmailInviteScreen
    var close: () -> Void
    private typealias Words = EmailInviteScreen.Words

    init(screen: EmailInviteScreen, close: @escaping () -> Void) {
        _screen = State(wrappedValue: screen)
        self.close = close
    }

    private var roleChoices: [Choice<InviteRole>] {
        screen.roles.map { Choice(value: $0, description: $0.title) }
    }

    private let historyChoices = [Choice(value: HistoryAccess.all, description: Words.historyAll),
                                  Choice(value: HistoryAccess.fromNow, description: Words.historyFromNow)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(screen.title)
                .font(.system(size: 17, weight: .semibold))
            if let message = screen.sentMessage {
                sent(message)
            } else {
                form.disabled(screen.isWorking)
            }
        }
        .padding(20)
        .frame(width: 480)
        .foregroundColor(Palette.ink)
        .background(Palette.surface)
    }

    @ViewBuilder
    private var form: some View {
        Field(label: Words.email, prompt: Words.emailPrompt,
              text: Binding(get: { screen.email }, set: { screen.email = $0 }))
        Field(label: Words.inviteeName, prompt: Words.inviteeNamePrompt,
              text: Binding(get: { screen.inviteeName }, set: { screen.inviteeName = $0 }))
        Field(label: Words.name, prompt: Words.namePrompt,
              text: Binding(get: { screen.myName }, set: { screen.myName = $0 }))
        if !screen.roles.isEmpty {
            Text(Words.role)
                .font(.system(size: 12))
            Picker(of: roleChoices, selection: Binding(
                get: { roleChoices.first { $0.value == screen.role } },
                set: { if let role = $0?.value { screen.role = role } }))
        }
        Text(Words.history)
            .font(.system(size: 12))
        Picker(of: historyChoices, selection: Binding(
            get: { historyChoices.first { $0.value == screen.history } },
            set: { if let history = $0?.value { screen.history = history } }))
        Note(screen.role.explanation)
        if let notice = screen.notice {
            Note(notice, warning: true)
        } else if let failure = screen.failure {
            Note(failure, warning: true)
        }
        Note(screen.note)
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            Spacer()
            Button(Words.cancel) { close() }
            Button(screen.sendLabel) { Task { await screen.send() } }
                .defaultAction()
                .disabled(!screen.canSend)
        }
    }

    @ViewBuilder
    private func sent(_ message: String) -> some View {
        Text(message)
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            Spacer()
            Button(Words.done) { close() }
                .defaultAction()
        }
    }
}

// MARK: - Join

struct JoinView: View {
    @State var screen: JoinScreen
    var close: () -> Void
    /// Opens the account sheet, to confirm the email.
    var openAccount: () -> Void
    private typealias Words = JoinScreen.Words

    init(screen: JoinScreen, close: @escaping () -> Void, openAccount: @escaping () -> Void) {
        _screen = State(wrappedValue: screen)
        self.close = close
        self.openAccount = openAccount
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(screen.title)
                .font(.system(size: 17, weight: .semibold))
            Field(label: Words.link, prompt: Words.linkPrompt,
                  text: Binding(get: { screen.linkText }, set: { screen.linkText = $0 }))
            Field(label: Words.name, prompt: Words.namePrompt,
                  text: Binding(get: { screen.myName }, set: { screen.myName = $0 }))
                .disabled(screen.isAddressedInvitation)
            if let invitation = screen.invitation {
                Text(invitation)
            } else if let problem = screen.linkProblem {
                Note(problem, warning: true)
            }
            if let notice = screen.notice {
                Note(notice, warning: true)
                if screen.offersEmailConfirmation {
                    Button(Words.confirmEmail) { openAccount() }
                }
            }
            if let failure = screen.failure, failure != screen.notice {
                Note(failure, warning: true)
            }
            HStack {
                Spacer()
                Button(Words.cancel) { close() }
                Button(screen.joinLabel) {
                    Task { if await screen.join() { close() } }
                }
                .defaultAction()
                .disabled(!screen.canJoin)
            }
        }
        .padding(20)
        .frame(width: 480)
        .foregroundColor(Palette.ink)
        .background(Palette.surface)
        .task(id: screen.linkText) { await screen.lookUp() }
    }
}
