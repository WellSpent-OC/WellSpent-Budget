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
        let carriesDevice = action == .found || action == .addDevice
        let entry = try MembershipLogEntry.signed(
            scope: scope,
            sequence: UInt64(entries.count),
            previousHash: head,
            action: action,
            subjectUserID: subject.id,
            subjectKeys: subject.keys,
            level: level,
            epochAfter: epoch,
            // A device is registered only by the founding entry or one of its own.
            deviceID: carriesDevice ? subject.device.id : nil,
            devicePublicKey: carriesDevice ? subject.device.publicKey : nil,
            author: author.identity,
            authorUserID: author.id
        )
        entries.append(entry)
    }

    /// An entry with every field chosen by the test. The epoch stays where it
    /// is unless one is given.
    mutating func appendRaw(_ action: MembershipAction, subject: UserID,
                            keys: IdentityPublicKeys? = nil, level: AccessLevel = .read,
                            device: DeviceID? = nil, devicePublicKey: Data? = nil,
                            epochAfter: Epoch? = nil, by author: Person) throws {
        entries.append(try MembershipLogEntry.signed(
            scope: scope, sequence: UInt64(entries.count), previousHash: head, action: action,
            subjectUserID: subject, subjectKeys: keys, level: level,
            epochAfter: epochAfter ?? epoch, deviceID: device, devicePublicKey: devicePublicKey,
            author: author.identity, authorUserID: author.id))
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

    // MARK: What an entry may change

    /// Mallory at Manage signs an entry that puts her keys in Robin's place.
    /// Every entry Robin signed after that was refused, and the keys for a new
    /// epoch went to her. Only Robin may change his keys, and an admin cannot
    /// slip someone else's in with a level change either.
    @Test func onlyTheOwnerOfKeysCanReplaceThem() throws {
        let scope = KeyScope.group(GroupID())
        let robin = Person(), mallory = Person(), jamie = Person()
        var log = try LogBuilder(scope: scope, founder: robin)
        try log.append(action: .add, subject: mallory, level: .manage, by: robin)
        try log.append(action: .addDevice, subject: mallory, level: .manage, by: mallory)
        try log.append(action: .add, subject: jamie, level: .admin, by: robin)
        let before = log

        try log.appendRaw(.rotateIdentity, subject: robin.id, keys: mallory.keys, by: mallory)
        #expect(refusal(log.entries, scope).hasPrefix("keysAlreadyEstablished"))

        log = before
        try log.appendRaw(.changeLevel, subject: mallory.id, keys: jamie.keys, level: .manage, by: jamie)
        #expect(refusal(log.entries, scope).hasPrefix("keysAlreadyEstablished"),
                "a level change cannot carry someone else's keys")

        log = before
        let fresh = IdentityKeyPair.generate()
        try log.appendRaw(.rotateIdentity, subject: robin.id, keys: fresh.publicKeys, by: robin)
        #expect(try MembershipLog.replay(log.entries, scope: scope).keys[robin.id] == fresh.publicKeys,
                "his own keys are his to change")
    }

    /// Keys count as someone's once they have signed an entry with them. A
    /// manager added Jamie, before he joined, with keys she made, and with
    /// keys never changing, the real ones could never go in: every later add
    /// was refused. Keys nobody has signed with can be replaced by a later
    /// add, and a removal clears them.
    @Test func keysNobodyHasSignedWithCanBeReplaced() throws {
        let scope = KeyScope.group(GroupID())
        let robin = Person(), mallory = Person(), jamie = Person(), madeUp = Person()
        var log = try LogBuilder(scope: scope, founder: robin)
        try log.append(action: .add, subject: mallory, level: .manage, by: robin)
        try log.appendRaw(.add, subject: jamie.id, keys: madeUp.keys, level: .read, by: mallory)
        let squatted = log

        try log.appendRaw(.add, subject: jamie.id, keys: jamie.keys, level: .write, by: robin)
        try log.append(action: .addDevice, subject: jamie, level: .write, by: jamie)
        #expect(try MembershipLog.replay(log.entries, scope: scope).keys[jamie.id] == jamie.keys)

        try log.appendRaw(.changeLevel, subject: jamie.id, keys: madeUp.keys, level: .write, by: robin)
        #expect(refusal(log.entries, scope).hasPrefix("keysAlreadyEstablished"),
                "once he has signed with them, they are his")

        log = squatted
        try log.appendRaw(.remove, subject: jamie.id, level: .none, by: robin)
        #expect(try MembershipLog.replay(log.entries, scope: scope).keys[jamie.id] == nil)
    }

    /// Registering your own device takes only View, and every device ID is in
    /// the log for any member to read. Mallory took Robin's device, or cut it
    /// off, and every member refused what it sent from then on. She could also
    /// take Leslie's ID first in a group Leslie had not joined yet, since a Mac
    /// uses one ID everywhere. A registration now belongs to the person and the
    /// device together, and only its owner's own entry makes one.
    @Test func aDeviceStaysWithWhoeverRegisteredIt() throws {
        let scope = KeyScope.group(GroupID())
        let robin = Person(), mallory = Person(), leslie = Person(), jamie = Person()
        var log = try LogBuilder(scope: scope, founder: robin)
        try log.append(action: .add, subject: mallory, level: .read, by: robin)
        try log.append(action: .add, subject: jamie, level: .admin, by: robin)
        let before = log

        // Leslie's ID, taken before she joins, and Robin's, taken after.
        try log.appendRaw(.addDevice, subject: mallory.id, device: leslie.device.id,
                          devicePublicKey: mallory.device.publicKey, by: mallory)
        try log.appendRaw(.addDevice, subject: mallory.id, device: robin.device.id,
                          devicePublicKey: mallory.device.publicKey, by: mallory)
        try log.append(action: .add, subject: leslie, level: .write, by: robin)
        try log.append(action: .addDevice, subject: leslie, level: .write, by: leslie)
        var state = try MembershipLog.replay(log.entries, scope: scope)
        #expect(state.device(leslie.device.id, of: leslie.id)?.publicKey == leslie.device.publicKey)
        #expect(state.device(robin.device.id, of: robin.id)?.publicKey == robin.device.publicKey)

        log = before
        try log.appendRaw(.revokeDevice, subject: mallory.id, device: robin.device.id, by: mallory)
        #expect(refusal(log.entries, scope).hasPrefix("notTheirDevice"))

        log = before
        try log.appendRaw(.addDevice, subject: robin.id, device: robin.device.id,
                          devicePublicKey: mallory.device.publicKey, by: jamie)
        #expect(refusal(log.entries, scope).hasPrefix("deviceTaken"), "an admin cannot swap his device's key")

        log = before
        try log.appendRaw(.changeLevel, subject: mallory.id, keys: mallory.keys, level: .read,
                          device: DeviceKeyPair().id, devicePublicKey: jamie.device.publicKey, by: jamie)
        #expect(refusal(log.entries, scope).hasPrefix("deviceNotOnItsOwn"),
                "nobody enrols a device under someone else's name with a level change")

        log = before
        let laptop = DeviceKeyPair()
        try log.appendRaw(.addDevice, subject: mallory.id, device: laptop.id,
                          devicePublicKey: laptop.publicKey, by: mallory)
        try log.appendRaw(.revokeDevice, subject: mallory.id, device: laptop.id, by: mallory)
        state = try MembershipLog.replay(log.entries, scope: scope)
        #expect(state.device(laptop.id, of: mallory.id) == nil, "her own device is hers to add and revoke")
    }

    /// The epoch is a 32-bit number. A group founded at the top of the range,
    /// followed by any entry that moves the epoch, made working out the next
    /// one overflow, which stopped the server process on every post. A group
    /// starts at the first epoch, and the next is worked out without
    /// overflowing.
    @Test func aGroupStartsAtTheFirstEpochAndTheTopCannotOverflow() throws {
        let scope = KeyScope.group(GroupID())
        let robin = Person()
        var log = try LogBuilder(scope: scope, founder: robin)
        log.entries = [try MembershipLogEntry.signed(
            scope: scope, sequence: 0, previousHash: MembershipLogEntry.rootHash, action: .found,
            subjectUserID: robin.id, subjectKeys: robin.keys, level: .superadmin,
            epochAfter: Epoch(UInt32.max), deviceID: robin.device.id,
            devicePublicKey: robin.device.publicKey, author: robin.identity, authorUserID: robin.id)]
        #expect(refusal(log.entries, scope).hasPrefix("epochNotNext"))

        var top = MembershipState()
        top.epoch = Epoch(UInt32.max)
        top.levels[robin.id] = .superadmin
        let wrapped = try MembershipLogEntry.signed(
            scope: scope, sequence: 1, previousHash: top.head, action: .rotate, subjectUserID: robin.id,
            subjectKeys: nil, level: .superadmin, epochAfter: Epoch(0), author: robin.identity,
            authorUserID: robin.id)
        #expect(throws: MembershipLogError.epochNotNext(atSequence: 1)) {
            try MembershipLog.checkWhatItChanges(wrapped, in: top)
        }
    }

    /// A member at View revoked her own device with the epoch set far ahead.
    /// Nobody held keys for it, so every member's edits stayed queued. The
    /// epoch moves one step, and only by a manager, who hands out its keys.
    @Test func theEpochMovesOneStepAndOnlyByAManager() throws {
        let scope = KeyScope.group(GroupID())
        let robin = Person(), mallory = Person()
        var log = try LogBuilder(scope: scope, founder: robin)
        try log.append(action: .add, subject: mallory, level: .read, by: robin)
        try log.append(action: .addDevice, subject: mallory, level: .read, by: mallory)
        let before = log

        try log.appendRaw(.revokeDevice, subject: mallory.id, device: mallory.device.id,
                          epochAfter: Epoch(1), by: mallory)
        #expect(refusal(log.entries, scope).hasPrefix("authorNotEntitled"))

        log = before
        try log.appendRaw(.rotate, subject: robin.id, epochAfter: Epoch(2), by: robin)
        #expect(refusal(log.entries, scope).hasPrefix("epochNotNext"))

        log = before
        try log.appendRaw(.revokeDevice, subject: mallory.id, device: mallory.device.id, by: mallory)
        try log.appendRaw(.rotate, subject: robin.id, epochAfter: Epoch(1), by: robin)
        #expect(try MembershipLog.replay(log.entries, scope: scope).epoch == Epoch(1))
    }

    /// Registering a device leaves the epoch where it is, and its entry
    /// needs only View. Mallory's named the next epoch, and the server then
    /// took it for the entry that started that epoch, so it refused the keys
    /// Robin's real start of it carried. A device entry names the current
    /// epoch, whoever writes it.
    @Test func aDeviceEntryNamesTheCurrentEpoch() throws {
        let scope = KeyScope.group(GroupID())
        let robin = Person(), mallory = Person()
        var log = try LogBuilder(scope: scope, founder: robin)
        try log.append(action: .add, subject: mallory, level: .read, by: robin)
        let before = log

        try log.appendRaw(.addDevice, subject: mallory.id, device: mallory.device.id,
                          devicePublicKey: mallory.device.publicKey, epochAfter: Epoch(1), by: mallory)
        #expect(refusal(log.entries, scope).hasPrefix("epochNotCurrent"))

        log = before
        let laptop = DeviceKeyPair()
        try log.appendRaw(.addDevice, subject: robin.id, device: laptop.id,
                          devicePublicKey: laptop.publicKey, epochAfter: Epoch(1), by: robin)
        #expect(refusal(log.entries, scope).hasPrefix("epochNotCurrent"), "not even from the founder")

        log = before
        try log.appendRaw(.addDevice, subject: mallory.id, device: mallory.device.id,
                          devicePublicKey: mallory.device.publicKey, by: mallory)
        #expect(refusal(log.entries, scope) == "accepted")
    }

    /// The server judges who holds an epoch's group key by the entry that
    /// started that epoch. It took the first entry naming the epoch, so a
    /// device entry naming it ahead of time stood in for Robin's real start,
    /// and both the keys sent with it and the budget keys he published later
    /// were refused. Only entries that move the epoch count. Whoever started
    /// an epoch can still publish budget keys for it from the key they
    /// sealed to themselves, which every "from now on" invite depends on.
    @Test func theEntryThatStartsAnEpochIsOneThatMovesIt() throws {
        let group = GroupID()
        let scope = KeyScope.group(group)
        let robin = Person(), mallory = Person(), jamie = Person()
        var log = try LogBuilder(scope: scope, founder: robin)
        try log.append(action: .add, subject: mallory, level: .manage, by: robin)
        // Written straight into the log, the way a server that skipped the
        // epoch rule would hold it.
        try log.appendRaw(.addDevice, subject: mallory.id, device: mallory.device.id,
                          devicePublicKey: mallory.device.publicKey, epochAfter: Epoch(1), by: mallory)
        try log.append(action: .add, subject: jamie, level: .read, by: robin, bumpEpoch: true)
        let start = try #require(log.entries.last)

        let next = ScopedKey.generate(scope: scope, epoch: Epoch(1))
        func sealed(to person: Person, by sender: Person) throws -> WrappedKey {
            try KeyWrap.wrapToIdentity(next, recipient: person.keys, recipientUserID: person.id,
                                       sender: sender.identity, senderUserID: sender.id)
        }
        let his = try sealed(to: robin, by: robin)
        #expect(MembershipLog.entryStarting(Epoch(1), in: log.entries) == start)
        #expect(MembershipLog.holdsGroupKey(robin.id, of: group, at: Epoch(1), log: log.entries,
                                            requestEntry: start, sentNow: [his], stored: []),
                "the keys sent with his start count")
        #expect(MembershipLog.holdsGroupKey(robin.id, of: group, at: Epoch(1), log: log.entries,
                                            requestEntry: nil, sentNow: [], stored: [his]),
                "and the key he sealed to himself counts later")
        #expect(!MembershipLog.holdsGroupKey(mallory.id, of: group, at: Epoch(1), log: log.entries,
                                             requestEntry: nil, sentNow: [],
                                             stored: [try sealed(to: mallory, by: mallory)]),
                "one she sealed to herself does not")
        #expect(MembershipLog.holdsGroupKey(mallory.id, of: group, at: Epoch(1), log: log.entries,
                                            requestEntry: nil, sentNow: [],
                                            stored: [try sealed(to: mallory, by: robin)]),
                "one he sealed to her does")
    }

    /// Servers compare the keys an add carries with the person's sign-up
    /// keys, and an add with none got round that. Jamie was then a member
    /// with no keys, whom no invite could add, and a key stored for him with
    /// that add stayed in his slot after he was removed. An add or a level
    /// change may leave out keys only for someone the log already has keys
    /// for.
    @Test func nobodyIsLeftAMemberWithoutKeys() throws {
        let scope = KeyScope.group(GroupID())
        let robin = Person(), leslie = Person(), jamie = Person()
        var log = try LogBuilder(scope: scope, founder: robin)
        try log.append(action: .add, subject: leslie, level: .read, by: robin)
        let before = log

        for action in [MembershipAction.add, .changeLevel] {
            log = before
            try log.appendRaw(action, subject: jamie.id, level: .read, by: robin)
            #expect(refusal(log.entries, scope).hasPrefix("memberWithoutKeys"), "\(action)")
        }

        log = before
        try log.appendRaw(.changeLevel, subject: leslie.id, level: .write, by: robin)
        #expect(refusal(log.entries, scope) == "accepted", "her keys are already in the log")

        log = before
        try log.appendRaw(.remove, subject: leslie.id, level: .none, by: robin)
        try log.appendRaw(.add, subject: leslie.id, level: .read, by: robin)
        #expect(refusal(log.entries, scope).hasPrefix("memberWithoutKeys"),
                "removing her cleared keys she never signed with")
    }

    /// Why a log was refused, as text, or "accepted".
    private func refusal(_ entries: [MembershipLogEntry], _ scope: KeyScope) -> String {
        do {
            _ = try MembershipLog.replay(entries, scope: scope)
            return "accepted"
        } catch {
            return String(describing: error)
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

    /// Two people can each register one device ID as their own, so a tie on
    /// the device is broken by who wrote the version. Unknown, the stored
    /// version stays, and the same author on the same device is a version
    /// sent again.
    @Test func aTieOnOneDeviceIsBrokenByTheAuthor() throws {
        let key = ScopedKey.generate(scope: .budget(BudgetID()))
        let shared = DeviceKeyPair()
        let recordID = RecordID()
        let low = UserID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let high = UserID(UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!)

        func write(by author: UserID) throws -> RecordEnvelope {
            try RecordCodec.seal(Note(merchant: "Hilltop", amountCents: 1), recordID: recordID,
                                 recordType: .transaction, groupID: GroupID(), budgetID: BudgetID(),
                                 scopeKey: key, lamport: 9, author: author,
                                 device: shared, membershipSequence: 1)
        }
        let hers = try write(by: high), his = try write(by: low)

        #expect(hers.replaces(lamport: 9, device: shared.id, isDeleted: false, author: low))
        #expect(!his.replaces(lamport: 9, device: shared.id, isDeleted: false, author: high))
        #expect(!hers.replaces(lamport: 9, device: shared.id, isDeleted: false, author: nil),
                "an unknown author keeps what is stored")
        #expect(!hers.replaces(lamport: 9, device: shared.id, isDeleted: false, author: high),
                "the same author is the same version")
        #expect(LamportClock.wins(hers, over: his) && !LamportClock.wins(his, over: hers))
    }
}
