import Foundation
import SwiftCrossUI
import WellSpentAppCore

// The invitation page on Linux: the shared JoinScreen, drawn where a budget
// opens, once a clicked invite link opened the app (`OpenedLinks`). What it
// holds, checks and says is the Mac's. This is layout only.

/// Who invited them and to what, the level and what it lets them do, how
/// much they would see, Your name, and Join. Signed out, or with the email
/// not confirmed yet, the notice and its button stand in place of Join. A
/// link that cannot be used says why, under "Join a Group". No Decline: a
/// link has no invite to decline.
struct InvitationPageView: View {
    let screen: JoinScreen
    /// The window's rules. Join goes through them, so the group's page opens
    /// once in.
    let main: MainScreen
    /// Opens the account sheet, to sign in or to confirm the email.
    var openAccount: () -> Void
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
                    if let problem = screen.linkProblem {
                        warning(problem)
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Who invited them and to what, then what the server says the invite
    /// offers, once it has said.
    private func offer(_ invitation: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(invitation)
                .font(.system(size: 22, weight: .semibold))
            if let line = screen.levelLine {
                levelLine(line)
            }
            if let explanation = screen.levelExplanation {
                Text(explanation)
                    .font(.system(size: 11))
                    .foregroundColor(Palette.muted)
            }
            if let history = screen.historyLine {
                Text(history)
                    .font(.system(size: 13))
            }
        }
    }

    /// "You'd join at Add.", with the level's name in bold so it stands out.
    @ViewBuilder
    private func levelLine(_ line: String) -> some View {
        if let level = screen.levelTitle, let range = line.range(of: level) {
            HStack(spacing: 0) {
                Text(String(line[..<range.lowerBound]))
                Text(level)
                    .font(.system(size: 13, weight: .semibold))
                Text(String(line[range.upperBound...]))
            }
            .font(.system(size: 13))
        } else {
            Text(line)
                .font(.system(size: 13))
        }
    }

    /// Your name, then Join, or what stands in its way and the button that
    /// deals with it.
    private var answer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(Words.name)
                    .font(.system(size: 13))
                TextField(Words.namePrompt, text: Binding(get: { screen.myName }, set: { screen.myName = $0 }))
                    .frame(width: 260)
            }
            if let notice = screen.notice {
                warning(notice)
                if screen.offersSignIn {
                    Button(Words.signIn) { openAccount() }
                } else if screen.offersEmailConfirmation {
                    Button(Words.confirmEmail) { openAccount() }
                }
            } else {
                Button(screen.joinLabel) { Task { await main.joinInvitation() } }
                    .disabled(!screen.canJoin)
            }
            if let failure = screen.failure, failure != screen.notice {
                warning(failure)
            }
        }
    }

    private func warning(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(Palette.warning)
    }
}
