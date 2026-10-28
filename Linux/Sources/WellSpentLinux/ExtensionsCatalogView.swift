import Foundation
import SwiftCrossUI
import WellSpentAppCore

/// Displays the catalog of WellSpent extensions on Linux.
struct ExtensionsCatalogView: View {
    var isWarTableEnabled: Bool
    var isWarTableAvailable: Bool = true
    var isPropertiesEnabled: Bool = false
    var isPropertiesAvailable: Bool = true
    var installWarTable: @MainActor @Sendable () -> Void
    var openWarTable: @MainActor @Sendable () -> Void
    var turnOnProperties: @MainActor @Sendable () -> Void = {}
    var openProperties: @MainActor @Sendable () -> Void = {}

    private var items: [ExtensionCatalogItem] {
        ExtensionCatalog.items(
            platform: "linux",
            isWarTableEnabled: isWarTableAvailable,
            isPropertiesEnabled: isPropertiesAvailable
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(items) { item in
                        card(for: item)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundColor(Palette.ink)
        .background(Palette.surface)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Extensions")
                .font(.system(size: 22, weight: .semibold))
            Text("Add what your life needs. Turn any extension off again, whenever you like.")
                .font(.system(size: 13))
                .foregroundColor(Palette.muted)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.sidebar)
    }

    private func card(for item: ExtensionCatalogItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(item.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Palette.ink)
                Spacer()
                statusTag(for: item)
            }

            Text(item.summary)
                .font(.system(size: 13))
                .foregroundColor(Palette.ink)

            HStack {
                Text(item.pricing)
                    .font(.system(size: 12))
                    .foregroundColor(Palette.muted)
                Spacer()
                actionButton(for: item)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.sidebar))
    }

    @ViewBuilder
    private func statusTag(for item: ExtensionCatalogItem) -> some View {
        switch item.status {
        case .available:
            if item.id == "wellspent.wartable" && isWarTableEnabled {
                Text("Turned on")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Palette.accent)
            } else if item.id == "wellspent.properties" && isPropertiesEnabled {
                Text("Turned on")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Palette.accent)
            } else {
                Text("Available")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Palette.blue)
            }
        case .comingSoon:
            Text("Coming later")
                .font(.system(size: 11))
                .foregroundColor(Palette.muted)
        case .idea:
            Text("Idea")
                .font(.system(size: 11))
                .foregroundColor(Palette.muted)
        }
    }

    @ViewBuilder
    private func actionButton(for item: ExtensionCatalogItem) -> some View {
        if item.id == "wellspent.wartable" {
            if isWarTableEnabled {
                Button("Open WarTable") {
                    openWarTable()
                }
            } else {
                Button("Install WarTable") {
                    installWarTable()
                }
            }
        } else if item.id == "wellspent.properties" {
            if isPropertiesEnabled {
                Button("Open Houses") {
                    openProperties()
                }
            } else {
                Button("Turn on") {
                    turnOnProperties()
                }
            }
        } else if item.status == .comingSoon {
            Note("Planned")
        } else {
            Note("Under review")
        }
    }
}
