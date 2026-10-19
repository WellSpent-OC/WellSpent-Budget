import XCTest

/// Whether an app under test shows a test account's address anywhere: in a
/// field, a line of text or a title. A failed step's picture goes to CI's
/// artifacts, which are public for a public repo, and the test addresses never
/// are. The check reads each app's accessibility tree, not the picture's pixels.
/// When a tree cannot be read, it answers yes, so no picture is taken.
enum ScreenPrivacy {
    /// What gives a test account's address away, from the variables the runs
    /// are given: each whole address, and the part before its @, since a narrow
    /// field or a title can show an address cut short.
    static var giveaways: [String] {
        let addresses = [TestAccounts.emailVariable, TestAccounts.secondEmailVariable]
            .compactMap { ProcessInfo.processInfo.environment[$0] }
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        let names = addresses.compactMap { $0.split(separator: "@").first.map(String.init) }.filter { $0.count >= 3 }
        return addresses + names
    }

    @MainActor
    static func showsAnAddress(in apps: [XCUIApplication]) -> Bool {
        let giveaways = Self.giveaways
        guard !giveaways.isEmpty else { return false }
        for app in apps where app.state != .notRunning {
            guard let root = try? app.snapshot() else { return true }
            var waiting = [root]
            while let element = waiting.popLast() {
                let words = [element.label, element.title, element.value as? String, element.placeholderValue]
                    .compactMap { $0?.lowercased() }
                if words.contains(where: { text in giveaways.contains { text.contains($0) } }) { return true }
                waiting.append(contentsOf: element.children)
            }
        }
        return false
    }
}
