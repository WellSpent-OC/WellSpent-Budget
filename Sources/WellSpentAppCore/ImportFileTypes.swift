// The files Import statement lets a person pick, in the system's file picker
// on the Mac and the iPhone. Apple only: Linux has no UTType, and its app picks
// a file its own way. It sits outside Screens for that reason.
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers

extension ImportReviewScreen {
    /// A CSV file, plain text, and any other file, which is how an OFX or QFX
    /// file is picked: neither has a type of its own on every device. What is
    /// in the file decides whether it can be read, and a file that cannot be
    /// read is explained in words (`ImportWording`).
    nonisolated public static let fileTypes: [UTType] = [.commaSeparatedText, .plainText, .data]
}
#endif
