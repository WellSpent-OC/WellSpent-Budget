import Foundation
import Testing
import WellSpentAppCore
import WarTableCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@Suite("Protected WarTable draft persistence") @MainActor
struct WarTableDraftStoreTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("wartable-drafts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: NSNumber(value: 0o700)])
        return root
    }

    // Scenario WARTABLE-02
    @Test func restartPreservesDraftProvenanceAndExactRetryIdentity() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("account/extension", isDirectory: true)
        let conversation = UUID(), group = UUID(), source = UUID(), reply = UUID()
        let request = WTPostMessage(conversationID: conversation, clientMessageID: UUID(), text: "A draft\nwith two lines", replyTo: reply, sourceIDs: [source])
        let draft = WarTableSavedDraft(groupID: group, text: request.text, replyTo: reply, sourceIDs: [source], pending: request)
        try WarTableDraftStore(directory: directory).save([conversation: draft])
        let restored = WarTableDraftStore(directory: directory).load()
        #expect(restored == [conversation: draft])
        #expect(restored[conversation]?.pending?.clientMessageID == request.clientMessageID)
        let folder = try FileManager.default.attributesOfItem(atPath: directory.path)
        let file = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("draft.json").path)
        #expect((folder[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((file[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["draft.json"])
    }

    @Test func boundsRejectOversizedWritesAndLeavePreviousDraftIntact() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = WarTableDraftStore(directory: root), conversation = UUID(), group = UUID()
        let original = WarTableSavedDraft(groupID: group, text: "Keep this draft")
        try store.save([conversation: original])
        #expect(throws: WarTableDraftStore.Failure.tooLarge) {
            try store.save([conversation: .init(groupID: group, text: String(repeating: "x", count: WarTableDraftStore.maximumTextBytes + 1))])
        }
        var many: [UUID: WarTableSavedDraft] = [:]
        for _ in 0 ... WarTableDraftStore.maximumDrafts { many[UUID()] = original }
        #expect(throws: WarTableDraftStore.Failure.tooLarge) { try store.save(many) }
        #expect(store.load() == [conversation: original])
    }

    @Test func pendingRequestMustBelongToItsConversation() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = WarTableDraftStore(directory: root)
        let wrong = WTPostMessage(conversationID: UUID(), clientMessageID: UUID(), text: "Wrong conversation")
        #expect(throws: WarTableDraftStore.Failure.corruptData) {
            try store.save([UUID(): .init(groupID: UUID(), text: wrong.text, pending: wrong)])
        }
        #expect(store.load().isEmpty)
    }

    // Scenario WARTABLE-05
    @Test func symlinkDirectoriesAndFilesNeverExposeOutsideContent() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: NSNumber(value: 0o700)])
        let original = [UUID(): WarTableSavedDraft(groupID: UUID(), text: "Do not follow a link")]
        try WarTableDraftStore(directory: outside).save(original)
        let linked = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
        let directoryStore = WarTableDraftStore(directory: linked)
        #expect(directoryStore.load().isEmpty)
        #expect(directoryStore.lastFailure == .invalidDirectory)
        #expect(throws: WarTableDraftStore.Failure.invalidDirectory) { try directoryStore.save(original) }
        let local = root.appendingPathComponent("local", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: NSNumber(value: 0o700)])
        try FileManager.default.createSymbolicLink(at: local.appendingPathComponent("draft.json"),
                                                   withDestinationURL: outside.appendingPathComponent("draft.json"))
        let fileStore = WarTableDraftStore(directory: local)
        #expect(fileStore.load().isEmpty && fileStore.lastFailure == .unsafeFile)
        #expect(throws: WarTableDraftStore.Failure.unsafeFile) { try fileStore.save(original) }
        #expect(throws: WarTableDraftStore.Failure.unsafeFile) { try fileStore.clear() }
        #expect(WarTableDraftStore(directory: outside).load() == original)
    }

    @Test func specialFilesAndBroadPermissionsAreRefusedWithoutBlocking() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("draft.json")
        #expect(mkfifo(file.path, mode_t(0o600)) == 0)
        let store = WarTableDraftStore(directory: root)
        #expect(store.load().isEmpty && store.lastFailure == .unsafeFile)
        try FileManager.default.removeItem(at: file)
        try store.save([UUID(): .init(groupID: UUID(), text: "Protected")])
        #expect(chmod(file.path, mode_t(0o644)) == 0)
        #expect(store.load().isEmpty && store.lastFailure == .unsafeFile)
    }

    @Test func corruptAndOversizedReadsFailClosedAndClearRemovesOwnedFile() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = WarTableDraftStore(directory: root), file = root.appendingPathComponent("draft.json")
        try Data("not JSON".utf8).write(to: file)
        #expect(chmod(file.path, mode_t(0o600)) == 0)
        #expect(store.load().isEmpty && store.lastFailure == .corruptData)
        try Data(repeating: 0, count: WarTableDraftStore.maximumFileBytes + 1).write(to: file)
        #expect(chmod(file.path, mode_t(0o600)) == 0)
        #expect(store.load().isEmpty && store.lastFailure == .tooLarge)
        try store.clear()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(store.load().isEmpty && store.lastFailure == nil)
        try store.clear()
    }
}
