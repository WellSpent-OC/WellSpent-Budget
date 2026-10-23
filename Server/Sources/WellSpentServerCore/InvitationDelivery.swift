import Foundation
import Fluent
import SQLKit
import Vapor
import WellSpentCrypto
import WellSpentModel

/// The invitation itself is the durable outbox. A restart retains its next
/// attempt and lease. No raw link token is stored: it is regenerated using the
/// server secret, and its hash must still match before anything is sent.
///
/// Mailer has no provider idempotency contract. Delivery is at least once: if
/// the provider accepts a message but its reply is lost, a retry may repeat it.
actor InvitationDelivery {
    private var task: Task<Void, Never>?
    private var processing = false
    private let automatic: Bool

    init(automatic: Bool = true) { self.automatic = automatic }

    func wake(_ app: Application) {
        guard automatic, task == nil else { return }
        task = Task { await self.deliverPending(on: app); self.finished() }
    }

    private func finished() { task = nil }

    func shutdown() async {
        task?.cancel()
        await task?.value
        task = nil
    }

    func deliverPending(on app: Application, now: Date = Date()) async {
        guard !processing else { return }
        processing = true
        defer { processing = false }
        do {
            let candidates = try await InviteRow.query(on: app.db)
                .filter(\.$inviteeEmail != nil).filter(\.$mailSentAt == nil)
                .filter(\.$mailStoppedAt == nil).filter(\.$mailNextAttemptAt <= now)
                .sort(\.$createdAt, .ascending).limit(50).all()
            for candidate in candidates {
                if Task.isCancelled { return }
                guard let id = candidate.id else { continue }
                do { try await deliver(id, groupID: candidate.groupID, on: app, now: now) }
                catch { app.logger.error("invitation delivery could not update its queue") }
            }
        } catch { app.logger.error("invitation delivery could not read its queue") }
    }

    private func deliver(_ id: UUID, groupID: UUID, on app: Application, now: Date) async throws {
        let invite: InviteRow? = try await app.db.transaction { database in
            try await holdGroup(groupID, on: database)
            guard let row = try await InviteRow.find(id, on: database),
                  row.inviteeEmail != nil, row.mailSentAt == nil, row.mailStoppedAt == nil,
                  (row.mailNextAttemptAt ?? .distantFuture) <= now,
                  (row.mailClaimedUntil ?? .distantPast) <= now else { return nil }
            guard invitationIsPending(row, now: now), (row.mailAttempts ?? 0) < EmailInvitationRules.maxMailAttempts else {
                row.mailStoppedAt = now
                try await row.save(on: database)
                return nil
            }
            row.mailAttempts = (row.mailAttempts ?? 0) + 1
            row.mailClaimedUntil = now.addingTimeInterval(300)
            try await row.save(on: database)
            return row
        }
        guard let invite, let address = invite.inviteeEmail else { return }
        guard let group = try await GroupRow.find(groupID, on: app.db), group.deletedAt == nil,
              let sender = try await MembershipRow.query(on: app.db).filter(\.$groupID == groupID)
                .filter(\.$userID == invite.inviterUserID).first(),
              let level = AccessLevel(rawValue: invite.level), let senderLevel = AccessLevel(rawValue: sender.level),
              MembershipRules.invite(at: level, holding: senderLevel) == nil,
              !(try await invitationEmailSuppressed(address, on: app)) else {
            try await stop(id, on: app.db, now: now)
            return
        }
        // This lookup never changes the create response. Existing members do
        // not need mail, and an inviter learns nothing about their addresses.
        if let user = try await UserRow.query(on: app.db).filter(\.$email == address).first(),
           try await MembershipRow.query(on: app.db).filter(\.$groupID == groupID)
            .filter(\.$userID == user.requireID()).filter(\.$level > 0).first() != nil {
            try await stop(id, on: app.db, now: now)
            return
        }
        let token = EmailInvitationRules.token(id, key: app.emailCodeKey)
        guard inviteTokenHash(token) == invite.inviteHash else {
            // A server-key rotation cannot silently send a broken link.
            try await stop(id, on: app.db, now: now)
            return
        }
        let groupName = try await invitationGroupName(groupID, on: app.db)
        let senderName = emailName(invite.inviterName ?? "", fallback: "Someone")
        let safeGroup = emailName(groupName, fallback: "a group")
        let stopToken = EmailInvitationRules.token(id, purpose: "stop-invite-email", key: app.emailCodeKey)
        let server = app.storage[ServerEnvironmentKey.self] == .live ? "sync.wellspent.space" : "staging.wellspent.space"
        let environment = app.storage[ServerEnvironmentKey.self] == .live ? "live" : "staging"
        let link = "\(app.invitationPublicBaseURL)/invite/\(token)?environment=\(environment)"
        let text = """
        \(senderName) invited you to \(safeGroup) in WellSpent.

        Open your invitation:
        \(link)

        Sign in to WellSpent with \(address). Your invitation also waits in the app until you accept or reject it.
        This invitation expires on \(invite.expiresAt.ISO8601Format()). WellSpent never asks for your password in an email or on a web page.

        Stop invitation emails:
        https://\(server)/email/invites/stop?token=\(stopToken)
        """
        // Cancellation while a message is already at the provider cannot
        // recall it. Check fresh state immediately before handing it over.
        guard let current = try await InviteRow.find(id, on: app.db), invitationIsPending(current),
              !(try await invitationEmailSuppressed(address, on: app)) else {
            try await stop(id, on: app.db, now: now)
            return
        }
        do {
            try await app.mailer.send(to: address, subject: "Your invitation to WellSpent", text: text)
            try await InviteRow.query(on: app.db).filter(\.$id == id)
                .set(\.$mailSentAt, to: Date()).set(\.$mailClaimedUntil, to: nil).update()
        } catch {
            let attempts = invite.mailAttempts ?? 1
            let delays: [TimeInterval] = [60, 300, 1800, 7200, 21600]
            let retry = attempts < EmailInvitationRules.maxMailAttempts
            try await InviteRow.query(on: app.db).filter(\.$id == id)
                .set(\.$mailNextAttemptAt, to: retry ? now.addingTimeInterval(delays[min(attempts - 1, delays.count - 1)]) : nil)
                .set(\.$mailStoppedAt, to: retry ? nil : now).set(\.$mailClaimedUntil, to: nil).update()
            app.logger.warning("invitation email delivery failed; the queue recorded the attempt")
        }
    }

    private func stop(_ id: UUID, on database: any Database, now: Date) async throws {
        try await InviteRow.query(on: database).filter(\.$id == id)
            .set(\.$mailStoppedAt, to: now).set(\.$mailClaimedUntil, to: nil).update()
    }
}

private func emailName(_ name: String, fallback: String) -> String {
    guard !name.isEmpty, name.count <= 50, !name.localizedCaseInsensitiveContains("wellspent"),
          name.allSatisfy({ $0.isLetter || $0.isNumber || " '-&".contains($0) }),
          !name.split(whereSeparator: { !$0.isNumber }).contains(where: { $0.count > 4 }) else { return fallback }
    return name
}

func invitationEmailSuppressed(_ address: String, on app: Application) async throws -> Bool {
    guard let sql = app.db as? any SQLDatabase else { throw Abort(.internalServerError) }
    return try await sql.select().column("address_hash").from("invite_email_suppressions")
        .where("address_hash", .equal, SQLBind(EmailInvitationRules.addressHash(address, key: app.emailCodeKey)))
        .first() != nil
}

extension Application {
    private struct InvitationDeliveryKey: StorageKey { typealias Value = InvitationDelivery }
    var invitationDelivery: InvitationDelivery {
        get { storage[InvitationDeliveryKey.self]! }
        set { storage[InvitationDeliveryKey.self] = newValue }
    }
}

final class InvitationDeliveryLifecycle: LifecycleHandler, @unchecked Sendable {
    private var timer: Task<Void, Never>?

    func didBootAsync(_ app: Application) async throws {
        timer = Task {
            while !Task.isCancelled {
                await app.invitationDelivery.wake(app)
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func shutdownAsync(_ app: Application) async {
        timer?.cancel()
        await timer?.value
        timer = nil
        await app.invitationDelivery.shutdown()
    }
}

private struct StopInvitationEmail: Content { let token: String }

func registerInvitationEmailStopRoutes(_ app: Application) {
    app.get("email", "invites", "stop") { request async throws -> Response in
        try await request.enforceRateLimit(.inviteLookup, scope: "stop-invitation-email")
        let token = try request.query.decode(StopInvitationEmail.self).token
        guard token.count == 43, token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
              try await InviteRow.query(on: request.db).filter(\.$mailStopHash == inviteTokenHash(token)).first() != nil else {
            throw Abort(.notFound, reason: "this invitation email link was not found")
        }
        // GET never changes a preference: mail scanners follow links.
        var headers = HTTPHeaders()
        headers.contentType = .html
        headers.add(name: "Cache-Control", value: "no-store")
        headers.add(name: "Referrer-Policy", value: "no-referrer")
        headers.add(name: "Content-Security-Policy", value: "default-src 'none'; form-action 'self'; frame-ancestors 'none'")
        return Response(status: .ok, headers: headers, body: .init(string: """
        <!doctype html><html lang="en"><meta charset="utf-8"><title>WellSpent invitation emails</title>
        <h1>Stop invitation emails</h1><p>Your invitations will still appear in WellSpent.</p>
        <form method="post"><input type="hidden" name="token" value="\(token)"><button>Stop invitation emails</button></form></html>
        """))
    }
    app.on(.POST, "email", "invites", "stop", body: .collect(maxSize: "4kb")) { request async throws -> String in
        try await request.enforceRateLimit(.inviteLookup, scope: "stop-invitation-email")
        let token = try request.content.decode(StopInvitationEmail.self).token
        guard let invite = try await InviteRow.query(on: request.db).filter(\.$mailStopHash == inviteTokenHash(token)).first(),
              let address = invite.inviteeEmail, let sql = request.db as? any SQLDatabase else {
            throw Abort(.notFound, reason: "this invitation email link was not found")
        }
        let hash = EmailInvitationRules.addressHash(address, key: app.emailCodeKey)
        try await sql.raw("INSERT INTO invite_email_suppressions (address_hash) VALUES (\(bind: hash)) ON CONFLICT DO NOTHING").run()
        return "Done. WellSpent will not email invitations to this address again. Your invitations still appear in the app."
    }
}
