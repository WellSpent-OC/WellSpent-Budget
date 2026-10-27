import Foundation
import SwiftCrossUI
import WellSpentAppCore

/// The far-left Activity Rail, inspired by VS Code.
/// Budgets is the default built-in extension.
/// Extensions is the second built-in extension for catalog discovery.
/// Add-ons like Runway and WarTable appear on the rail once installed.
struct ActivityRailView: View {
    @Binding var active: ActiveExtension
    var isRunwayInstalled: Bool = false
    var isWarTableInstalled: Bool
    var openAccount: @MainActor @Sendable () -> Void

    var body: some View {
        VStack(spacing: 8) {
            railButton(title: "Budget", symbol: "◧", isSelected: active == .budgets) {
                active = .budgets
            }

            if isRunwayInstalled {
                railButton(title: "Runway", symbol: "🏡", isSelected: active == .runway) {
                    active = .runway
                }
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
                VStack(spacing: 2) {
                    Text("👤")
                        .font(.system(size: 15))
                        .foregroundColor(Palette.sidebarHeader)
                    Text("Account")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(Palette.sidebarHeader)
                }
                .frame(width: 42, height: 40)
            }
            .help("Account and sync")
            .accessibility(label: "Account")
            .buttonStyle(.plain)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        .frame(minWidth: 50, maxWidth: 50)
        .frame(maxHeight: .infinity)
        .background(Palette.railBackground)
    }

    private func railButton(title: String, symbol: String, isSelected: Bool, action: @escaping @MainActor @Sendable () -> Void) -> some View {
        Button(action: action) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Palette.railButtonActive : Color.clear)
                if isSelected {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Palette.gold, style: StrokeStyle(width: 1.5))
                }
                VStack(spacing: 2) {
                    Text(symbol)
                        .font(.system(size: 15, weight: isSelected ? .bold : .regular))
                        .foregroundColor(isSelected ? Palette.goldLight : Palette.sidebarHeader)
                    Text(title)
                        .font(.system(size: 8, weight: isSelected ? .bold : .medium))
                        .foregroundColor(isSelected ? Palette.goldLight : Palette.sidebarHeader)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: 42, height: 42)
        }
        .help(title)
        .accessibility(label: title, selected: isSelected)
        .buttonStyle(.plain)
    }
}
