#if canImport(SwiftUI)
import SwiftUI

/// Honest staging preview placeholder for WarTable.
/// Validates rail and catalog switching dynamics without pulling forward incomplete UI work.
public struct WarTablePlaceholderView: View {
    public var openCatalog: @MainActor () -> Void
    public var turnOff: @MainActor () -> Void

    public init(
        openCatalog: @escaping @MainActor () -> Void,
        turnOff: @escaping @MainActor () -> Void
    ) {
        self.openCatalog = openCatalog
        self.turnOff = turnOff
    }

    public var body: some View {
        VStack(spacing: 16) {
            Spacer()

            VStack(spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Palette.accent)

                Text("WarTable")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Palette.ink)

                Text("STAGING PREVIEW · IN DEVELOPMENT")
                    .font(.system(size: 10, weight: .heavy))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Palette.warning.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(Palette.warning)

                Text("AI agent chat and collaborative workrooms are currently on hold for refinement. You can turn this extension off at any time in the Extensions catalog.")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .padding(.top, 4)

                HStack(spacing: 12) {
                    Button(action: openCatalog) {
                        Text("Open Catalog")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.line, lineWidth: 1))
                            .foregroundStyle(Palette.ink)
                    }
                    .buttonStyle(.plain)

                    Button(action: turnOff) {
                        Text("Turn Off Extension")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Palette.warning, in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 12)
            }
            .padding(28)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                    .foregroundStyle(Palette.line)
            )

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.ground)
    }
}
#endif

