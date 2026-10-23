import Foundation
import Vapor
import Fluent
import WellSpentCrypto
import WellSpentModel

enum InvitationWeb {
    static func serverOrigin(_ environment: ServerEnvironment) -> String {
        environment == .live ? "https://sync.wellspent.space" : "https://staging.wellspent.space"
    }

    /// Defaults to the server which actually serves this page. A website can
    /// take over after its routing is installed, without changing invitations.
    static func baseURL(_ configured: String?, environment: ServerEnvironment) throws -> String {
        guard let configured, !configured.isEmpty else { return serverOrigin(environment) }
        guard let url = URLComponents(string: configured), url.scheme == "https",
              let host = url.host, ["wellspent.space", "sync.wellspent.space", "staging.wellspent.space"].contains(host),
              url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              !(environment == .live && host == "staging.wellspent.space"),
              !(environment != .live && host == "sync.wellspent.space") else {
            throw Abort(.internalServerError, reason: "INVITATION_PUBLIC_BASE_URL must be an HTTPS WellSpent origin for this environment")
        }
        return "https://\(host)"
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    static func response(_ body: String, status: HTTPStatus = .ok) -> Response {
        var headers = HTTPHeaders()
        headers.contentType = .html
        headers.add(name: "Cache-Control", value: "no-store")
        headers.add(name: "Referrer-Policy", value: "no-referrer")
        headers.add(name: "X-Content-Type-Options", value: "nosniff")
        headers.add(name: "Content-Security-Policy", value: "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'")
        return Response(status: status, headers: headers, body: .init(string: """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Your WellSpent invitation</title><style>body{max-width:36rem;margin:4rem auto;padding:0 1.5rem;background:#f5f1e8;color:#302b25;font:18px/1.5 system-ui}a{color:#5e4818}h1{line-height:1.2}.open{display:inline-block;padding:.7rem 1rem;background:#e5d2a5;border-radius:.4rem}</style></head>
        <body>\(body)</body></html>
        """))
    }
}

extension Application {
    private struct InvitationBaseURLKey: StorageKey { typealias Value = String }
    var invitationPublicBaseURL: String {
        get { storage[InvitationBaseURLKey.self]! }
        set { storage[InvitationBaseURLKey.self] = newValue }
    }
}

/// Vapor's default route and error loggers include URLs. A link token must
/// never appear there. Keep only a fixed route name and status for these pages.
struct InvitationPageLogging: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let path = (request.url.path.removingPercentEncoding ?? request.url.path).lowercased()
        guard path.hasPrefix("/invite/") || path == "/email/invites/stop" else {
            return try await next.respond(to: request)
        }
        let logger = request.logger
        request.logger = Logger(label: "invitation-page", factory: { _ in SwiftLogNoOpLogHandler() })
        let response = try await next.respond(to: request)
        logger.info("invitation page answered \(response.status.code)")
        return response
    }
}

func registerInvitationLanding(_ app: Application) {
    app.get("invite", ":token") { request async throws -> Response in
        try await request.enforceRateLimit(.inviteLookup, scope: "invitation-page")
        let token = try request.parameters.require("token")
        let environment = app.storage[ServerEnvironmentKey.self] ?? .live
        let expected = environment == .live ? "live" : "staging"
        if let named = request.query[String.self, at: "environment"], named != expected {
            return InvitationWeb.response("<h1>This invitation belongs to another WellSpent build.</h1><p>Open the original link from your invitation email.</p>", status: .badRequest)
        }
        guard token.count == 43, token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
              let invite = try await InviteRow.query(on: request.db).filter(\.$inviteHash == inviteTokenHash(token)).first(),
              invitationIsPending(invite), let group = try await GroupRow.find(invite.groupID, on: request.db), group.deletedAt == nil,
              let inviter = try await MembershipRow.query(on: request.db).filter(\.$groupID == invite.groupID)
                .filter(\.$userID == invite.inviterUserID).first(),
              let level = AccessLevel(rawValue: invite.level), let inviterLevel = AccessLevel(rawValue: inviter.level),
              MembershipRules.invite(at: level, holding: inviterLevel) == nil else {
            return InvitationWeb.response("<h1>This invitation is no longer available.</h1><p>Ask the person who invited you to send a new invitation.</p>", status: .gone)
        }
        let groupName = try await invitationGroupName(invite.groupID, on: request.db)
        let groupTitle = groupName.isEmpty ? "a group" : groupName
        let sender = invite.inviterName ?? "Someone"
        var parts = URLComponents()
        parts.queryItems = [URLQueryItem(name: "s", value: token), URLQueryItem(name: "g", value: groupTitle),
                            URLQueryItem(name: "f", value: sender)]
        let scheme = environment == .live ? "wellspent" : "wellspent-staging"
        let appLink = "\(scheme)://join#\(parts.percentEncodedQuery ?? "")"
        let levelName: String
        switch level {
        case .read: levelName = "View"
        case .write: levelName = "Add"
        case .manage: levelName = "Manage"
        default: levelName = "Admin"
        }
        let history = invite.historyAccess == HistoryAccess.fromNow.rawValue ? "changes from when you join" : "everything so far"
        let name = invite.inviteeName.map { " as \(InvitationWeb.escape($0))" } ?? ""
        return InvitationWeb.response("""
        <h1>\(InvitationWeb.escape(sender)) invited you to \(InvitationWeb.escape(groupTitle)).</h1>
        <p>You would join\(name) at \(levelName), and see \(history).</p>
        <p><a class="open" href="\(InvitationWeb.escape(appLink))">Open in WellSpent</a></p>
        <p>In the app, sign in or create an account with the address that received this invitation. Then accept or reject the invitation in your group list.</p>
        <p>Need the app? <a href="https://wellspent.space">Visit WellSpent</a>, then open this email link again. Your invitation also waits in the app after you sign in.</p>
        <p>This invitation expires on \(InvitationWeb.escape(invite.expiresAt.ISO8601Format())). Opening this page does not join the group or confirm an email address.</p>
        <p>WellSpent never asks for your password in an email or on a web page.</p>
        """)
    }
}
