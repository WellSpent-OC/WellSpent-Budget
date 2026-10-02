import Foundation
import Vapor
import WellSpentCrypto

/// Vapor's `Content` is a marker on top of `Codable`, so these cost nothing at
/// runtime. They live here rather than in WellSpentCrypto so the client never has
/// to link Vapor to share a type with the server.
extension RecordEnvelope: @retroactive ResponseEncodable {}
extension RecordEnvelope: @retroactive RequestDecodable {}
extension RecordEnvelope: @retroactive Content {}

extension MembershipLogEntry: @retroactive ResponseEncodable {}
extension MembershipLogEntry: @retroactive RequestDecodable {}
extension MembershipLogEntry: @retroactive Content {}

extension WrappedKey: @retroactive ResponseEncodable {}
extension WrappedKey: @retroactive RequestDecodable {}
extension WrappedKey: @retroactive Content {}
