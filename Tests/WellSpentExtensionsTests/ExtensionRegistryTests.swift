import Testing
import Foundation
import WellSpentExtensions

@Suite("Compiled extension registry")
struct ExtensionRegistryTests {
    private func manifest(id: String = "org.example.board", schema: Int = 1,
                          actions: [ExtensionManifest.Action] = []) -> ExtensionManifest {
        .init(schemaVersion: schema, id: id, name: "Board", version: "0.1.0", license: "MIT",
              platforms: ["linux"], ownedData: ["messages"], actions: actions)
    }
    @Test func onlyDeclaredPlatformsReceiveAnExtension() throws {
        let m = manifest(actions: [.init(name: "enroll", access: .sensitive)])
        let registry = try ExtensionRegistry([m])
        #expect(registry.available(on: "linux") == [m])
        #expect(registry.available(on: "ios").isEmpty)
        #expect(registry.manifest(id: m.id) == m)
        #expect(registry.manifest(id: "unregistered") == nil)
        #expect(try JSONDecoder().decode(ExtensionManifest.self, from: JSONEncoder().encode(m)) == m)
    }
    @Test func rejectsAmbiguousOrUnrecognizedManifests() {
        #expect(throws: ExtensionRegistry.InvalidManifest.unsupportedSchema) { try ExtensionRegistry([manifest(schema: 2)]) }
        #expect(throws: ExtensionRegistry.InvalidManifest.invalidID) { try ExtensionRegistry([manifest(id: "../budget")]) }
        #expect(throws: ExtensionRegistry.InvalidManifest.duplicateID) { try ExtensionRegistry([manifest(), manifest()]) }
        #expect(throws: ExtensionRegistry.InvalidManifest.duplicateAction) {
            try ExtensionRegistry([manifest(actions: [.init(name: "read", access: .read), .init(name: "read", access: .write)])])
        }
    }
}
