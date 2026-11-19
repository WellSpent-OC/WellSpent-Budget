import Foundation

/// Network failures a staging UI test can turn on, one request at a time
/// (`Workspace.faultFileVariable`). A named request fails as if the app
/// could not reach the server. A real build has none: only a test build
/// reads the file, and a release build is compiled without it.
public struct AppFaults: Sendable {
    /// The requests a test can make fail.
    public enum Operation: String, CaseIterable, Sendable {
        /// Accept fails before it reaches the server.
        case invitationAccept = "invitation.accept"
        /// Reject fails before it reaches the server.
        case invitationReject = "invitation.reject"
        /// The server takes the Accept, and its answer never arrives.
        case invitationAcceptAnswerLost = "invitation.accept.answerLost"
        /// The server takes the Reject, and its answer never arrives.
        case invitationRejectAnswerLost = "invitation.reject.answerLost"
    }

    private let named: @Sendable () -> Set<Operation>

    public init(named: @escaping @Sendable () -> Set<Operation>) {
        self.named = named
    }

    /// No failures: every real build.
    public static let none = AppFaults { [] }

    /// The error a named request fails with: the one a server that can't be
    /// reached gives. A test reads the app's words for it from here.
    public static var unreachable: URLError { URLError(.cannotConnectToHost) }

    /// Throws `unreachable` if `operation` is named.
    public func check(_ operation: Operation) throws {
        if named().contains(operation) { throw Self.unreachable }
    }

    #if DEBUG
    /// Failures read from `path` each time a request asks: one name per line,
    /// such as `invitation.accept`. A test turns one on or off by writing the
    /// file again, with no relaunch. A missing, empty or unreadable file
    /// names none, and a name the app doesn't know is ignored.
    public static func file(_ path: String) -> AppFaults {
        AppFaults {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
            return parse(text)
        }
    }

    static func parse(_ text: String) -> Set<Operation> {
        Set(text.split(whereSeparator: \.isWhitespace).compactMap { Operation(rawValue: String($0)) })
    }

    /// The same written out, for a test that sets the failures.
    public static func text(for operations: [Operation]) -> String {
        operations.map(\.rawValue).joined(separator: "\n") + "\n"
    }
    #endif
}
