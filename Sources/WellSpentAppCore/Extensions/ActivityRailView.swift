#if canImport(SwiftUI)
import SwiftUI

/// The far-left vertical Activity Rail for desktop (macOS) and large screens (iPadOS).
/// Budgets is the default built-in view.
/// Extensions provides catalog discovery.
/// Installed add-ons (such as WarTable in staging) join the rail when turned on.
public struct ActivityRailView: View {
    @Binding public var active: ActiveExtension
    public var isWarTableInstalled: Bool
    public var openAccount: @MainActor () -> Void

    public init(
        active: Binding<ActiveExtension>,
        isWarTableInstalled: Bool,
        openAccount: @escaping @MainActor () -> Void
    ) {
        self._active = active
        self.isWarTableInstalled = isWarTableInstalled
        self.openAccount = openAccount
    }

    public var body: some View {
        VStack(spacing: 12) {
            railButton(title: "Budget", symbol: "chart.pie.fill", isSelected: active == .budgets) {
                active = .budgets
            }

            if isWarTableInstalled {
                railButton(title: "WarTable", symbol: "bubble.left.and.bubble.right.fill", isSelected: active == .warTable) {
                    active = .warTable
                }
            }

            railButton(title: "Extensions", symbol: "square.dashed", isSelected: active == .catalog) {
                active = .catalog
            }

            Spacer()

            Button(action: openAccount) {
                VStack(spacing: 3) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15))
                        .foregroundStyle(Palette.muted)
                    Text("Account")
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.muted)
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("Account and sync")
            .accessibilityLabel("Account")
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        .frame(minWidth: 68, maxWidth: 68)
        .frame(maxHeight: .infinity)
        .background(Palette.sidebar)
    }

    private func railButton(
        title: String,
        symbol: String,
        isSelected: Bool,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: isSelected ? .bold : .regular))
                    .foregroundStyle(isSelected ? Palette.accent : Palette.muted)
                Text(title)
                    .font(.system(size: 9, weight: isSelected ? .bold : .regular))
                    .foregroundStyle(isSelected ? Palette.accent : Palette.muted)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Palette.accent.opacity(0.18) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        // Rail buttons change views, they do not take typed input, so the
        // keyboard focus ring (a blue square on macOS) has nothing to say here.
        .focusEffectDisabled()
        .help(title)
        .accessibilityLabel(title)
    }
}
#endif

