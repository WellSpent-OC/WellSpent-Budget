import Foundation
import SwiftCrossUI
import WellSpentAppCore

/// Where Houses opens on Linux until the Properties package draws its own
/// screens. Turning it off takes the rail back to Budgets, with every budget
/// and entry exactly as it was. The Mac and iPhone twin is HousesPlaceholderView.
struct HousesView: View {
    var openCatalog: @MainActor @Sendable () -> Void
    var turnOff: @MainActor @Sendable () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("🏡")
                .font(.system(size: 34))
            Text("Houses")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(Palette.ink)
            Text("STAGING PREVIEW · IN DEVELOPMENT")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Palette.muted)
            Text("Your houses, their bookings and what they bring in will show here.")
                .font(.system(size: 13))
                .foregroundColor(Palette.muted)
            HStack(spacing: 10) {
                Button("Open Catalog") { openCatalog() }
                Button("Turn Off Extension") { turnOff() }
            }
            .padding(.top, 6)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundColor(Palette.ink)
        .background(Palette.surface)
    }
}
