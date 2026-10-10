import Foundation
import WellSpentCrypto
import WellSpentModel

/// The sidebar's rules, with no SwiftUI, so every desktop shares them.
public enum SidebarRules {
    /// Collapsed groups are stored as comma-separated IDs, because a stored
    /// setting holds strings, not sets.
    public static func isCollapsed(_ group: GroupID, in stored: String) -> Bool {
        stored.split(separator: ",").contains { $0 == group.uuid.uuidString }
    }

    public static func toggling(_ group: GroupID, in stored: String) -> String {
        var ids = stored.split(separator: ",").map(String.init)
        let id = group.uuid.uuidString
        if let index = ids.firstIndex(of: id) { ids.remove(at: index) } else { ids.append(id) }
        return ids.joined(separator: ",")
    }

    /// Groups waiting on their founder that this device holds nothing of,
    /// deleted or not, so no section speaks for them.
    public static func unseenWaiting(_ waiting: Set<GroupID>, held: [BudgetGroup]) -> Int {
        waiting.subtracting(held.map(\.id)).count
    }
}
