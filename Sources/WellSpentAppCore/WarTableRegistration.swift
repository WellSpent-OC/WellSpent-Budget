import Foundation
import WellSpentExtensions

public enum WarTableRegistration {
    public static let manifest = ExtensionManifest(
        id: "wellspent.wartable", name: "WarTable", version: "0.1.0", license: "MIT",
        platforms: ["linux"], ownedData: ["conversations", "messages", "agents", "context", "tasks", "reviews"],
        actions: [
            .init(name: "read_conversations", access: .read),
            .init(name: "send_message", access: .write),
            .init(name: "enroll_agent", access: .sensitive),
            .init(name: "approve_context", access: .sensitive),
            .init(name: "authorize_task", access: .sensitive),
            .init(name: "review_change", access: .sensitive)
        ])
    public static let registry = try! ExtensionRegistry([manifest])
}
