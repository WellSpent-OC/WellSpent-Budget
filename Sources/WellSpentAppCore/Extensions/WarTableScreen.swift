import Foundation
import Observation
import WarTableCore
import WellSpentCrypto
import WellSpentSync

public struct WarTableGroup: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public init(id: UUID, name: String) { self.id = id; self.name = name }
}

/// Session-scoped board state. The app's budgets do not depend on this object.
@MainActor @Observable
public final class WarTableScreen {
    public private(set) var snapshot: WTSnapshot?
    public private(set) var selectedGroupID: UUID?
    public private(set) var selectedConversationID: UUID?
    public private(set) var messages: [WTMessage] = []
    public var draft = "" { didSet { draftEdited() } }
    public var selectedReplyID: UUID? { didSet { draftEdited() } }
    public var selectedSourceIDs: [UUID] = [] { didSet { draftEdited() } }
    public private(set) var isBusy = false
    public private(set) var failure: String?
    public private(set) var notice: String?
    public private(set) var status = "Open a group to join its WarTable."
    public private(set) var enrollment: WTEnrollment?
    public private(set) var hasOlderMessages = false
    @ObservationIgnored private let workspace: Workspace
    @ObservationIgnored private let client: WarTableClient
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var generation: Int
    @ObservationIgnored private var selectionGeneration = 0
    @ObservationIgnored private var drafts: [UUID: WarTableSavedDraft] = [:]
    @ObservationIgnored private var pending: [UUID: WTPostMessage] = [:]
    @ObservationIgnored private let suppliedDraftStore: WarTableDraftStore?
    @ObservationIgnored private var draftStore: WarTableDraftStore?
    @ObservationIgnored private var draftsLoaded = false
    @ObservationIgnored private var restoringDraft = false
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var historyStart: Int?
    @ObservationIgnored private var loadingHistory = false

    public init(workspace: Workspace, client: WarTableClient? = nil, draftStore: WarTableDraftStore? = nil) {
        self.workspace = workspace
        self.suppliedDraftStore = draftStore
        self.generation = workspace.sync.extensionSessionGeneration
        self.client = client ?? WarTableClient { [sync = workspace.sync] request in
            try await sync.extensionRequest(request)
        }
        workspace.afterReload.append { [weak self] in self?.accountChanged() }
        workspace.sync.extensionSessionObservers.append { [weak self] in self?.accountChanged() }
    }

    public var groups: [WarTableGroup] {
        workspace.model.groups.map { .init(id: $0.id.uuid, name: $0.name) }
    }
    public var isSignedIn: Bool { workspace.sync.account != nil }
    public var installation: WTInstallation? { snapshot?.installation }
    public var conversations: [WTConversation] { snapshot?.conversations ?? [] }
    public var agents: [WTAgent] { snapshot?.agents ?? [] }
    public var contextSources: [WTContextSource] { snapshot?.contextSources ?? [] }
    public var tasks: [WTTask] { snapshot?.tasks ?? [] }
    public var eligiblePeople: [WTPerson] {
        guard let id = selectedGroupID else { return [] }
        let group = GroupID(id), names = workspace.sync.memberNames(in: GroupID(id))
        let existing = Set(snapshot?.people.map(\.id) ?? [])
        return workspace.sync.members(of: group).keys.filter { !existing.contains($0.uuid) }.map {
            WTPerson(id: $0.uuid, displayName: names[$0] ?? "Group member", kind: .human, role: .member)
        }.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
    public func refreshPeople() async {
        if let id = selectedGroupID { await workspace.sync.refresh(GroupID(id)) }
    }
    public var canManage: Bool { snapshot?.permissions.contains(.manageInstallation) == true }
    public var canRequestRecovery: Bool {
        guard snapshot == nil, let id = selectedGroupID, let user = workspace.sync.userID else { return false }
        return workspace.sync.founder(of: GroupID(id)) == user
    }
    public var canEnable: Bool {
        if snapshot != nil { return canManage }
        guard let id = selectedGroupID, let user = workspace.sync.userID else { return false }
        return workspace.sync.founder(of: GroupID(id)) == user
    }
    public var audienceLabel: String {
        guard let conversation = conversations.first(where: { $0.id == selectedConversationID }), let snapshot else {
            return "The owner, extension admins and managers can read every conversation."
        }
        let people = Dictionary(uniqueKeysWithValues: snapshot.people.map { ($0.id, $0.displayName) })
        let names = conversation.audienceIDs.map { people[$0] ?? "Participant" }
        return "Visible to: " + names.joined(separator: ", ")
    }

    public func start() {
        guard polling == nil else { return }
        accountChanged()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }
    public func stop() { rememberDraft(); _ = persistDrafts(); polling?.cancel(); polling = nil; enrollment = nil }
    public func dismissEnrollment() { enrollment = nil }

    private func accountChanged() {
        let current = workspace.sync.extensionSessionGeneration
        guard generation != current || !isSignedIn else { return }
        generation = current; selectionGeneration += 1
        try? draftStore?.clear()
        draftStore = nil; draftsLoaded = false
        restoringDraft = true; defer { restoringDraft = false }
        snapshot = nil; messages = []; draft = ""; drafts = [:]; pending = [:]
        selectedReplyID = nil; selectedSourceIDs = []
        enrollment = nil; selectedGroupID = nil; selectedConversationID = nil
        historyStart = nil
        failure = nil; notice = nil; hasOlderMessages = false
        status = isSignedIn ? "Choose a group." : "Sign in to use WarTable with a group."
    }
    private func current(_ selection: Int, _ session: Int) -> Bool {
        accountChanged()
        return selectionGeneration == selection && generation == session && isSignedIn
    }

    public func selectGroup(_ id: UUID) async {
        accountChanged()
        guard groups.contains(where: { $0.id == id }) else { return }
        rememberDraft()
        selectionGeneration += 1; selectedGroupID = id; selectedConversationID = nil
        snapshot = nil; messages = []; draft = ""; enrollment = nil; failure = nil; hasOlderMessages = false
        selectedReplyID = nil; selectedSourceIDs = []
        historyStart = nil
        await refresh()
    }
    public func selectConversation(_ id: UUID) async {
        guard conversations.contains(where: { $0.id == id }) else { return }
        rememberDraft()
        selectionGeneration += 1; selectedConversationID = id; messages = []; restoreDraft()
        failure = nil; hasOlderMessages = false
        historyStart = nil
        await refresh()
    }

    public func refresh() async {
        accountChanged()
        guard isSignedIn, !refreshing, !isBusy else { return }
        loadDraftsIfNeeded()
        if selectedGroupID == nil { selectedGroupID = groups.first?.id }
        guard let group = selectedGroupID else { status = "Create or join a group to use WarTable."; return }
        let selected = selectionGeneration, session = generation
        refreshing = true; defer { refreshing = false }
        do {
            let next = try await client.get(WTSnapshot.self, group: group)
            guard current(selected, session) else { return }
            snapshot = next
            let visible = Set(next.conversations.map(\.id))
            for id in drafts.filter({ $0.value.groupID == group && !visible.contains($0.key) }).map(\.key) {
                drafts[id] = nil; pending[id] = nil
            }
            if !next.conversations.contains(where: { $0.id == selectedConversationID }) {
                if let old = selectedConversationID { drafts[old] = nil; pending[old] = nil }
                selectedConversationID = next.conversations.first?.id
                historyStart = nil
                messages = []; restoreDraft()
            }
            _ = persistDrafts()
            if next.installation.isEnabled, let conversation = selectedConversationID {
                var query = ["conversationID": conversation.uuidString, "limit": "100"]
                if let historyStart { query["after"] = String(historyStart - 1) }
                var page = try await client.get(WTMessagePage.self, group: group, path: ["messages"], query: query)
                var refreshed = page.messages
                let older = historyStart != nil ? hasOlderMessages : page.hasMore
                while historyStart != nil && page.hasMore && refreshed.count < 1000 {
                    query["after"] = String(page.nextCursor)
                    page = try await client.get(WTMessagePage.self, group: group, path: ["messages"], query: query)
                    refreshed += page.messages
                    try Task.checkCancellation()
                }
                guard current(selected, session) else { return }
                // Refresh visible history so redactions are reflected. Older pages
                // are explicitly reloaded when requested, not a durable chat cache.
                messages = refreshed; hasOlderMessages = older
            } else { messages = [] }
            status = next.installation.isEnabled ? "Connected" : "WarTable is disabled for this group."
            failure = nil
        } catch is CancellationError { return }
        catch {
            guard current(selected, session) else { return }
            if case ReadableTransportError.http(let code, _) = error, code == 404 {
                snapshot = nil; messages = []; status = "WarTable has not been enabled for this group."
            } else {
                if isAccessError(error) { clearAccess() }
                failure = message(for: error); status = "Could not refresh. Your draft is kept on this device."
            }
        }
    }

    public func loadOlderMessages() async -> Bool {
        guard !loadingHistory else { return false }
        guard messages.count < 1000 else { notice = "Use Latest messages to return to the current conversation."; return false }
        guard let group = selectedGroupID, let conversation = selectedConversationID, let first = messages.first else { return false }
        let selection = selectionGeneration, session = generation
        loadingHistory = true; defer { loadingHistory = false }
        do {
            let page = try await client.get(WTMessagePage.self, group: group, path: ["messages"],
                query: ["conversationID": conversation.uuidString, "before": String(first.sequence), "limit": "100"])
            guard current(selection, session) else { return false }
            let existing = Set(messages.map(\.id))
            messages = page.messages.filter { !existing.contains($0.id) } + messages; hasOlderMessages = page.hasMore
            historyStart = messages.first?.sequence
            return true
        } catch { if current(selection, session) { failure = message(for: error) }; return false }
    }
    public func latestMessages() async {
        selectionGeneration += 1
        historyStart = nil; messages = []; hasOlderMessages = false
        await refresh()
    }
    /// Called by an explicit read action, never merely because polling saved
    /// messages in memory while the person was reading an earlier page.
    public func markRead() async -> Bool {
        guard let group = selectedGroupID, let conversation = selectedConversationID,
              let last = messages.last else { return false }
        let selection = selectionGeneration, session = generation
        do {
            try await client.acknowledge(group: group, conversation: conversation, sequence: last.sequence)
            guard current(selection, session) else { return false }
            await refresh(); return true
        } catch { if current(selection, session) { failure = message(for: error) }; return false }
    }

    public func enable(displayName: String = "Owner") async -> Bool {
        await mutate(WTSnapshot.self, method: .put, body: WTConfigureRequest(enabled: true, displayName: displayName)) { self.snapshot = $0 }
    }
    public func disable() async -> Bool {
        await mutate(WTSnapshot.self, method: .put, body: WTConfigureRequest(enabled: false)) {
            self.snapshot = $0; self.messages = []; self.enrollment = nil
        }
    }
    public func send() async -> Bool {
        guard !isBusy, let conversation = selectedConversationID, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let text = draft
        let request: WTPostMessage
        if let existing = pending[conversation], existing.text == text, existing.replyTo == selectedReplyID,
           Set(existing.sourceIDs) == Set(selectedSourceIDs) { request = existing }
        else {
            request = WTPostMessage(conversationID: conversation, clientMessageID: UUID(), text: text,
                                    replyTo: selectedReplyID, sourceIDs: selectedSourceIDs)
            pending[conversation] = request
        }
        rememberDraft()
        // Persist the exact idempotency key before the request can reach the
        // server, so a crash after commit but before its reply is safe to retry.
        guard persistDrafts() else { return false }
        return await mutate(WTMessage.self, path: ["messages"], body: request) { saved in
            if !self.messages.contains(where: { $0.id == saved.id }) { self.messages.append(saved) }
            if self.draft == text, self.selectedReplyID == request.replyTo,
               Set(self.selectedSourceIDs) == Set(request.sourceIDs) {
                self.restoringDraft = true
                self.draft = ""; self.drafts[conversation] = nil
                self.selectedReplyID = nil; self.selectedSourceIDs = []
                self.restoringDraft = false
            }
            self.pending[conversation] = nil; self.notice = "Saved"
            self.rememberDraft(); _ = self.persistDrafts()
        }
    }
    public func createDirect(title: String, participantIDs: [UUID]) async -> Bool {
        await mutate(WTConversation.self, path: ["conversations"], body: WTCreateConversation(title: title, participantIDs: participantIDs)) {
            self.rememberDraft()
            self.selectionGeneration += 1
            self.selectedConversationID = $0.id; self.messages = []; self.restoreDraft()
            self.historyStart = nil; self.hasOlderMessages = false
        }
    }
    public func enrollAgent(_ body: WTEnrollAgentRequest) async -> Bool {
        await mutate(WTEnrollment.self, path: ["agents", "enroll"], body: body) { self.enrollment = $0 }
    }
    public func controlAgent(_ id: UUID, action: WTAgentAction) async -> Bool {
        await mutate(WTAgent.self, path: ["agents", id.uuidString, "control"], body: WTAgentControl(action: action)) { _ in }
    }
    public func redactMessage(_ id: UUID, reason: String) async -> Bool {
        await mutate(WTMessage.self, path: ["messages", id.uuidString, "redact"], body: WTRedactRequest(reason: reason)) { _ in }
    }
    public func setRole(_ body: WTSetRoleRequest) async -> Bool {
        await mutate(WTSnapshot.self, path: ["roles"], body: body) { self.snapshot = $0 }
    }
    public func transferOwnership(to id: UUID) async -> Bool {
        await mutate(WTSnapshot.self, path: ["owner"], body: WTTransferOwner(userID: id)) { self.snapshot = $0 }
    }
    public func recoverOwnership() async -> Bool {
        guard let user = workspace.sync.userID else { return false }
        return await mutate(WTInstallation.self, path: ["recover-owner"], body: WTTransferOwner(userID: user.uuid)) { _ in
            self.notice = "Ownership recovered. Review access before enabling WarTable."
        }
    }
    public func createSource(_ body: WTCreateSource) async -> Bool {
        await mutate(WTContextSource.self, path: ["context-sources"], body: body) { _ in }
    }
    public func updateSource(_ id: UUID, request: WTCreateSource) async -> Bool {
        await mutate(WTContextSource.self, method: .put, path: ["context-sources", id.uuidString], body: request) { _ in }
    }
    public func createGrant(_ body: WTCreateGrant) async -> Bool {
        await mutate(WTGrant.self, path: ["grants"], body: body) { _ in }
    }
    public func revokeGrant(_ id: UUID) async -> Bool {
        await mutate(WTGrant.self, path: ["grants", id.uuidString, "revoke"], body: Empty()) { _ in }
    }
    public func createTask(_ body: WTCreateTask) async -> Bool {
        await mutate(WTTask.self, path: ["tasks"], body: body) { _ in }
    }
    public func authorizeTask(_ id: UUID, request: WTAuthorizeTask) async -> Bool {
        await mutate(WTTask.self, path: ["tasks", id.uuidString, "authorize"], body: request) { _ in }
    }
    public func stopTask(_ id: UUID) async -> Bool {
        await mutate(WTTask.self, path: ["tasks", id.uuidString, "stop"], body: Empty()) { _ in }
    }
    public func recordReview(_ id: UUID, request: WTRecordReview) async -> Bool {
        await mutate(WTReview.self, path: ["tasks", id.uuidString, "reviews"], body: request) { _ in }
    }
    public func checkProvider(_ id: UUID) async -> Bool {
        await mutate(WTProviderCheck.self, path: ["tasks", id.uuidString, "provider-check"], body: Empty()) { _ in
            self.notice = "Provider state checked. Review the current task and evidence."
        }
    }
    private struct Empty: Encodable, Sendable {}

    private func rememberDraft() {
        if let id = selectedConversationID, let group = selectedGroupID {
            if draft.isEmpty && selectedReplyID == nil && selectedSourceIDs.isEmpty && pending[id] == nil {
                drafts[id] = nil
            } else {
                drafts[id] = WarTableSavedDraft(groupID: group, text: draft, replyTo: selectedReplyID,
                                                sourceIDs: selectedSourceIDs, pending: pending[id])
            }
        }
    }
    private func restoreDraft() {
        restoringDraft = true; defer { restoringDraft = false }
        let saved = selectedConversationID.flatMap { drafts[$0] }
        draft = saved?.text ?? ""; selectedReplyID = saved?.replyTo; selectedSourceIDs = saved?.sourceIDs ?? []
    }
    private func draftEdited() {
        guard !restoringDraft, isSignedIn, selectedConversationID != nil else { return }
        loadDraftsIfNeeded(); rememberDraft(); _ = persistDrafts()
    }
    private func loadDraftsIfNeeded() {
        guard !draftsLoaded else { return }
        draftsLoaded = true
        draftStore = suppliedDraftStore ?? workspace.sync.warTableDraftDirectory.map(WarTableDraftStore.init)
        drafts = draftStore?.load() ?? [:]
        pending = drafts.compactMapValues(\.pending)
        if draftStore?.lastFailure != nil { failure = "Saved drafts could not be opened safely." }
    }
    @discardableResult private func persistDrafts() -> Bool {
        do { try draftStore?.save(drafts); return true }
        catch { failure = "Your draft could not be saved on this device. Sending is paused until it can be saved."; return false }
    }
    private func clearAccess() {
        let removed = drafts.filter { $0.value.groupID == selectedGroupID }.map(\.key)
        for id in removed { drafts[id] = nil; pending[id] = nil }
        if let id = selectedConversationID { drafts[id] = nil; pending[id] = nil }
        selectedConversationID = nil; snapshot = nil; messages = []; enrollment = nil
        draft = ""; selectedReplyID = nil; selectedSourceIDs = []; historyStart = nil
        _ = persistDrafts()
    }

    private func mutate<T: Decodable & Sendable, B: Encodable & Sendable>(_ type: T.Type,
            method: ExtensionRequest.Method = .post, path: [String] = [], body: B,
            apply: (T) -> Void) async -> Bool {
        accountChanged()
        guard isSignedIn, let group = selectedGroupID, !isBusy else { return false }
        // An earlier polling reply must not undo the result of this mutation.
        selectionGeneration += 1
        let selection = selectionGeneration, session = generation
        isBusy = true; failure = nil; notice = nil
        do {
            let result = try await client.send(type, group: group, method: method, path: path, body: body)
            guard current(selection, session) else { isBusy = false; return false }
            apply(result); isBusy = false
            await refresh()
            return true
        } catch {
            isBusy = false
            guard current(selection, session) else { return false }
            failure = message(for: error)
            if isAccessError(error) { clearAccess() }
            return false
        }
    }
    private func isAccessError(_ error: Error) -> Bool {
        if case ReadableTransportError.sessionEnded = error { return true }
        if case ReadableTransportError.http(let code, _) = error { return code == 401 || code == 403 }
        return false
    }
    private func message(for error: Error) -> String {
        if case ReadableTransportError.http(_, let reason) = error, !reason.isEmpty { return String(reason.prefix(500)) }
        if isAccessError(error) { return "Access has changed. Sign in again or ask the group owner." }
        if error is DecodingError { return "This server's WarTable response was not recognized. Check its version." }
        return "Could not reach WarTable. Check the connection and try again."
    }
}
