import Foundation

/// Diagnosis for #199, not for merging. A staging build with
/// WELLSPENT_DIAG_LOG set appends one timed line per event to that file, so a
/// UI test can read what the app did around a click.
public enum DiagLog {
    public static let variable = "WELLSPENT_DIAG_LOG"

    private static let path: String? = {
        guard AppEnvironment.current == .staging,
              let path = ProcessInfo.processInfo.environment[variable], !path.isEmpty else { return nil }
        return path
    }()

    public static func note(_ event: String) {
        guard let path else { return }
        let line = String(format: "%.3f ", Date().timeIntervalSince1970) + event + "\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
        }
    }
}
