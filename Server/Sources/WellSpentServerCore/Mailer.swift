import Foundation
import Vapor

/// What the server needs from an email service: one plain message to one person.
public protocol Mailer: Sendable {
    func send(to address: String, subject: String, text: String) async throws
}

/// Sends through Resend's HTTP API.
///
/// The API key should be a sending-only key: whoever can read Resend's sent mail
/// can read every reset code that passes through it.
struct ResendMailer: Mailer {
    let apiKey: String
    let from: String
    let client: any Client

    func send(to address: String, subject: String, text: String) async throws {
        struct Body: Content { let from: String; let to: [String]; let subject: String; let text: String }
        let response = try await client.post("https://api.resend.com/emails") { request in
            request.headers.bearerAuthorization = .init(token: apiKey)
            try request.content.encode(Body(from: from, to: [address], subject: subject, text: text))
        }
        guard (200 ..< 300).contains(response.status.code) else {
            // The reply body is left out: it can echo the address.
            throw Abort(.badGateway, reason: "the email service answered \(response.status.code)")
        }
    }
}

/// Writes each message, code included, to the log instead of sending it.
///
/// For development and for staging, which has no internet access and holds only
/// test accounts. Never live: a log is not somewhere a way into a real account
/// should sit, so `chooseMailer` refuses that.
struct LogMailer: Mailer {
    let logger: Logger

    func send(to address: String, subject: String, text: String) async throws {
        logger.notice("email to \(address): \(subject)\n\(text)")
    }
}

/// Which mailer a server uses, decided once at start.
///
/// A live server with no email service would run, but nobody could confirm an
/// address or reset a password, and nothing would say why. So it refuses to
/// start instead. Which server this is comes from `ServerEnvironment`, where a
/// production server with no `WELLSPENT_ENVIRONMENT` is live, so a missing
/// marker fails safe.
enum MailerChoice: Equatable {
    case resend(apiKey: String, from: String)
    case log

    static let defaultFrom = "WellSpent <no-reply@wellspent.space>"

    static func choose(server: ServerEnvironment, resendAPIKey: String?, from: String?) throws -> MailerChoice {
        if let key = resendAPIKey, !key.isEmpty {
            // Compose passes an unset variable as empty, so empty means unset.
            let sender = from.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            return .resend(apiKey: key, from: sender ?? defaultFrom)
        }
        if server != .live { return .log }
        throw Abort(.internalServerError, reason: """
            RESEND_API_KEY is not set. A live server must send email, or nobody can \
            confirm an address or reset a password. Staging sets WELLSPENT_ENVIRONMENT=staging.
            """)
    }
}

extension Application {
    private struct MailerKey: StorageKey {
        typealias Value = any Mailer
    }

    /// The mailer chosen in `configure`. Tests replace it with one that records.
    public var mailer: any Mailer {
        get {
            guard let mailer = storage[MailerKey.self] else {
                fatalError("configure() sets the mailer before any route runs")
            }
            return mailer
        }
        set { storage[MailerKey.self] = newValue }
    }

    func configureMailer() throws {
        // Set by `configure` before this runs. Unset, the strictest answer.
        switch try MailerChoice.choose(server: storage[ServerEnvironmentKey.self] ?? .live,
                                       resendAPIKey: Environment.get("RESEND_API_KEY"),
                                       from: Environment.get("MAIL_FROM")) {
        case .resend(let apiKey, let from):
            mailer = ResendMailer(apiKey: apiKey, from: from, client: client)
            logger.notice("mail: sent through Resend")
        case .log:
            mailer = LogMailer(logger: logger)
            logger.notice("mail: written to the log, codes included; never on live")
        }
    }

    /// Sends without making the request wait.
    ///
    /// Used where the time a request takes must not depend on whether an account
    /// exists: a forgot-password request for a real address would otherwise take
    /// as long as the email service, and one for an unknown address would not.
    /// A failure is logged without the address.
    func sendInBackground(to address: String, subject: String, text: String) {
        let mailer = self.mailer
        let logger = self.logger
        Task {
            do {
                try await mailer.send(to: address, subject: subject, text: text)
            } catch {
                logger.error("could not send an email: \(error)")
            }
        }
    }
}
