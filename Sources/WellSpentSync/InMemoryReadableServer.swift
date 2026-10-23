import Foundation
import WellSpentCrypto
import WellSpentModel

/// A readable server in memory, for tests.
///
/// It keeps the rules the real server keeps in `AccountsV2.swift`,
/// `GroupsV2.swift` and `SyncV2.swift`: who may change what, the history
/// floor, the owner rule, the ID checks, the Lamport limits and the same
/// last-writer-wins. Change one, change the other. Rate limits and email
/// delivery are left out; the codes it would email are kept for tests.
public final class InMemoryReadableServer: @unchecked Sendable {
    public let environment: String
    private let lock = NSLock()

    private struct Account {
        let id: UserID
        var email: String
        var password: String
        var verified: Bool
        /// Bumped by each password change. A session made before it is over.
        var stamp: Int
    }

    private struct Session {
        let id: UUID
        let user: UserID
        let stamp: Int
        let label: String?
        let createdAt: Date
    }

    private struct Group {
        let id: GroupID
        let founder: UserID
        var importKey: Data?
        var lastSeq: UInt64 = 0
        var maxLamport: UInt64 = 0
        var deleted = false
    }

    private struct Membership {
        var level: AccessLevel
        let floor: UInt64
    }

    private struct Stored {
        var record: WireRecord
        let group: GroupID
        let owner: UserID
        var updatedBy: UserID
        /// The sequence the record was first stored at, which the history floor reads.
        let firstSeq: UInt64
    }

    private struct Invite {
        let id: UUID
        let group: GroupID
        let inviter: UserID
        let level: AccessLevel
        let history: HistoryAccess
        let expiresAt: Date
        var accepted = false
        var email: String? = nil
        var inviteeName: String? = nil
        var inviterName: String? = nil
        var rejected = false
        var cancelled = false
        var closed = false
    }

    private var accounts: [UserID: Account] = [:]
    private var sessionsByToken: [String: Session] = [:]
    private var groups: [GroupID: Group] = [:]
    private var memberships: [GroupID: [UserID: Membership]] = [:]
    private var records: [RecordID: Stored] = [:]
    private var invitesByToken: [String: Invite] = [:]
    /// The codes the server would email, by address and purpose.
    private var codes: [String: String] = [:]

    public init(environment: String = "development") {
        self.environment = environment
    }

    /// A client of this server, signed in with `session` or not at all.
    public func client(session: ServerSession? = nil) -> InMemoryReadableSession {
        InMemoryReadableSession(server: self, session: session)
    }

    // MARK: - Test hooks

    /// An account as the switch leaves one: its ID kept from before, and its
    /// address not confirmed, since the sealed server never confirmed any.
    /// `verified` is for a test that needs one confirmed already.
    @discardableResult
    public func seedAccount(id: UserID = UserID(), email: String, password: String,
                            verified: Bool = false) -> UserID {
        lock.withLock {
            accounts[id] = Account(id: id, email: email.lowercased(), password: password, verified: verified,
                                   stamp: 0)
        }
        return id
    }

    /// A group as the switch leaves one made before it: its founder a member,
    /// and no import key until the founder's app brings the old one.
    public func seedLegacyGroup(id: GroupID, founder: UserID, maxLamport: UInt64 = 0) {
        lock.withLock {
            groups[id] = Group(id: id, founder: founder, importKey: nil, maxLamport: maxLamport)
            memberships[id, default: [:]][founder] = Membership(level: .superadmin, floor: 0)
        }
    }

    /// Someone already in a group, as the switch leaves a member who joined
    /// before it.
    public func seedMember(_ user: UserID, in group: GroupID, level: AccessLevel, floor: UInt64 = 0) {
        lock.withLock { memberships[group, default: [:]][user] = Membership(level: level, floor: floor) }
    }

    /// Ends every session of the account, as signing out everywhere does.
    public func endSessions(of user: UserID) {
        lock.withLock { sessionsByToken = sessionsByToken.filter { $0.value.user != user } }
    }

    /// The last code the server would have emailed to `email`.
    public func lastCode(for email: String, purpose: CodePurpose) -> String? {
        lock.withLock { codes["\(purpose)|\(email.lowercased())"] }
    }

    /// The token delivered by email, for tests opening the emailed app link.
    public func emailedInvitationToken(for id: UUID) -> String? {
        lock.withLock { invitesByToken.first { $0.value.id == id && $0.value.email != nil }?.key }
    }

    public enum CodePurpose: String, Sendable { case verify, reset }

    /// What the server stores for a group, in server order.
    public func records(in group: GroupID) -> [WireRecord] {
        lock.withLock {
            records.values.filter { $0.group == group }.map(\.record)
                .sorted { ($0.serverSeq ?? 0) < ($1.serverSeq ?? 0) }
        }
    }

    public func importKey(of group: GroupID) -> Data? {
        lock.withLock { groups[group]?.importKey }
    }

    // MARK: - Rules shared by the calls

    private static let minPassword = 10, maxPassword = 128
    private static let maxInviteDays = 30, defaultInviteDays = 7
    private static let maxRecordsPerPush = 500, maxPullPage = 500, maxBodyBytes = 64 * 1024
    private static let alwaysVisible: Set<RecordType> = [.groupMeta, .budget, .memberProfile]
    private static let owned: Set<RecordType> = [.transaction, .receipt, .statement]
    private static let grantable: Set<AccessLevel> = [.read, .write, .manage, .admin]
    static let groupDeletedRefusal = "the group has been deleted"

    private static func fail(_ status: Int, _ reason: String) -> ReadableTransportError {
        .http(status: status, reason: reason)
    }

    private static func normalise(_ raw: String) throws -> String {
        var typed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed.lowercased().hasPrefix("mailto:") {
            typed = String(typed.dropFirst("mailto:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let email = typed.precomposedStringWithCanonicalMapping.lowercased()
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard email.count <= 254, parts.count == 2, !parts[0].isEmpty, parts[1].count >= 3,
              parts[1].contains("."), !parts[1].hasPrefix("."), !parts[1].hasSuffix("."),
              !parts[1].contains(".."),
              !email.unicodeScalars.contains(where: { $0.properties.isWhitespace
                  || $0.properties.generalCategory == .control }) else {
            throw fail(400, "that does not look like an email address")
        }
        return email
    }

    /// As the server keeps a device's name: trimmed, at most 64 characters,
    /// and none at all when empty.
    private static func label(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return String(trimmed.prefix(64))
    }

    private static func checkPassword(_ password: String) throws {
        guard password.count >= minPassword else { throw fail(400, "a password needs at least 10 characters") }
        guard password.count <= maxPassword else { throw fail(400, "a password can have at most 128 characters") }
    }

    private static func neededToSet(from old: AccessLevel?, to new: AccessLevel) -> AccessLevel {
        max(new, old ?? .none) >= .manage ? .admin : .manage
    }

    private static func neededToRemove(_ level: AccessLevel) -> AccessLevel {
        level >= .manage ? .admin : .manage
    }

    private static func mayGrant(_ level: AccessLevel, holding mine: AccessLevel) -> Bool {
        grantable.contains(level) && level <= mine
    }

    private static func code() -> String {
        String((0 ..< 8).map { _ in "ABCDEFGHJKMNPQRSTUVWXYZ23456789".randomElement()! })
    }

    /// A code as typed, as the server reads it: any case, with or without
    /// the dash or spaces.
    private static func typed(_ code: String) -> String {
        code.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func token() -> String {
        Data((0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) }).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Callers hold `lock`.
    private func account(email: String) -> Account? {
        accounts.values.first { $0.email == email }
    }

    private func issueSession(for user: Account, label: String?) -> ServerSession {
        let token = Self.token()
        sessionsByToken[token] = Session(id: UUID(), user: user.id, stamp: user.stamp, label: Self.label(label),
                                         createdAt: Date())
        return ServerSession(userID: user.id, token: token, expiresAt: Date().addingTimeInterval(90 * 86_400),
                             emailVerified: user.verified)
    }

    /// The signed-in account, or the session is over.
    private func caller(_ token: String?) throws -> (Account, Session) {
        guard let token, let session = sessionsByToken[token], let account = accounts[session.user],
              session.stamp == account.stamp else {
            throw ReadableTransportError.sessionEnded("Unauthorized")
        }
        return (account, session)
    }

    private func requireMembership(_ group: GroupID, user: UserID, needed: AccessLevel) throws -> (Group, Membership) {
        guard let membership = memberships[group]?[user], membership.level != .none,
              let stored = groups[group] else {
            throw Self.fail(403, "you are not a member of that group")
        }
        guard membership.level.allows(needed) else { throw Self.fail(403, "that needs \(needed)") }
        return (stored, membership)
    }

    private func serverGroup(_ group: Group, _ membership: Membership) -> ServerGroup {
        ServerGroup(id: group.id, founderID: group.founder, level: membership.level,
                    importKey: group.importKey ?? Data(), historyFloor: membership.floor, deleted: group.deleted)
    }

    // MARK: - Accounts

    func signUp(email raw: String, password: String, label: String?) throws -> ServerSession {
        try lock.withLock {
            let email = try Self.normalise(raw)
            try Self.checkPassword(password)
            guard account(email: email) == nil else { throw Self.fail(409, "that email already has an account") }
            let user = Account(id: UserID(), email: email, password: password, verified: false, stamp: 0)
            accounts[user.id] = user
            codes["verify|\(email)"] = Self.code()
            return issueSession(for: user, label: label)
        }
    }

    func signIn(email raw: String, password: String, label: String?) throws -> ServerSession {
        try lock.withLock {
            guard let email = try? Self.normalise(raw), let user = account(email: email),
                  user.password == password else { throw ReadableTransportError.badCredentials }
            return issueSession(for: user, label: label)
        }
    }

    func forgot(email raw: String) {
        lock.withLock {
            guard let email = try? Self.normalise(raw), let user = account(email: email), user.verified else { return }
            codes["reset|\(email)"] = Self.code()
        }
    }

    func reset(email raw: String, code: String, newPassword: String, label: String?) throws -> ServerSession {
        try lock.withLock {
            try Self.checkPassword(newPassword)
            guard let email = try? Self.normalise(raw), var user = account(email: email), user.verified,
                  let expected = codes["reset|\(email)"], expected == Self.typed(code) else {
                throw Self.fail(400, "that code is wrong or has expired")
            }
            codes["reset|\(email)"] = nil
            user.password = newPassword
            user.stamp += 1
            accounts[user.id] = user
            sessionsByToken = sessionsByToken.filter { $0.value.user != user.id }
            return issueSession(for: user, label: label)
        }
    }

    func me(_ token: String?) throws -> Me {
        try lock.withLock {
            let (user, _) = try caller(token)
            return Me(userID: user.id, email: user.email, emailVerified: user.verified)
        }
    }

    func signOut(_ token: String?) throws {
        try lock.withLock {
            _ = try caller(token)
            if let token { sessionsByToken[token] = nil }
        }
    }

    func signOutEverywhere(_ token: String?) throws {
        try lock.withLock {
            let (user, _) = try caller(token)
            sessionsByToken = sessionsByToken.filter { $0.value.user != user.id }
        }
    }

    func sessions(_ token: String?) throws -> [DeviceSession] {
        try lock.withLock {
            let (user, current) = try caller(token)
            return sessionsByToken.values.filter { $0.user == user.id }.map {
                DeviceSession(id: $0.id, deviceLabel: $0.label, createdAt: $0.createdAt, lastUsedAt: $0.createdAt,
                              current: $0.id == current.id)
            }
        }
    }

    func endSession(_ id: UUID, _ token: String?) throws {
        try lock.withLock {
            let (user, _) = try caller(token)
            guard let match = sessionsByToken.first(where: { $0.value.id == id && $0.value.user == user.id }) else {
                throw Self.fail(404, "no such session")
            }
            sessionsByToken[match.key] = nil
        }
    }

    func verify(code: String, _ token: String?) throws {
        try lock.withLock {
            var user = try caller(token).0
            guard !user.verified else { return }
            guard codes["verify|\(user.email)"] == Self.typed(code) else {
                throw Self.fail(400, "that code is wrong or has expired")
            }
            codes["verify|\(user.email)"] = nil
            user.verified = true
            accounts[user.id] = user
        }
    }

    func resendVerification(_ token: String?) throws {
        try lock.withLock {
            let (user, _) = try caller(token)
            guard !user.verified else { return }
            codes["verify|\(user.email)"] = Self.code()
        }
    }

    func changePassword(current: String, new: String, _ token: String?) throws {
        try lock.withLock {
            let (found, session) = try caller(token)
            guard found.password == current else { throw ReadableTransportError.wrongCurrentPassword }
            try Self.checkPassword(new)
            var user = found
            user.password = new
            user.stamp += 1
            accounts[user.id] = user
            // Every other session ends; this one carries on under the new stamp.
            sessionsByToken = sessionsByToken.filter { $0.value.user != user.id }
            if let token {
                sessionsByToken[token] = Session(id: session.id, user: user.id, stamp: user.stamp,
                                                 label: session.label, createdAt: session.createdAt)
            }
        }
    }

    // MARK: - Groups, members and invites

    func listGroups(_ token: String?) throws -> [ServerGroup] {
        try lock.withLock {
            let (user, _) = try caller(token)
            return memberships.compactMap { id, members in
                guard let membership = members[user.id], membership.level != .none, let group = groups[id] else {
                    return nil
                }
                return serverGroup(group, membership)
            }
            .sorted { $0.id.uuid.uuidString < $1.id.uuid.uuidString }
        }
    }

    func createGroup(id: GroupID, importKey: Data?, _ token: String?) throws -> ServerGroup {
        try lock.withLock {
            let (user, _) = try caller(token)
            if let key = importKey, key.count != 32 { throw Self.fail(400, "an import key is 32 bytes") }
            if var existing = groups[id] {
                guard existing.founder == user.id, let membership = memberships[id]?[user.id] else {
                    throw Self.fail(409, "that group already exists")
                }
                if let key = importKey, existing.importKey == nil {
                    existing.importKey = key
                    groups[id] = existing
                }
                return serverGroup(existing, membership)
            }
            guard !RecordID(id.uuid).isNameBased, records[RecordID(id.uuid)] == nil else {
                throw Self.fail(409, "that ID is already used")
            }
            let group = Group(id: id, founder: user.id,
                              importKey: importKey ?? Data((0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) }))
            let membership = Membership(level: .superadmin, floor: 0)
            groups[id] = group
            memberships[id, default: [:]][user.id] = membership
            return serverGroup(group, membership)
        }
    }

    func members(of group: GroupID, _ token: String?) throws -> [ServerMember] {
        try lock.withLock {
            let (user, _) = try caller(token)
            _ = try requireMembership(group, user: user.id, needed: .read)
            return (memberships[group] ?? [:]).filter { $0.value.level != .none }
                .map { ServerMember(userID: $0.key, level: $0.value.level) }
                .sorted { $0.userID.uuid.uuidString < $1.userID.uuid.uuidString }
        }
    }

    func setLevel(_ new: AccessLevel, of subject: UserID, in group: GroupID, _ token: String?) throws {
        try lock.withLock {
            let (user, _) = try caller(token)
            guard Self.grantable.contains(new) else { throw Self.fail(400, "that is not a level a member can be given") }
            let (stored, mine) = try requireMembership(group, user: user.id, needed: .manage)
            guard subject != stored.founder else { throw Self.fail(403, "the founder's level cannot change") }
            guard let theirs = memberships[group]?[subject], theirs.level != .none else {
                throw Self.fail(404, "they are not a member")
            }
            let needed = Self.neededToSet(from: theirs.level, to: new)
            guard mine.level.allows(needed) else { throw Self.fail(403, "that needs \(needed)") }
            guard Self.mayGrant(new, holding: mine.level) else { throw Self.fail(403, "that needs \(new)") }
            memberships[group]?[subject]?.level = new
        }
    }

    func remove(_ subject: UserID, from group: GroupID, _ token: String?) throws {
        try lock.withLock {
            let (user, _) = try caller(token)
            let (stored, mine) = try requireMembership(group, user: user.id, needed: .read)
            guard subject != stored.founder else {
                throw Self.fail(403, "the founder cannot leave or be removed; delete the group instead")
            }
            if subject == user.id {
                memberships[group]?[subject] = nil
                closeInvitations(to: user.email, in: group)
                return
            }
            guard let theirs = memberships[group]?[subject], theirs.level != .none else {
                throw Self.fail(404, "they are not a member")
            }
            let needed = Self.neededToRemove(theirs.level)
            guard mine.level.allows(needed) else { throw Self.fail(403, "that needs \(needed)") }
            memberships[group]?[subject] = nil
            if let email = accounts[subject]?.email { closeInvitations(to: email, in: group) }
        }
    }

    func createInvite(group: GroupID, level: AccessLevel, history: HistoryAccess, days: Int?,
                      _ token: String?, email: String? = nil, inviteeName: String? = nil,
                      inviterName: String? = nil) throws -> CreatedInvite {
        try lock.withLock {
            let (user, _) = try caller(token)
            guard Self.grantable.contains(level) else { throw Self.fail(400, "that is not a level a member can be given") }
            let days = days ?? Self.defaultInviteDays
            guard (1 ... Self.maxInviteDays).contains(days) else { throw Self.fail(400, "an invite lasts 1 to 30 days") }
            let (stored, mine) = try requireMembership(group, user: user.id, needed: .manage)
            guard !stored.deleted else { throw Self.fail(403, "you are not a member of that group") }
            let needed = Self.neededToSet(from: nil, to: level)
            guard mine.level.allows(needed), Self.mayGrant(level, holding: mine.level) else {
                throw Self.fail(403, "that needs \(max(needed, level))")
            }
            let address = email.map(Self.normalisedEmail)
            if let address {
                guard user.verified else { throw Self.fail(403, "Confirm your email before inviting someone.") }
                guard address.contains("@"), !address.contains(where: \.isWhitespace),
                      Self.validInvitationName(inviteeName), Self.validInvitationName(inviterName) else {
                    throw Self.fail(400, "Enter their email and both names.")
                }
                guard !invitesByToken.values.contains(where: {
                    $0.group == group && $0.email == address && !$0.accepted && !$0.rejected && !$0.cancelled && !$0.closed && $0.expiresAt > Date()
                }) else { throw Self.fail(409, "That person already has a pending invitation.") }
                if let recipient = accounts.values.first(where: { $0.email == address }),
                   memberships[group]?[recipient.id]?.level != nil {
                    throw Self.fail(409, "That person is already in the group.")
                }
                for key in Array(invitesByToken.keys) {
                    if let prior = invitesByToken[key], prior.group == group,
                       prior.email == address, prior.rejected {
                        invitesByToken[key]?.closed = true
                    }
                }
            }
            let token = Self.token()
            var invite = Invite(id: UUID(), group: group, inviter: user.id, level: level, history: history,
                                expiresAt: Date().addingTimeInterval(TimeInterval(days) * 86_400))
            invite.email = address
            invite.inviteeName = inviteeName?.trimmingCharacters(in: .whitespacesAndNewlines)
            invite.inviterName = inviterName?.trimmingCharacters(in: .whitespacesAndNewlines)
            invitesByToken[token] = invite
            return CreatedInvite(id: invite.id, token: token, expiresAt: invite.expiresAt)
        }
    }

    func invites(in group: GroupID, _ token: String?) throws -> [ServerInvite] {
        try lock.withLock {
            let (user, _) = try caller(token)
            _ = try requireMembership(group, user: user.id, needed: .manage)
            return invitesByToken.values.filter { $0.group == group && !$0.accepted && !$0.cancelled && !$0.closed && $0.expiresAt > Date() }
                .map { ServerInvite(id: $0.id, level: $0.level, history: $0.history, expiresAt: $0.expiresAt,
                                    inviterID: $0.inviter, email: $0.email, inviteeName: $0.inviteeName,
                                    inviterName: $0.inviterName, status: $0.rejected ? "rejected" : "pending") }
        }
    }

    func cancelInvite(_ id: UUID, in group: GroupID, _ token: String?) throws {
        try lock.withLock {
            let (user, _) = try caller(token)
            let (_, mine) = try requireMembership(group, user: user.id, needed: .read)
            guard let match = invitesByToken.first(where: { $0.value.id == id && $0.value.group == group }) else {
                throw Self.fail(404, "no such invite")
            }
            guard match.value.inviter == user.id || mine.level.allows(.manage) else {
                throw Self.fail(403, "that needs manage")
            }
            guard !match.value.accepted, !match.value.rejected else {
                throw Self.fail(409, "That invitation is closed.")
            }
            if match.value.cancelled { return }
            guard !match.value.closed else { throw Self.fail(404, "no such invite") }
            guard match.value.expiresAt > Date() else { throw Self.fail(410, "That invitation has expired.") }
            invitesByToken[match.key]?.cancelled = true
        }
    }

    func preview(token inviteToken: String) throws -> InviteTerms {
        try lock.withLock {
            guard let invite = invitesByToken[inviteToken], !invite.accepted, !invite.rejected,
                  !invite.cancelled, !invite.closed else { throw Self.fail(404, "no such invite") }
            guard invite.expiresAt > Date() else { throw Self.fail(410, "that invite has expired") }
            return InviteTerms(groupID: invite.group, level: invite.level, history: invite.history,
                               expiresAt: invite.expiresAt, invitationID: invite.email == nil ? nil : invite.id,
                               inviteeName: invite.email == nil ? nil : invite.inviteeName)
        }
    }

    func accept(token inviteToken: String, _ token: String?) throws -> ServerGroup {
        try lock.withLock {
            let (user, _) = try caller(token)
            guard user.verified else { throw Self.fail(403, "confirm your email address before joining a group") }
            guard var invite = invitesByToken[inviteToken] else { throw Self.fail(404, "no such invite") }
            if let email = invite.email, email != user.email { throw Self.fail(404, "no such invite") }
            guard !invite.accepted else { throw Self.fail(409, "that invite has already been accepted") }
            guard !invite.rejected else { throw Self.fail(409, "that invite has already been rejected") }
            guard !invite.cancelled, !invite.closed else { throw Self.fail(404, "no such invite") }
            guard invite.expiresAt > Date() else { throw Self.fail(410, "that invite has expired") }
            guard var group = groups[invite.group], !group.deleted else { throw Self.fail(404, "no such invite") }
            if let existing = memberships[invite.group]?[user.id], existing.level != .none {
                throw Self.fail(409, "you are already in that group")
            }
            // The invite speaks for its maker as they are now.
            guard let inviter = memberships[invite.group]?[invite.inviter], inviter.level != .none,
                  inviter.level.allows(Self.neededToSet(from: nil, to: invite.level)),
                  Self.mayGrant(invite.level, holding: inviter.level) else {
                throw Self.fail(410, "that invite is no longer valid")
            }
            let floor = max(invite.history == .fromNow ? group.lastSeq : 0, inviter.floor)
            invite.accepted = true
            invitesByToken[inviteToken] = invite
            closeInvitations(to: user.email, in: invite.group, except: invite.id)
            let membership = Membership(level: invite.level, floor: floor)
            memberships[invite.group, default: [:]][user.id] = membership
            if let name = invite.inviteeName {
                let profile = MemberProfile(groupID: invite.group, userID: user.id, displayName: name)
                let data = try RecordCodec.encoder.encode(profile)
                group.lastSeq += 1
                group.maxLamport += 1
                let record = WireRecord(id: profile.id, type: .memberProfile, budgetID: nil,
                                        lamport: group.maxLamport, clientID: DeviceID(), isDeleted: false,
                                        body: String(decoding: data, as: UTF8.self), createdBy: user.id,
                                        updatedBy: user.id, serverSeq: group.lastSeq)
                records[profile.id] = Stored(record: record, group: invite.group, owner: user.id,
                                             updatedBy: user.id, firstSeq: group.lastSeq)
                groups[invite.group] = group
            }
            return serverGroup(group, membership)
        }
    }

    private static func normalisedEmail(_ typed: String) -> String {
        var email = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if email.lowercased().hasPrefix("mailto:") { email = String(email.dropFirst(7)) }
        return email.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func validInvitationName(_ raw: String?) -> Bool {
        let name = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name.count <= 50 && !name.unicodeScalars.contains {
            $0.properties.generalCategory == .control || $0.properties.generalCategory == .format
        }
    }

    func incomingInvitations(_ token: String?) throws -> [IncomingInvitation] {
        try lock.withLock {
            let (user, _) = try caller(token)
            guard user.verified else { throw Self.fail(403, "Confirm your email first.") }
            return invitesByToken.values.filter { invitation in
                guard invitation.email == user.email, !invitation.accepted, !invitation.rejected,
                      !invitation.cancelled, !invitation.closed, invitation.expiresAt > Date(),
                      groups[invitation.group]?.deleted == false,
                      let inviter = memberships[invitation.group]?[invitation.inviter] else { return false }
                return inviter.level.allows(Self.neededToSet(from: nil, to: invitation.level))
                    && Self.mayGrant(invitation.level, holding: inviter.level)
            }.map { invite in
                let name = records[RecordID(invite.group.uuid)].flatMap {
                    try? RecordCodec.decoder.decode(BudgetGroup.self, from: Data($0.record.body.utf8)).name
                } ?? "Group"
                return IncomingInvitation(id: invite.id, groupID: invite.group, groupName: name,
                                          inviterName: invite.inviterName ?? "", inviteeName: invite.inviteeName ?? "",
                                          level: invite.level, history: invite.history, expiresAt: invite.expiresAt)
            }.sorted { $0.id.uuidString < $1.id.uuidString }
        }
    }

    func acceptInvitation(_ id: UUID, _ token: String?) throws -> ServerGroup {
        let key: String = try lock.withLock {
            let (user, _) = try caller(token)
            guard let match = invitesByToken.first(where: { $0.value.id == id && $0.value.email == user.email }) else {
                throw Self.fail(404, "no such invite")
            }
            return match.key
        }
        return try accept(token: key, token)
    }

    func rejectInvitation(_ id: UUID, _ token: String?) throws {
        try lock.withLock {
            let (user, _) = try caller(token)
            guard user.verified else { throw Self.fail(403, "Confirm your email first.") }
            guard let match = invitesByToken.first(where: { $0.value.id == id && $0.value.email == user.email }) else {
                throw Self.fail(404, "no such invite")
            }
            guard !match.value.accepted, !match.value.rejected else { throw Self.fail(409, "That invitation is closed.") }
            guard !match.value.cancelled, !match.value.closed else { throw Self.fail(404, "no such invite") }
            guard match.value.expiresAt > Date() else { throw Self.fail(410, "That invitation has expired.") }
            invitesByToken[match.key]?.rejected = true
        }
    }

    /// Called while holding the server lock. A membership reached another
    /// way closes old pending offers, including after a later removal.
    private func closeInvitations(to email: String, in group: GroupID, except id: UUID? = nil) {
        for key in Array(invitesByToken.keys) {
            guard let invitation = invitesByToken[key], invitation.group == group,
                  invitation.email == email, invitation.id != id,
                  !invitation.rejected, !invitation.accepted, !invitation.cancelled else { continue }
            invitesByToken[key]?.closed = true
        }
    }

    // MARK: - Sync

    /// The IDs inside a record's body, which must match where it was sent.
    private static func binding(_ body: String, type: RecordType)
        -> (id: UUID, group: GroupID, budget: BudgetID?, profileUser: UserID?)? {
        let data = Data(body.utf8), decoder = RecordCodec.decoder
        switch type {
        case .groupMeta:
            guard let value = try? decoder.decode(BudgetGroup.self, from: data) else { return nil }
            return (value.id.uuid, value.id, nil, nil)
        case .budget:
            guard let value = try? decoder.decode(Budget.self, from: data) else { return nil }
            return (value.id.uuid, value.groupID, value.id, nil)
        case .transaction:
            guard let value = try? decoder.decode(Transaction.self, from: data) else { return nil }
            return (value.id.uuid, value.groupID, value.budgetID, nil)
        case .receipt:
            guard let value = try? decoder.decode(Receipt.self, from: data) else { return nil }
            return (value.id.uuid, value.groupID, value.budgetID, nil)
        case .statement:
            guard let value = try? decoder.decode(ImportedStatement.self, from: data) else { return nil }
            return (value.id.uuid, value.groupID, nil, nil)
        case .memberProfile:
            guard let value = try? decoder.decode(MemberProfile.self, from: data) else { return nil }
            return (value.id.uuid, value.groupID, nil, value.userID)
        default:
            return nil
        }
    }

    /// The server's `replacesV2`.
    private static func replaces(_ incoming: WireRecord, author: UserID, stored: Stored) -> Bool {
        if incoming.type == .groupMeta, incoming.isDeleted != stored.record.isDeleted { return incoming.isDeleted }
        if incoming.lamport != stored.record.lamport { return incoming.lamport > stored.record.lamport }
        if incoming.clientID != stored.record.clientID {
            return incoming.clientID.uuid.uuidString > stored.record.clientID.uuid.uuidString
        }
        guard author != stored.updatedBy else { return false }
        return author.uuid.uuidString > stored.updatedBy.uuid.uuidString
    }

    func push(_ incoming: [WireRecord], group groupID: GroupID, _ token: String?) throws -> PushResult {
        try lock.withLock {
            let (user, _) = try caller(token)
            guard incoming.count <= Self.maxRecordsPerPush else {
                throw Self.fail(413, "at most \(Self.maxRecordsPerPush) records per push")
            }
            let (_, membership) = try requireMembership(groupID, user: user.id, needed: .write)
            guard var group = groups[groupID] else { throw Self.fail(403, "you are not a member of that group") }
            let level = membership.level
            let isFounderOrAdmin = group.founder == user.id || level.allows(.admin)
            let highestBefore = group.maxLamport
            var highest = highestBefore
            var accepted: [RecordID] = []
            var rejected: [RecordID: String] = [:]

            for record in incoming {
                func refuse(_ reason: String) { rejected[record.id] = reason }
                let type = record.type
                guard type.isKnown else { refuse("unknown record type"); continue }
                guard record.body.utf8.count <= Self.maxBodyBytes else { refuse("the record is too large"); continue }
                guard let inside = Self.binding(record.body, type: type), inside.id == record.id.uuid,
                      inside.group == groupID, inside.budget == record.budgetID else {
                    refuse("the record does not match where it was sent"); continue
                }
                guard (type == .groupMeta) == (record.id.uuid == groupID.uuid) else {
                    refuse("record ID does not match its type"); continue
                }
                if type == .memberProfile {
                    guard inside.profileUser == user.id,
                          record.id == RecordID.memberProfile(group: groupID, user: user.id) else {
                        refuse("that ID belongs to a member profile"); continue
                    }
                } else if record.id.isNameBased {
                    refuse("that ID belongs to a member profile"); continue
                }
                guard record.lamport < RecordEnvelope.lamportCeiling else {
                    refuse(RecordEnvelope.lamportTooLargeRefusal); continue
                }
                guard record.lamport <= highestBefore + RecordEnvelope.lamportLead else {
                    refuse(RecordEnvelope.lamportTooFarAheadRefusal); continue
                }
                let existing = records[record.id]
                if existing == nil, type != .groupMeta, groups[GroupID(record.id.uuid)] != nil {
                    refuse("record ID does not match its type"); continue
                }
                if let existing {
                    guard existing.group == groupID, existing.record.type == type else {
                        refuse("another record already has this ID"); continue
                    }
                    if existing.record.lamport == record.lamport, existing.record.clientID == record.clientID,
                       existing.updatedBy == user.id, existing.record.isDeleted == record.isDeleted {
                        accepted.append(record.id); continue
                    }
                }
                if group.deleted { refuse(Self.groupDeletedRefusal); continue }

                switch type {
                case .groupMeta:
                    if record.isDeleted {
                        guard isFounderOrAdmin else { refuse("only the founder or an admin can delete the group"); continue }
                    } else {
                        guard level.allows(.manage) else { refuse("only a manager can change the group"); continue }
                    }
                case .budget:
                    guard level.allows(.manage) else { refuse("only a manager can change a budget"); continue }
                default:
                    break
                }
                let owner = existing?.owner ?? user.id
                if Self.owned.contains(type), owner != user.id, !level.allows(.manage) {
                    refuse("only its owner or a manager can change it"); continue
                }
                var body = record.body
                if type == .transaction {
                    guard var transaction = try? RecordCodec.decoder.decode(Transaction.self, from: Data(body.utf8)) else {
                        refuse("the record does not match where it was sent"); continue
                    }
                    if let claimed = transaction.createdBy, claimed != owner {
                        refuse("a transaction keeps the owner it was made with"); continue
                    }
                    if transaction.createdBy == nil {
                        transaction.createdBy = owner
                        guard let encoded = try? RecordCodec.encoder.encode(transaction) else {
                            refuse("the record does not match where it was sent"); continue
                        }
                        body = String(decoding: encoded, as: UTF8.self)
                    }
                }
                if type != .budget, let budgetID = record.budgetID, let budget = records[RecordID(budgetID.uuid)],
                   budget.group != groupID || budget.record.type != .budget {
                    refuse("that budget is not in this group"); continue
                }
                if let existing {
                    guard Self.replaces(record, author: user.id, stored: existing) else {
                        let reopens = type == .groupMeta && existing.record.isDeleted && !record.isDeleted
                        refuse(reopens ? Self.groupDeletedRefusal : RecordEnvelope.olderVersionRefusal)
                        continue
                    }
                }
                group.lastSeq += 1
                let stored = WireRecord(id: record.id, type: type, budgetID: record.budgetID, lamport: record.lamport,
                                        clientID: record.clientID, isDeleted: record.isDeleted, body: body,
                                        createdBy: owner, updatedBy: user.id, serverSeq: group.lastSeq)
                records[record.id] = Stored(record: stored, group: groupID, owner: owner, updatedBy: user.id,
                                            firstSeq: existing?.firstSeq ?? group.lastSeq)
                if type == .groupMeta, record.isDeleted { group.deleted = true }
                highest = max(highest, record.lamport)
                accepted.append(record.id)
            }
            group.maxLamport = highest
            groups[groupID] = group
            return PushResult(accepted: accepted, rejected: rejected, serverSeq: group.lastSeq)
        }
    }

    func pull(group groupID: GroupID, since: UInt64, limit: Int, _ token: String?) throws -> ReadablePull {
        try lock.withLock {
            let (user, _) = try caller(token)
            let (group, membership) = try requireMembership(groupID, user: user.id, needed: .read)
            let limit = min(max(1, limit), Self.maxPullPage)
            let visible = records.values
                .filter { $0.group == groupID && ($0.record.serverSeq ?? 0) > since }
                .filter { Self.alwaysVisible.contains($0.record.type) || $0.firstSeq > membership.floor }
                .sorted { ($0.record.serverSeq ?? 0) < ($1.record.serverSeq ?? 0) }
            let page = Array(visible.prefix(limit))
            let hasMore = visible.count > limit
            let lastHandedOver = page.last?.record.serverSeq ?? since
            let next = hasMore ? lastHandedOver : max(since, group.lastSeq, lastHandedOver)
            return ReadablePull(records: page.map(\.record), serverSeq: next, hasMore: hasMore)
        }
    }
}

/// One client of an `InMemoryReadableServer`, holding its own session as
/// `ReadableHTTPTransport` does.
public actor InMemoryReadableSession: ReadableAccountTransport {
    public nonisolated let server: InMemoryReadableServer
    private var session: ServerSession?

    init(server: InMemoryReadableServer, session: ServerSession?) {
        self.server = server
        self.session = session
    }

    public var currentSession: ServerSession? { session }
    private var token: String? { session?.token }

    public nonisolated func resuming(with session: ServerSession) -> any ReadableAccountTransport {
        InMemoryReadableSession(server: server, session: session)
    }

    public func health() async throws -> HTTPTransport.Health {
        HTTPTransport.Health(status: "ok", environment: server.environment)
    }

    public func signUp(email: String, password: String, deviceLabel: String?) async throws -> ServerSession {
        let new = try server.signUp(email: email, password: password, label: deviceLabel)
        session = new
        return new
    }

    public func signIn(email: String, password: String, deviceLabel: String?) async throws -> ServerSession {
        let new = try server.signIn(email: email, password: password, label: deviceLabel)
        session = new
        return new
    }

    public func resetPassword(email: String, code: String, newPassword: String,
                              deviceLabel: String?) async throws -> ServerSession {
        let new = try server.reset(email: email, code: code, newPassword: newPassword, label: deviceLabel)
        session = new
        return new
    }

    public func forgotPassword(email: String) async throws { server.forgot(email: email) }

    public func signOut() async throws {
        defer { session = nil }
        guard session != nil else { return }
        try server.signOut(token)
    }

    /// As `ReadableHTTPTransport` does: the session is forgotten only once
    /// the server has ended it, or says it already had.
    public func signOutEverywhere() async throws {
        do {
            try server.signOutEverywhere(token)
        } catch ReadableTransportError.sessionEnded(let reason) {
            session = nil
            throw ReadableTransportError.sessionEnded(reason)
        }
        session = nil
    }

    public func me() async throws -> Me { try server.me(token) }
    public func sessions() async throws -> [DeviceSession] { try server.sessions(token) }
    public func endSession(_ id: UUID) async throws { try server.endSession(id, token) }
    public func verifyEmail(code: String) async throws { try server.verify(code: code, token) }
    public func resendVerification() async throws { try server.resendVerification(token) }

    public func changePassword(current: String, new: String) async throws {
        try server.changePassword(current: current, new: new, token)
    }

    public func groups() async throws -> [ServerGroup] { try server.listGroups(token) }

    public func createGroup(id: GroupID, importKey: Data?) async throws -> ServerGroup {
        try server.createGroup(id: id, importKey: importKey, token)
    }

    public func members(of group: GroupID) async throws -> [ServerMember] { try server.members(of: group, token) }

    public func setLevel(_ level: AccessLevel, of user: UserID, in group: GroupID) async throws {
        try server.setLevel(level, of: user, in: group, token)
    }

    public func remove(_ user: UserID, from group: GroupID) async throws {
        try server.remove(user, from: group, token)
    }

    public func createInvite(group: GroupID, level: AccessLevel, history: HistoryAccess,
                             days: Int?) async throws -> CreatedInvite {
        try server.createInvite(group: group, level: level, history: history, days: days, token)
    }

    public func invites(in group: GroupID) async throws -> [ServerInvite] { try server.invites(in: group, token) }

    public func cancelInvite(_ id: UUID, in group: GroupID) async throws {
        try server.cancelInvite(id, in: group, token)
    }

    public func previewInvite(token inviteToken: String) async throws -> InviteTerms {
        try server.preview(token: inviteToken)
    }

    public func acceptInvite(token inviteToken: String) async throws -> ServerGroup {
        try server.accept(token: inviteToken, token)
    }

    public func createEmailInvite(group: GroupID, email: String, inviteeName: String, inviterName: String,
                                  level: AccessLevel, history: HistoryAccess, days: Int?) async throws -> SentEmailInvite {
        let made = try server.createInvite(group: group, level: level, history: history, days: days,
                                           token, email: email, inviteeName: inviteeName, inviterName: inviterName)
        return SentEmailInvite(id: made.id, expiresAt: made.expiresAt)
    }

    public func incomingInvitations() async throws -> [IncomingInvitation] {
        try server.incomingInvitations(token)
    }

    public func acceptInvitation(_ id: UUID) async throws -> ServerGroup {
        try server.acceptInvitation(id, token)
    }

    public func rejectInvitation(_ id: UUID) async throws {
        try server.rejectInvitation(id, token)
    }

    public func push(_ records: [WireRecord], group: GroupID) async throws -> PushResult {
        try server.push(records, group: group, token)
    }

    public func pull(group: GroupID, since: UInt64, limit: Int) async throws -> ReadablePull {
        try server.pull(group: group, since: since, limit: limit, token)
    }
}
