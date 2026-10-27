#if canImport(SwiftUI)
import SwiftUI

/// Displays the catalog of WellSpent extensions in SwiftUI (macOS and iOS).
public struct ExtensionsCatalogView: View {
    public var isWarTableInstalled: Bool
    public var isWarTableAvailable: Bool
    public var toggleWarTable: @MainActor () -> Void
    public var openWarTable: @MainActor () -> Void
    public var done: (@MainActor () -> Void)?

    public init(
        isWarTableInstalled: Bool,
        isWarTableAvailable: Bool = true,
        toggleWarTable: @escaping @MainActor () -> Void,
        openWarTable: @escaping @MainActor () -> Void,
        done: (@MainActor () -> Void)? = nil
    ) {
        self.isWarTableInstalled = isWarTableInstalled
        self.isWarTableAvailable = isWarTableAvailable
        self.toggleWarTable = toggleWarTable
        self.openWarTable = openWarTable
        self.done = done
    }

    private var items: [ExtensionCatalogItem] {
        #if os(iOS)
        ExtensionCatalog.items(platform: "ios", isWarTableEnabled: isWarTableAvailable)
        #else
        ExtensionCatalog.items(platform: "macos", isWarTableEnabled: isWarTableAvailable)
        #endif
    }

    public var body: some View {
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
        .background(Palette.ground)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Extensions")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Palette.ink)
                Text("Add what your life needs. Turn any extension off again, whenever you like.")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
            }

            Spacer()

            if let done {
                Button("Done", action: done)
                    .font(.system(size: 14, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.accent)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.sidebar)
    }

    private func card(for item: ExtensionCatalogItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(item.name)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Palette.ink)

                Spacer()

                statusBadge(for: item)
            }

            Text(item.summary)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text(item.pricing)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)

                Spacer()

                cardAction(for: item)
            }
        }
        .padding(14)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Palette.line, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func statusBadge(for item: ExtensionCatalogItem) -> some View {
        if item.id == "wellspent.wartable" {
            if isWarTableInstalled {
                Text("Turned on")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Palette.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(Palette.accent)
            } else {
                Text("Available")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Palette.blue.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(Palette.blue)
            }
        } else {
            switch item.status {
            case .available:
                Text("Available")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Palette.blue.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(Palette.blue)
            case .comingSoon:
                Text("Coming later")
                    .font(.system(size: 10))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Palette.muted.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(Palette.muted)
            case .idea:
                Text("Idea")
                    .font(.system(size: 10))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Palette.muted.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(Palette.muted)
            }
        }
    }

    @ViewBuilder
    private func cardAction(for item: ExtensionCatalogItem) -> some View {
        if item.id == "wellspent.wartable" {
            HStack(spacing: 8) {
                if isWarTableInstalled {
                    Button(action: openWarTable) {
                        Text("Open")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Palette.line, lineWidth: 1))
                            .foregroundStyle(Palette.ink)
                    }
                    .buttonStyle(.plain)

                    Button(action: toggleWarTable) {
                        Text("Turn off")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Palette.warning, in: RoundedRectangle(cornerRadius: 5))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: toggleWarTable) {
                        Text("Turn on")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Palette.accent, in: RoundedRectangle(cornerRadius: 5))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
            }
        } else {
            Text(item.status == .comingSoon ? "Planned" : "Under review")
                .font(.system(size: 11))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Palette.ground, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Palette.line, lineWidth: 1))
                .foregroundStyle(Palette.muted)
        }
    }
}
#endif

