import Foundation

/// A screen a staging build can open on by itself, so a test, or a picture of
/// one screen, reaches it with no taps. A live build never opens on one.
public enum StartingScreen: String, Sendable, CaseIterable {
    /// The first budget on the list, open.
    case budget
    /// The first budget, with Add open over it.
    case add
    /// The account sheet, at its first step.
    case account

    /// The environment variable that names one. Like
    /// `AccountDirectory.dataRootVariable`, only a staging build reads it.
    public static let variable = "WELLSPENT_START_ON"

    /// The screen `processEnvironment` asks for. Nil in a live build, when
    /// nothing is asked for, and for a name this build does not know.
    public static func requested(in processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
                                 environment: AppEnvironment = .current) -> StartingScreen? {
        guard environment == .staging, let name = processEnvironment[variable] else { return nil }
        return StartingScreen(rawValue: name)
    }

    /// Whether it opens a budget first.
    public var opensABudget: Bool { self != .account }
}
