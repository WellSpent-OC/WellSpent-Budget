import Foundation
import Observation
import SwiftCrossUI
import WellSpentAppCore
import WellSpentCrypto
import WellSpentModel
import WellSpentSync

// A group's page on Linux: the shared MembersScreen, drawn with GTK where a
// budget opens. What it holds, checks and says is the Mac's; this is layout
// only.

/// The open page's people, made once each time a group's page opens, and
/// again after a rename, so its words name the group as it is now. The Mac
/// gets a page of its own per group from the view's identity; SwiftCrossUI
/// keeps a view's state by its place in the window, so it is kept here.
@MainActor
final class OpenGroupPage {
    private var screen: MembersScreen?

    /// The people for the group whose page shows, or nil when none does.
    func screen(for group: BudgetGroup?, sync: SyncCoordinator) -> MembersScreen? {
        guard let group else {
            screen = nil
            return nil
        }
        if let screen, screen.group == group.id, screen.groupName == group.name { return screen }
        let made = MembersScreen(actions: sync, group: group.id, groupName: group.name)
        screen = made
        return made
    }
}

/// Draws a group's page: its name, the line under it, its money for the
/// month, and its people, with what this person may change. A click on the
/// group's name opens it, and so does People… in its menu. The money is
/// MainScreen's. Leave Group… asks the window's own question.
struct GroupPageView: View {
    let screen: MembersScreen
    let group: BudgetGroup
    /// The window's rules, and its question before a leave.
    let main: MainScreen
    var sync: SyncCoordinator
    /// Opens the Share sheet for this group.
    var invite: () -> Void
    @State private var cancellingInvite: ServerInvite?
    private typealias Words = MembersScreen.Words

    var body: some View {
        // A copy the alert's buttons keep: GTK closes an alert, which clears
        // its question, before the button's action runs.
        let removing = screen.removing
        let cancelling = cancellingInvite
        VStack(alignment: .leading, spacing: 0) {
            // After a removal, a quiet line at the top, where Undo sits on a
            // budget. No pop-up.
            if let removed = screen.removedNote {
                HStack {
                    Text(removed)
                        .font(.system(size: 12))
                        .foregroundColor(Palette.ink)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Palette.sidebar)
                Palette.line.frame(height: 1)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    // Every budget in the group added up for the month, above
                    // its people. None for a group with no budgets.
                    if let money = main.money(of: group.id) {
                        GroupMoneySection(money: money)
                    }
                    if !screen.rows.isEmpty || !screen.pendingInvites.isEmpty {
                        people
                    }
                    if let failure = screen.failure {
                        Note(failure, warning: true)
                    }
                    if screen.mayLeave {
                        Button(Words.leave) { main.askToLeave(group) }
                            .disabled(screen.isWorking)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundColor(Palette.ink)
        .background(Palette.surface)
        // Whoever joined since the last sync shows as the page opens, and
        // after each sync while it stays open.
        .task(id: ObjectIdentifier(screen)) { await screen.refresh() }
        .onChange(of: sync.lastSyncedAt) { screen.reload() }
        .alert(removeQuestion, isPresented: Binding(get: { removing != nil },
                                                    set: { if !$0 { screen.keepThem() } })) {
            // Cancel first: GTK focuses the first button, so Return keeps it.
            Button(Words.cancel) { screen.keepThem() }
            Button(Words.removeButton) {
                if let removing { screen.remove(removing.id) }
            }
        }
        .alert(cancelInviteQuestion(cancelling), isPresented: Binding(get: { cancelling != nil },
                                                                     set: { if !$0 { cancellingInvite = nil } })) {
            Button(Words.cancel) { cancellingInvite = nil }
            Button(EmailInvitationWords.cancelInvite) {
                if let cancelling { Task { await screen.cancelInvite(cancelling.id) } }
            }
        }
    }

    /// GTK's alert has a title and no message, so the two go together.
    private var removeQuestion: String {
        guard let title = screen.removeQuestion, let message = screen.removeMessage else { return "" }
        return "\(title)\n\n\(message)"
    }

    private func cancelInviteQuestion(_ invitation: ServerInvite?) -> String {
        guard let invitation else { return "" }
        let recipient = EmailInvitationWords.recipient(invitation)
        return "\(EmailInvitationWords.cancelQuestion(recipient))\n\n\(EmailInvitationWords.cancelMessage)"
    }

    /// The name, with Invite Someone… on the right, and the line under it.
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(group.name)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(Palette.ink)
                Spacer()
                if screen.mayInvite {
                    Button(Words.invite) { invite() }
                }
            }
            Text(screen.summary)
                .font(.system(size: 12))
                .foregroundColor(Palette.muted)
        }
    }

    private var people: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Words.people.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Palette.muted)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(screen.rows) { row in
                    person(row)
                    if row.id != screen.rows.last?.id || !screen.pendingInvites.isEmpty {
                        Palette.line.frame(height: 1)
                    }
                }
                ForEach(screen.pendingInvites) { invitation in
                    pendingInvitation(invitation)
                    if invitation.id != screen.pendingInvites.last?.id {
                        Palette.line.frame(height: 1)
                    }
                }
            }
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Palette.sidebar))
        }
    }

    /// Invitations stay apart from members: pending is not membership, and
    /// rejecting requires the sender to make a fresh invitation.
    private func pendingInvitation(_ invitation: ServerInvite) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(EmailInvitationWords.recipient(invitation))
                    .font(.system(size: 13))
                    .foregroundColor(Palette.muted)
                if let email = invitation.email {
                    Text(email)
                        .font(.system(size: 11))
                        .foregroundColor(Palette.muted)
                }
            }
            Spacer()
            Text(EmailInvitationWords.status(invitation))
                .font(.system(size: 11))
                .foregroundColor(Palette.muted)
            if screen.canCancelInvite(invitation.id) {
                Button(EmailInvitationWords.cancelInvite) { cancellingInvite = invitation }
                    .disabled(screen.isWorking)
            }
        }
        .padding(.vertical, 8)
    }

    /// A person's level as the page holds it now, not as the row it was drawn
    /// with said.
    private func level(of person: UserID) -> AccessLevel? {
        screen.rows.first { $0.id == person }?.level
    }

    private func levelChoices(_ row: MembersScreen.Row) -> [Choice<AccessLevel>] {
        row.levelChoices.map { Choice(value: $0, description: Words.levelTitle($0)) }
    }

    /// One person: their name, what their level lets them do, and the level.
    /// The picker and Remove… show only where this person may change them.
    /// Anyone else's level is a small label.
    private func person(_ row: MembersScreen.Row) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.label)
                    .font(.system(size: 13))
                    .foregroundColor(Palette.ink)
                Text(Words.levelExplanation(row.level))
                    .font(.system(size: 11))
                    .foregroundColor(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if row.levelChoices.isEmpty {
                Text(row.levelTitle)
                    .font(.system(size: 11))
                    .foregroundColor(Palette.muted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Palette.muted.opacity(0.4))
                    }
            } else {
                Picker(of: levelChoices(row), selection: Binding(
                    // Read fresh, as the import review's lists are: an old row
                    // laid out again would set the list back, and undo a change.
                    get: { levelChoices(row).first { $0.value == level(of: row.id) } },
                    set: { choice in
                        guard let level = choice?.value else { return }
                        Task { await screen.setLevel(level, for: row.id) }
                    }))
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
