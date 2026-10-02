import Testing
import Foundation
import Crypto
@testable import WellSpentCrypto

@Suite("Access ladder")
struct AccessLevelTests {
    @Test func ladderIsAFloor() {
        #expect(AccessLevel.manage.allows(.read))
        #expect(AccessLevel.manage.allows(.write))
        #expect(AccessLevel.manage.allows(.manage))
        #expect(!AccessLevel.write.allows(.manage))
        #expect(!AccessLevel.none.allows(.read))
    }

    /// The quirk inherited from models/Membership.rb. An admin outranks a manager
    /// but is still not a superadmin. If this test ever fails, someone "tidied up"
    /// the comparison and silently promoted every admin in the system.
    @Test func superadminIsExactMatchNotAFloor() {
        #expect(AccessLevel.superadmin.allows(.superadmin))
        #expect(!AccessLevel.admin.allows(.superadmin))
        #expect(AccessLevel.superadmin.allows(.admin))
    }

    @Test func onlyReadIsCryptographicallyEnforced() {
        #expect(AccessLevel.read.isCryptographicallyEnforced)
        for level in [AccessLevel.write, .manage, .admin, .superadmin] {
            #expect(!level.isCryptographicallyEnforced,
                    "\(level) is enforced by the server and by peers, not by encryption")
        }
    }
}

@Suite("Padding hides length")
struct PaddingTests {
    @Test(arguments: [0, 1, 100, 251, 252, 253, 500, 1000, 4091, 4092, 5000, 20000])
    func roundTrip(size: Int) throws {
        let plain = Data(repeating: 0xAB, count: size)
        let padded = try Padding.pad(plain)
        #expect(padded.count == Padding.bucket(for: padded.count))
        #expect(try Padding.unpad(padded) == plain)
    }

    /// The point of padding: a 12-character merchant and a 200-character one must
    /// be indistinguishable on the wire.
    @Test func differentLengthsShareABucket() throws {
        let short = try Padding.pad(Data(repeating: 1, count: 12))
        let long  = try Padding.pad(Data(repeating: 1, count: 200))
        #expect(short.count == long.count)
    }

    @Test func bucketBoundaries() {
        #expect(Padding.bucket(for: 1) == 1024)
        #expect(Padding.bucket(for: 1024) == 1024)
        #expect(Padding.bucket(for: 1025) == 2048)
        #expect(Padding.bucket(for: 4096) == 4096)
        #expect(Padding.bucket(for: 4097) == 8192)
    }

    @Test func corruptLengthIsRejected() {
        var bad = Data([0xFF, 0xFF, 0xFF, 0xFF])
        bad.append(Data(repeating: 0, count: 252))
        #expect(throws: (any Error).self) { try Padding.unpad(bad) }
    }

    @Test func blobBuckets() {
        #expect(BlobPadding.bucket(for: 1) == 65536)
        #expect(BlobPadding.bucket(for: 100_000) == 131072)
    }
}

@Suite("Fingerprints and safety numbers")
struct FingerprintTests {
    @Test func formatAndStability() {
        let keys = IdentityKeyPair.generate().publicKeys
        let a = keys.fingerprint.description
        #expect(a == keys.fingerprint.description)
        #expect(a.count == 14)                            // 12 characters plus 2 dashes
        #expect(a.filter { $0 == "-" }.count == 2)
        for c in a where c != "-" {
            #expect(Fingerprint.alphabet.contains(c), "\(c) is not Crockford base32")
        }
        #expect(!a.contains("I") && !a.contains("L") && !a.contains("O") && !a.contains("U"))
    }

    @Test func distinctKeysGiveDistinctFingerprints() {
        #expect(IdentityKeyPair.generate().publicKeys.fingerprint
                != IdentityKeyPair.generate().publicKeys.fingerprint)
    }

    /// Both people must read the same number without agreeing who goes first.
    @Test func safetyNumberIsOrderIndependent() {
        let robin = IdentityKeyPair.generate().publicKeys
        let leslie = IdentityKeyPair.generate().publicKeys
        #expect(SafetyNumber(robin, leslie) == SafetyNumber(leslie, robin))
        #expect(SafetyNumber(robin, leslie).digits.count == 35)   // 6 groups of 5, 5 spaces
    }
}

@Suite("Record sealing")
struct RecordSealTests {
    @Test func roundTrip() throws {
        let key = ScopedKey.generate(scope: .budget(BudgetID()))
        let id = RecordID()
        let plain = Data(#"{"amount":-42.17,"merchant":"Home Depot"}"#.utf8)
        let sealed = try RecordSeal.seal(plain, scopeKey: key.material, recordID: id)
        #expect(try RecordSeal.open(sealed, scopeKey: key.material, recordID: id) == plain)
    }

    @Test func ciphertextHidesLength() throws {
        let key = ScopedKey.generate(scope: .budget(BudgetID()))
        let a = try RecordSeal.seal(Data("coffee".utf8), scopeKey: key.material, recordID: RecordID())
        let b = try RecordSeal.seal(Data(repeating: 0x41, count: 200), scopeKey: key.material, recordID: RecordID())
        #expect(a.ciphertext.count == b.ciphertext.count)
    }

    @Test func wrongRecordIDFails() throws {
        let key = ScopedKey.generate(scope: .budget(BudgetID()))
        let sealed = try RecordSeal.seal(Data("x".utf8), scopeKey: key.material, recordID: RecordID())
        #expect(throws: (any Error).self) {
            try RecordSeal.open(sealed, scopeKey: key.material, recordID: RecordID())
        }
    }

    @Test func tamperedCiphertextFails() throws {
        let key = ScopedKey.generate(scope: .budget(BudgetID()))
        let id = RecordID()
        let sealed = try RecordSeal.seal(Data("x".utf8), scopeKey: key.material, recordID: id)
        var ct = sealed.ciphertext
        ct[ct.startIndex] ^= 0x01
        let tampered = RecordSeal.Sealed(nonce: sealed.nonce, ciphertext: ct)
        #expect(throws: (any Error).self) {
            try RecordSeal.open(tampered, scopeKey: key.material, recordID: id)
        }
    }

    /// Two devices editing the same record offline must not collide.
    @Test func noncesDiffer() throws {
        let key = ScopedKey.generate(scope: .budget(BudgetID()))
        let id = RecordID()
        let a = try RecordSeal.seal(Data("x".utf8), scopeKey: key.material, recordID: id)
        let b = try RecordSeal.seal(Data("x".utf8), scopeKey: key.material, recordID: id)
        #expect(a.nonce != b.nonce)
        #expect(a.ciphertext != b.ciphertext)
    }
}

@Suite("Key wrapping")
struct KeyWrapTests {
    @Test func wrapGroupKeyToAnotherPerson() throws {
        let robin = IdentityKeyPair.generate()
        let leslie = IdentityKeyPair.generate()
        let groupKey = ScopedKey.generate(scope: .group(GroupID()))

        let wrapped = try KeyWrap.wrapToIdentity(groupKey, recipient: leslie.publicKeys,
                                                 recipientUserID: UserID(),
                                                 sender: robin, senderUserID: UserID())
        let opened = try KeyWrap.unwrapToIdentity(wrapped, recipient: leslie, sender: robin.publicKeys)
        #expect(opened.rawBytes == groupKey.rawBytes)
        #expect(opened.scope == groupKey.scope)
    }

    @Test func aStrangerCannotUnwrap() throws {
        let robin = IdentityKeyPair.generate()
        let leslie = IdentityKeyPair.generate()
        let stranger = IdentityKeyPair.generate()
        let key = ScopedKey.generate(scope: .group(GroupID()))
        let wrapped = try KeyWrap.wrapToIdentity(key, recipient: leslie.publicKeys,
                                                 recipientUserID: UserID(), sender: robin, senderUserID: UserID())
        #expect(throws: (any Error).self) {
            try KeyWrap.unwrapToIdentity(wrapped, recipient: stranger, sender: robin.publicKeys)
        }
    }

    /// Auth mode means the recipient learns who wrapped this without a separate
    /// signature. Claiming it came from someone else must fail.
    @Test func forgedSenderFails() throws {
        let robin = IdentityKeyPair.generate()
        let leslie = IdentityKeyPair.generate()
        let impostor = IdentityKeyPair.generate()
        let key = ScopedKey.generate(scope: .group(GroupID()))
        let wrapped = try KeyWrap.wrapToIdentity(key, recipient: leslie.publicKeys,
                                                 recipientUserID: UserID(), sender: robin, senderUserID: UserID())
        #expect(throws: (any Error).self) {
            try KeyWrap.unwrapToIdentity(wrapped, recipient: leslie, sender: impostor.publicKeys)
        }
    }

    @Test func budgetKeyUnderGroupKey() throws {
        let groupKey = ScopedKey.generate(scope: .group(GroupID()))
        let budgetKey = ScopedKey.generate(scope: .budget(BudgetID()))
        let wrapped = try KeyWrap.wrapUnderGroupKey(budgetKey, groupKey: groupKey.material, senderUserID: UserID())
        #expect(try KeyWrap.unwrapUnderGroupKey(wrapped, groupKey: groupKey.material).rawBytes == budgetKey.rawBytes)
    }

    /// A wrap from one epoch must not open as another. Scope and epoch go into the
    /// HPKE info string, so the AEAD catches it.
    @Test func epochIsBoundIntoTheWrap() throws {
        let robin = IdentityKeyPair.generate()
        let leslie = IdentityKeyPair.generate()
        let key = ScopedKey.generate(scope: .group(GroupID()), epoch: Epoch(3))
        let real = try KeyWrap.wrapToIdentity(key, recipient: leslie.publicKeys,
                                              recipientUserID: UserID(), sender: robin, senderUserID: UserID())
        let relabelled = WrappedKey(scope: real.scope, epoch: Epoch(4), wrapKind: real.wrapKind,
                                    ciphersuite: real.ciphersuite, recipientUserID: real.recipientUserID,
                                    senderUserID: real.senderUserID, encapsulatedKey: real.encapsulatedKey,
                                    nonce: real.nonce, ciphertext: real.ciphertext)
        #expect(throws: (any Error).self) {
            try KeyWrap.unwrapToIdentity(relabelled, recipient: leslie, sender: robin.publicKeys)
        }
    }
}

@Suite("Invites")
struct InviteTests {
    private func makeInvite(robin: IdentityKeyPair) -> (Invite, InviteSecret) {
        let secret = InviteSecret()
        let invite = Invite(id: secret.id, scope: .group(GroupID()), level: .write,
                            historyAccess: .all, inviterUserID: UserID(),
                            inviterKeys: robin.publicKeys,
                            expiresAt: Date().addingTimeInterval(7 * 86400))
        return (invite, secret)
    }

    @Test func acceptanceRoundTrip() throws {
        let robin = IdentityKeyPair.generate()
        let leslie = IdentityKeyPair.generate()
        let (invite, secret) = makeInvite(robin: robin)

        let acceptance = InviteAcceptance(accepterUserID: UserID(),
                                          accepterKeys: leslie.publicKeys,
                                          displayName: "Leslie")
        let sealed = try InviteCrypto.sealAcceptance(acceptance, invite: invite, secret: secret)
        let opened = try InviteCrypto.openAcceptance(sealed, invite: invite, secret: secret, inviter: robin)

        #expect(opened.displayName == "Leslie")
        #expect(opened.accepterKeys == leslie.publicKeys)
    }

    /// The property the whole invite design rests on.
    ///
    /// The server holds the invite row and can see the inviter's public key, so it
    /// could try to answer the invite itself and insert its own key. It cannot,
    /// because it never saw the secret that went over iMessage. Without that secret
    /// the acceptance does not open, and the inviter never adds the impostor.
    @Test func serverWithoutTheSecretCannotAnswerTheInvite() throws {
        let robin = IdentityKeyPair.generate()
        let attacker = IdentityKeyPair.generate()
        let (invite, realSecret) = makeInvite(robin: robin)

        let guessed = InviteSecret()          // everything the server has, except the secret
        let forged = InviteAcceptance(accepterUserID: UserID(),
                                      accepterKeys: attacker.publicKeys,
                                      displayName: "Leslie")
        let sealed = try InviteCrypto.sealAcceptance(forged, invite: invite, secret: guessed)

        #expect(throws: (any Error).self,
                "an acceptance sealed without the invite secret must not open") {
            try InviteCrypto.openAcceptance(sealed, invite: invite, secret: realSecret, inviter: robin)
        }
    }

    @Test func inviteIDRevealsNothingAboutTheSecret() {
        let secret = InviteSecret()
        #expect(secret.id.count == 16)
        #expect(!secret.bytes.starts(with: secret.id))
        #expect(secret.id == KeyDerivation.inviteID(inviteSecret: secret.bytes))
    }
}

@Suite("Identity and recovery")
struct IdentityTests {
    @Test func escrowRoundTrip() throws {
        let original = IdentityKeyPair.generate()
        let restored = try IdentityKeyPair(escrowBytes: original.escrowBytes)
        #expect(restored.publicKeys == original.publicKeys)
        #expect(original.escrowBytes.count == 64)
    }

    @Test func recoveryKeyIsDeterministic() {
        let entropy = Data(repeating: 0x5A, count: 16)
        let a = KeyDerivation.recoveryKey(entropy: entropy).withUnsafeBytes { Data($0) }
        let b = KeyDerivation.recoveryKey(entropy: entropy).withUnsafeBytes { Data($0) }
        #expect(a == b)
        #expect(a.count == 32)
    }

    /// Losing the recovery code with a device still alive is survivable. The
    /// identity key is in hand, so a new code just re-wraps the same 64 bytes.
    @Test func recoveryCodeCanBeReplacedWithoutChangingIdentity() throws {
        let identity = IdentityKeyPair.generate()
        let firstKey  = KeyDerivation.recoveryKey(entropy: Data(repeating: 1, count: 16))
        let secondKey = KeyDerivation.recoveryKey(entropy: Data(repeating: 2, count: 16))

        let firstBox  = try AES.GCM.seal(identity.escrowBytes, using: firstKey)
        let secondBox = try AES.GCM.seal(identity.escrowBytes, using: secondKey)

        let reopened = try IdentityKeyPair(
            escrowBytes: try AES.GCM.open(AES.GCM.SealedBox(combined: secondBox.combined!), using: secondKey))
        #expect(reopened.publicKeys == identity.publicKeys)
        #expect(firstBox.combined != secondBox.combined)
    }
}

@Suite("Record types")
struct RecordTypeTests {
    /// A name this build has never heard of decodes, and encodes back the same,
    /// so a server or an older app can pass it along untouched.
    @Test func anUnknownTypeSurvivesTheRoundTrip() throws {
        let json = Data(#""somethingNew""#.utf8)
        let decoded = try JSONDecoder().decode(RecordType.self, from: json)
        #expect(decoded.rawValue == "somethingNew")
        #expect(!decoded.isKnown)
        #expect(try JSONEncoder().encode(decoded) == json)
        #expect(try JSONEncoder().encode(RecordType.transaction) == Data(#""transaction""#.utf8),
                "known types are on the wire exactly as before")
        #expect(RecordType.transaction.isKnown)
    }
}
