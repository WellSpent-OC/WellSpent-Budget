import SwiftCrossUI
import WellSpentAppCore
import WellSpentSync

/// An invited group is visible before membership exists. Its muted name
/// cannot open budgets; the two answers remain normal keyboard buttons.
struct IncomingInvitationRow: View {
    let invitation: IncomingInvitation
    let main: MainScreen
    @State private var confirmingRejection = false
    private typealias Words = EmailInvitationWords

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(invitation.groupName.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Palette.muted)
            Text(Words.invited)
                .font(.system(size: 11))
                .foregroundColor(Palette.muted)
            Text(Words.from(invitation.inviterName))
                .font(.system(size: 11))
                .foregroundColor(Palette.muted)
            Text(Words.terms(invitation))
                .font(.system(size: 11))
                .foregroundColor(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(Words.reject) { confirmingRejection = true }
                    .disabled(main.isResponding(to: invitation.id))
                    .fixedSize()
                Spacer()
                Button(Words.accept) { Task { await main.acceptInvitation(invitation) } }
                    .disabled(main.isResponding(to: invitation.id))
                    .fixedSize()
            }
            if let failure = main.invitationFailure(for: invitation.id) {
                Note(failure, warning: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.sidebar))
        .padding(.bottom, 6)
        .alert("\(Words.rejectQuestion(invitation.groupName))\n\n\(Words.rejectMessage)",
               isPresented: $confirmingRejection) {
            Button(MainScreen.Words.cancel) { confirmingRejection = false }
            Button(Words.reject) {
                Task { await main.rejectInvitation(invitation) }
            }
        }
    }
}
