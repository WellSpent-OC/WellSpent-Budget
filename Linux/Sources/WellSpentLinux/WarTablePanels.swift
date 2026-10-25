import Foundation
import SwiftCrossUI
import WarTableCore
import WellSpentAppCore

struct WarTablePeopleView: View {
    let screen: WarTableScreen
    var open: (WarTableSheet) -> Void
    @State private var revoking: WTAgent?

    var body: some View {
        let agentToRevoke = revoking
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("People and agents").font(.system(size: 18, weight: .semibold))
                if let snapshot = screen.snapshot {
                    ForEach(snapshot.people.filter { $0.kind == .human }) { person in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(person.displayName).font(.system(size: 13, weight: .semibold))
                                Note(person.role?.rawValue.capitalized ?? "Member")
                            }
                            Spacer()
                            if snapshot.permissions.contains(.managePeople), person.role != .owner {
                                Button("Edit role…") { open(.person(person)) }
                            }
                        }
                    }
                    if snapshot.permissions.contains(.managePeople) {
                        Button("Add group member…") { open(.addPerson) }
                    }
                    if snapshot.me.role == .owner {
                        Button("Transfer ownership…") { open(.transferOwner) }
                            .disabled(snapshot.people.filter { $0.kind == .human && $0.id != snapshot.me.id }.isEmpty)
                    }
                    Divider()
                    if snapshot.agents.isEmpty {
                        Note("No agents connected. Enroll an agent, then connect its local tool using the one-time code.")
                    }
                    ForEach(snapshot.agents) { agent in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(agent.name) · \(WarTableWords.agentStatus(agent.status))")
                                .font(.system(size: 13, weight: .semibold))
                            Note("\(agent.provider) · \(agent.machine)")
                            Note(agent.executionProfile == "enforced-local" ? "Execution: Isolated local work" : "Execution: Chat only")
                            if let seen = agent.lastSeen {
                                Note("Last seen \(seen.formatted(date: .abbreviated, time: .shortened))")
                            }
                            if snapshot.permissions.contains(.manageAgents), agent.status != .revoked {
                                HStack {
                                    Button(agent.status == .paused ? "Resume \(agent.name)" : "Pause \(agent.name)") {
                                        Task { _ = await screen.controlAgent(agent.id, action: agent.status == .paused ? .resume : .pause) }
                                    }.disabled(screen.isBusy)
                                    Button("Revoke \(agent.name)…") { revoking = agent }.disabled(screen.isBusy)
                                }
                            }
                        }
                        Divider()
                    }
                if snapshot.permissions.contains(.enrollAgents) {
                        Button("Enroll agent…") { open(.enroll) }.disabled(screen.isBusy)
                    }
                    Note("Pausing chat stops board reads and sends. Stop a code task separately in Work.")
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("Revoke \(revoking?.name ?? "this agent")? It will need a new enrollment to reconnect. Active work receives a stop request.",
               isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } })) {
            Button("Keep access") { revoking = nil }
            Button("Revoke") { if let agentToRevoke { Task { _ = await screen.controlAgent(agentToRevoke.id, action: .revoke) } } }
        }
    }
}

struct WarTableContextView: View {
    let screen: WarTableScreen
    var open: (WarTableSheet) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Approved context").font(.system(size: 18, weight: .semibold))
                Note("Only the listed sources and paths are in scope. A reference does not prove that an agent can access it.")
                if let snapshot = screen.snapshot {
                    if snapshot.contextSources.isEmpty { Note("No context sources yet.") }
                    ForEach(snapshot.contextSources) { source in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(source.name).font(.system(size: 14, weight: .semibold))
                            Note("\(source.kind == .repository ? "Repository" : "Knowledge base") · \(source.isPublic ? "Public" : "Private") · \(source.status)")
                            Text(source.reference).font(.system(size: 12)).textSelectionEnabled()
                            Note("Allowed paths: " + source.allowedPaths.joined(separator: ", "))
                            Note("Audience: " + WarTableWords.names(source.audienceIDs, in: snapshot))
                            Note("Source policy revision \(source.revision)")
                            if snapshot.permissions.contains(.authorizeTask) {
                                Button("Edit source…") { open(.editSource(source)) }
                            }
                        }
                        Divider()
                    }
                    if snapshot.permissions.contains(.authorizeTask) {
                        HStack {
                            Button("Add context source…") { open(.source) }
                            Button("Grant source access…") { open(.grant) }
                                .disabled(snapshot.contextSources.isEmpty)
                        }
                    }
                    Text("Access grants").font(.system(size: 14, weight: .semibold))
                    if snapshot.grants.isEmpty { Note("No source access grants.") }
                    ForEach(snapshot.grants) { grant in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(WarTableWords.names([grant.subjectID], in: snapshot))
                            Note(snapshot.contextSources.first { $0.id == grant.sourceID }?.name ?? "Unavailable source")
                            Note(grant.capabilities.map(WarTableWords.capability).joined(separator: ", "))
                            Note(grant.isRevoked ? "Revoked" : "Expires \(grant.expiresAt.formatted(date: .abbreviated, time: .shortened))")
                            if !grant.isRevoked, snapshot.permissions.contains(.authorizeTask) {
                                Button("Revoke grant") { Task { _ = await screen.revokeGrant(grant.id) } }
                                    .disabled(screen.isBusy)
                            }
                        }
                        Divider()
                    }
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct WarTableWorkView: View {
    let screen: WarTableScreen
    var open: (WarTableSheet) -> Void
    @State private var stopping: WTTask?
    @State private var linkFailure: String?

    var body: some View {
        let taskToStop = stopping
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Work and reviews").font(.system(size: 18, weight: .semibold))
                    Spacer()
                    if screen.snapshot?.permissions.contains(.proposeTask) == true {
                        Button("Create task…") { open(.task) }
                            .disabled(screen.selectedConversationID == nil)
                    }
                }
                if let linkFailure { Note(linkFailure, warning: true) }
                if let snapshot = screen.snapshot {
                    if snapshot.tasks.isEmpty { Note("No tasks yet. A suggestion becomes work only with a scoped authorization.") }
                    ForEach(snapshot.tasks) { task in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(task.title).font(.system(size: 15, weight: .semibold))
                            Text(WarTableWords.taskState(task.state)).font(.system(size: 12, weight: .semibold))
                            Text(task.details).textSelectionEnabled()
                            Note("Source: " + (snapshot.contextSources.first { $0.id == task.sourceID }?.name ?? "Unavailable source"))
                            if let assignee = task.assigneeID { Note("Assigned to: " + WarTableWords.names([assignee], in: snapshot)) }
                            if let reviewer = task.reviewerID { Note("Reviewer: " + WarTableWords.names([reviewer], in: snapshot)) }
                            if !task.expectedChecks.isEmpty { Note("Expected checks: " + task.expectedChecks.joined(separator: ", ")) }
                            if let commit = task.headCommit { Text("Commit: \(commit)").font(.system(size: 11)).textSelectionEnabled() }
                            if let url = task.prURL {
                                Text(url).font(.system(size: 12)).textSelectionEnabled()
                                Button("Open PR in Chrome") { openLink(url) }
                                if snapshot.permissions.contains(.authorizeTask) || task.reviewerID == snapshot.me.id {
                                    Button("Check GitHub state") { Task { _ = await screen.checkProvider(task.id) } }
                                        .disabled(screen.isBusy)
                                }
                            }
                            HStack {
                                if snapshot.permissions.contains(.authorizeTask), task.state == .proposed || task.state == .blocked {
                                    Button("Authorize task…") { open(.authorize(task)) }
                                }
                                if task.headCommit != nil, task.state == .awaitingReview,
                                   task.assigneeID != snapshot.me.id,
                                   task.reviewerID == snapshot.me.id || snapshot.me.role == .owner {
                                    Button("Review…") { open(.review(task)) }
                                }
                                if snapshot.permissions.contains(.authorizeTask), ![.done, .cancelled].contains(task.state) {
                                    Button("Stop task…") { stopping = task }.frame(minWidth: 112).disabled(task.state == .stopping)
                                }
                            }.disabled(screen.isBusy)
                            if task.state == .stopping { Note("Stop requested; waiting for the worker to confirm.", warning: true) }
                            ForEach(snapshot.runs.filter { $0.taskID == task.id }) { run in
                                Note("Run: \(run.state) · Context \(run.contextReceipt.revision)")
                                Note("Rules \(run.contextReceipt.rulesRevision) · Handoff \(run.contextReceipt.handoffReference)")
                            }
                            ForEach(snapshot.evidence.filter { $0.taskID == task.id }) { evidence in
                                Text("\(evidence.kind): \(evidence.summary)").font(.system(size: 12)).textSelectionEnabled()
                            }
                            ForEach(snapshot.reviews.filter { $0.taskID == task.id }) { review in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(WarTableWords.reviewDecision(review.decision)) at \(review.headCommit)").font(.system(size: 12))
                                    Note(review.headCommit == task.headCommit ? "Current commit" : "Stale review: the commit changed")
                                    Note(review.providerConfirmed ? "Confirmed by repository provider" : "Recorded in WarTable; provider approval not confirmed")
                                    Text(review.summary).font(.system(size: 12)).textSelectionEnabled()
                                }
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.sidebar)
                    }
                    Note("Review, merge and deployment are separate actions. WarTable does not infer that a PR merged from a worker message.")
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("Stop \(stopping?.title ?? "this task")? New task actions stop immediately. A running worker must acknowledge cancellation.",
               isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } })) {
            Button("Keep running") { stopping = nil }
            Button("Stop task") { if let taskToStop { Task { _ = await screen.stopTask(taskToStop.id) } } }
        }
    }

    private func openLink(_ url: String) {
        linkFailure = WarTableBrowser.open(url) ? nil : "Google Chrome could not open this HTTPS link. You can copy the address above."
    }
}
