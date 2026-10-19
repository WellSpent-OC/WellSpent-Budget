import XCTest

/// Whether an app under test shows a test account's address anywhere: in a
/// field, a line of text or a title. A failed step's picture goes to CI's
/// artifacts, which are public for a public repo, and the test addresses never
/// are. The check reads each app's accessibility tree, not the picture's pixels.
/// When a tree cannot be read, it answers yes, so no picture is taken.
enum ScreenPrivacy {
    /// The test accounts' addresses, from the variables the runs are given.
    static var addresses: [String] {
        [TestAccounts.emailVariable, TestAccounts.secondEmailVariable]
            .compactMap { ProcessInfo.processInfo.environment[$0] }
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    @MainActor
    static func showsAnAddress(in apps: [XCUIApplication]) -> Bool {
        let addresses = Self.addresses
        guard !addresses.isEmpty else { return false }
        for app in apps where app.state != .notRunning {
            guard let root = try? app.snapshot() else { return true }
            var waiting = [root]
            while let element = waiting.popLast() {
                let words = [element.label, element.title, element.value as? String, element.placeholderValue]
                    .compactMap { $0?.lowercased() }
                if words.contains(where: { text in addresses.contains { text.contains($0) } }) { return true }
                waiting.append(contentsOf: element.children)
            }
        }
        return false
    }
}
