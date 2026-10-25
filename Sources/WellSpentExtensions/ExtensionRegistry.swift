import Foundation

/// The host only loads extensions compiled and reviewed with this app.
/// A manifest declares capabilities; it never grants account or repository access.
public struct ExtensionManifest: Codable, Equatable, Sendable, Identifiable {
    public enum Access: String, Codable, Sendable { case read, write, sensitive }
    public struct Action: Codable, Equatable, Sendable {
        public let name: String
        public let access: Access
        public init(name: String, access: Access) { self.name = name; self.access = access }
    }
    public let schemaVersion: Int
    public let id: String
    public let name: String
    public let version: String
    public let license: String
    public let platforms: [String]
    public let ownedData: [String]
    public let actions: [Action]
    public init(schemaVersion: Int = 1, id: String, name: String, version: String, license: String,
                platforms: [String], ownedData: [String], actions: [Action]) {
        self.schemaVersion = schemaVersion; self.id = id; self.name = name
        self.version = version; self.license = license; self.platforms = platforms
        self.ownedData = ownedData; self.actions = actions
    }
}

public struct ExtensionRegistry: Sendable {
    public enum InvalidManifest: Error, Equatable { case unsupportedSchema, invalidID, duplicateID, duplicateAction }
    public let manifests: [ExtensionManifest]
    public init(_ manifests: [ExtensionManifest]) throws {
        var ids = Set<String>()
        for manifest in manifests {
            guard manifest.schemaVersion == 1 else { throw InvalidManifest.unsupportedSchema }
            guard !manifest.id.isEmpty, manifest.id.utf8.count <= 100,
                  manifest.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") })
            else { throw InvalidManifest.invalidID }
            guard ids.insert(manifest.id).inserted else { throw InvalidManifest.duplicateID }
            guard Set(manifest.actions.map(\.name)).count == manifest.actions.count else {
                throw InvalidManifest.duplicateAction
            }
        }
        self.manifests = manifests
    }
    public func available(on platform: String) -> [ExtensionManifest] {
        manifests.filter { $0.platforms.contains(platform) }
    }
    public func manifest(id: String) -> ExtensionManifest? { manifests.first { $0.id == id } }
}
