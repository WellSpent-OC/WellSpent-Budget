import Foundation

public extension RecordCodec {
    /// A transaction's body with `createdBy` set to `owner`, changed in place.
    ///
    /// The server stamps the owner on a transaction that arrives without one.
    /// Decoding the body into `Transaction` and encoding it again dropped every
    /// field the server's build did not know, so a field added to transactions
    /// was lost until the server was redeployed. Setting the one key in the
    /// JSON object keeps the rest as sent. Nil when the body is not a JSON
    /// object.
    static func stampingOwner(_ body: Data, owner: UserID) -> Data? {
        guard var object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
        object["createdBy"] = owner.uuid.uuidString
        return try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
    }
}
