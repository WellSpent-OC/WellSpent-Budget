import Foundation

/// A statement file a staging build reads when Import statement is pressed,
/// in place of showing the file picker, so a UI test can import one. A test
/// cannot reach the iPhone's Files picker, and a new simulator holds no files
/// to pick. A live build never reads it, so a TestFlight build always shows
/// the picker.
public enum UITestStatement {
    /// The environment variable that names the file, by its whole path. Like
    /// `StartingScreen.variable`, only a staging build reads it.
    public static let variable = "WELLSPENT_UI_TEST_STATEMENT"

    /// The file `processEnvironment` names. Nil in a live build, and when no
    /// file is named. It is read again at each press, so a test can write the
    /// file again between imports.
    public static func requested(in processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
                                 environment: AppEnvironment = .current) -> URL? {
        guard environment == .staging, let path = processEnvironment[variable], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }
}
