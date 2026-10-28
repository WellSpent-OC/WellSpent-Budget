#if canImport(SwiftUI)
import SwiftUI

/// Where Houses opens on the Mac and the iPhone until the Properties package
/// draws its own screens. Turning it off takes the rail or the tabs back to
/// Budgets, with every budget and entry exactly as it was.
public struct HousesPlaceholderView: View {
    public var openCatalog: @MainActor () -> Void
    public var turnOff: @MainActor () -> Void

    public init(openCatalog: @escaping @MainActor () -> Void, turnOff: @escaping @MainActor () -> Void) {
        self.openCatalog = openCatalog
        self.turnOff = turnOff
    }

    public var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "house.fill")
                .font(.system(size: 34))
                .foregroundStyle(Palette.accent)
            Text("Houses")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Palette.ink)
            Text("STAGING PREVIEW · IN DEVELOPMENT")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Palette.muted)
            Text("Your houses, their bookings and what they bring in will show here.")
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button("Open Catalog", action: openCatalog)
                Button("Turn Off Extension", action: turnOff)
            }
            .padding(.top, 6)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.ground)
    }
}
#endif
