import Foundation
import WarTableCore
import WellSpentSync

/// All providers and the Linux shell use the same wire contract. Authentication
/// stays in the host transport, never in a view or an extension manifest.
public struct WarTableClient: Sendable {
    private let request: @Sendable (ExtensionRequest) async throws -> Data
    public init(request: @escaping @Sendable (ExtensionRequest) async throws -> Data) { self.request = request }

    public func get<T: Decodable & Sendable>(_ type: T.Type, group: UUID, path: [String] = [],
                                            query: [String: String] = [:]) async throws -> T {
        try await call(type, group: group, method: .get, path: path, query: query)
    }
    public func send<T: Decodable & Sendable, Body: Encodable & Sendable>(_ type: T.Type, group: UUID,
            method: ExtensionRequest.Method = .post, path: [String] = [], body: Body) async throws -> T {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try await call(type, group: group, method: method, path: path, body: encoder.encode(body))
    }
    public func acknowledge(group: UUID, conversation: UUID, sequence: Int) async throws {
        let encoder = JSONEncoder()
        let body = try encoder.encode(WTReadReceipt(conversationID: conversation, sequence: sequence))
        _ = try await request(ExtensionRequest(extensionID: "wellspent.wartable", method: .post,
            path: ["groups", group.uuidString, "receipts"], body: body))
    }
    private func call<T: Decodable & Sendable>(_ type: T.Type, group: UUID, method: ExtensionRequest.Method,
            path: [String], query: [String: String] = [:], body: Data? = nil) async throws -> T {
        let request = try ExtensionRequest(extensionID: "wellspent.wartable", method: method,
            path: ["groups", group.uuidString] + path, query: query, body: body)
        let data = try await self.request(request)
        try Task.checkCancellation()
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}
