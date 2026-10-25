import Foundation
import SwiftCrossUI
import WarTableCore
import WellSpentAppCore

enum WarTablePanel: String, CaseIterable { case chat = "Chat", people = "People", context = "Context", work = "Work" }
enum WarTableSheet {
    case direct, enroll, source, grant, task, attachContext, addPerson, transferOwner, conversationList
    case person(WTPerson), authorize(WTTask), review(WTTask), redact(WTMessage), editSource(WTContextSource)
}

/// Native presentation only. The shared screen owns requests, permissions,
/// account changes, polling and drafts. No examples are injected into the UI.
struct WarTableView: View {
    let screen: WarTableScreen
    var openAccount: () -> Void
    @State private var panel: WarTablePanel = .chat
    @State private var sheet: WarTableSheet?
    @State private var displayName = ""
    @State private var latestRequest = 0
    @State private var showingConversations = true
    @State private var disabling = false
    @State private var recovering = false

    private var conversation: WTConversation? {
        screen.snapshot?.conversations.first { $0.id == screen.selectedConversationID }
    }
    private var groups: [Choice<UUID>] {
        screen.groups.map { Choice(value: $0.id, description: $0.name) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let failure = screen.failure {
                Note(failure, warning: true).padding(12)
            }
            if let notice = screen.notice {
                Note(notice).padding(.horizontal, 12).padding(.bottom, 8)
            }
            if let snapshot = screen.snapshot, snapshot.installation.isEnabled {
                GeometryReader { geometry in
                HStack(spacing: 0) {
                    if showingConversations && geometry.size.width >= 660 { conversations(snapshot) }
                    VStack(alignment: .leading, spacing: 0) {
                        navigation(snapshot, compact: geometry.size.width < 660)
                        switch panel {
                        case .chat: chat(snapshot)
                        case .people:
                            WarTablePeopleView(screen: screen, open: { sheet = $0 })
                        case .context:
                            WarTableContextView(screen: screen, open: { sheet = $0 })
                        case .work:
                            WarTableWorkView(screen: screen, open: { sheet = $0 })
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                }
            } else {
                setup
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundColor(Palette.ink)
        .background(Palette.surface)
        .onAppear { screen.start() }
        .onDisappear { screen.stop() }
        .onChange(of: screen.selectedGroupID) { closeSheet(); panel = .chat }
        .onChange(of: screen.snapshot?.me.id) { closeSheet(); displayName = "" }
        .sheet(isPresented: Binding(get: { sheet != nil }, set: { if !$0 { closeSheet() } })) {
            if let sheet { form(sheet).tabMovesFocus() }
        }
        .alert("Turn off WarTable for this group? Chat access stops. Budgets remain available.",
               isPresented: $disabling) {
            Button("Keep on") { disabling = false }
            Button("Turn off") { Task { _ = await screen.disable() } }
        }
        .alert("Recover ownership? This is available only if the previous owner is no longer eligible. WarTable stays disabled, existing grants are revoked and work is stopped.",
               isPresented: $recovering) {
            Button("Cancel") { recovering = false }
            Button("Recover ownership") { Task { _ = await screen.recoverOwnership() } }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("WarTable").font(.system(size: 22, weight: .semibold))
                Spacer()
                Button("Refresh") { Task { await screen.refresh() } }.disabled(screen.isBusy)
                if screen.snapshot?.installation.isEnabled == true && screen.canManage {
                    Button("Turn off…") { disabling = true }
                }
            }
            if !groups.isEmpty {
                HStack {
                    Text("Group").font(.system(size: 12))
                    Picker(of: groups, selection: Binding(
                        get: { groups.first { $0.value == screen.selectedGroupID } },
                        set: { if let id = $0?.value { Task { await screen.selectGroup(id) } } }))
                        .warTableControlLabel("WarTable group")
                        .disabled(screen.isBusy)
                    Spacer()
                }
            }
            Text(screen.status).font(.system(size: 12)).foregroundColor(Palette.muted)
        }
        .padding(16)
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("A place for your group and its agents")
                .font(.system(size: 18, weight: .semibold))
            Text("Share a conversation, connect your tools, and track authorized work.")
            Text("The owner and extension admins and managers can see every conversation. Code access is a separate, scoped choice.")
            if screen.selectedGroupID != nil {
                Field(label: "Your WarTable name", prompt: "The name your group will see", text: $displayName)
                Button("Turn on WarTable") {
                    Task { _ = await screen.enable(displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines)) }
                }
                .disabled(screen.isBusy || !screen.canEnable || displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if !screen.canEnable { Note("The group owner can enable WarTable.") }
                if screen.failure != nil && screen.canRequestRecovery {
                    Button("Recover ownership…") { recovering = true }
                }
            } else {
                Text("Sign in and choose a synced group to use WarTable.")
                Button("Open Account") { openAccount() }
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.sidebar)
    }

    private func conversations(_ snapshot: WTSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("CONVERSATIONS").font(.system(size: 10, weight: .semibold)).foregroundColor(Palette.muted)
                ForEach(snapshot.conversations) { item in
                    Button(item.title) {
                        panel = .chat
                        Task { await screen.selectConversation(item.id) }
                    }
                    .accessibility(value: item.lastSequence > item.readSequence ? "Unread messages" : nil,
                                   selected: item.id == screen.selectedConversationID)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if item.kind == .direct {
                        Text("Direct · \(item.audienceIDs.count) people")
                            .font(.system(size: 11)).foregroundColor(Palette.muted)
                    }
                }
                if snapshot.permissions.contains(.sendMessage) {
                    Button("New conversation…") { sheet = .direct }
                }
            }.padding(12)
        }
        .frame(width: 180).frame(maxHeight: .infinity)
        .background(Palette.sidebar)
    }

    private func navigation(_ snapshot: WTSnapshot, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button(!compact && showingConversations ? "Hide list" : "Conversations") {
                    if compact { sheet = .conversationList } else { showingConversations.toggle() }
                }
                ForEach(WarTablePanel.allCases, id: \.rawValue) { choice in
                    Button(choice.rawValue) { panel = choice }
                        .accessibility(selected: panel == choice)
                }
            }
            Text(snapshot.installation.oversightNotice).font(.system(size: 12))
            if !snapshot.agents.isEmpty {
                Text(snapshot.agents.map { "\($0.name): \(WarTableWords.agentStatus($0.status))" }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundColor(Palette.muted)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.sidebar)
    }

    @ViewBuilder
    private func chat(_ snapshot: WTSnapshot) -> some View {
        if let conversation {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(conversation.title).font(.system(size: 18, weight: .semibold))
                    Text("Visible to: " + WarTableWords.names(conversation.audienceIDs, in: snapshot))
                        .font(.system(size: 12)).textSelectionEnabled()
                    HStack {
                        Text("History").font(.system(size: 11)).foregroundColor(Palette.muted)
                        Spacer()
                        if screen.hasOlderMessages {
                            Button("Older messages") { Task { _ = await screen.loadOlderMessages() } }
                                .disabled(screen.isBusy)
                        }
                        Button("Latest messages") {
                            Task { await screen.latestMessages(); latestRequest += 1 }
                        }
                        if conversation.lastSequence > conversation.readSequence {
                            Button("Mark read") { Task { _ = await screen.markRead() } }
                        }
                        if snapshot.permissions.contains(.proposeTask) {
                            Button("Create task…") { sheet = .task }
                        }
                    }
                }.padding(12)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if screen.messages.isEmpty {
                            Note("No messages yet. Start the conversation.")
                        }
                        ForEach(screen.messages) { message in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(message.senderName) · \(message.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.system(size: 11, weight: .semibold)).foregroundColor(Palette.muted)
                                Text(message.isRedacted ? "Message redacted" : message.text)
                                    .textSelectionEnabled()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if let reply = message.replyTo {
                                    Note("Reply to " + (screen.messages.first { $0.id == reply }?.senderName ?? "an earlier message"))
                                }
                                if !message.sourceIDs.isEmpty {
                                    Note("Context: " + message.sourceIDs.map { id in snapshot.contextSources.first { $0.id == id }?.name ?? "Unavailable source" }.joined(separator: ", "))
                                }
                                HStack {
                                    if snapshot.permissions.contains(.sendMessage) && !message.isRedacted {
                                        Button("Reply") {
                                            screen.selectedReplyID = message.id
                                            screen.selectedSourceIDs = Array(Set(screen.selectedSourceIDs).union(message.sourceIDs))
                                        }
                                            .accessibility(label: "Reply to \(message.senderName)")
                                            .frame(minWidth: 75)
                                    }
                                    if snapshot.permissions.contains(.redact) && !message.isRedacted {
                                        Button("Redact…") { sheet = .redact(message) }
                                            .accessibility(label: "Redact message from \(message.senderName)")
                                    }
                                }
                            }
                        }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                .warTableTranscript(conversation: conversation.id.uuidString,
                                    firstMessage: screen.messages.first?.id.uuidString ?? "",
                                    lastMessage: screen.messages.last?.id.uuidString ?? "", latest: latestRequest)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    if let reply = screen.selectedReplyID {
                        HStack {
                            Note("Replying to " + (screen.messages.first { $0.id == reply }?.senderName ?? "an earlier message"))
                            Button("Cancel reply") { screen.selectedReplyID = nil }
                        }
                    }
                    if !screen.selectedSourceIDs.isEmpty {
                        Note("Attached context: " + screen.selectedSourceIDs.map { id in snapshot.contextSources.first { $0.id == id }?.name ?? "Unavailable source" }.joined(separator: ", "))
                    }
                    Text("Message").font(.system(size: 11, weight: .semibold)).foregroundColor(Palette.muted)
                    TextEditor(text: Binding(get: { screen.draft }, set: { screen.draft = $0 }))
                        .warTableComposer()
                        .frame(height: 80)
                        .padding(1).background(Palette.line)
                    HStack {
                        Note("Enter for a new line · Ctrl+Enter to send")
                        Spacer()
                        if !snapshot.contextSources.isEmpty {
                            Button("Context…") { sheet = .attachContext }
                        }
                        Button("Send") { Task { _ = await screen.send() } }
                            .warTableSendShortcut()
                            .disabled(screen.isBusy || !snapshot.permissions.contains(.sendMessage) ||
                                      screen.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.padding(12)
            }
        } else {
            Note("Choose a conversation.").padding(20)
            Spacer()
        }
    }

    private func closeSheet() { sheet = nil; screen.dismissEnrollment() }

    @ViewBuilder
    private func form(_ sheet: WarTableSheet) -> some View {
        switch sheet {
        case .direct: WarTableDirectForm(screen: screen, close: closeSheet)
        case .enroll: WarTableEnrollmentForm(screen: screen, close: closeSheet)
        case .source: WarTableSourceForm(screen: screen, close: closeSheet)
        case .editSource(let source): WarTableSourceForm(screen: screen, source: source, close: closeSheet)
        case .grant: WarTableGrantForm(screen: screen, close: closeSheet)
        case .task: WarTableTaskForm(screen: screen, close: closeSheet)
        case .person(let person): WarTablePersonForm(screen: screen, person: person, close: closeSheet)
        case .authorize(let task): WarTableAuthorizeForm(screen: screen, task: task, close: closeSheet)
        case .review(let task): WarTableReviewForm(screen: screen, task: task, close: closeSheet)
        case .redact(let message): WarTableRedactForm(screen: screen, message: message, close: closeSheet)
        case .attachContext: WarTableAttachContextForm(screen: screen, close: closeSheet)
        case .addPerson: WarTableAddPersonForm(screen: screen, close: closeSheet)
        case .transferOwner: WarTableTransferOwnerForm(screen: screen, close: closeSheet)
        case .conversationList:
            VStack(alignment: .leading, spacing: 14) {
                Text("Conversations").font(.system(size: 19, weight: .semibold))
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(screen.conversations) { conversation in
                            Button(conversation.title) {
                                Task { await screen.selectConversation(conversation.id); panel = .chat; closeSheet() }
                            }
                        }
                    }
                }.frame(maxHeight: 350)
                Button("New conversation…") { self.sheet = .direct }
                Button("Close") { closeSheet() }
            }.padding(20).frame(width: 420).background(Palette.surface)
        }
    }
}

enum WarTableWords {
    static func principals(_ snapshot: WTSnapshot) -> [WTPerson] {
        snapshot.people + snapshot.agents.filter { agent in
            agent.status != .revoked && !snapshot.people.contains { $0.id == agent.id }
        }.map { WTPerson(id: $0.id, displayName: $0.name, kind: .agent) }
    }
    static func names(_ ids: [UUID], in snapshot: WTSnapshot) -> String {
        ids.map { id in
            snapshot.people.first(where: { $0.id == id })?.displayName ??
            snapshot.agents.first(where: { $0.id == id })?.name ?? "Unavailable participant"
        }.joined(separator: ", ")
    }
    static func agentStatus(_ status: WTAgentStatus) -> String { status.rawValue.capitalized }
    static func taskState(_ state: WTTaskState) -> String {
        state == .awaitingReview ? "Awaiting review" : state.rawValue.capitalized
    }
    static func reviewDecision(_ decision: WTReviewDecision) -> String {
        switch decision {
        case .approve: "Approved"
        case .requestChanges: "Changes requested"
        case .comment: "Comment"
        }
    }
    static func paths(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
