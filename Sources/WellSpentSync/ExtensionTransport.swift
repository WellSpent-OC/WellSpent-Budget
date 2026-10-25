import Foundation

/// A narrow authenticated host service. The session token never leaves the host.
/// Only compiled extension routes on the account's existing server are accepted.
public protocol ExtensionTransport: Sendable {
    func extensionRequest(_ request: ExtensionRequest) async throws -> Data
}

public struct ExtensionRequest: Sendable {
    public enum Method: String, Sendable { case get = "GET", post = "POST", put = "PUT", delete = "DELETE", patch = "PATCH" }
    public enum Invalid: Error, Equatable { case unknownExtension, invalidPath, tooLarge }
    public let extensionID: String
    public let method: Method
    public let path: [String]
    public let query: [String: String]
    public let body: Data?
    public init(extensionID: String, method: Method, path: [String], query: [String: String] = [:], body: Data? = nil) throws {
        guard extensionID == "wellspent.wartable" else { throw Invalid.unknownExtension }
        guard path.count <= 12, path.allSatisfy({ component in
            !component.isEmpty && component.utf8.count <= 100 &&
            component.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }), query.count <= 10, query.allSatisfy({ $0.key.utf8.count <= 100 && $0.value.utf8.count <= 200 })
        else { throw Invalid.invalidPath }
        guard (body?.count ?? 0) <= 1_048_576 else { throw Invalid.tooLarge }
        self.extensionID = extensionID; self.method = method; self.path = path
        self.query = query; self.body = body
    }
}
