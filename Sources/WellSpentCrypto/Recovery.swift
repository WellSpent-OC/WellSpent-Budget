import Foundation
import Crypto

/// The twelve words that are the only way back in when every device is gone.
///
/// BIP39's English list, chosen for three properties a home-made list would not
/// have: every word is distinguishable from the first four letters, so the app can
/// autocomplete and catch typos; the list carries a checksum, so a wrong word is
/// caught before it produces a silently wrong key; and the words survive being
/// handwritten and read aloud over the phone in a way base32 does not.
///
/// This is not a wallet. There is no PBKDF2 seed step and no derivation path,
/// because nothing here interoperates with one.
public enum RecoveryCode {
    public static let wordCount = 12
    public static let entropyBytes = 16      // 128 bits
    static let bitsPerWord = 11
    static let checksumBits = 4              // entropy bits / 32

    public enum Failure: Error, Equatable, Sendable {
        case wrongWordCount(expected: Int, got: Int)
        case unknownWord(String)
        case checksumFailed
        case wordlistMissing
    }

    /// Loaded once. 2048 words, verified at load, because a truncated resource
    /// would otherwise produce codes that decode to the wrong key.
    public static let wordlist: [String] = {
        guard let url = Bundle.module.url(forResource: "bip39-english", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let words = text.split(whereSeparator: \.isNewline).map(String.init)
        return words.count == 2048 ? words : []
    }()

    private static let index: [String: Int] = {
        var m = [String: Int](minimumCapacity: 2048)
        for (i, w) in wordlist.enumerated() { m[w] = i }
        return m
    }()

    // MARK: - Generating

    /// 128 bits from the system's cryptographic generator. Never from a passphrase,
    /// never from anything a person chose.
    public static func generateEntropy() -> Data {
        SymmetricKey(size: .init(bitCount: entropyBytes * 8)).withUnsafeBytes { Data($0) }
    }

    public static func encode(entropy: Data) throws -> [String] {
        guard !wordlist.isEmpty else { throw Failure.wordlistMissing }
        guard entropy.count == entropyBytes else {
            throw CryptoError.badKeyLength(expected: entropyBytes, got: entropy.count)
        }

        var bits: [Bool] = []
        bits.reserveCapacity(entropyBytes * 8 + checksumBits)
        for byte in entropy {
            for shift in stride(from: 7, through: 0, by: -1) { bits.append((byte >> UInt8(shift)) & 1 == 1) }
        }
        // The checksum is the top four bits of SHA-256 over the entropy.
        let first = Array(SHA256.hash(data: entropy)).first ?? 0
        for shift in stride(from: 7, through: 8 - checksumBits, by: -1) {
            bits.append((first >> UInt8(shift)) & 1 == 1)
        }

        return (0 ..< wordCount).map { group in
            var value = 0
            for bit in 0 ..< bitsPerWord { value = (value << 1) | (bits[group * bitsPerWord + bit] ? 1 : 0) }
            return wordlist[value]
        }
    }

    public static func decode(words: [String]) throws -> Data {
        guard !wordlist.isEmpty else { throw Failure.wordlistMissing }
        guard words.count == wordCount else {
            throw Failure.wrongWordCount(expected: wordCount, got: words.count)
        }

        var bits: [Bool] = []
        bits.reserveCapacity(wordCount * bitsPerWord)
        for word in words {
            let key = word.trimmingCharacters(in: .whitespaces).lowercased()
            guard let value = index[key] else { throw Failure.unknownWord(word) }
            for shift in stride(from: bitsPerWord - 1, through: 0, by: -1) {
                bits.append((value >> shift) & 1 == 1)
            }
        }

        var entropy = Data(count: entropyBytes)
        for byteIndex in 0 ..< entropyBytes {
            var byte: UInt8 = 0
            for bit in 0 ..< 8 { byte = (byte << 1) | (bits[byteIndex * 8 + bit] ? 1 : 0) }
            entropy[byteIndex] = byte
        }

        let first = Array(SHA256.hash(data: entropy)).first ?? 0
        for (offset, shift) in stride(from: 7, through: 8 - checksumBits, by: -1).enumerated() {
            let expected = (first >> UInt8(shift)) & 1 == 1
            guard bits[entropyBytes * 8 + offset] == expected else { throw Failure.checksumFailed }
        }
        return entropy
    }

    // MARK: - Typing help

    /// BIP39 guarantees the first four letters identify a word. This is what makes
    /// the entry field forgiving without weakening anything.
    public static func completions(for prefix: String, limit: Int = 5) -> [String] {
        let p = prefix.trimmingCharacters(in: .whitespaces).lowercased()
        guard !p.isEmpty else { return [] }
        return wordlist.lazy.filter { $0.hasPrefix(p) }.prefix(limit).map { $0 }
    }
}

/// The blob the server holds: a person's identity keys, sealed under their
/// recovery code.
///
/// Safe to store on the server because the key is 128 bits of machine randomness,
/// so there is nothing to guess offline. The same blob sealed under a human-chosen
/// password would be a cracking job against every customer at once.
public struct RecoveryEscrow: Codable, Sendable {
    public let nonce: Data
    public let ciphertext: Data
    public let createdAt: Date

    public init(nonce: Data, ciphertext: Data, createdAt: Date) {
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.createdAt = createdAt
    }

    public static func seal(identity: IdentityKeyPair, entropy: Data, now: Date = Date()) throws -> RecoveryEscrow {
        let key = KeyDerivation.recoveryKey(entropy: entropy)
        let box = try AES.GCM.seal(identity.escrowBytes, using: key, nonce: AES.GCM.Nonce(),
                                   authenticating: Context.data(Context.recovery))
        return RecoveryEscrow(nonce: Data(box.nonce), ciphertext: box.ciphertext + box.tag, createdAt: now)
    }

    public func open(entropy: Data) throws -> IdentityKeyPair {
        let key = KeyDerivation.recoveryKey(entropy: entropy)
        let box = try AES.GCM.SealedBox(combined: nonce + ciphertext)
        let raw = try AES.GCM.open(box, using: key, authenticating: Context.data(Context.recovery))
        return try IdentityKeyPair(escrowBytes: raw)
    }

    public func open(words: [String]) throws -> IdentityKeyPair {
        try open(entropy: try RecoveryCode.decode(words: words))
    }
}

/// Asking for three of the twelve back, to prove the card is really in front of them.
///
/// Three positions rather than all twelve. Twelve trains people to paste from a
/// screenshot, which defeats the point. Three proves the paper exists.
public struct RecoveryChallenge: Equatable, Sendable {
    public let positions: [Int]      // 1-based, as shown to the person

    public static func make(count: Int = 3, of total: Int = RecoveryCode.wordCount) -> RecoveryChallenge {
        precondition(count <= total)
        var chosen = Set<Int>()
        while chosen.count < count { chosen.insert(Int.random(in: 1 ... total)) }
        return RecoveryChallenge(positions: chosen.sorted())
    }

    public init(positions: [Int]) { self.positions = positions }

    public func check(answers: [Int: String], against words: [String]) -> Bool {
        guard answers.count == positions.count else { return false }
        for position in positions {
            guard position >= 1, position <= words.count,
                  let given = answers[position]?.trimmingCharacters(in: .whitespaces).lowercased(),
                  given == words[position - 1]
            else { return false }
        }
        return true
    }
}
