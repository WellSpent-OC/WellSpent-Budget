// SPDX-License-Identifier: MIT
import Foundation

public enum WTPolicy {
    public static let messageByteLimit = 16 * 1024
    public static let replyLimit = 5
    public static let leaseSeconds: TimeInterval = 120
    public static func oversees(_ role: WTRole?) -> Bool {
        role == .owner || role == .admin || role == .manager
    }
    public static func permissions(_ role: WTRole?) -> [WTCapability] {
        var result: [WTCapability] = [.readChat, .sendMessage, .readContext, .proposeTask]
        if oversees(role) { result.append(.manageAgents) }
        if role == .owner || role == .admin { result += [.managePeople, .enrollAgents, .redact] }
        if role == .owner { result += [.manageInstallation, .authorizeTask] }
        return result
    }
    /// Logical repository paths only; the local adapter must also resolve
    /// symlinks and enforce the resulting filesystem boundary.
    public static func validPath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\")
            && !path.unicodeScalars.contains { $0.properties.generalCategory == .control }
            && !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }
    public static func permits(_ path: String, within roots: [String]) -> Bool {
        guard validPath(path) else { return false }
        return roots.contains { root in
            validPath(root) && (root == "." || path == root || path.hasPrefix(root + "/"))
        }
    }
    public static func isLocalWrite(_ capability: WTCapability) -> Bool {
        [.editBranch, .runChecks, .writeHandoff].contains(capability)
    }
    public static func mentions(_ name: String, in text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        return text.range(of: "(?<![\\p{L}\\p{N}_])@" + escaped + "(?![\\p{L}\\p{N}_])", options: [.regularExpression, .caseInsensitive]) != nil
    }
}
