import Testing
import Foundation
import Fluent
import SQLKit
import NIOConcurrencyHelpers
import Vapor
import VaporTesting
import WellSpentCrypto
import WellSpentModel
@testable import WellSpentServerCore

private struct AddressedInvite: Content {
    let level: Int
    var historyAccess = "all"
    var expiresInDays: Int? = nil
    let email: String
    var inviteeName = "Sam"
    var inviterName = "Robin"
}

private struct InviteTokenBody: Content { let token: String }
private struct InvitationGroupBody: Content { let id: UUID }
private struct InvitationLevelBody: Content { let level: Int }

private func invitationFixture(on app: Application) async throws -> (UUID, V2Session, V2Session, String) {
    let suffix = UUID().uuidString.lowercased()
    let owner = try await v2SignUpConfirmed("invite-owner-\(suffix)@example.com", on: app)
    let address = "invite-recipient-\(suffix)@example.com"
    let recipient = try await v2SignUpConfirmed(address, on: app)
    let groupID = UUID()
    #expect(try await v2Status(.POST, "api/v2/groups", token: owner.token,
                              body: InvitationGroupBody(id: groupID), on: app) == .created)
    let group = BudgetGroup(id: GroupID(groupID), name: "Household")
    try await SyncRecordRow(id: groupID, groupID: groupID, budgetID: nil, recordType: RecordType.groupMeta.rawValue,
                            body: String(decoding: RecordCodec.encoder.encode(group), as: UTF8.self),
                            createdBy: owner.userID, clientID: UUID(), lamport: 1,
                            isDeleted: false, serverSeq: 1).create(on: app.db)
    let budget = Budget(groupID: GroupID(groupID), name: "Food", limit: Money(minorUnits: 50_000))
    try await SyncRecordRow(id: budget.id.uuid, groupID: groupID, budgetID: budget.id.uuid, recordType: "budget",
                            body: String(decoding: RecordCodec.encoder.encode(budget), as: UTF8.self),
                            createdBy: owner.userID, clientID: UUID(), lamport: 2,
                            isDeleted: false, serverSeq: 2).create(on: app.db)
    let stored = try #require(try await GroupRow.find(groupID, on: app.db))
    stored.lastSeq = 2
    stored.maxLamport = 2
    try await stored.save(on: app.db)
    return (groupID, owner, recipient, address)
}

private func sendInvitation(_ groupID: UUID, to address: String, as owner: V2Session,
                            level: AccessLevel = .write, history: String = "all", on app: Application)
    async throws -> InviteCreatedResponse {
    var answer: InviteCreatedResponse?
    try await app.testing().test(.POST, "api/v2/groups/\(groupID)/invites", headers: v2Bearer(owner.token),
        beforeRequest: { request in
            try request.content.encode(AddressedInvite(level: level.rawValue, historyAccess: history, email: address))
        }, afterResponse: { response async throws in
            #expect(response.status == .created)
            answer = try response.content.decode(InviteCreatedResponse.self)
        })
    return try #require(answer)
}

private func incoming(_ person: V2Session, on app: Application) async throws -> [IncomingInvitationResponse] {
    var result: [IncomingInvitationResponse] = []
    try await app.testing().test(.GET, "api/v2/invitations", headers: v2Bearer(person.token),
        afterResponse: { response async throws in
            #expect(response.status == .ok)
            result = try response.content.decode([IncomingInvitationResponse].self)
        })
    return result
}

@Suite("Server, addressed group invitations", .serialized)
struct EmailInvitationTests {
    @Test func onlyTheConfirmedRecipientSeesAndAcceptsAnInvitationAndViewKeepsTheirName() async throws {
        try await withV2App { app, _ in
            let (group, owner, recipient, address) = try await invitationFixture(on: app)
            let created = try await sendInvitation(group, to: " MAILTO:\(address.uppercased()) ", as: owner,
                                                   level: .read, history: "fromNow", on: app)
            #expect(created.token == nil, "an addressed link is not returned to the inviter")
            try await app.testing().test(.POST, "api/v2/invites/preview", beforeRequest: { request in
                try request.content.encode(InviteTokenBody(token: EmailInvitationRules.token(created.id, key: app.emailCodeKey)))
            }, afterResponse: { response async throws in
                #expect(response.status == .ok)
                let preview = try response.content.decode(InvitePreview.self)
                #expect(preview.invitationID == created.id && preview.inviteeName == "Sam")
            })
            let waiting = try await incoming(recipient, on: app)
            #expect(waiting.map(\.id) == [created.id])
            #expect(waiting.first?.groupName == "Household" && waiting.first?.inviterName == "Robin")
            #expect(waiting.first?.inviteeName == "Sam")
            #expect(try await incoming(owner, on: app).isEmpty)
            #expect(try await v2Status(.GET, "api/v2/groups/\(group)/pull", token: recipient.token, on: app) == .forbidden)
            for action in ["accept", "reject"] {
                #expect(try await v2Status(.POST, "api/v2/invitations/\(created.id)/\(action)",
                                          token: owner.token, on: app) == .notFound)
            }
            let user = try #require(try await UserRow.find(recipient.userID, on: app.db))
            user.emailVerifiedAt = nil
            try await user.save(on: app.db)
            #expect(try await v2Status(.GET, "api/v2/invitations", token: recipient.token, on: app) == .forbidden)
            #expect(try await v2Status(.POST, "api/v2/invitations/\(created.id)/accept", token: recipient.token, on: app) == .forbidden)
            user.emailVerifiedAt = Date()
            try await user.save(on: app.db)
            var reply: GroupResponse?
            try await app.testing().test(.POST, "api/v2/invitations/\(created.id)/accept", headers: v2Bearer(recipient.token),
                afterResponse: { response async throws in
                    #expect(response.status == .ok)
                    reply = try response.content.decode(GroupResponse.self)
                })
            #expect(reply?.level == AccessLevel.read.rawValue && reply?.historyFloor == 2)
            #expect(reply?.importKey.count == 32)
            #expect(try await incoming(recipient, on: app).isEmpty)
            #expect(try await v2Status(.GET, "api/v2/groups/\(group)/pull", token: recipient.token, on: app) == .ok)
            try await app.testing().test(.GET, "api/v2/groups/\(group)/pull", headers: v2Bearer(recipient.token),
                afterResponse: { response async throws in
                    let pulled = try response.content.decode(PullV2Response.self)
                    #expect(pulled.records.contains { $0.type == "budget" && $0.body.contains("Food") })
                })
            let profileID = MemberProfile.recordID(group: GroupID(group), user: UserID(recipient.userID))
            let row = try #require(try await SyncRecordRow.find(profileID.uuid, on: app.db))
            let profile = try RecordCodec.decoder.decode(MemberProfile.self, from: Data(row.body.utf8))
            #expect(profile.displayName == "Sam")
            #expect(!row.body.contains(address))
        }
    }

    @Test func rejectionIsTerminalAndTheInviterMustCreateAFreshInvitation() async throws {
        try await withV2App { app, _ in
            let (group, owner, recipient, address) = try await invitationFixture(on: app)
            let first = try await sendInvitation(group, to: address, as: owner, on: app)
            let body = AddressedInvite(level: AccessLevel.write.rawValue, email: address)
            #expect(try await v2Status(.POST, "api/v2/groups/\(group)/invites", token: owner.token, body: body, on: app) == .conflict)
            #expect(try await v2Status(.POST, "api/v2/invitations/\(first.id)/reject", token: recipient.token, on: app) == .noContent)
            #expect(try await incoming(recipient, on: app).isEmpty)
            #expect(try await v2Status(.POST, "api/v2/invitations/\(first.id)/accept", token: recipient.token, on: app) == .conflict)
            let firstToken = EmailInvitationRules.token(first.id, key: app.emailCodeKey)
            #expect(try await v2Status(.POST, "api/v2/invites/accept", token: recipient.token,
                                      body: InviteTokenBody(token: firstToken), on: app) == .conflict)
            var pending: [InviteInfo] = []
            try await app.testing().test(.GET, "api/v2/groups/\(group)/invites", headers: v2Bearer(owner.token),
                afterResponse: { response async throws in pending = try response.content.decode([InviteInfo].self) })
            #expect(pending.first?.status == "rejected" && pending.first?.email == address)
            let second = try await sendInvitation(group, to: address, as: owner, on: app)
            #expect(second.id != first.id)
            #expect(try await incoming(recipient, on: app).map(\.id) == [second.id])
            #expect(try await v2Status(.POST, "api/v2/invitations/\(second.id)/accept", token: recipient.token, on: app) == .ok)
            #expect(try await v2Status(.POST, "api/v2/invites/accept", token: recipient.token,
                                      body: InviteTokenBody(token: firstToken), on: app) == .conflict)
            try await app.testing().test(.GET, "api/v2/groups/\(group)/invites", headers: v2Bearer(owner.token),
                afterResponse: { response async throws in
                    #expect(try response.content.decode([InviteInfo].self).isEmpty,
                            "the old rejection is not shown beside an accepted member")
                })
        }
    }

    @Test func forwardedLinksStayBoundAndCancellationAndExpiryEndBothWaysIn() async throws {
        try await withV2App { app, _ in
            let (group, owner, recipient, address) = try await invitationFixture(on: app)
            let first = try await sendInvitation(group, to: address, as: owner, on: app)
            let body = InviteTokenBody(token: EmailInvitationRules.token(first.id, key: app.emailCodeKey))
            #expect(try await v2Status(.POST, "api/v2/invites/accept", token: owner.token, body: body, on: app) == .notFound)
            #expect(try await v2Status(.DELETE, "api/v2/groups/\(group)/invites/\(first.id)", token: owner.token, on: app) == .noContent)
            #expect(try await v2Status(.POST, "api/v2/invites/accept", token: recipient.token, body: body, on: app) == .notFound)
            #expect(try await v2Status(.POST, "api/v2/invites/preview", body: body, on: app) == .notFound)
            let second = try await sendInvitation(group, to: address, as: owner, on: app)
            let row = try #require(try await InviteRow.find(second.id, on: app.db))
            row.expiresAt = Date().addingTimeInterval(-1)
            try await row.save(on: app.db)
            #expect(try await incoming(recipient, on: app).isEmpty)
            for action in ["accept", "reject"] {
                #expect(try await v2Status(.POST, "api/v2/invitations/\(second.id)/\(action)", token: recipient.token, on: app) == .gone)
            }
        }
    }

    @Test func joiningThroughALinkClosesTheEmailInviteEvenAfterRemoval() async throws {
        try await withV2App { app, _ in
            let (group, owner, recipient, address) = try await invitationFixture(on: app)
            let email = try await sendInvitation(group, to: address, as: owner, on: app)
            let token = urlSafeToken()
            let link = InviteRow(inviteHash: inviteTokenHash(token), groupID: group, inviterUserID: owner.userID,
                                 level: AccessLevel.write.rawValue, historyAccess: "all", expiresAt: Date().addingTimeInterval(3600))
            try await link.create(on: app.db)
            #expect(try await v2Status(.POST, "api/v2/invites/accept", token: recipient.token,
                                      body: InviteTokenBody(token: token), on: app) == .ok)
            #expect(try await v2Status(.DELETE, "api/v2/groups/\(group)/members/\(recipient.userID)", token: owner.token, on: app) == .noContent)
            #expect(try await incoming(recipient, on: app).isEmpty)
            #expect(try await v2Status(.POST, "api/v2/invitations/\(email.id)/accept", token: recipient.token, on: app) == .notFound)
            #expect(try await InviteRow.find(email.id, on: app.db)?.closedAt != nil)
            try await app.testing().test(.GET, "api/v2/groups/\(group)/invites", headers: v2Bearer(owner.token),
                afterResponse: { response async throws in
                    #expect(try response.content.decode([InviteInfo].self).isEmpty)
                })
            let fresh = try await sendInvitation(group, to: address, as: owner, on: app)
            #expect(fresh.id != email.id)
            #expect(try await incoming(recipient, on: app).map(\.id) == [fresh.id])
            #expect(try await v2Status(.POST, "api/v2/invitations/\(fresh.id)/accept", token: recipient.token, on: app) == .ok)
        }
    }

    @Test func acceptAndRejectRacingChooseExactlyOneOutcome() async throws {
        try await withV2App { app, _ in
            let (group, owner, recipient, address) = try await invitationFixture(on: app)
            let invite = try await sendInvitation(group, to: address, as: owner, on: app)
            async let accepted = v2Status(.POST, "api/v2/invitations/\(invite.id)/accept", token: recipient.token, on: app)
            async let rejected = v2Status(.POST, "api/v2/invitations/\(invite.id)/reject", token: recipient.token, on: app)
            let answers = try await [accepted, rejected]
            #expect(answers.filter { $0 == .ok || $0 == .noContent }.count == 1)
            #expect(answers.contains(.conflict))
            let row = try #require(try await InviteRow.find(invite.id, on: app.db))
            #expect((row.acceptedAt != nil) != (row.rejectedAt != nil))
            let memberships = try await MembershipRow.query(on: app.db).filter(\.$groupID == group)
                .filter(\.$userID == recipient.userID).count()
            #expect(memberships == (row.acceptedAt == nil ? 0 : 1))
        }
    }

    @Test func acceptAndCancelRacingChooseExactlyOneOutcome() async throws {
        try await withV2App { app, _ in
            let (group, owner, recipient, address) = try await invitationFixture(on: app)
            let invite = try await sendInvitation(group, to: address, as: owner, on: app)
            async let accepted = v2Status(.POST, "api/v2/invitations/\(invite.id)/accept", token: recipient.token, on: app)
            async let cancelled = v2Status(.DELETE, "api/v2/groups/\(group)/invites/\(invite.id)", token: owner.token, on: app)
            let answers = try await [accepted, cancelled]
            #expect(answers.filter { $0 == .ok || $0 == .noContent }.count == 1)
            #expect(answers.contains(.conflict) || answers.contains(.notFound))
            let row = try #require(try await InviteRow.find(invite.id, on: app.db))
            #expect((row.acceptedAt != nil) != (row.cancelledAt != nil))
            let memberships = try await MembershipRow.query(on: app.db).filter(\.$groupID == group)
                .filter(\.$userID == recipient.userID).count()
            #expect(memberships == (row.acceptedAt == nil ? 0 : 1))
        }
    }

    @Test func unconfirmedSendersBadNamesAndInsufficientLevelsCannotSend() async throws {
        try await withV2App { app, _ in
            let (group, owner, recipient, address) = try await invitationFixture(on: app)
            let body = AddressedInvite(level: AccessLevel.write.rawValue, email: address)
            #expect(try await v2Status(.POST, "api/v2/groups/\(group)/invites", token: recipient.token, body: body, on: app) == .forbidden)
            let user = try #require(try await UserRow.find(owner.userID, on: app.db))
            user.emailVerifiedAt = nil
            try await user.save(on: app.db)
            #expect(try await v2Status(.POST, "api/v2/groups/\(group)/invites", token: owner.token, body: body, on: app) == .forbidden)
            user.emailVerifiedAt = Date()
            try await user.save(on: app.db)
            var bad = body
            bad.inviteeName = "\n\t"
            #expect(try await v2Status(.POST, "api/v2/groups/\(group)/invites", token: owner.token, body: bad, on: app) == .badRequest)
        }
    }

    @Test func aDemotedInvitersPendingEmailCannotGrantAccess() async throws {
        try await withV2App { app, _ in
            let (group, owner, recipient, address) = try await invitationFixture(on: app)
            let manager = try await v2SignUpConfirmed("invite-manager-\(UUID())@example.com", on: app)
            try await MembershipRow(groupID: group, userID: manager.userID,
                                    level: AccessLevel.manage.rawValue, joinedAtSequence: 0).create(on: app.db)
            let invite = try await sendInvitation(group, to: address, as: manager, on: app)
            #expect(try await v2Status(.PATCH, "api/v2/groups/\(group)/members/\(manager.userID)", token: owner.token,
                                      body: InvitationLevelBody(level: AccessLevel.write.rawValue), on: app) == .noContent)
            #expect(try await incoming(recipient, on: app).isEmpty)
            #expect(try await v2Status(.POST, "api/v2/invitations/\(invite.id)/accept", token: recipient.token, on: app) == .gone)
        }
    }

    @Test func persistentQuotasBoundNewSendersAcrossGroups() async throws {
        try await withV2App { app, _ in
            await app.invitationDelivery.shutdown()
            app.invitationDelivery = InvitationDelivery(automatic: false)
            let (_, owner, _, address) = try await invitationFixture(on: app)
            for index in 0 ... EmailInvitationRules.perNewInviter {
                let group = UUID()
                #expect(try await v2Status(.POST, "api/v2/groups", token: owner.token,
                                          body: InvitationGroupBody(id: group), on: app) == .created)
                let status = try await v2Status(.POST, "api/v2/groups/\(group)/invites", token: owner.token,
                    body: AddressedInvite(level: AccessLevel.write.rawValue, email: address), on: app)
                #expect(status == (index < EmailInvitationRules.perNewInviter ? .created : .tooManyRequests))
            }
            #expect(try await InviteRow.query(on: app.db).filter(\.$inviterUserID == owner.userID).count()
                    == EmailInvitationRules.perNewInviter)
            try app.enableTestMailbox(token: String(repeating: "t", count: 32))
            let testGroup = UUID()
            #expect(try await v2Status(.POST, "api/v2/groups", token: owner.token,
                                      body: InvitationGroupBody(id: testGroup), on: app) == .created)
            #expect(try await v2Status(.POST, "api/v2/groups/\(testGroup)/invites", token: owner.token,
                body: AddressedInvite(level: AccessLevel.write.rawValue, email: address), on: app) == .created)
            #expect(try await v2Status(.POST, "api/v2/groups/\(testGroup)/invites", token: owner.token,
                body: AddressedInvite(level: AccessLevel.write.rawValue, email: "recipient@other.invalid"), on: app) == .tooManyRequests,
                    "a test sender cannot use the allowance to email real addresses")
            app.storage[ServerEnvironmentKey.self] = .live
            let liveGroup = UUID()
            #expect(try await v2Status(.POST, "api/v2/groups", token: owner.token,
                                      body: InvitationGroupBody(id: liveGroup), on: app) == .created)
            #expect(try await v2Status(.POST, "api/v2/groups/\(liveGroup)/invites", token: owner.token,
                body: AddressedInvite(level: AccessLevel.write.rawValue, email: address), on: app) == .tooManyRequests,
                    "even a stale mailbox flag cannot enlarge live limits")
        }
    }

    @Test func endedInvitationsAreNeverDelivered() async throws {
        try await withV2App { app, _ in
            await app.invitationDelivery.shutdown()
            app.invitationDelivery = InvitationDelivery(automatic: false)
            let (group, owner, recipient, address) = try await invitationFixture(on: app)
            let mailer = V2RecordingMailer()
            app.mailer = mailer
            let rejected = try await sendInvitation(group, to: address, as: owner, on: app)
            #expect(try await v2Status(.POST, "api/v2/invitations/\(rejected.id)/reject", token: recipient.token, on: app) == .noContent)
            let cancelled = try await sendInvitation(group, to: address, as: owner, on: app)
            #expect(try await v2Status(.DELETE, "api/v2/groups/\(group)/invites/\(cancelled.id)", token: owner.token, on: app) == .noContent)
            let expired = try await sendInvitation(group, to: address, as: owner, on: app)
            let row = try #require(try await InviteRow.find(expired.id, on: app.db))
            row.expiresAt = Date().addingTimeInterval(-1)
            try await row.save(on: app.db)
            let accepted = try await sendInvitation(group, to: address, as: owner, on: app)
            #expect(try await v2Status(.POST, "api/v2/invitations/\(accepted.id)/accept", token: recipient.token, on: app) == .ok)
            await app.invitationDelivery.deliverPending(on: app)
            #expect(await mailer.count(to: address) == 0)
            for id in [rejected.id, cancelled.id, expired.id, accepted.id] {
                #expect(try await InviteRow.find(id, on: app.db)?.mailStoppedAt != nil)
            }
        }
    }

    @Test func queuedEmailRetriesWithoutRawTokensAndOptOutOnlyHappensOnPost() async throws {
        try await withV2App { app, _ in
            await app.invitationDelivery.shutdown()
            app.invitationDelivery = InvitationDelivery(automatic: false)
            let (group, owner, recipient, address) = try await invitationFixture(on: app)
            let mailer = RetryInvitationMailer()
            app.mailer = mailer
            let invite = try await sendInvitation(group, to: address, as: owner, on: app)
            let now = Date()
            await app.invitationDelivery.deliverPending(on: app, now: now)
            let failed = try #require(try await InviteRow.find(invite.id, on: app.db))
            #expect(failed.mailAttempts == 1 && failed.mailSentAt == nil)
            #expect(failed.mailNextAttemptAt! > now && failed.mailClaimedUntil == nil)
            await app.invitationDelivery.deliverPending(on: app, now: now.addingTimeInterval(61))
            let sent = try #require(try await InviteRow.find(invite.id, on: app.db))
            #expect(sent.mailAttempts == 2 && sent.mailSentAt != nil)
            let text = try #require(await mailer.messages.last)
            let token = EmailInvitationRules.token(invite.id, key: app.emailCodeKey)
            #expect(text.contains("https://staging.wellspent.space/invite/\(token)?environment=staging"))
            #expect(text.contains("Robin invited you to Household"))
            #expect(text.contains(sent.expiresAt.ISO8601Format()))
            #expect(sent.inviteHash == inviteTokenHash(token))
            #expect(sent.inviteHash != Data(token.utf8))
            let stop = EmailInvitationRules.token(invite.id, purpose: "stop-invite-email", key: app.emailCodeKey)
            #expect(try await v2Status(.GET, "email/invites/stop?token=\(stop)", on: app) == .ok)
            #expect(try await invitationEmailSuppressed(address, on: app) == false)
            #expect(try await v2Status(.POST, "email/invites/stop", body: InviteTokenBody(token: stop), on: app) == .ok)
            #expect(try await invitationEmailSuppressed(address, on: app))
            #expect(try await incoming(recipient, on: app).map(\.id) == [invite.id], "opting out affects mail, not invitations")
            #expect(try await v2Status(.POST, "api/v2/invitations/\(invite.id)/reject", token: recipient.token, on: app) == .noContent)
            let second = try await sendInvitation(group, to: address, as: owner, on: app)
            await app.invitationDelivery.deliverPending(on: app)
            #expect(try await InviteRow.find(second.id, on: app.db)?.mailStoppedAt != nil)
            #expect(await mailer.messages.count == 1)
        }
    }

    @Test func migrationIsRepeatableAndKeepsLegacyInvites() async throws {
        try await withV2App { app, _ in
            await app.invitationDelivery.shutdown()
            app.invitationDelivery = InvitationDelivery(automatic: false)
            let invite = InviteRow(inviteHash: inviteTokenHash(urlSafeToken()), groupID: UUID(), inviterUserID: UUID(),
                                   level: AccessLevel.read.rawValue, historyAccess: "all", expiresAt: Date().addingTimeInterval(3600))
            try await invite.create(on: app.db)
            try await AddEmailInvitations().prepare(on: app.db)
            #expect(try await InviteRow.find(invite.id, on: app.db)?.inviteeEmail == nil)
            try await AddEmailInvitations().revert(on: app.db)
            try await AddEmailInvitations().prepare(on: app.db)
            #expect(try await InviteRow.find(invite.id, on: app.db)?.inviteHash == invite.inviteHash)
        }
    }

    @Test func theLandingPageEscapesNamesUsesTheRightAppAndNeverAcceptsOnGet() async throws {
        try await withV2App { app, _ in
            let (group, owner, recipient, address) = try await invitationFixture(on: app)
            let created = try await sendInvitation(group, to: address, as: owner, on: app)
            let row = try #require(try await InviteRow.find(created.id, on: app.db))
            row.inviterName = "<img src=x onerror=alert(1)>"
            row.inviteeName = "Sam & Pat"
            try await row.save(on: app.db)
            let token = EmailInvitationRules.token(created.id, key: app.emailCodeKey)
            let path = "invite/\(token)?environment=staging"
            try await app.testing().test(.GET, path, afterResponse: { response async throws in
                #expect(response.status == .ok)
                #expect(response.headers.first(name: "Cache-Control") == "no-store")
                #expect(response.headers.first(name: "Referrer-Policy") == "no-referrer")
                let html = response.body.string
                #expect(html.contains("wellspent-staging://join#s=\(token)"))
                #expect(html.contains("&lt;img src=x onerror=alert(1)&gt;"))
                #expect(!html.contains("<img"))
                #expect(html.contains("Sam &amp; Pat"))
                #expect(!html.contains(address), "the public page never exposes the account address")
                #expect(!html.contains("type=\"password\""))
                #expect(html.contains("sign in or create an account"))
            })
            #expect(try await InviteRow.find(created.id, on: app.db)?.acceptedAt == nil)
            #expect(try await v2Status(.GET, "api/v2/groups/\(group)/pull", token: recipient.token, on: app) == .forbidden)
            #expect(try await v2Status(.GET, "invite/\(token)?environment=live", on: app) == .badRequest)
            #expect(try await v2Status(.GET, "invite/not-an-invite", on: app) == .gone)
            #expect(try await v2Status(.POST, "api/v2/invitations/\(created.id)/reject", token: recipient.token, on: app) == .noContent)
            #expect(try await v2Status(.GET, path, on: app) == .gone)
        }
    }

    @Test func invitationPublicOriginsCannotCrossEnvironmentsOrPointAtAnotherSite() throws {
        #expect(try InvitationWeb.baseURL(nil, environment: .live) == "https://sync.wellspent.space")
        #expect(try InvitationWeb.baseURL(nil, environment: .staging) == "https://staging.wellspent.space")
        #expect(try InvitationWeb.baseURL("https://wellspent.space/", environment: .live) == "https://wellspent.space")
        for invalid in ["http://wellspent.space", "https://other.example", "https://wellspent.space@other.example",
                        "https://wellspent.space/path", "https://wellspent.space?next=other", "https://staging.wellspent.space"] {
            #expect(throws: (any Error).self) { try InvitationWeb.baseURL(invalid, environment: .live) }
        }
        #expect(throws: (any Error).self) { try InvitationWeb.baseURL("https://sync.wellspent.space", environment: .staging) }
    }

    @Test func anInvitationWaitsForAnUnknownAddressToSignUpAndConfirm() async throws {
        try await withV2App { app, mailer in
            let (group, owner, _, _) = try await invitationFixture(on: app)
            let address = "invite-future-\(UUID().uuidString.lowercased())@example.com"
            let created = try await sendInvitation(group, to: address, as: owner, on: app)
            #expect(try await UserRow.query(on: app.db).filter(\.$email == address).first() == nil)
            let token = EmailInvitationRules.token(created.id, key: app.emailCodeKey)
            #expect(try await v2Status(.GET, "invite/\(token)", on: app) == .ok)
            #expect(try await UserRow.query(on: app.db).filter(\.$email == address).first() == nil)
            #expect(try await MembershipRow.query(on: app.db).filter(\.$groupID == group).count() == 1)
            let newcomer = try await v2SignUp(address, on: app)
            #expect(try await v2Status(.GET, "api/v2/invitations", token: newcomer.token, on: app) == .forbidden)
            // The code email and invitation can arrive in either order.
            let messages = await mailer.waitFor(2, to: address)
            let codeMessage = try #require(messages.first { $0.subject.contains("code") })
            let code = try v2Code(in: codeMessage)
            #expect(try await v2Status(.POST, "api/v2/email/verify", token: newcomer.token,
                                      body: V2CodeBody(code: code), on: app) == .noContent)
            #expect(try await incoming(newcomer, on: app).map(\.id) == [created.id])
            #expect(try await v2Status(.GET, "api/v2/groups/\(group)/pull", token: newcomer.token, on: app) == .forbidden)
            #expect(try await v2Status(.POST, "api/v2/invitations/\(created.id)/accept", token: newcomer.token, on: app) == .ok)
            try await app.testing().test(.GET, "api/v2/groups/\(group)/pull", headers: v2Bearer(newcomer.token),
                afterResponse: { response async throws in
                    #expect(response.status == .ok)
                    #expect(try response.content.decode(PullV2Response.self).records.contains { $0.type == "budget" })
                })
        }
    }

    @Test func invitationPageLoggingNeverRecordsTheLinkOrStopToken() async throws {
        try await withV2App { app, _ in
            let (group, owner, _, address) = try await invitationFixture(on: app)
            let created = try await sendInvitation(group, to: address, as: owner, on: app)
            let token = EmailInvitationRules.token(created.id, key: app.emailCodeKey)
            let stop = EmailInvitationRules.token(created.id, purpose: "stop-invite-email", key: app.emailCodeKey)
            let capture = InvitationLogCapture()
            app.logger = Logger(label: "invitation-log-test", factory: { _ in InvitationLogHandler(capture: capture) })
            _ = try await v2Status(.GET, "invite/\(token)", on: app)
            _ = try await v2Status(.GET, "invite/\(token)?environment=wrong", on: app)
            _ = try await v2Status(.GET, "email/invites/stop?token=\(stop)", on: app)
            #expect(capture.lines.contains { $0.contains("invitation page answered") })
            #expect(!capture.lines.contains { $0.contains(token) || $0.contains(stop) })
        }
    }
}

private actor RetryInvitationMailer: Mailer {
    private var first = true
    private(set) var messages: [String] = []
    func send(to address: String, subject: String, text: String) async throws {
        if first { first = false; throw Abort(.badGateway) }
        messages.append(text)
    }
}

private final class InvitationLogCapture: @unchecked Sendable {
    private let lock = NIOLock()
    private var stored: [String] = []
    var lines: [String] { lock.withLock { stored } }
    func append(_ line: String) { lock.withLock { stored.append(line) } }
}

private struct InvitationLogHandler: LogHandler {
    let capture: InvitationLogCapture
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .info
    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }
    func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?,
             source: String, file: String, function: String, line: UInt) {
        capture.append("\(message) \(self.metadata) \(metadata ?? [:])")
    }
}
