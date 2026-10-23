#if canImport(SwiftUI)
import SwiftUI
import WellSpentSync

/// An invitation belongs beside the groups, before it grants any group access.
struct IncomingInvitationRow: View {
    let screen: MainScreen
    let invitation: IncomingInvitation
    @State private var confirmingRejection = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(invitation.groupName)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 4)
                Text(EmailInvitationWords.invited)
                    .font(.caption)
            }
            .foregroundStyle(Palette.muted)
            Text(EmailInvitationWords.from(invitation.inviterName))
                .font(.caption)
                .foregroundStyle(Palette.muted)
            Text(EmailInvitationWords.terms(invitation))
                .font(.caption)
            if let failure = screen.invitationFailure(for: invitation.id) {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(EmailInvitationWords.reject) { confirmingRejection = true }
                    .accessibilityIdentifier(AccessibilityID.rejectInvitation(invitation.id))
                Spacer()
                Button(EmailInvitationWords.accept) {
                    Task { await screen.acceptInvitation(invitation) }
                }
                .accessibilityIdentifier(AccessibilityID.acceptInvitation(invitation.id))
            }
            .buttonStyle(.bordered)
            .disabled(screen.isResponding(to: invitation.id))
        }
        .padding(.vertical, 6)
        .accessibilityIdentifier(AccessibilityID.incomingInvitation(invitation.id))
        .confirmationDialog(EmailInvitationWords.rejectQuestion(invitation.groupName),
                            isPresented: $confirmingRejection, titleVisibility: .visible) {
            Button(EmailInvitationWords.reject, role: .destructive) {
                Task { await screen.rejectInvitation(invitation) }
            }
            Button(ShareScreen.Words.cancel, role: .cancel) { }
        } message: {
            Text(EmailInvitationWords.rejectMessage)
        }
    }
}

/// Managers can see an invitation waiting and withdraw it from the group page.
struct OutgoingInvitationRow: View {
    let screen: MembersScreen
    let invitation: ServerInvite
    @State private var confirmingCancellation = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(EmailInvitationWords.recipient(invitation))
                    .font(.subheadline)
                if let email = invitation.email {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(Palette.muted)
                }
                Text(EmailInvitationWords.status(invitation))
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 4)
            if screen.canCancelInvite(invitation.id) {
                Button(EmailInvitationWords.cancelInvite) { confirmingCancellation = true }
                    .disabled(screen.isWorking)
                    .accessibilityIdentifier(AccessibilityID.cancelInvitation(invitation.id))
            }
        }
        .padding(.vertical, 8)
        .accessibilityIdentifier(AccessibilityID.outgoingInvitation(invitation.id))
        .confirmationDialog(EmailInvitationWords.cancelQuestion(EmailInvitationWords.recipient(invitation)),
                            isPresented: $confirmingCancellation, titleVisibility: .visible) {
            Button(EmailInvitationWords.cancelInvite, role: .destructive) {
                Task { await screen.cancelInvite(invitation.id) }
            }
            Button(ShareScreen.Words.cancel, role: .cancel) { }
        } message: {
            Text(EmailInvitationWords.cancelMessage)
        }
    }
}
#endif
