// The Mac's Delete Account sheet. The words and steps are the shared
// DeleteAccountScreen's; this is layout only.
#if canImport(SwiftUI) && os(macOS)
import SwiftUI
import WellSpentPlans

struct DeleteAccountSheet: View {
    @State var screen: DeleteAccountScreen
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private typealias Words = DeleteAccountScreen.Words

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Words.title)
                .font(.system(size: 17, weight: .semibold))
            ForEach(screen.lines, id: \.self) { line in
                Text(line)
                    .font(.system(size: 13, weight: line == screen.appleLine ? .bold : .regular))
                    .fixedSize(horizontal: false, vertical: true)
                if line == screen.appleLine {
                    Button(Words.openAppleSettings) { openURL(PlanLinks.appleSubscriptions) }
                        .linkButtonStyle()
                        .accessibilityIdentifier(AccessibilityID.deleteOpenAppleSettings)
                }
            }
            Text(Words.passwordPrompt)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
            SecureField(Words.password, text: $screen.password)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(AccessibilityID.deletePassword)
                .onSubmit { Task { await screen.submit() } }
            if let failure = screen.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(AccessibilityID.deleteFailure)
            }
            HStack {
                Spacer()
                Button(Words.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(AccessibilityID.deleteCancel)
                Button(Words.delete, role: .destructive) { Task { await screen.submit() } }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.warning)
                    .disabled(!screen.canDelete)
                    .accessibilityIdentifier(AccessibilityID.deleteConfirm)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onChange(of: screen.isDone) { _, done in if done { dismiss() } }
    }
}
#endif
