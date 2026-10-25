import Foundation
import SwiftCrossUI
import WellSpentAppCore

/// High-level navigation modes on the Activity Rail.
enum ActiveExtension: String, CaseIterable, Sendable {
    case budgets
    case warTable
    case catalog
}

/// The far-left Activity Rail, inspired by VS Code.
/// Budgets is the default built-in extension.
/// Extensions is the second built-in extension for catalog discovery.
/// Add-ons like WarTable appear on the rail once installed.
struct ActivityRailView: View {
    @Binding var active: ActiveExtension
    var isWarTableInstalled: Bool
    var openAccount: @MainActor @Sendable () -> Void

    var body: some View {
        VStack(spacing: 12) {
            railButton(title: "Budget", symbol: "◧", isSelected: active == .budgets) {
                active = .budgets
            }

            if isWarTableInstalled {
                railButton(title: "WarTable", symbol: "⚔", isSelected: active == .warTable) {
                    active = .warTable
                }
            }

            railButton(title: "Extensions", symbol: "⬚", isSelected: active == .catalog) {
                active = .catalog
            }

            Spacer()

            Button(action: openAccount) {
                VStack(spacing: 3) {
                    Text("⚙")
                        .font(.system(size: 14))
                        .foregroundColor(Palette.muted)
                    Text("Account")
                        .font(.system(size: 9))
                        .foregroundColor(Palette.muted)
                }
                .padding(4)
                .frame(maxWidth: .infinity)
            }
            .help("Account and sync")
            .accessibility(label: "Account")
            .buttonStyle(.plain)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        .frame(minWidth: 54, maxWidth: 54)
        .frame(maxHeight: .infinity)
        .background(Palette.sidebar)
    }

    private func railButton(title: String, symbol: String, isSelected: Bool, action: @escaping @MainActor @Sendable () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text(symbol)
                    .font(.system(size: 16, weight: isSelected ? .bold : .regular))
                    .foregroundColor(isSelected ? Palette.accent : Palette.muted)
                Text(title)
                    .font(.system(size: 9, weight: isSelected ? .bold : .regular))
                    .foregroundColor(isSelected ? Palette.accent : Palette.muted)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color(PaletteValues.accent).opacity(0.15) : Color.clear))
        }
        .help(title)
        .accessibility(label: title, selected: isSelected)
        .buttonStyle(.plain)
    }
}
