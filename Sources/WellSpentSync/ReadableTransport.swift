import Foundation
import WellSpentCrypto

/// What readable sync needs from the server to move one group's records.
///
/// The server stores records as they are and checks who may change what, so
/// unlike `SyncTransport` there is no key or access history to fetch.
public protocol ReadableSyncTransport: Sendable {
    /// Sends records. Each is accepted or refused on its own, with a reason.
    func push(_ records: [WireRecord], group: GroupID) async throws -> PushResult

    /// Records stored after `since`, in server order.
    func pull(group: GroupID, since: UInt64, limit: Int) async throws -> ReadablePull
}

/// Everything else the app asks the readable server: the account, groups,
/// members and invites. One signed-in session per value.
public protocol ReadableAccountTransport: ReadableSyncTransport {
    /// Which server this is. Asked before a password is sent, so a test
    /// build never signs in to the live server or the other way round.
    func health() async throws -> HTTPTransport.Health

    /// Each returns the new session and uses it for the calls after.
    func signUp(email: String, password: String, deviceLabel: String?) async throws -> ServerSession
    func signIn(email: String, password: String, deviceLabel: String?) async throws -> ServerSession
    /// Sets a new password with the code emailed by `forgotPassword`, and
    /// signs this device in. Every other session of the account ends.
    func resetPassword(email: String, code: String, newPassword: String,
                       deviceLabel: String?) async throws -> ServerSession
    /// Emails a reset code if the address has an account. Says nothing either way.
    func forgotPassword(email: String) async throws

    func signOut() async throws
    func signOutEverywhere() async throws
    func me() async throws -> Me
    func sessions() async throws -> [DeviceSession]
    func endSession(_ id: UUID) async throws
    func verifyEmail(code: String) async throws
    func resendVerification() async throws
    /// Keeps this device signed in and ends every other session.
    func changePassword(current: String, new: String) async throws

    /// Every group this account belongs to, deleted ones included.
    func groups() async throws -> [ServerGroup]
    /// Makes a group with this account as founder. For a group made before
    /// the switch, sent by its founder, it sets the import key once and
    /// returns the group as it stands.
    func createGroup(id: GroupID, importKey: Data?) async throws -> ServerGroup
    func members(of group: GroupID) async throws -> [ServerMember]
    func setLevel(_ level: AccessLevel, of user: UserID, in group: GroupID) async throws
    /// Removing yourself is leaving.
    func remove(_ user: UserID, from group: GroupID) async throws
    func createInvite(group: GroupID, level: AccessLevel, history: HistoryAccess,
                      days: Int?) async throws -> CreatedInvite
    func invites(in group: GroupID) async throws -> [ServerInvite]
    func cancelInvite(_ id: UUID, in group: GroupID) async throws
    /// Needs no session: anyone holding the link may see what it is for.
    func previewInvite(token: String) async throws -> InviteTerms
    func acceptInvite(token: String) async throws -> ServerGroup
    func createEmailInvite(group: GroupID, email: String, inviteeName: String, inviterName: String,
                           level: AccessLevel, history: HistoryAccess, days: Int?) async throws -> SentEmailInvite
    func incomingInvitations() async throws -> [IncomingInvitation]
    func acceptInvitation(_ id: UUID) async throws -> ServerGroup
    func rejectInvitation(_ id: UUID) async throws

    /// The same server, with a session saved earlier.
    func resuming(with session: ServerSession) -> any ReadableAccountTransport
}
