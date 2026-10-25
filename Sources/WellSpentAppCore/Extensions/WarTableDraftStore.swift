import Foundation
import WarTableCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Local drafts and the exact request to reuse after an uncertain send. Never a bearer credential.
public struct WarTableSavedDraft: Codable, Sendable, Equatable {
    public var groupID: UUID
    public var text: String
    public var replyTo: UUID?
    public var sourceIDs: [UUID]
    public var pending: WTPostMessage?
    public init(groupID: UUID, text: String, replyTo: UUID? = nil, sourceIDs: [UUID] = [], pending: WTPostMessage? = nil) {
        self.groupID = groupID; self.text = text; self.replyTo = replyTo
        self.sourceIDs = sourceIDs; self.pending = pending
    }
}

/// The caller supplies an account, environment and server isolated directory.
/// Descriptor-relative IO refuses symbolic links instead of following a replaced path.
@MainActor
public final class WarTableDraftStore {
    public enum Failure: Error, Equatable { case invalidDirectory, unsafeFile, tooLarge, corruptData, ioFailure }
    public static let maximumDrafts = 100
    public static let maximumTextBytes = 16 * 1024
    public static let maximumFileBytes = 4 * 1024 * 1024
    public private(set) var lastFailure: Failure?
    private let directory: URL
    private let filename = "draft.json"

    public init(directory: URL) { self.directory = directory }

    /// Failure never restores uncertain or unsafe private content into a view.
    public func load() -> [UUID: WarTableSavedDraft] {
        do {
            guard let folder = try openDirectory(create: false) else { lastFailure = nil; return [:] }
            defer { close(folder) }
            let file = openat(folder, filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard file >= 0 else {
                if errno == ENOENT { lastFailure = nil; return [:] }
                throw Failure.unsafeFile
            }
            defer { close(file) }
            try validateFile(file)
            var data = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = buffer.withUnsafeMutableBytes { bytes in
                    read(file, bytes.baseAddress, bytes.count)
                }
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw Failure.ioFailure
                }
                guard data.count + count <= Self.maximumFileBytes else { throw Failure.tooLarge }
                data.append(contentsOf: buffer.prefix(count))
            }
            let drafts: [UUID: WarTableSavedDraft]
            do { drafts = try JSONDecoder().decode([UUID: WarTableSavedDraft].self, from: data) }
            catch { throw Failure.corruptData }
            try validate(drafts)
            lastFailure = nil
            return drafts
        } catch let failure as Failure { lastFailure = failure; return [:] }
        catch { lastFailure = .ioFailure; return [:] }
    }

    public func save(_ drafts: [UUID: WarTableSavedDraft]) throws {
        do {
            try validate(drafts)
            if drafts.isEmpty { try clear(); return }
            let data = try JSONEncoder().encode(drafts)
            guard data.count <= Self.maximumFileBytes else { throw Failure.tooLarge }
            guard let folder = try openDirectory(create: true) else { throw Failure.ioFailure }
            defer { close(folder) }
            try validateExistingFile(in: folder)
            let temporary = ".draft-\(UUID().uuidString).tmp"
            let file = openat(folder, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            guard file >= 0 else { throw Failure.ioFailure }
            defer { close(file); unlinkat(folder, temporary, 0) }
            guard fchmod(file, mode_t(0o600)) == 0 else { throw Failure.ioFailure }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw Failure.ioFailure
                    }
                    guard count > 0 else { throw Failure.ioFailure }
                    offset += count
                }
            }
            guard fsync(file) == 0 else { throw Failure.ioFailure }
            try validateExistingFile(in: folder)
            guard renameat(folder, temporary, folder, filename) == 0 else { throw Failure.ioFailure }
            if fsync(folder) != 0 && errno != EINVAL { throw Failure.ioFailure }
            lastFailure = nil
        } catch let failure as Failure { lastFailure = failure; throw failure }
        catch { lastFailure = .ioFailure; throw Failure.ioFailure }
    }

    public func clear() throws {
        do {
            guard let folder = try openDirectory(create: false) else { lastFailure = nil; return }
            defer { close(folder) }
            try validateExistingFile(in: folder)
            if unlinkat(folder, filename, 0) != 0 && errno != ENOENT { throw Failure.ioFailure }
            if fsync(folder) != 0 && errno != EINVAL { throw Failure.ioFailure }
            lastFailure = nil
        } catch let failure as Failure { lastFailure = failure; throw failure }
        catch { lastFailure = .ioFailure; throw Failure.ioFailure }
    }

    private func validate(_ drafts: [UUID: WarTableSavedDraft]) throws {
        guard drafts.count <= Self.maximumDrafts else { throw Failure.tooLarge }
        for (conversation, draft) in drafts {
            guard draft.text.utf8.count <= Self.maximumTextBytes, draft.sourceIDs.count <= 100 else { throw Failure.tooLarge }
            if let pending = draft.pending {
                guard pending.conversationID == conversation else { throw Failure.corruptData }
                guard pending.text.utf8.count <= Self.maximumTextBytes, pending.sourceIDs.count <= 100 else { throw Failure.tooLarge }
            }
        }
    }

    private func validateFile(_ file: Int32, enforceSize: Bool = true) throws {
        var info = stat()
        guard fstat(file, &info) == 0 else { throw Failure.ioFailure }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == geteuid(),
              info.st_mode & mode_t(0o777) == mode_t(0o600), info.st_nlink == 1 else { throw Failure.unsafeFile }
        if enforceSize {
            guard info.st_size >= 0, info.st_size <= off_t(Self.maximumFileBytes) else { throw Failure.tooLarge }
        }
    }

    private func validateExistingFile(in folder: Int32) throws {
        let file = openat(folder, filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else {
            if errno == ENOENT { return }
            throw Failure.unsafeFile
        }
        defer { close(file) }
        try validateFile(file, enforceSize: false)
    }

    private func openDirectory(create: Bool) throws -> Int32? {
        guard directory.isFileURL, directory.path.hasPrefix("/") else { throw Failure.invalidDirectory }
        let components = directory.pathComponents.filter { $0 != "/" }
        guard !components.isEmpty, !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { throw Failure.invalidDirectory }
        var folder = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { throw Failure.ioFailure }
        do {
            for component in components {
                var child = openat(folder, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if child < 0 && errno == ENOENT {
                    if !create { close(folder); return nil }
                    guard mkdirat(folder, component, mode_t(0o700)) == 0 || errno == EEXIST else { throw Failure.ioFailure }
                    child = openat(folder, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard child >= 0 else { throw Failure.invalidDirectory }
                close(folder); folder = child
            }
            var info = stat()
            guard fstat(folder, &info) == 0, info.st_uid == geteuid() else { throw Failure.invalidDirectory }
            if create {
                guard fchmod(folder, mode_t(0o700)) == 0 else { throw Failure.ioFailure }
            } else if info.st_mode & mode_t(0o777) != mode_t(0o700) { throw Failure.invalidDirectory }
            return folder
        } catch { close(folder); throw error }
    }
}
