#if os(macOS)
import Foundation

/// Runs one of the scripts in `scripts/`, for the tests of the checks a release
/// goes through. A check says what it found on standard error, so that is what
/// comes back, with the exit status.
struct ScriptRun {
    let status: Int32
    let said: String

    static func run(_ script: String, _ arguments: [String]) throws -> ScriptRun {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/\(script)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [path.path] + arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        try process.run()
        let said = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return ScriptRun(status: process.terminationStatus, said: said)
    }
}
#endif
