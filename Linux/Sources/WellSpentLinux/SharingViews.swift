import Foundation
import Observation
import SwiftCrossUI
import WellSpentAppCore
import WellSpentCrypto
import WellSpentLinuxNative
import WellSpentModel
import WellSpentSync

// Sharing on Linux: the shared ShareScreen, JoinScreen and MembersScreen,
// drawn with GTK. What each holds, checks and says is the Mac's; this is
// layout only.

// MARK: - Share

struct ShareView: View {
    @State var screen: ShareScreen
    var close: () -> Void
    private typealias Words = ShareScreen.Words

    init(screen: ShareScreen, close: @escaping () -> Void) {
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
                .font(.title3)
            if let link = screen.link {
                created(link)
            } else {
                form
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    @ViewBuilder
    private var form: some View {
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
        HStack {
            Note(Words.linkNote)
            Spacer()
            Button(Words.cancel) { close() }
            Button(screen.createLabel) { Task { await screen.create() } }
                .disabled(!screen.canCreate)
        }
    }

    @ViewBuilder
    private func created(_ link: InviteLink) -> some View {
        Text(link.url)
            .font(.system(size: 11))
            .textSelectionEnabled()
        Note(SyncWording.inviteNote)
        HStack {
            Button(Words.copyLink) { wellspent_clipboard_set_text(link.url) }
            Spacer()
            Button(Words.done) { close() }
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
                .font(.title3)
            Field(label: Words.link, prompt: Words.linkPrompt,
                  text: Binding(get: { screen.linkText }, set: { screen.linkText = $0 }))
            Field(label: Words.name, prompt: Words.namePrompt,
                  text: Binding(get: { screen.myName }, set: { screen.myName = $0 }))
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
                .disabled(!screen.canJoin)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

// MARK: - People

struct MembersView: View {
    @State var screen: MembersScreen
    let group: BudgetGroup
    var model: AppModel
    var sync: SyncCoordinator
    var close: () -> Void
    /// Opens the share sheet for this group.
    var invite: () -> Void
    @State var leaving: PendingDelete?
    private typealias Words = MembersScreen.Words

    init(screen: MembersScreen, group: BudgetGroup, model: AppModel, sync: SyncCoordinator,
         close: @escaping () -> Void, invite: @escaping () -> Void) {
        _screen = State(wrappedValue: screen)
        self.group = group
        self.model = model
        self.sync = sync
        self.close = close
        self.invite = invite
    }

    var body: some View {
        // Copies the alerts' buttons keep: GTK closes an alert, which clears
        // its question, before the button's action runs.
        let removing = screen.removing
        let leavingNow = leaving
        VStack(alignment: .leading, spacing: 12) {
            Text(screen.title)
                .font(.title3)
            ForEach(screen.rows) { row in
                person(row)
            }
            if let failure = screen.failure {
                Note(failure, warning: true)
            }
            HStack {
                if screen.mayLeave {
                    Button(Words.leave) {
                        // Always a leave, never a delete for everyone, whatever
                        // this person's level.
                        leaving = .group(group, budgets: model.summaries[group.id]?.count ?? 0,
                                         reach: .thisMacOnly)
                    }
                }
                Spacer()
                if screen.mayInvite {
                    Button(Words.invite) { invite() }
                }
                Button(Words.done) { close() }
            }
        }
        .padding(20)
        .frame(width: 520)
        // Whoever joined since the last sync shows at once.
        .task { await screen.refresh() }
        .alert(removeQuestion, isPresented: Binding(get: { removing != nil },
                                                    set: { if !$0 { screen.keepThem() } })) {
            Button(Words.removeButton) {
                if let removing { screen.remove(removing.id) }
            }
            Button(Words.cancel) { screen.keepThem() }
        }
        .alert(leaveQuestion, isPresented: Binding(get: { leavingNow != nil }, set: { if !$0 { leaving = nil } })) {
            Button(Words.leaveButton) {
                if let leavingNow {
                    leaving = nil
                    leavingNow.confirm(model: model, sync: sync)
                    close()
                }
            }
            Button(Words.cancel) { leaving = nil }
        }
    }

    /// GTK's alert has a title and no message, so the two go together.
    private var removeQuestion: String {
        guard let title = screen.removeQuestion, let message = screen.removeMessage else { return "" }
        return "\(title)\n\n\(message)"
    }

    private var leaveQuestion: String {
        "\(Words.leaveTitle(group.name))\n\n\(screen.leaveMessage)"
    }

    private func levelChoices(_ row: MembersScreen.Row) -> [Choice<AccessLevel>] {
        row.levelChoices.map { Choice(value: $0, description: Words.levelTitle($0)) }
    }

    private func person(_ row: MembersScreen.Row) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.label)
                Text(Words.levelExplanation(row.level))
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
            }
            Spacer()
            if row.levelChoices.isEmpty {
                Text(row.levelTitle)
                    .foregroundColor(.gray)
            } else {
                Picker(of: levelChoices(row), selection: Binding(
                    get: { levelChoices(row).first { $0.value == row.level } },
                    set: { choice in
                        guard let level = choice?.value else { return }
                        Task { await screen.setLevel(level, for: row.id) }
                    }))
                    .disabled(screen.isWorking)
            }
            if row.mayRemove {
                Button(Words.remove) { screen.askToRemove(row.id) }
                    .disabled(screen.isWorking)
            }
        }
    }
}
