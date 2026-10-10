import Foundation
import WellSpentImport

/// Why a statement could not be imported, in words a person can act on, on
/// any desktop. The file is named, and raw error text is never shown. The
/// alert's title already says something went wrong, so these do not.
public enum ImportWording {
    public static func words(for error: any Error, file name: String) -> String {
        let file = "\u{201C}\(name)\u{201D}"
        if let failure = error as? ImportError {
            switch failure {
            case .unrecognisedFormat:
                return "\(file) is not a statement this app can read. \(download)"
            case .noRowsFound:
                return "\(file) has no entries to import."
            case .malformedRow(let line, let reason):
                return "Line \(line) of \(file) could not be read: \(reason). \(download)"
            }
        }
        if let failure = error as? CocoaError {
            switch failure.code {
            case .fileReadNoSuchFile, .fileNoSuchFile:
                return "\(file) is not there any more. It may have been moved or deleted."
            case .fileReadNoPermission:
                return "This app is not allowed to open \(file)."
            case .fileReadInapplicableStringEncoding, .fileReadCorruptFile:
                return "\(file) could not be read as text. \(download)"
            default:
                return "\(file) could not be opened. Try again."
            }
        }
        // The rest come from this device's own budgets, not the file.
        return "The statement could not be checked against your budgets. Try again."
    }

    static let download = "Download a CSV, OFX or QFX file from your bank and import that."
}
