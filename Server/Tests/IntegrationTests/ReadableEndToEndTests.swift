import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Vapor
@testable import WellSpentServerCore
import WellSpentCrypto
import WellSpentModel
import WellSpentStore
import WellSpentSync

/// The app's readable client and engine against the real /api/v2 routes,
/// over real HTTP. The in-memory server the app's own tests use keeps the
/// same rules; this is where the two would disagree.
@Suite("End to end, readable sync over HTTP", .serialized)
struct ReadableEndToEndTests {
    /// Keeps the email the server would send, so a test can read its code.
    actor Mailbox: Mailer {
        private var sent: [(to: String, text: String)] = []

        func send(to address: String, subject: String, text: String) async throws {
            sent.append((address, text))
        }

        /// The newest code sent to `address`. Some mail goes after the reply,
        /// so this waits a little for it.
        func code(to address: String, after count: Int = 0) async throws -> String {
            for _ in 0 ..< 100 {
                let mine = sent.filter { $0.to == address }
                if mine.count > count, let text = mine.last?.text,
                   let match = text.firstMatch(of: try Regex("[A-Z0-9]{4}-[A-Z0-9]{4}")) {
                    return String(text[match.range])
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw Abort(.notFound, reason: "no code was sent to \(address)")
        }

        func count(to address: String) -> Int { sent.filter { $0.to == address }.count }
    }

    /// Boots the server on a real port, with mail kept in a mailbox.
    private func withServer(_ body: (URL, Mailbox) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        let mailbox = Mailbox()
        do {
            try await configure(app)
            app.mailer = mailbox
            app.http.server.configuration.hostname = "127.0.0.1"
            app.http.server.configuration.port = 0
            try await app.server.start()
            guard let port = app.http.server.shared.localAddress?.port else {
                Issue.record("server did not report a bound port")
                await app.server.shutdown()
                try await app.asyncShutdown()
                return
            }
            try await body(URL(string: "http://127.0.0.1:\(port)")!, mailbox)
            await app.server.shutdown()
        } catch {
            await app.server.shutdown()
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    /// One device: a database, an ID, the HTTP client and the engine.
    private struct Device {
        let store: Store
        let client: ReadableHTTPTransport
        let clientID = DeviceID()

        init(_ server: URL) throws {
            store = Store(database: try WellSpentDatabase.inMemory())
            client = ReadableHTTPTransport(baseURL: server)
        }

        func engine(_ user: UserID) -> ReadableSyncEngine {
            ReadableSyncEngine(store: store, transport: client, clientID: clientID, userID: user)
        }
    }

    /// Whole seconds, as the record codec sends dates.
    private let noon = Date(timeIntervalSince1970: 1_790_000_000)

    /// An account made on one device signs in on a second, finds the group
    /// with its import key, and both devices' edits go both ways.
    @Test func twoDevicesOfOneAccountShareEverything() async throws {
        try await withServer { server, _ in
            let laptop = try Device(server)
            #expect(try await laptop.client.health().environment == "development")
            let me = try await laptop.client.signUp(email: "robin@example.com", password: "a-long-password",
                                                    deviceLabel: "Laptop").userID
            let group = BudgetGroup(name: "Household", createdAt: noon, updatedAt: noon)
            let budget = Budget(groupID: group.id, name: "Food", limit: Money(minorUnits: 10_000), createdAt: noon,
                                updatedAt: noon)
            let key = Data(repeating: 7, count: 32)
            #expect(try await laptop.client.createGroup(id: group.id, importKey: key).importKey == key)
            #expect(try await laptop.client.createGroup(id: group.id, importKey: Data(repeating: 8, count: 32))
                        .importKey == key, "the key is set once")
            try laptop.store.save(group)
            try laptop.store.save(budget)
            let lunch = Transaction(budgetID: budget.id, groupID: group.id, date: noon, merchant: "Cafe",
                                    amount: Money(minorUnits: -1_250), createdAt: noon, updatedAt: noon)
            try laptop.store.save(lunch)
            let sent = try await laptop.engine(me).sync(group: group.id, level: .superadmin)
            #expect(sent.pushed == 3 && sent.rejected == 0)

            let desktop = try Device(server)
            _ = try await desktop.client.signIn(email: "robin@example.com", password: "a-long-password",
                                                deviceLabel: "Desktop")
            let listed = try await desktop.client.groups()
            #expect(listed.map(\.id) == [group.id] && listed.first?.importKey == key)
            try desktop.store.placeholderGroup(group.id, name: "")
            let taken = try await desktop.engine(me).sync(group: group.id, level: .superadmin)
            #expect(taken.applied == 3 && taken.conflicts == 0)
            #expect(try desktop.store.transaction(lunch.id)?.createdBy == me, "the server wrote the owner in")

            var edited = try #require(try desktop.store.transaction(lunch.id))
            edited.merchant = "Bakery"
            try desktop.store.save(edited)
            _ = try await desktop.engine(me).sync(group: group.id, level: .superadmin)
            _ = try await laptop.engine(me).sync(group: group.id, level: .superadmin)
            #expect(try laptop.store.transaction(lunch.id)?.merchant == "Bakery")
            #expect(Set(try await laptop.client.sessions().compactMap(\.deviceLabel)) == ["Laptop", "Desktop"])
        }
    }

    /// Records sent again are taken as no-ops: nothing new is stored.
    @Test func recordsSentAgainAreNoOps() async throws {
        try await withServer { server, _ in
            let laptop = try Device(server)
            let me = try await laptop.client.signUp(email: "robin@example.com", password: "a-long-password",
                                                    deviceLabel: nil).userID
            let group = BudgetGroup(name: "Household", createdAt: noon, updatedAt: noon)
            _ = try await laptop.client.createGroup(id: group.id, importKey: nil)
            try laptop.store.save(group, queue: false)
            try laptop.store.prepareResend(of: group.id, scope: .everything, me: me)
            let first = try await laptop.engine(me).sync(group: group.id, level: .superadmin)
            try laptop.store.prepareResend(of: group.id, scope: .everything, me: me)
            let again = try await laptop.engine(me).sync(group: group.id, level: .superadmin)
            #expect(first.pushed == 1 && again.pushed == 1 && again.rejected == 0)
            #expect(again.serverSeq == first.serverSeq, "the same version, stored once")
        }
    }

    /// A forgotten password, through the real routes: a confirmed address,
    /// a code by email, and every other device signed out.
    @Test func aResetSignsTheOtherDeviceOut() async throws {
        try await withServer { server, mailbox in
            let laptop = try Device(server)
            _ = try await laptop.client.signUp(email: "robin@example.com", password: "a-long-password",
                                               deviceLabel: nil)
            try await laptop.client.verifyEmail(code: try await mailbox.code(to: "robin@example.com"))
            #expect(try await laptop.client.me().emailVerified)

            let desktop = try Device(server)
            let before = await mailbox.count(to: "robin@example.com")
            try await desktop.client.forgotPassword(email: "Robin@Example.com")
            let code = try await mailbox.code(to: "robin@example.com", after: before)
            _ = try await desktop.client.resetPassword(email: "robin@example.com", code: code.lowercased(),
                                                       newPassword: "a-new-password", deviceLabel: nil)
            _ = try await desktop.client.me()
            await #expect(throws: ReadableTransportError.self) { _ = try await laptop.client.me() }
            do {
                _ = try await laptop.client.groups()
                Issue.record("the laptop's session should have ended")
            } catch ReadableTransportError.sessionEnded {
            }
        }
    }

    /// Changing the password tells a wrong current password from an ended
    /// session, over the real routes.
    @Test func aWrongCurrentPasswordIsNotAnEndedSession() async throws {
        try await withServer { server, _ in
            let laptop = try Device(server)
            _ = try await laptop.client.signUp(email: "robin@example.com", password: "a-long-password",
                                               deviceLabel: nil)
            await #expect(throws: ReadableTransportError.wrongCurrentPassword) {
                try await laptop.client.changePassword(current: "not it at all", new: "a-new-password")
            }
            try await laptop.client.changePassword(current: "a-long-password", new: "a-new-password")
            _ = try await laptop.client.me()
            await #expect(throws: ReadableTransportError.badCredentials) {
                _ = try await Device(server).client.signIn(email: "robin@example.com", password: "a-long-password",
                                                           deviceLabel: nil)
            }
        }
    }

    /// Sharing, through the real routes: an invite previewed without a
    /// session, accepted by a confirmed address, and a used one refused.
    @Test func anInviteIsPreviewedAcceptedAndThenUsedUp() async throws {
        try await withServer { server, mailbox in
            let robin = try Device(server)
            let robinID = try await robin.client.signUp(email: "robin@example.com", password: "a-long-password",
                                                        deviceLabel: nil).userID
            let group = BudgetGroup(name: "Household", createdAt: noon, updatedAt: noon)
            _ = try await robin.client.createGroup(id: group.id, importKey: nil)
            try robin.store.save(group)
            _ = try await robin.engine(robinID).sync(group: group.id, level: .superadmin)
            let invite = try await robin.client.createInvite(group: group.id, level: .write, history: .all, days: nil)
            let link = try #require(InviteLink(token: invite.token, groupName: group.name, inviterName: "Robin"))

            let leslie = try Device(server)
            _ = try await leslie.client.signUp(email: "leslie@example.com", password: "a-long-password",
                                               deviceLabel: nil)
            let terms = try await leslie.client.previewInvite(token: link.token)
            #expect(terms.groupID == group.id && terms.level == .write)
            try await leslie.client.verifyEmail(code: try await mailbox.code(to: "leslie@example.com"))
            let joined = try await leslie.client.acceptInvite(token: link.token)
            #expect(joined.id == group.id && joined.level == .write)

            await #expect(throws: ReadableTransportError.http(status: 404, reason: "no such invite")) {
                _ = try await leslie.client.previewInvite(token: link.token)
            }
            #expect(Set(try await robin.client.members(of: group.id).map(\.userID)).count == 2)
        }
    }
}
