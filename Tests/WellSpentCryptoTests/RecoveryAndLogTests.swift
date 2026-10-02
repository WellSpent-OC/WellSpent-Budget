import Testing
import Foundation
import Crypto
@testable import WellSpentCrypto

@Suite("Recovery code")
struct RecoveryCodeTests {
    @Test func wordlistLoadedAndWellFormed() {
        #expect(RecoveryCode.wordlist.count == 2048)
        #expect(RecoveryCode.wordlist.first == "abandon")
        #expect(RecoveryCode.wordlist.last == "zoo")
        // The property the typing help depends on.
        let prefixes = Set(RecoveryCode.wordlist.map { String($0.prefix(4)) })
        #expect(prefixes.count == 2048, "BIP39 guarantees four letters identify a word")
    }

    @Test func roundTrip() throws {
        for _ in 0 ..< 50 {
            let entropy = RecoveryCode.generateEntropy()
            let words = try RecoveryCode.encode(entropy: entropy)
            #expect(words.count == 12)
            #expect(try RecoveryCode.decode(words: words) == entropy)
        }
    }

    /// The official BIP39 test vector. If this passes, the bit packing is right,
    /// and a code written on paper years from now will still decode.
    @Test func knownAnswerVector() throws {
        let entropy = Data(repeating: 0x00, count: 16)
        let words = try RecoveryCode.encode(entropy: entropy)
        #expect(words == Array(repeating: "abandon", count: 11) + ["about"])

        let ffff = Data(repeating: 0xFF, count: 16)
        #expect(try RecoveryCode.encode(entropy: ffff) == Array(repeating: "zoo", count: 11) + ["wrong"])
    }

    @Test func caseAndSpacingAreForgiven() throws {
        let entropy = RecoveryCode.generateEntropy()
        let words = try RecoveryCode.encode(entropy: entropy)
        let messy = words.map { "  " + $0.uppercased() + " " }
        #expect(try RecoveryCode.decode(words: messy) == entropy)
    }

    /// A single mistyped word must never silently decode to a different key. That
    /// would look exactly like data loss to the person typing it.
    ///
    /// The checksum catches roughly fifteen in sixteen single-word errors. The rest
    /// decode to different entropy, which the escrow then refuses to open. Either
    /// way the person is told, rather than handed a key that does not work.
    @Test func oneWrongWordNeverDecodesBackToTheOriginal() throws {
        var caughtByChecksum = 0
        var caughtByDifferentEntropy = 0

        for _ in 0 ..< 64 {
            let entropy = RecoveryCode.generateEntropy()
            var words = try RecoveryCode.encode(entropy: entropy)
            let wrong = RecoveryCode.wordlist.first { $0 != words[0] }
            words[0] = try #require(wrong)

            do {
                let decoded = try RecoveryCode.decode(words: words)
                #expect(decoded != entropy, "a wrong word must not reproduce the original key")
                caughtByDifferentEntropy += 1
            } catch RecoveryCode.Failure.checksumFailed {
                caughtByChecksum += 1
            }
        }

        #expect(caughtByChecksum + caughtByDifferentEntropy == 64)
        #expect(caughtByChecksum > 0, "the checksum should be doing most of the work")
    }

    @Test func wrongWordCountRejected() {
        #expect(throws: RecoveryCode.Failure.wrongWordCount(expected: 12, got: 11)) {
            try RecoveryCode.decode(words: Array(repeating: "abandon", count: 11))
        }
    }

    @Test func wordOutsideTheListRejected() {
        var words = Array(repeating: "abandon", count: 11)
        words.append("notaword")
        #expect(throws: RecoveryCode.Failure.unknownWord("notaword")) {
            try RecoveryCode.decode(words: words)
        }
    }

    @Test func completionsHelpTyping() {
        #expect(RecoveryCode.completions(for: "aban") == ["abandon"])
        #expect(RecoveryCode.completions(for: "zo").contains("zoo"))
        #expect(RecoveryCode.completions(for: "").isEmpty)
    }
}

@Suite("Escrow and the confirmation challenge")
struct EscrowTests {
    @Test func escrowRoundTripThroughWords() throws {
        let identity = IdentityKeyPair.generate()
        let entropy = RecoveryCode.generateEntropy()
        let words = try RecoveryCode.encode(entropy: entropy)

        let escrow = try RecoveryEscrow.seal(identity: identity, entropy: entropy)
        let restored = try escrow.open(words: words)
        #expect(restored.publicKeys == identity.publicKeys)
    }

    /// This is what a stolen server database looks like: blobs and nothing else.
    @Test func wrongCodeCannotOpenTheEscrow() throws {
        let identity = IdentityKeyPair.generate()
        let escrow = try RecoveryEscrow.seal(identity: identity, entropy: RecoveryCode.generateEntropy())
        #expect(throws: (any Error).self) {
            try escrow.open(entropy: RecoveryCode.generateEntropy())
        }
    }

    @Test func challengeAcceptsTheRightWords() throws {
        let words = try RecoveryCode.encode(entropy: RecoveryCode.generateEntropy())
        let challenge = RecoveryChallenge(positions: [3, 7, 11])
        let answers = [3: words[2], 7: words[6], 11: words[10]]
        #expect(challenge.check(answers: answers, against: words))
    }

    @Test func challengeRejectsAWrongWord() throws {
        let words = try RecoveryCode.encode(entropy: RecoveryCode.generateEntropy())
        let challenge = RecoveryChallenge(positions: [3, 7, 11])
        let answers = [3: words[2], 7: "abandon", 11: words[10]]
        #expect(!challenge.check(answers: answers, against: words) || words[6] == "abandon")
    }

    @Test func challengePicksDistinctPositionsInRange() {
        for _ in 0 ..< 200 {
            let c = RecoveryChallenge.make()
            #expect(c.positions.count == 3)
            #expect(Set(c.positions).count == 3)
            #expect(c.positions.allSatisfy { $0 >= 1 && $0 <= 12 })
            #expect(c.positions == c.positions.sorted())
        }
    }
}

// MARK: - Membership log

private struct Person {
    let id = UserID()
    let identity = IdentityKeyPair.generate()
    let device = DeviceKeyPair()
    var keys: IdentityPublicKeys { identity.publicKeys }
}

private struct LogBuilder {
    let scope: KeyScope
    var entries: [MembershipLogEntry] = []
    var epoch = Epoch.initial

    init(scope: KeyScope, founder: Person) throws {
        self.scope = scope
        try append(action: .found, subject: founder, level: .superadmin, by: founder)
    }

    var head: Data { entries.last?.hash ?? MembershipLogEntry.rootHash }

    mutating func append(action: MembershipAction, subject: Person, level: AccessLevel,
                         by author: Person, bumpEpoch: Bool = false) throws {
        if bumpEpoch { epoch = epoch.next }
        let entry = try MembershipLogEntry.signed(
            scope: scope,
            sequence: UInt64(entries.count),
            previousHash: head,
            action: action,
            subjectUserID: subject.id,
            subjectKeys: subject.keys,
            level: level,
            epochAfter: epoch,
            deviceID: subject.device.id,
            devicePublicKey: subject.device.publicKey,
            author: author.identity,
            authorUserID: author.id
        )
        entries.append(entry)
    }
}

@Suite("Membership log")
struct MembershipLogTests {
    @Test func foundingThenAddingTwoPeople() throws {
        let scope = KeyScope.group(GroupID())
        let robin = Person(), leslie = Person(), jamie = Person()

        var log = try LogBuilder(scope: scope, founder: robin)
        try log.append(action: .add, subject: leslie, level: .write, by: robin)
        try log.append(action: .add, subject: jamie, level: .read, by: robin)

        let state = try MembershipLog.replay(log.entries, scope: scope)
        #expect(state.founder == robin.id)
        #expect(state.level(of: robin.id) == .superadmin)
        #expect(state.level(of: leslie.id) == .write)
        #expect(state.level(of: jamie.id) == .read)
        #expect(state.members.count == 3)
    }

    @Test func removalTakesAccessAndBumpsTheEpoch() throws {
        let scope = KeyScope.group(GroupID())
        let robin = Person(), jamie = Person()

        var log = try LogBuilder(scope: scope, founder: robin)
        try log.append(action: .add, subject: jamie, level: .write, by: robin)
        #expect(try MembershipLog.replay(log.entries, scope: scope).epoch == .initial)

        try log.append(action: .remove, subject: jamie, level: .none, by: robin, bumpEpoch: true)
        let state = try MembershipLog.replay(log.entries, scope: scope)
        #expect(state.level(of: jamie.id) == AccessLevel.none)
        #expect(state.epoch == Epoch(1))
        #expect(!state.allows(jamie.id, .read))
    }

    /// A server that quietly edits history has to break the hash chain to do it.
    @Test func tamperingWithHistoryBreaksTheChain() throws {
        let scope = KeyScope.group(GroupID())
        let robin = Person(), jamie = Person()
        var log = try LogBuilder(scope: scope, founder: robin)
        try log.append(action: .add, subject: jamie, level: .read, by: robin)

        // Promote Jamie by rewriting the entry in place, as a malicious server would.
        let original = log.entries[1]
        log.entries[1] = MembershipLogEntry(
            scope: original.scope, sequence: original.sequence, previousHash: original.previousHash,
            action: original.action, subjectUserID: original.subjectUserID, subjectKeys: original.subjectKeys,
            level: .admin,                                   // the lie
            epochAfter: original.epochAfter, at: original.at,
            authorUserID: original.authorUserID,
            deviceID: original.deviceID, devicePublicKey: original.devicePublicKey,
            authorSignature: original.authorSignature
        )

        #expect(throws: MembershipLogError.badSignature(atSequence: 1)) {
            try MembershipLog.replay(log.entries, scope: scope)
        }
    }

    @Test func droppingAnEntryBreaksTheChain() throws {
        let scope = KeyScope.group(GroupID())
        let robin = Person(), leslie = Person(), jamie = Person()
        var log = try LogBuilder(scope: scope, founder: robin)
        try log.append(action: .add, subject: leslie, level: .write, by: robin)
        try log.append(action: .add, subject: jamie, level: .read, by: robin)

        var truncated = log.entries
        truncated.remove(at: 1)
        #expect(throws: (any Error).self) { try MembershipLog.replay(truncated, scope: scope) }
    }

    /// Someone with `write` cannot add members, however convincing the entry looks,
    /// because the replay checks their level at that point in the chain.
    @Test func aWriterCannotAddMembers() throws {
        let scope = KeyScope.group(GroupID())
        let robin = Person(), leslie = Person(), stranger = Person()

        var log = try LogBuilder(scope: scope, founder: robin)
        try log.append(action: .add, subject: leslie, level: .write, by: robin)
        try log.append(action: .add, subject: stranger, level: .read, by: leslie)

        #expect(throws: MembershipLogError.authorNotEntitled(atSequence: 2, needed: .manage)) {
            try MembershipLog.replay(log.entries, scope: scope)
        }
    }

    /// Promoting someone to manage takes admin, not manage. Otherwise a manager
    /// could mint another manager and the ladder means nothing.
    @Test func promotingToManageNeedsAdmin() throws {
        let scope = KeyScope.group(GroupID())
        let robin = Person(), manager = Person(), target = Person()

        var log = try LogBuilder(scope: scope, founder: robin)
        try log.append(action: .add, subject: manager, level: .manage, by: robin)
        try log.append(action: .add, subject: target, level: .manage, by: manager)

        #expect(throws: MembershipLogError.authorNotEntitled(atSequence: 2, needed: .admin)) {
            try MembershipLog.replay(log.entries, scope: scope)
        }
    }

    @Test func aManagerCanAddAWriter() throws {
        let scope = KeyScope.group(GroupID())
        let robin = Person(), manager = Person(), target = Person()

        var log = try LogBuilder(scope: scope, founder: robin)
        try log.append(action: .add, subject: manager, level: .manage, by: robin)
        try log.append(action: .add, subject: target, level: .write, by: manager)

        let state = try MembershipLog.replay(log.entries, scope: scope)
        #expect(state.level(of: target.id) == .write)
    }

    /// superadmin is an exact match rather than a floor, so nobody can reach it to
    /// remove the founder.
    @Test func theFounderCannotBeRemoved() throws {
        let scope = KeyScope.group(GroupID())
        let robin = Person(), admin = Person()

        var log = try LogBuilder(scope: scope, founder: robin)
        try log.append(action: .add, subject: admin, level: .admin, by: robin)
        try log.append(action: .remove, subject: robin, level: .none, by: admin, bumpEpoch: true)

        #expect(throws: (any Error).self) { try MembershipLog.replay(log.entries, scope: scope) }
    }

    /// A founding entry vouches for itself. Accepted anywhere but first, it let
    /// a member who can only view sign herself in as founder and superadmin,
    /// with the power to delete the group for everyone.
    @Test func onlyTheFirstEntryCanFoundTheGroup() throws {
        let scope = KeyScope.group(GroupID())
        let robin = Person(), mallory = Person()

        var log = try LogBuilder(scope: scope, founder: robin)
        try log.append(action: .add, subject: mallory, level: .read, by: robin)
        try log.append(action: .found, subject: mallory, level: .superadmin, by: mallory)

        #expect(throws: MembershipLogError.foundingEntryNotFirst(atSequence: 2)) {
            try MembershipLog.replay(log.entries, scope: scope)
        }
    }

    @Test func removalRequiresRotationButLevelChangeDoesNot() {
        #expect(MembershipLog.requiresRotation(.remove))
        #expect(MembershipLog.requiresRotation(.revokeDevice))
        #expect(!MembershipLog.requiresRotation(.changeLevel))
        #expect(!MembershipLog.requiresRotation(.add))
    }

    @Test func emptyLogIsRejected() {
        #expect(throws: MembershipLogError.empty) {
            try MembershipLog.replay([], scope: .group(GroupID()))
        }
    }
}

// MARK: - Record envelopes

private struct Note: Codable, Equatable {
    var merchant: String
    var amountCents: Int
}

@Suite("Record envelopes")
struct RecordEnvelopeTests {
    private func fixture() -> (ScopedKey, DeviceKeyPair, UserID, GroupID, BudgetID) {
        (ScopedKey.generate(scope: .budget(BudgetID())), DeviceKeyPair(), UserID(), GroupID(), BudgetID())
    }

    @Test func sealAndOpen() throws {
        let (key, device, user, group, budget) = fixture()
        let note = Note(merchant: "Hilltop", amountCents: 14208)

        let envelope = try RecordCodec.seal(
            note, recordID: RecordID(), recordType: .transaction, groupID: group, budgetID: budget,
            scopeKey: key, lamport: 7, author: user, device: device, membershipSequence: 3
        )
        let opened = try RecordCodec.open(
            Note.self, from: envelope, scopeKey: key,
            deviceKey: device.signing.publicKey, authorLevel: .write
        )
        #expect(opened == note)
        #expect(envelope.lamport == 7)
        #expect(envelope.payloadKind == .snapshot)
    }

    /// A reader still holds the key, so the ciphertext will open. The level check
    /// is what stops their write being accepted.
    @Test func aReaderCannotWrite() throws {
        let (key, device, user, group, budget) = fixture()
        let envelope = try RecordCodec.seal(
            Note(merchant: "x", amountCents: 1), recordID: RecordID(), recordType: .transaction,
            groupID: group, budgetID: budget, scopeKey: key, lamport: 1,
            author: user, device: device, membershipSequence: 1
        )
        #expect(throws: EnvelopeError.authorNotEntitled(.read)) {
            try RecordCodec.open(Note.self, from: envelope, scopeKey: key,
                                 deviceKey: device.signing.publicKey, authorLevel: .read)
        }
    }

    /// The server knows the group and budget ids in the clear, so it could try to
    /// move a record between budgets. The signature covers those fields.
    @Test func theServerCannotMoveARecordBetweenBudgets() throws {
        let (key, device, user, group, budget) = fixture()
        let real = try RecordCodec.seal(
            Note(merchant: "Costco", amountCents: 28631), recordID: RecordID(), recordType: .transaction,
            groupID: group, budgetID: budget, scopeKey: key, lamport: 2,
            author: user, device: device, membershipSequence: 1
        )

        let moved = RecordEnvelope(
            version: real.version, recordID: real.recordID, recordType: real.recordType,
            groupID: real.groupID, budgetID: BudgetID(),          // the tampering
            keyEpoch: real.keyEpoch, ciphersuite: real.ciphersuite, payloadKind: real.payloadKind,
            nonce: real.nonce, ciphertext: real.ciphertext, lamport: real.lamport,
            authorUserID: real.authorUserID, authorDeviceID: real.authorDeviceID,
            membershipSequence: real.membershipSequence, isDeleted: real.isDeleted,
            signature: real.signature
        )
        #expect(!moved.verifySignature(byDeviceKey: device.signing.publicKey))
        #expect(throws: EnvelopeError.badSignature) {
            try RecordCodec.open(Note.self, from: moved, scopeKey: key,
                                 deviceKey: device.signing.publicKey, authorLevel: .write)
        }
    }

    @Test func aRevokedDeviceSignatureIsRejected() throws {
        let (key, device, user, group, budget) = fixture()
        let envelope = try RecordCodec.seal(
            Note(merchant: "x", amountCents: 1), recordID: RecordID(), recordType: .transaction,
            groupID: group, budgetID: budget, scopeKey: key, lamport: 1,
            author: user, device: device, membershipSequence: 1
        )
        let otherDevice = DeviceKeyPair()
        #expect(!envelope.verifySignature(byDeviceKey: otherDevice.signing.publicKey))
    }

    @Test func anOldEpochKeyWillNotOpenANewRecord() throws {
        let scope = KeyScope.budget(BudgetID())
        let oldKey = ScopedKey.generate(scope: scope, epoch: Epoch(1))
        let newKey = ScopedKey.generate(scope: scope, epoch: Epoch(2))
        let device = DeviceKeyPair()

        let envelope = try RecordCodec.seal(
            Note(merchant: "after rotation", amountCents: 500), recordID: RecordID(),
            recordType: .transaction, groupID: GroupID(), budgetID: BudgetID(),
            scopeKey: newKey, lamport: 1, author: UserID(), device: device, membershipSequence: 2
        )
        #expect(throws: EnvelopeError.wrongScopeKey) {
            try RecordCodec.open(Note.self, from: envelope, scopeKey: oldKey,
                                 deviceKey: device.signing.publicKey, authorLevel: .write)
        }
    }
}

@Suite("Lamport clock")
struct LamportTests {
    @Test func tickAlwaysMovesForward() {
        var clock = LamportClock()
        #expect(clock.tick() == 1)
        #expect(clock.tick() == 2)
        clock.witness(10)
        #expect(clock.tick() == 11)
        clock.witness(3)                 // older news changes nothing
        #expect(clock.tick() == 12)
    }

    @Test func conflictResolutionIsDeterministicOnEveryDevice() throws {
        let key = ScopedKey.generate(scope: .budget(BudgetID()))
        let deviceA = DeviceKeyPair(), deviceB = DeviceKeyPair()
        let recordID = RecordID()

        func write(_ text: String, lamport: UInt64, device: DeviceKeyPair) throws -> RecordEnvelope {
            try RecordCodec.seal(Note(merchant: text, amountCents: 1), recordID: recordID,
                                 recordType: .transaction, groupID: GroupID(), budgetID: BudgetID(),
                                 scopeKey: key, lamport: lamport, author: UserID(),
                                 device: device, membershipSequence: 1)
        }

        let older = try write("mac", lamport: 4, device: deviceA)
        let newer = try write("iphone", lamport: 5, device: deviceB)
        #expect(LamportClock.wins(newer, over: older))
        #expect(!LamportClock.wins(older, over: newer))

        // A true tie must still resolve the same way for both devices.
        let tieA = try write("mac", lamport: 9, device: deviceA)
        let tieB = try write("iphone", lamport: 9, device: deviceB)
        #expect(LamportClock.wins(tieA, over: tieB) != LamportClock.wins(tieB, over: tieA))
    }
}
