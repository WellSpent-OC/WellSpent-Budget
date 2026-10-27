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
            HStack(alignment: .center, spacing: 6) {
                Text(invitation.groupName)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Text(EmailInvitationWords.invited)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Palette.accent.opacity(0.12), in: Capsule())
                    .overlay(Capsule().stroke(Palette.accent.opacity(0.25), lineWidth: 0.5))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(EmailInvitationWords.from(invitation.inviterName))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                Text(EmailInvitationWords.terms(invitation))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failure = screen.invitationFailure(for: invitation.id) {
                Text(failure)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button {
                    confirmingRejection = true
                } label: {
                    Text(EmailInvitationWords.reject)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.8))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.rejectInvitation(invitation.id))

                Button {
                    Task { await screen.acceptInvitation(invitation) }
                } label: {
                    Text(EmailInvitationWords.accept)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(Palette.accent, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.acceptInvitation(invitation.id))
            }
            .disabled(screen.isResponding(to: invitation.id))
            .opacity(screen.isResponding(to: invitation.id) ? 0.6 : 1.0)
            .padding(.top, 2)
        }
        #if os(macOS)
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.10), lineWidth: 1))
        .padding(.vertical, 4)
        #else
        .padding(.vertical, 6)
        #endif
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
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(EmailInvitationWords.recipient(invitation))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                if let email = invitation.email {
                    Text(email)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                }
                Text(EmailInvitationWords.status(invitation))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 4)
            if screen.canCancelInvite(invitation.id) {
                Button(EmailInvitationWords.cancelInvite) { confirmingCancellation = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.warning)
                    .disabled(screen.isWorking)
                    .accessibilityIdentifier(AccessibilityID.cancelInvitation(invitation.id))
            }
        }
        .padding(.vertical, 10)
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
