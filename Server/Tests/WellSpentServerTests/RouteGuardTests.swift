import Testing
import Foundation
import NIOCore
import Vapor
import VaporTesting
@testable import WellSpentServerCore

/// What every route of the readable API refuses, checked over the server's own
/// list of routes, so a route added later is held to it without anyone
/// remembering to add a test: no sign-in, a malformed ID in its path, and a
/// body that isn't JSON.
@Suite("Server, every route's guards", .serialized)
struct RouteGuardTests {
    /// The routes anyone may call without signing in. Every other route of
    /// /api/v2 must refuse a request that isn't signed in.
    static let open: Set<String> = [
        "POST /api/v2/signup",
        "POST /api/v2/signin",
        "POST /api/v2/password/forgot",
        "POST /api/v2/password/reset",
        "POST /api/v2/invites/preview",
    ]

    /// The routes that read a JSON body. Every POST and PATCH of /api/v2 is
    /// named here or in `bodyless`, so a new one has to be sorted.
    static let withBody: Set<String> = [
        "POST /api/v2/signup",
        "POST /api/v2/signin",
        "POST /api/v2/password/forgot",
        "POST /api/v2/password/reset",
        "POST /api/v2/password/change",
        "POST /api/v2/email/verify",
        "POST /api/v2/groups",
        "POST /api/v2/groups/:groupID/push",
        "POST /api/v2/groups/:groupID/invites",
        "PATCH /api/v2/groups/:groupID/members/:userID",
        "POST /api/v2/invites/preview",
        "POST /api/v2/invites/accept",
    ]

    /// POSTs that read no body.
    static let bodyless: Set<String> = [
        "POST /api/v2/signout",
        "POST /api/v2/signout/everywhere",
        "POST /api/v2/email/verify/resend",
    ]

    /// Every route of /api/v2 that isn't open refuses no sign-in, a token that
    /// was never a session's, and a session that has ended, all with 401.
    @Test func everySignedInRouteRefusesNoWrongOrEndedSignIn() async throws {
        try await withV2App { app, _ in
            let ended = try await v2SignUp("guards-ended@example.com", on: app)
            #expect(try await v2Status(.POST, "api/v2/signout", token: ended.token, on: app) == .noContent)

            let routes = Self.routes(of: app).filter { !Self.open.contains($0.name) }
            #expect(routes.count >= 19, "the server's list of routes was not read: \(routes.map(\.name))")
            var refusedWrongly: [String] = []
            for route in routes {
                for (token, kind) in [(nil, "no sign-in"), ("not-a-session", "a wrong token"),
                                      (ended.token, "an ended session")] as [(String?, String)] {
                    let status = try await Self.status(route.method, route.path(), token: token, on: app)
                    if status != .unauthorized { refusedWrongly.append("\(route.name), \(kind): \(status.code)") }
                }
            }
            #expect(refusedWrongly.isEmpty, "these answered something other than 401: \(refusedWrongly)")
        }
    }

    /// The open list names only routes that exist, so it can't hide a stale
    /// name, and every POST and PATCH is sorted into body or no body.
    @Test func theListsNameEveryRouteOnce() async throws {
        try await withV2App { app, _ in
            let names = Set(Self.routes(of: app).map(\.name))
            #expect(Self.open.subtracting(names).isEmpty, "open routes that don't exist: \(Self.open.subtracting(names))")
            #expect(Self.withBody.subtracting(names).isEmpty,
                    "body routes that don't exist: \(Self.withBody.subtracting(names))")
            #expect(Self.withBody.isDisjoint(with: Self.bodyless))
            let writes = names.filter { $0.hasPrefix("POST ") || $0.hasPrefix("PATCH ") }
            let unsorted = writes.subtracting(Self.withBody).subtracting(Self.bodyless)
            #expect(unsorted.isEmpty, "sort these into withBody or bodyless: \(unsorted)")
        }
    }

    /// An ID in a path that isn't a UUID is refused before anything is looked
    /// up, on every route that takes one, with 422, Vapor's answer for a path
    /// value that doesn't read as its type.
    @Test func aMalformedIDInAPathIsRefusedWith422() async throws {
        try await withV2App { app, _ in
            let person = try await v2SignUpConfirmed("guards-ids@example.com", on: app)
            var refusedWrongly: [String] = []
            for route in Self.routes(of: app) where !route.parameters.isEmpty {
                for parameter in route.parameters {
                    let path = route.path(malformed: parameter)
                    let status = try await Self.status(route.method, path, token: person.token,
                                                       body: route.method == .GET || route.method == .DELETE
                                                           ? nil : "{}", on: app)
                    if status != .unprocessableEntity {
                        refusedWrongly.append("\(route.name), \(parameter): \(status.code)")
                    }
                }
            }
            #expect(refusedWrongly.isEmpty, "these answered something other than 422: \(refusedWrongly)")
        }
    }

    /// A body that isn't JSON is refused with 400 on every route that reads
    /// one, signed in or not.
    @Test func aBodyThatIsNotJSONIsRefusedWith400() async throws {
        try await withV2App { app, _ in
            let person = try await v2SignUpConfirmed("guards-json@example.com", on: app)
            let group = UUID()
            #expect(try await v2Status(.POST, "api/v2/groups", token: person.token,
                                       body: ["id": group.uuidString], on: app) == .created)
            var refusedWrongly: [String] = []
            for route in Self.routes(of: app) where Self.withBody.contains(route.name) {
                let path = route.path(values: ["groupID": group.uuidString, "userID": person.userID.uuidString])
                let token = Self.open.contains(route.name) ? nil : person.token
                for body in ["{", "not json", "[1, 2"] {
                    let status = try await Self.status(route.method, path, token: token, body: body, on: app)
                    if status != .badRequest { refusedWrongly.append("\(route.name), \(body): \(status.code)") }
                }
            }
            #expect(refusedWrongly.isEmpty, "these answered something other than 400: \(refusedWrongly)")
        }
    }

    // MARK: - The server's own list

    struct Route {
        let method: HTTPMethod
        let components: [PathComponent]

        var name: String { "\(method.rawValue) /\(components.map(\.description).joined(separator: "/"))" }

        var parameters: [String] {
            components.compactMap { if case .parameter(let name) = $0 { name } else { nil } }
        }

        /// The path with each parameter filled: from `values`, or a fresh UUID.
        func path(values: [String: String] = [:], malformed: String? = nil) -> String {
            components.map { component in
                guard case .parameter(let name) = component else { return component.description }
                if name == malformed { return "not-a-uuid" }
                return values[name] ?? UUID().uuidString
            }.joined(separator: "/")
        }
    }

    static func routes(of app: Application) -> [Route] {
        app.routes.all
            .map { Route(method: $0.method, components: $0.path) }
            .filter { $0.components.count >= 2 && $0.components[0].description == "api"
                && $0.components[1].description == "v2" }
    }

    static func status(_ method: HTTPMethod, _ path: String, token: String?, body: String? = nil,
                       on app: Application) async throws -> HTTPStatus {
        var status = HTTPStatus.internalServerError
        try await app.testing().test(method, path, headers: token.map(v2Bearer) ?? [:], beforeRequest: { request in
            if let body {
                request.headers.contentType = .json
                request.body = ByteBuffer(string: body)
            }
        }, afterResponse: { response async throws in
            status = response.status
        })
        return status
    }
}
