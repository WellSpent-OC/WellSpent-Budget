import Foundation
import SwiftCrossUI
import WellSpentAppCore

/// The far-left Activity Rail, inspired by VS Code.
/// Budgets is the default built-in extension.
/// Extensions is the second built-in extension for catalog discovery.
/// Add-ons like Properties (Houses) and WarTable appear on the rail once turned on.
struct ActivityRailView: View {
    @Binding var active: ActiveExtension
    var isPropertiesInstalled: Bool = false
    var isWarTableInstalled: Bool
    var showsSync: Bool = false
    var syncTitle: String = "Sync"
    var syncHelp: String = "Sync now"
    var isSyncing: Bool = false
    var isBusy: Bool = false
    var syncNow: (@MainActor @Sendable () -> Void)? = nil
    /// "Sign in" until there is an account, then "Account": the shared words,
    /// which the UI tests and a screen reader go by.
    var accountTitle: String = "Account"
    var accountHelp: String = "Account and sync"
    var openAccount: @MainActor @Sendable () -> Void

    var body: some View {
        VStack(spacing: 8) {
            railButton(title: "Budget", symbol: "◧", isSelected: active == .budgets) {
                active = .budgets
            }

            if isPropertiesInstalled {
                railButton(title: "Houses", symbol: "🏡", isSelected: active == .properties) {
                    active = .properties
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

            if showsSync, let syncNow {
                Button(action: syncNow) {
                    VStack(spacing: 2) {
                        Text(isSyncing ? "⏳" : "🔄")
                            .font(.system(size: 15))
                            .foregroundColor(Palette.sidebarHeader)
                        Text(syncTitle)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(Palette.sidebarHeader)
                    }
                    .frame(width: 42, height: 40)
                }
                .help(syncHelp)
                .accessibility(label: syncTitle)
                .buttonStyle(.plain)
                .disabled(isBusy)
            }

            Button(action: openAccount) {
                VStack(spacing: 2) {
                    Text("👤")
                        .font(.system(size: 15))
                        .foregroundColor(Palette.sidebarHeader)
                    Text(accountTitle)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(Palette.sidebarHeader)
                }
                .frame(width: 42, height: 40)
            }
            .help(accountHelp)
            .accessibility(label: accountTitle)
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
