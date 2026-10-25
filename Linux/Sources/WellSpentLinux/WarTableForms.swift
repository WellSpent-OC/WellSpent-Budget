import Foundation
import SwiftCrossUI
import WarTableCore
import WellSpentAppCore
import WellSpentLinuxNative

struct WarTableForm<Content: View>: View {
    let title: String
    let screen: WarTableScreen
    let close: () -> Void
    let submitTitle: String
    let canSubmit: Bool
    let submit: () -> Void
    let content: Content

    init(_ title: String, screen: WarTableScreen, close: @escaping () -> Void,
         submitTitle: String, canSubmit: Bool, submit: @escaping () -> Void,
         @ViewBuilder content: () -> Content) {
        self.title = title; self.screen = screen; self.close = close
        self.submitTitle = submitTitle; self.canSubmit = canSubmit; self.submit = submit
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 19, weight: .semibold))
            ScrollView { content }.frame(maxHeight: 430)
            if let failure = screen.failure { Note(failure, warning: true) }
            HStack {
                Spacer()
                Button("Cancel") { close() }
                Button(submitTitle) { submit() }.disabled(!canSubmit || screen.isBusy)
            }
        }
        .padding(20).frame(width: 560)
        .foregroundColor(Palette.ink).background(Palette.surface)
    }
}

struct WarTableIDPicker: View {
    let label: String
    let choices: [Choice<UUID>]
    @Binding var selected: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 12))
            Picker(of: choices, selection: Binding(
                get: { choices.first { $0.value == selected } },
                set: { selected = $0?.value }))
                .warTableControlLabel(label)
        }
    }
}

struct WarTableAudiencePicker: View {
    let snapshot: WTSnapshot
    @Binding var selected: Set<UUID>
    var excludingMe = false

    private var people: [WTPerson] {
        WarTableWords.principals(snapshot).filter { !excludingMe || $0.id != snapshot.me.id }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(people) { person in
                Toggle("\(person.displayName) · \(person.kind == .agent ? "Agent" : "Person")", isOn: Binding(
                    get: { selected.contains(person.id) },
                    set: { if $0 { selected.insert(person.id) } else { selected.remove(person.id) } }))
                    .toggleStyle(.checkbox)
                    .warTableControlLabel("\(person.displayName) · \(person.kind == .agent ? "Agent" : "Person")")
            }
        }
    }
}

struct WarTableDirectForm: View {
    let screen: WarTableScreen
    let close: () -> Void
    @State private var title = ""
    @State private var selected: Set<UUID> = []

    var body: some View {
        WarTableForm("New direct conversation", screen: screen, close: close, submitTitle: "Start conversation",
                     canSubmit: !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !selected.isEmpty,
                     submit: { Task { if await screen.createDirect(title: title, participantIDs: Array(selected)) { close() } } }) {
            VStack(alignment: .leading, spacing: 12) {
                Field(label: "Conversation name", prompt: "What is this conversation for?", text: $title)
                Text("Choose recipients")
                if let snapshot = screen.snapshot {
                    WarTableAudiencePicker(snapshot: snapshot, selected: $selected, excludingMe: true)
                    let overseers = snapshot.people.filter { [.owner, .admin, .manager].contains($0.role) }.map(\.id)
                    let audience = Set(overseers + [snapshot.me.id]).union(selected)
                    Text("Visible to: " + WarTableWords.names(Array(audience).sorted { $0.uuidString < $1.uuidString }, in: snapshot))
                        .font(.system(size: 12))
                }
                Note("The owner and current extension admins and managers are always included.")
            }
        }
    }
}

struct WarTableEnrollmentForm: View {
    let screen: WarTableScreen
    let close: () -> Void
    @State private var name = ""
    @State private var provider = ""
    @State private var machine = ""
    @State private var profile = "chat-only"
    private let profiles = [Choice(value: "chat-only", description: "Chat only"),
                            Choice(value: "enforced-local", description: "Isolated local work")]

    var body: some View {
        if let enrollment = screen.enrollment {
            VStack(alignment: .leading, spacing: 14) {
                Text("Connect \(enrollment.agent.name)").font(.system(size: 19, weight: .semibold))
                Note("Use this one-time code in the local WarTable adapter. It expires \(enrollment.expiresAt.formatted(date: .omitted, time: .shortened)).")
                Text(enrollment.code).font(.system(size: 16, weight: .semibold)).textSelectionEnabled()
                Button("Copy enrollment code") { wellspent_clipboard_set_text(enrollment.code) }
                Note("Keep the code out of chat, screenshots and Git. The agent stays disconnected until its tool connects.")
                Button("Done") { close() }
            }.padding(20).frame(width: 560).background(Palette.surface)
        } else {
            WarTableForm("Enroll agent", screen: screen, close: close, submitTitle: "Create enrollment code",
                         canSubmit: !name.isEmpty && !provider.isEmpty && !machine.isEmpty,
                         submit: { Task { _ = await screen.enrollAgent(.init(name: name, provider: provider, machine: machine, executionProfile: profile)) } }) {
                VStack(alignment: .leading, spacing: 12) {
                    Field(label: "Agent name", prompt: "A name you will recognize", text: $name)
                    Field(label: "Agent tool", prompt: "The tool you are connecting", text: $provider)
                    Field(label: "Machine label", prompt: "A recognizable label, not a private path", text: $machine)
                    Picker(of: profiles, selection: Binding(get: { profiles.first { $0.value == profile } }, set: { if let value = $0?.value { profile = value } }))
                        .warTableControlLabel("Agent execution profile")
                    if profile == "enforced-local" {
                        Note("Local work requires the connector's configured sandbox and separate source grants. Choosing this profile does not start work or prove that the worker is ready.")
                    }
                    Note("Chat messages are readable by the server operator. A connected agent may send messages and approved context to its model provider. Review that provider's terms before sharing private material.")
                    Note("Enrollment connects chat. It does not grant budget access, repository writes or permission to run a task.")
                }
            }
        }
    }
}

struct WarTablePersonForm: View {
    let screen: WarTableScreen
    let person: WTPerson
    let close: () -> Void
    @State private var role: WTRole?

    init(screen: WarTableScreen, person: WTPerson, close: @escaping () -> Void) {
        self.screen = screen; self.person = person; self.close = close
        _role = State(wrappedValue: person.role)
    }
    private var choices: [Choice<WTRole>] {
        (screen.snapshot?.me.role == .owner ? [WTRole.member, .manager, .admin] : [.member, .manager])
            .map { Choice(value: $0, description: $0.rawValue.capitalized) }
    }
    var body: some View {
        WarTableForm("Role for \(person.displayName)", screen: screen, close: close, submitTitle: "Save role",
                     canSubmit: role != nil, submit: { Task {
                         if await screen.setRole(.init(userID: person.id, role: role, displayName: person.displayName)) { close() }
                     } }) {
            VStack(alignment: .leading, spacing: 12) {
                Picker(of: choices, selection: Binding(get: { choices.first { $0.value == role } }, set: { role = $0?.value }))
                    .warTableControlLabel("Extension role")
                Note("Admins and managers see every retained conversation, including earlier messages. Source access restrictions still apply.")
                Note("This changes WarTable oversight only. It does not grant repository access, review or merge rights.")
            }
        }
    }
}

struct WarTableAddPersonForm: View {
    let screen: WarTableScreen
    let close: () -> Void
    @State private var selected: UUID?
    @State private var name = ""
    var body: some View {
        WarTableForm("Add group member", screen: screen, close: close, submitTitle: "Add member",
                     canSubmit: selected != nil && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                     submit: { guard let selected else { return }; Task {
                         if await screen.setRole(.init(userID: selected, role: .member, displayName: name)) { close() }
                     } }) {
            VStack(alignment: .leading, spacing: 12) {
                WarTableIDPicker(label: "Group member", choices: screen.eligiblePeople.map { Choice(value: $0.id, description: $0.displayName) }, selected: $selected)
                Field(label: "WarTable name", prompt: "The name the group will see", text: $name)
                Note("Only verified current members of this WellSpent group can join. New people start as members; use Edit role to assign oversight afterward.")
                Button("Refresh group members") { Task { await screen.refreshPeople() } }
                if screen.eligiblePeople.isEmpty { Note("No other eligible group members. Invite people to the WellSpent group first.") }
            }
        }
        .onAppear { Task { await screen.refreshPeople() } }
        .onChange(of: selected) { name = screen.eligiblePeople.first { $0.id == selected }?.displayName ?? "" }
    }
}

struct WarTableTransferOwnerForm: View {
    let screen: WarTableScreen
    let close: () -> Void
    @State private var selected: UUID?
    @State private var confirming = false
    var body: some View {
        let recipient = selected
        WarTableForm("Transfer WarTable ownership", screen: screen, close: close, submitTitle: "Review transfer…",
                     canSubmit: recipient != nil, submit: { confirming = true }) {
            VStack(alignment: .leading, spacing: 12) {
                WarTableIDPicker(label: "New owner", choices: (screen.snapshot?.people ?? []).filter {
                    $0.kind == .human && $0.id != screen.snapshot?.me.id
                }.map { Choice(value: $0.id, description: $0.displayName) }, selected: $selected)
                Note("The new owner can see all retained conversations and manage the installation. Existing work is stopped and must be authorized again. This transfers WarTable ownership only.")
            }
        }
        .alert("Transfer ownership? The new owner gains access to retained history. Existing work is stopped and needs new authorization.", isPresented: $confirming) {
            Button("Keep ownership") { confirming = false }
            Button("Transfer ownership") {
                if let recipient { Task { if await screen.transferOwnership(to: recipient) { close() } } }
            }
        }
    }
}

struct WarTableSourceForm: View {
    let screen: WarTableScreen
    let source: WTContextSource?
    let close: () -> Void
    @State private var name = ""
    @State private var kind = WTSourceKind.repository
    @State private var reference = ""
    @State private var paths = ""
    @State private var audience: Set<UUID> = []
    @State private var isPublic = false
    private let kinds = [Choice(value: WTSourceKind.repository, description: "Repository"),
                         Choice(value: WTSourceKind.kb, description: "Knowledge base")]

    init(screen: WarTableScreen, source: WTContextSource? = nil, close: @escaping () -> Void) {
        self.screen = screen; self.source = source; self.close = close
        _name = State(wrappedValue: source?.name ?? "")
        _kind = State(wrappedValue: source?.kind ?? .repository)
        _reference = State(wrappedValue: source?.reference ?? "")
        _paths = State(wrappedValue: source?.allowedPaths.joined(separator: "\n") ?? "")
        _audience = State(wrappedValue: Set(source?.audienceIDs ?? []))
        _isPublic = State(wrappedValue: source?.isPublic ?? false)
    }

    var body: some View {
        WarTableForm(source == nil ? "Add context source" : "Edit context source", screen: screen, close: close,
                     submitTitle: source == nil ? "Add source" : "Save source",
                     canSubmit: !name.isEmpty && !reference.isEmpty && !WarTableWords.paths(paths).isEmpty && !audience.isEmpty,
                     submit: { Task {
                         let request = WTCreateSource(name: name, kind: kind, reference: reference,
                             allowedPaths: WarTableWords.paths(paths), audienceIDs: Array(audience), isPublic: isPublic)
                         let saved: Bool
                         if let source { saved = await screen.updateSource(source.id, request: request) }
                         else { saved = await screen.createSource(request) }
                         if saved { close() }
                     } }) {
            VStack(alignment: .leading, spacing: 12) {
                Field(label: "Source name", prompt: "Project or knowledge source", text: $name)
                Picker(of: kinds, selection: Binding(get: { kinds.first { $0.value == kind } }, set: { if let value = $0?.value { kind = value } }))
                    .warTableControlLabel("Source type")
                Field(label: "Source reference", prompt: "Repository URL or logical KB reference", text: $reference)
                Text("Allowed relative paths, one per line").font(.system(size: 12))
                TextEditor(text: $paths).accessibility(label: "Allowed paths").frame(height: 70)
                Toggle("Public source", isOn: $isPublic).toggleStyle(.checkbox).warTableControlLabel("Public source")
                Text("Allowed audience")
                if let snapshot = screen.snapshot { WarTableAudiencePicker(snapshot: snapshot, selected: $audience) }
                Note("Do not enter credentials or machine paths. Local mappings stay in the connector. Access must be verified before work starts.")
                if source != nil { Note("Policy changes require fresh context and can stop existing work. Retained messages remain subject to their source audience.") }
            }
        }
        .onAppear { if let id = screen.snapshot?.me.id { audience.insert(id) } }
    }
}

struct WarTableGrantForm: View {
    let screen: WarTableScreen
    let close: () -> Void
    @State private var sourceID: UUID?
    @State private var subjectID: UUID?
    @State private var paths = ""
    @State private var hours = "1"
    @State private var capabilities: Set<WTCapability> = [.readContext]
    private let available: [WTCapability] = [.readContext, .editBranch, .runChecks, .openPR, .review, .writeHandoff]

    var body: some View {
        WarTableForm("Grant source access", screen: screen, close: close, submitTitle: "Grant access",
                     canSubmit: sourceID != nil && subjectID != nil && !WarTableWords.paths(paths).isEmpty &&
                         (Int(hours).map { (1 ... 24).contains($0) } ?? false), submit: save) {
            VStack(alignment: .leading, spacing: 12) {
                if let snapshot = screen.snapshot {
                    WarTableIDPicker(label: "Source", choices: snapshot.contextSources.map { Choice(value: $0.id, description: $0.name) }, selected: $sourceID)
                    WarTableIDPicker(label: "Person or agent", choices: WarTableWords.principals(snapshot).map { Choice(value: $0.id, description: $0.displayName) }, selected: $subjectID)
                }
                Text("Allowed relative paths, one per line").font(.system(size: 12))
                TextEditor(text: $paths).accessibility(label: "Grant paths").frame(height: 60)
                ForEach(available, id: \.rawValue) { capability in
                    Toggle(WarTableWords.capability(capability), isOn: Binding(
                        get: { capabilities.contains(capability) },
                        set: { if $0 { capabilities.insert(capability) } else { capabilities.remove(capability) } }))
                        .toggleStyle(.checkbox)
                        .warTableControlLabel(WarTableWords.capability(capability))
                }
                Field(label: "Expires in hours", prompt: "1 to 24", text: $hours)
                Note("A grant cannot exceed your own source authority. Execution also requires a connected worker that enforces these limits. This does not grant merge or deployment rights.")
            }
        }
        .onAppear {
            sourceID = sourceID ?? screen.contextSources.first?.id
            subjectID = subjectID ?? screen.snapshot?.people.first?.id
        }
        .onChange(of: sourceID) { paths = screen.contextSources.first { $0.id == sourceID }?.allowedPaths.joined(separator: "\n") ?? "" }
    }
    private func save() {
        guard let sourceID, let subjectID, let hours = Int(hours) else { return }
        Task {
            if await screen.createGrant(.init(subjectID: subjectID, sourceID: sourceID, capabilities: Array(capabilities),
                allowedPaths: WarTableWords.paths(paths), expiresAt: Date().addingTimeInterval(Double(hours) * 3600))) { close() }
        }
    }
}

struct WarTableTaskForm: View {
    let screen: WarTableScreen
    let close: () -> Void
    @State private var sourceID: UUID?
    @State private var title = ""
    @State private var details = ""
    @State private var checks = ""

    var body: some View {
        WarTableForm("Create task", screen: screen, close: close, submitTitle: "Propose task",
                     canSubmit: sourceID != nil && screen.selectedConversationID != nil && !title.isEmpty && !details.isEmpty,
                     submit: save) {
            VStack(alignment: .leading, spacing: 12) {
                Field(label: "Task title", prompt: "The result you want", text: $title)
                WarTableIDPicker(label: "Task source", choices: screen.contextSources.map { Choice(value: $0.id, description: $0.name) }, selected: $sourceID)
                Text("Desired result and boundaries").font(.system(size: 12))
                TextEditor(text: $details).accessibility(label: "Task details").frame(height: 90)
                Text("Expected checks, one per line").font(.system(size: 12))
                TextEditor(text: $checks).accessibility(label: "Expected checks").frame(height: 60)
                Note("A proposal does not run code. An authorizer assigns an agent, scoped grant and independent reviewer before work starts.")
                if screen.contextSources.isEmpty { Note("Add an approved context source in Context first.", warning: true) }
            }
        }.onAppear { sourceID = sourceID ?? screen.contextSources.first?.id }
    }
    private func save() {
        guard let conversation = screen.selectedConversationID, let sourceID else { return }
        Task {
            if await screen.createTask(.init(conversationID: conversation, sourceID: sourceID,
                                            title: title, details: details, expectedChecks: WarTableWords.paths(checks))) { close() }
        }
    }
}

struct WarTableAuthorizeForm: View {
    let screen: WarTableScreen
    let task: WTTask
    let close: () -> Void
    @State private var grantID: UUID?
    @State private var reviewerID: UUID?
    private var grants: [WTGrant] {
        screen.snapshot?.grants.filter { $0.sourceID == task.sourceID && !$0.isRevoked && $0.expiresAt > Date() } ?? []
    }
    var body: some View {
        WarTableForm("Authorize \(task.title)", screen: screen, close: close, submitTitle: "Authorize task",
                     canSubmit: grantID != nil && reviewerID != nil &&
                        grants.first(where: { $0.id == grantID })?.subjectID != reviewerID, submit: save) {
            VStack(alignment: .leading, spacing: 12) {
                if let snapshot = screen.snapshot {
                    WarTableIDPicker(label: "Worker grant", choices: grants.map { grant in
                        Choice(value: grant.id, description: WarTableWords.names([grant.subjectID], in: snapshot) + " · " + grant.capabilities.map(WarTableWords.capability).joined(separator: ", "))
                    }, selected: $grantID)
                    WarTableIDPicker(label: "Independent reviewer", choices: WarTableWords.principals(snapshot).filter {
                        $0.id != grants.first(where: { $0.id == grantID })?.subjectID
                    }.map { Choice(value: $0.id, description: $0.displayName) }, selected: $reviewerID)
                    if let grant = grants.first(where: { $0.id == grantID }) {
                        Note("Paths: " + grant.allowedPaths.joined(separator: ", "))
                        Note("Expires \(grant.expiresAt.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
                Note("The assigned worker must enforce this grant. A disconnected or unsupported worker does not count as running. Review and merge remain separate.")
                if grants.isEmpty { Note("Create a valid source grant in Context first.", warning: true) }
            }
        }.onAppear { grantID = grants.first?.id; reviewerID = screen.snapshot?.me.id }
    }
    private func save() {
        guard let grant = grants.first(where: { $0.id == grantID }), let reviewerID else { return }
        Task {
            if await screen.authorizeTask(task.id, request: .init(grantID: grant.id, assigneeID: grant.subjectID, reviewerID: reviewerID)) { close() }
        }
    }
}

struct WarTableReviewForm: View {
    let screen: WarTableScreen
    let task: WTTask
    let close: () -> Void
    @State private var baseCommit = ""
    @State private var summary = ""
    @State private var decision = WTReviewDecision.comment
    private let decisions = [Choice(value: WTReviewDecision.comment, description: "Comment"),
                             Choice(value: WTReviewDecision.requestChanges, description: "Request changes"),
                             Choice(value: WTReviewDecision.approve, description: "Approve this commit")]
    var body: some View {
        WarTableForm("Review \(task.title)", screen: screen, close: close, submitTitle: "Record review",
                     canSubmit: task.headCommit != nil && !baseCommit.isEmpty && !summary.isEmpty,
                     submit: save) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Head commit: \(task.headCommit ?? "Unavailable")").font(.system(size: 12)).textSelectionEnabled()
                Field(label: "Reviewed base commit", prompt: "Exact base revision", text: $baseCommit)
                Picker(of: decisions, selection: Binding(get: { decisions.first { $0.value == decision } }, set: { if let value = $0?.value { decision = value } }))
                    .warTableControlLabel("Review decision")
                Text("Findings and evidence").font(.system(size: 12))
                TextEditor(text: $summary).accessibility(label: "Review findings").frame(height: 110)
                Note("A WarTable review is advisory until confirmed by the repository provider. A changed commit invalidates this review. Recording a review does not merge or deploy.")
            }
        }
    }
    private func save() {
        guard let head = task.headCommit else { return }
        Task { if await screen.recordReview(task.id, request: .init(headCommit: head, baseCommit: baseCommit,
                                                                   decision: decision, summary: summary)) { close() } }
    }
}

struct WarTableRedactForm: View {
    let screen: WarTableScreen
    let message: WTMessage
    let close: () -> Void
    @State private var reason = ""
    var body: some View {
        WarTableForm("Redact message", screen: screen, close: close, submitTitle: "Redact message",
                     canSubmit: !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                     submit: { Task { if await screen.redactMessage(message.id, reason: reason) { close() } } }) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Message from \(message.senderName)")
                Field(label: "Reason", prompt: "Why this message needs redaction", text: $reason)
                Note("The message is replaced by a redaction marker. Copies already read by people or agents cannot be recalled.")
            }
        }
    }
}

struct WarTableAttachContextForm: View {
    let screen: WarTableScreen
    let close: () -> Void
    @State private var selected: Set<UUID> = []
    var body: some View {
        WarTableForm("Attach approved context", screen: screen, close: close, submitTitle: "Use selected context",
                     canSubmit: true, submit: { screen.selectedSourceIDs = Array(selected); close() }) {
            VStack(alignment: .leading, spacing: 12) {
                Note("Source policy applies to everyone in the conversation, including overseers. Attaching a reference grants no new file or code access.")
                if let snapshot = screen.snapshot {
                    ForEach(snapshot.contextSources) { source in
                        let audience = snapshot.conversations.first { $0.id == screen.selectedConversationID }?.audienceIDs ?? []
                        let permitted = Set(audience).isSubset(of: Set(source.audienceIDs))
                        Toggle(source.name, isOn: Binding(get: { selected.contains(source.id) }, set: {
                            if $0 { selected.insert(source.id) } else { selected.remove(source.id) }
                        })).toggleStyle(.checkbox).warTableControlLabel(source.name).disabled(!permitted)
                        if !permitted { Note("This source is not approved for the whole conversation.") }
                    }
                }
            }
        }.onAppear { selected = Set(screen.selectedSourceIDs) }
    }
}

extension WarTableWords {
    static func capability(_ value: WTCapability) -> String {
        switch value {
        case .readChat: "Read chat"
        case .sendMessage: "Send messages"
        case .manageInstallation: "Manage extension"
        case .managePeople: "Manage people"
        case .manageAgents: "Manage agents"
        case .enrollAgents: "Enroll agents"
        case .redact: "Redact messages"
        case .readContext: "Read context"
        case .proposeTask: "Propose tasks"
        case .authorizeTask: "Authorize tasks"
        case .editBranch: "Edit branch"
        case .runChecks: "Run checks"
        case .openPR: "Open or update PR"
        case .review: "Review"
        case .merge: "Merge"
        case .writeHandoff: "Write handoff"
        }
    }
}
