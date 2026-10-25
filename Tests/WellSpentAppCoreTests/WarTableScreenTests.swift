import Foundation
import Testing
import WellSpentAppCore
import WellSpentStore
import WellSpentKeyStore
import WellSpentSync
import WarTableCore

private actor BoardFixture {
    var snapshot: WTSnapshot
    var messages: [WTMessage] = []
    var postedIDs: [UUID] = []
    var loseNextReply = false
    var delayNextRead = false
    var waiting = false
    var continuation: CheckedContinuation<Void, Never>?
    var delayHistory = false
    var historyWaiting = false
    var historyContinuation: CheckedContinuation<Void, Never>?
    var denyReads = false
    init(group: UUID, user: UUID) {
        let owner = WTPerson(id: user, displayName: "Owner", kind: .human, role: .owner)
        let room = WTConversation(id: UUID(), title: "Everyone", kind: .everyone, participantIDs: [], audienceIDs: [user])
        snapshot = WTSnapshot(installation: .init(id: UUID(), groupID: group, ownerID: user, isEnabled: true, revision: 1),
            me: owner, permissions: [.readChat, .sendMessage, .manageInstallation], people: [owner], agents: [],
            conversations: [room], contextSources: [], grants: [], tasks: [], runs: [], evidence: [], reviews: [], eventCursor: 0)
    }
    func loseReply() { loseNextReply = true }
    func delayRead() { delayNextRead = true }
    func release() { continuation?.resume(); continuation = nil }
    func delayHistoryRead() { delayHistory = true }
    func releaseHistory() { historyContinuation?.resume(); historyContinuation = nil }
    func refuseReads(_ value: Bool) { denyReads = value }
    func seedHistory(_ count: Int) {
        messages = (1...count).map { sequence in
            WTMessage(id: UUID(), conversationID: snapshot.conversations[0].id, sequence: sequence,
                senderID: snapshot.me.id, senderName: "Owner", text: "Message \(sequence)",
                createdAt: Date(timeIntervalSince1970: 1_800_000_000), clientMessageID: UUID())
        }
        snapshot.conversations[0].lastSequence = count
    }
    func redactFirst() { messages[0].isRedacted = true; messages[0].text = "Message redacted" }
    func request(_ request: ExtensionRequest) async throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        if request.method == .get && request.path.count == 2 {
            if denyReads { throw ReadableTransportError.http(status: 403, reason: "Access revoked") }
            let reply = try encoder.encode(snapshot)
            if delayNextRead {
                delayNextRead = false
                await withCheckedContinuation { continuation = $0; waiting = true }
            }
            return reply
        }
        if request.path.last == "messages", request.method == .get {
            let visible = messages.filter { $0.conversationID.uuidString == request.query["conversationID"] }
            let limit = Int(request.query["limit"] ?? "100") ?? 100
            let candidates: [WTMessage]
            let page: [WTMessage]
            if let value = request.query["after"], let after = Int(value) {
                candidates = visible.filter { $0.sequence > after }; page = Array(candidates.prefix(limit))
            } else {
                let before = Int(request.query["before"] ?? "") ?? Int.max
                candidates = visible.filter { $0.sequence < before }; page = Array(candidates.suffix(limit))
            }
            if delayHistory { delayHistory = false; await withCheckedContinuation { historyContinuation = $0; historyWaiting = true } }
            return try encoder.encode(WTMessagePage(messages: page, nextCursor: page.last?.sequence ?? 0, hasMore: candidates.count > limit))
        }
        if request.path.last == "conversations", request.method == .post {
            let body = try JSONDecoder().decode(WTCreateConversation.self, from: request.body!)
            let room = WTConversation(id: UUID(), title: body.title, kind: .direct,
                participantIDs: body.participantIDs, audienceIDs: body.participantIDs + [snapshot.me.id])
            snapshot.conversations.append(room)
            return try encoder.encode(room)
        }
        if request.path.last == "receipts" {
            let body = try JSONDecoder().decode(WTReadReceipt.self, from: request.body!)
            snapshot.conversations[0].readSequence = body.sequence
            return Data()
        }
        if request.path.last == "messages", request.method == .post {
            let input = try JSONDecoder().decode(WTPostMessage.self, from: request.body!)
            postedIDs.append(input.clientMessageID)
            let value: WTMessage
            if let existing = messages.first(where: { $0.clientMessageID == input.clientMessageID }) { value = existing }
            else {
                value = WTMessage(id: UUID(), conversationID: input.conversationID, sequence: messages.count + 1,
                    senderID: snapshot.me.id, senderName: snapshot.me.displayName, text: input.text,
                    createdAt: Date(timeIntervalSince1970: 1_800_000_000), clientMessageID: input.clientMessageID)
                messages.append(value)
            }
            if loseNextReply { loseNextReply = false; throw URLError(.networkConnectionLost) }
            return try encoder.encode(value)
        }
        throw ReadableTransportError.http(status: 404, reason: "Not found")
    }
}

@Suite("WarTable screen behavior", .serialized) @MainActor
struct WarTableScreenTests {
    private func setup(signedIn: Bool = true, draftStore: WarTableDraftStore? = nil) async throws -> (Workspace, WarTableScreen, BoardFixture) {
        let store = Store(database: try WellSpentDatabase.inMemory())
        let transport = StubReadableTransport()
        let sync = SyncCoordinator(store: store, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults(),
                                   makeTransport: { _ in transport })
        if signedIn { try await sync.signUp(email: "board@example.test", password: "long-test-password") }
        let model = AppModel(store: store)
        let group = try #require(model.addGroup(named: "Test group"))
        if signedIn { await sync.syncAll() }
        let workspace = Workspace(model: model, sync: sync)
        let fixture = BoardFixture(group: group.uuid, user: sync.userID?.uuid ?? UUID())
        let screen = WarTableScreen(workspace: workspace, client: WarTableClient { try await fixture.request($0) }, draftStore: draftStore)
        return (workspace, screen, fixture)
    }

    // WARTABLE-01
    @Test func signedOutBoardKeepsBudgetsAndExplainsSignIn() async throws {
        let (workspace, screen, _) = try await setup(signedIn: false)
        await screen.refresh()
        #expect(!screen.isSignedIn)
        #expect(screen.snapshot == nil)
        #expect(screen.status.contains("Sign in"))
        #expect(workspace.model.groups.count == 1)
        #expect(await screen.enable() == false)
    }

    // WARTABLE-02
    @Test func lostSendResponseKeepsDraftAndRetriesTheSameID() async throws {
        let (_, screen, fixture) = try await setup()
        await screen.refresh()
        #expect(screen.installation?.isEnabled == true)
        screen.draft = "First line\nSecond line"
        await fixture.loseReply()
        #expect(await screen.send() == false)
        #expect(screen.draft == "First line\nSecond line")
        #expect(screen.failure != nil)
        #expect(await screen.send())
        #expect(screen.draft.isEmpty)
        #expect(screen.messages.count == 1)
        #expect(screen.messages.first?.text == "First line\nSecond line")
        let ids = await fixture.postedIDs
        #expect(ids.count == 2 && ids[0] == ids[1])
        #expect(await fixture.messages.count == 1)
    }

    // WARTABLE-05
    @Test func signingOutImmediatelyClearsChatAndDraft() async throws {
        let (workspace, screen, _) = try await setup()
        await screen.refresh()
        screen.draft = "Do not carry this into another account"
        #expect(screen.snapshot != nil)
        await workspace.sync.signOut()
        #expect(screen.snapshot == nil)
        #expect(screen.messages.isEmpty && screen.draft.isEmpty)
        #expect(screen.enrollment == nil)
    }

    // WARTABLE-05
    @Test func oldRefreshCannotRestoreChatAfterSignOut() async throws {
        let (workspace, screen, fixture) = try await setup()
        await screen.refresh()
        await fixture.delayRead()
        let refresh = Task { await screen.refresh() }
        while !(await fixture.waiting) { await Task.yield() }
        await workspace.sync.signOut()
        await fixture.release()
        await refresh.value
        #expect(screen.snapshot == nil)
        #expect(screen.messages.isEmpty)
    }

    // WARTABLE-02
    @Test func olderHistorySurvivesPollingAndIncludesRedactions() async throws {
        let (_, screen, fixture) = try await setup()
        await fixture.seedHistory(150)
        await screen.refresh()
        #expect(screen.messages.count == 100 && screen.hasOlderMessages)
        #expect(await screen.loadOlderMessages())
        #expect(screen.messages.count == 150 && !screen.hasOlderMessages)
        await fixture.redactFirst()
        await screen.refresh()
        #expect(screen.messages.count == 150)
        #expect(screen.messages.first?.text == "Message redacted")
        #expect(screen.conversations[0].readSequence == 0)
        #expect(await screen.markRead())
        #expect(screen.conversations[0].readSequence == 150)
        await screen.latestMessages()
        #expect(screen.messages.count == 100)
        #expect(screen.messages.first?.sequence == 51)
    }

    @Test func openingDirectConversationDiscardsEarlierPollingReplyAndCursor() async throws {
        let (_, screen, fixture) = try await setup()
        await fixture.seedHistory(150); await screen.refresh()
        #expect(await screen.loadOlderMessages())
        let old = screen.selectedConversationID
        await fixture.delayRead()
        let polling = Task { await screen.refresh() }
        while !(await fixture.waiting) { await Task.yield() }
        #expect(await screen.createDirect(title: "Review", participantIDs: []))
        let direct = screen.selectedConversationID
        #expect(direct != old)
        await fixture.release(); await polling.value
        #expect(screen.selectedConversationID == direct)
        #expect(screen.messages.isEmpty)
        await screen.refresh()
        #expect(screen.selectedConversationID == direct && screen.messages.isEmpty)
    }

    @Test func latestMessagesWinsOverAnOlderPageAndDuplicateLoadsAreRefused() async throws {
        let (_, screen, fixture) = try await setup()
        await fixture.seedHistory(150); await screen.refresh()
        await fixture.delayHistoryRead()
        let older = Task { await screen.loadOlderMessages() }
        while !(await fixture.historyWaiting) { await Task.yield() }
        #expect(await screen.loadOlderMessages() == false)
        await screen.latestMessages()
        await fixture.releaseHistory()
        #expect(await older.value == false)
        #expect(screen.messages.count == 100 && screen.messages.first?.sequence == 51)
    }

    @Test func revokedAccessPurgesDraftAndRetryState() async throws {
        let (_, screen, fixture) = try await setup()
        await screen.refresh()
        screen.draft = "Private unfinished draft"
        screen.selectedReplyID = UUID(); screen.selectedSourceIDs = [UUID()]
        await fixture.refuseReads(true); await screen.refresh()
        #expect(screen.snapshot == nil && screen.messages.isEmpty)
        #expect(screen.draft.isEmpty && screen.selectedReplyID == nil && screen.selectedSourceIDs.isEmpty)
        await fixture.refuseReads(false); await screen.refresh()
        #expect(screen.draft.isEmpty && screen.selectedReplyID == nil && screen.selectedSourceIDs.isEmpty)
    }

    // WARTABLE-02 WARTABLE-05
    @Test func restartRestoresExactUncertainSendAndSignOutPurgesDisk() async throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WarTableDraftStore(directory: directory)
        let (workspace, first, fixture) = try await setup(draftStore: store)
        await first.refresh()
        first.draft = "Keep the exact retry across restart"
        let reply = UUID(), source = UUID()
        first.selectedReplyID = reply; first.selectedSourceIDs = [source]
        await fixture.loseReply()
        #expect(await first.send() == false)
        let second = WarTableScreen(workspace: workspace,
            client: WarTableClient { try await fixture.request($0) }, draftStore: WarTableDraftStore(directory: directory))
        await second.refresh()
        #expect(second.draft == first.draft)
        #expect(second.selectedReplyID == reply && second.selectedSourceIDs == [source])
        #expect(await second.send())
        let ids = await fixture.postedIDs
        #expect(ids.count == 2 && ids[0] == ids[1])
        #expect(store.load().isEmpty)
        second.draft = "Private unsent text"
        #expect(store.load().count == 1)
        await workspace.sync.signOut()
        #expect(store.load().isEmpty)
    }

    @Test func unsafeDraftStoragePreventsAnUnrecoverableSend() async throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = directory.appendingPathComponent("unsafe")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        let (_, screen, fixture) = try await setup(draftStore: WarTableDraftStore(directory: link))
        await screen.refresh(); screen.draft = "Keep this until it can be saved"
        #expect(await screen.send() == false)
        #expect(await fixture.postedIDs.isEmpty)
        #expect(screen.failure?.contains("could not be saved") == true)
    }
}
