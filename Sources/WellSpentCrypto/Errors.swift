import Foundation

public enum CryptoError: Error, Equatable, Sendable {
    case badKeyLength(expected: Int, got: Int)
    case paddingCorrupt(reason: String)
    case nonceWrongSize(expected: Int, got: Int)
    case payloadTooLarge(limit: Int, got: Int)
    case recoveryCodeChecksumFailed
}
