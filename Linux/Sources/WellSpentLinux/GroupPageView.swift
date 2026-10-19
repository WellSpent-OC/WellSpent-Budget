import Foundation
import Observation
import SwiftCrossUI
import WellSpentAppCore
import WellSpentCrypto
import WellSpentModel

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

/// Draws a group's page: its name, the line under it, and its people, with
/// what this person may change. A click on the group's name opens it, and so
/// does People… in its menu. Leave Group… asks the window's own question.
struct GroupPageView: View {
    let screen: MembersScreen
    let group: BudgetGroup
    /// The window's rules, and its question before a leave.
    let main: MainScreen
    var sync: SyncCoordinator
    /// Opens the Share sheet for this group.
    var invite: () -> Void
    private typealias Words = MembersScreen.Words

    var body: some View {
        // A copy the alert's buttons keep: GTK closes an alert, which clears
        // its question, before the button's action runs.
        let removing = screen.removing
        VStack(alignment: .leading, spacing: 12) {
            // After a removal, a quiet line at the top, where Undo sits on a
            // budget. No pop-up.
            if let removed = screen.removedNote {
                Text(removed)
                    .font(.system(size: 12))
                Divider()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if !screen.rows.isEmpty {
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
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
    }

    /// GTK's alert has a title and no message, so the two go together.
    private var removeQuestion: String {
        guard let title = screen.removeQuestion, let message = screen.removeMessage else { return "" }
        return "\(title)\n\n\(message)"
    }

    /// The name, with Invite Someone… on the right, and the line under it.
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(group.name)
                    .font(.title2)
                Spacer()
                if screen.mayInvite {
                    Button(Words.invite) { invite() }
                }
            }
            Text(screen.summary)
                .font(.system(size: 12))
                .foregroundColor(.gray)
        }
    }

    private var people: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Words.people.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.gray)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(screen.rows) { row in
                    person(row)
                    if row.id != screen.rows.last?.id {
                        Divider()
                    }
                }
            }
        }
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
                Text(Words.levelExplanation(row.level))
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
            }
            Spacer()
            if row.levelChoices.isEmpty {
                Text(row.levelTitle)
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.gray.opacity(0.4))
                    }
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
        .padding(.vertical, 8)
    }
}
