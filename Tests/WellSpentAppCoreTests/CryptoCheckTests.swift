#if os(macOS)
import Foundation
import Testing

/// `scripts/crypto-check.sh`, which the release check runs on the exact app it
/// is about to upload: the export answer holds only while the app's code uses
/// Apple's encryption alone. Each test builds a small app whose code files are
/// real Mach-O headers followed by the text a linked library would leave.
@Suite("A release holds Apple's encryption only")
struct CryptoCheckTests {
    @Test func anAppOfAppleEncryptionOnlyPasses() throws {
        let result = try Self.check(code: ["Contents/MacOS/WellSpent": "$s9CryptoKit3AESO3GCMO CryptoKit"])
        #expect(result.status == 0, "\(result.said)")
    }

    @Test func boringSSLInADebugBuildsDylibFails() throws {
        // A debug build keeps the code in .debug.dylib, beside a clean stub.
        let result = try Self.check(code: ["Contents/MacOS/WellSpent": "stub",
                                           "Contents/MacOS/WellSpent.debug.dylib": "CCryptoBoringSSL_SHA256_Init"])
        #expect(result.status == 1)
        #expect(result.said.contains("WellSpent.debug.dylib"), "\(result.said)")
    }

    @Test func cryptoExtrasInAFrameworkFails() throws {
        let result = try Self.check(code: ["Contents/MacOS/WellSpent": "CryptoKit",
                                           "Contents/Frameworks/Kit.framework/Kit": "$s12CryptoExtras7BoringSSLScryptV"])
        #expect(result.status == 1)
        #expect(result.said.contains("Kit.framework"), "\(result.said)")
    }

    @Test func swiftCryptosOwnAlgorithmFails() throws {
        let result = try Self.check(code: ["Contents/MacOS/WellSpent": "OpenSSLAESGCMImpl"])
        #expect(result.status == 1)
    }

    @Test func swiftCryptosHelpersAreNotEncryption() throws {
        let result = try Self.check(code: ["Contents/MacOS/WellSpent": "openSSLSafeCompare constantTimeCompare hexString"])
        #expect(result.status == 0, "\(result.said)")
    }

    @Test func theHelpersFoldersPathInADebugBuildIsNotBoringSSL() throws {
        let helpers = try Self.check(code: ["Contents/MacOS/WellSpent.debug.dylib":
                                            "/build/checkouts/swift-crypto/Sources/Crypto/Util/BoringSSL/"])
        #expect(helpers.status == 0, "\(helpers.said)")
        let boringSSL = try Self.check(code: ["Contents/MacOS/WellSpent.debug.dylib":
                                              "/build/checkouts/swift-crypto/Sources/CCryptoBoringSSL/crypto/"])
        #expect(boringSSL.status == 1)
    }

    @Test func aFileThatIsNotCodeIsNotRead() throws {
        let result = try Self.check(code: ["Contents/MacOS/WellSpent": "CryptoKit"],
                                    other: ["Contents/Resources/Licenses.txt": "BoringSSL license text"])
        #expect(result.status == 0, "\(result.said)")
    }

    @Test func anAppWithNoCodeFails() throws {
        let result = try Self.check(code: [:], other: ["Contents/Info.plist": "<plist/>"])
        #expect(result.status == 1)
        #expect(result.said.contains("no code"), "\(result.said)")
    }

    // MARK: - Running the script

    /// The first 32 bytes of a 64-bit arm64 executable, which `file` reads as Mach-O.
    static let machHeader = Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
                                  0x02, 0x00, 0x00, 0x00] + [UInt8](repeating: 0, count: 16))

    static func check(code: [String: String], other: [String: String] = [:]) throws -> ScriptRun {
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("crypto-check-\(UUID().uuidString)/WellSpent.app", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        for (path, text) in code {
            let url = app.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (machHeader + Data("\0\(text)\0".utf8)).write(to: url)
        }
        for (path, text) in other {
            let url = app.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        return try ScriptRun.run("crypto-check.sh", [app.path])
    }
}
#endif
