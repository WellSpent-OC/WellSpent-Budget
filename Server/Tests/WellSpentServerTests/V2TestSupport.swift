import Testing
import Foundation
import Crypto
import Fluent
import Vapor
import VaporTesting
@testable import WellSpentServerCore

// Shared by the /api/v2 test files.

/// Keeps every message instead of sending it, so a test can read the code.
actor V2RecordingMailer: Mailer {
    struct Message: Sendable { let to: String; let subject: String; let text: String }
    private(set) var messages: [Message] = []

    func send(to address: String, subject: String, text: String) async throws {
        messages.append(Message(to: address, subject: subject, text: text))
    }

    /// Messages to one address. Some are sent after the request answers, so this
    /// waits a little for them.
    func waitFor(_ count: Int, to address: String) async -> [Message] {
        for _ in 0 ..< 100 {
            let found = messages.filter { $0.to == address }
            if found.count >= count { return found }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return messages.filter { $0.to == address }
    }

    func count(to address: String) -> Int { messages.filter { $0.to == address }.count }
}

func withV2App(_ body: (Application, V2RecordingMailer) async throws -> Void) async throws {
    let app = try await Application.make(.testing)
    let mailer = V2RecordingMailer()
    do {
        try await configure(app)
        app.mailer = mailer
        try await app.asyncBoot()
        try await body(app, mailer)
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}

/// Pulls the XXXX-XXXX code out of an email.
func v2Code(in message: V2RecordingMailer.Message?) throws -> String {
    let text = try #require(message?.text)
    let pattern = try Regex("[A-Z0-9]{4}-[A-Z0-9]{4}")
    return String(try #require(text.firstMatch(of: pattern)).output[0].substring!)
}

struct V2SignUp: Content { let email: String; let password: String; let deviceLabel: String? }
struct V2SignIn: Content { let email: String; let password: String; let deviceLabel: String? }
struct V2Session: Content { let userID: UUID; let token: String; let expiresAt: Date; let emailVerified: Bool }
struct V2Me: Content { let userID: UUID; let email: String; let emailVerified: Bool }
struct V2CodeBody: Content { let code: String }
struct V2Forgot: Content { let email: String }
struct V2Reset: Content { let email: String; let code: String; let newPassword: String; let deviceLabel: String? }
struct V2Change: Content { let currentPassword: String; let newPassword: String }
struct V2SessionInfo: Content { let id: UUID; let deviceLabel: String?; let lastUsedAt: Date; let current: Bool }

func v2Bearer(_ token: String) -> HTTPHeaders {
    var headers = HTTPHeaders()
    headers.bearerAuthorization = .init(token: token)
    return headers
}

let v2Password = "a-long-enough-password"

func v2SignUp(_ email: String, label: String? = "Mac", on app: Application) async throws -> V2Session {
    var session: V2Session?
    try await app.testing().test(.POST, "api/v2/signup", beforeRequest: { request in
        try request.content.encode(V2SignUp(email: email, password: v2Password, deviceLabel: label))
    }, afterResponse: { response async throws in
        #expect(response.status == .ok)
        session = try response.content.decode(V2Session.self)
    })
    return try #require(session)
}

func v2SignIn(_ email: String, _ password: String, label: String? = nil,
                    on app: Application) async throws -> (HTTPStatus, V2Session?) {
    var result: (HTTPStatus, V2Session?) = (.internalServerError, nil)
    try await app.testing().test(.POST, "api/v2/signin", beforeRequest: { request in
        try request.content.encode(V2SignIn(email: email, password: password, deviceLabel: label))
    }, afterResponse: { response async throws in
        result = (response.status, response.status == .ok ? try response.content.decode(V2Session.self) : nil)
    })
    return result
}

func v2Status(_ method: HTTPMethod, _ path: String, token: String? = nil,
                    body: (any Content)? = nil, on app: Application) async throws -> HTTPStatus {
    var status = HTTPStatus.internalServerError
    try await app.testing().test(method, path, headers: token.map(v2Bearer) ?? [:], beforeRequest: { request in
        if let body { try request.content.encode(body) }
    }, afterResponse: { response async throws in
        status = response.status
    })
    return status
}

func v2Me(_ token: String, on app: Application) async throws -> V2Me? {
    var me: V2Me?
    try await app.testing().test(.GET, "api/v2/me", headers: v2Bearer(token), afterResponse: { response async throws in
        if response.status == .ok { me = try response.content.decode(V2Me.self) }
    })
    return me
}

/// Signs up and confirms the address, as the app does on first run.
func v2VerifiedAccount(_ email: String, on app: Application, mailer: V2RecordingMailer) async throws -> V2Session {
    let session = try await v2SignUp(email, on: app)
    let sent = try v2Code(in: await mailer.waitFor(1, to: email).first)
    #expect(try await v2Status(.POST, "api/v2/email/verify", token: session.token, body: V2CodeBody(code: sent), on: app) == .noContent)
    return session
}


/// Signs up and marks the address confirmed, as if the code had been typed.
/// For tests about something else, such as joining a group.
func v2SignUpConfirmed(_ email: String, label: String? = "Mac", on app: Application) async throws -> V2Session {
    let session = try await v2SignUp(email, label: label, on: app)
    let user = try #require(try await UserRow.find(session.userID, on: app.db))
    user.emailVerifiedAt = Date()
    try await user.save(on: app.db)
    return session
}
