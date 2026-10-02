import SwiftUI
import WellSpentCrypto
import WellSpentModel
import WellSpentSync

// MARK: - Words

/// The three things a person can be invited to do, in the words the screens use.
enum InviteRole: CaseIterable, Identifiable {
    case view, add, manage

    var id: Self { self }

    var level: AccessLevel {
        switch self {
        case .view: return .read
        case .add: return .write
        case .manage: return .manage
        }
    }

    var title: String {
        switch self {
        case .view: return "View"
        case .add: return "Add"
        case .manage: return "Manage"
        }
    }

    var explanation: String {
        switch self {
        case .view: return "Sees every budget and transaction. Changes nothing."
        case .add: return "Adds transactions, and edits or deletes their own."
        case .manage: return "Edits budgets and anyone's transactions, and invites other people."
        }
    }

    static func describing(_ level: AccessLevel) -> String {
        switch level {
        case .read: return "view this group"
        case .write: return "add transactions"
        default: return "manage this group"
        }
    }
}

// MARK: - Share

struct ShareSheet: View {
    @Bindable var sync: SyncCoordinator
    let group: BudgetGroup
    @Environment(\.dismiss) private var dismiss

    @State private var myName = ""
    @State private var role = InviteRole.add
    @State private var history = HistoryAccess.all
    @State private var working = false
    @State private var problem: String?
    @State private var link: InviteLink?

    /// `created` opens the sheet showing a link already made, for tests.
    init(sync: SyncCoordinator, group: BudgetGroup, created: InviteLink? = nil) {
        self.sync = sync
        self.group = group
        _link = State(initialValue: created)
    }

    static func canCreate(myName: String, signedIn: Bool) -> Bool {
        signedIn && !myName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Share \u{201C}\(group.name)\u{201D}")
                .font(.system(size: 17, weight: .semibold))

            if let link {
                created(link)
            } else {
                form
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { myName = (try? sync.displayName(in: group.id)) ?? "" }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            Form {
                TextField("Your name", text: $myName, prompt: Text("How the group will see you"))
                Picker("They can", selection: $role) {
                    ForEach(InviteRole.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("They see", selection: $history) {
                    Text("Everything so far").tag(HistoryAccess.all)
                    Text("Only from now on").tag(HistoryAccess.fromNow)
                }
            }
            .formStyle(.grouped)

            Text(role.explanation)
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)

            if !(sync.account != nil) {
                note("Sign in first. Sharing goes through your account.", warning: true)
            } else if let problem {
                note(problem, warning: true)
            }

            HStack {
                Text("You get a link to send by text or email.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(working ? "Creating…" : "Create Link") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || !Self.canCreate(myName: myName, signedIn: (sync.account != nil)))
            }
        }
    }

    private func created(_ link: InviteLink) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(link.url)
                .font(.money(11, weight: .regular))
                .textSelection(.enabled)
                .lineLimit(3)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 8))

            Text("""
                 Send this to the person you are inviting. It works once and expires in \
                 7 days. After they join, your Mac adds them the next time it syncs.
                 """)
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                ShareLink(item: link.url) { Label("Send…", systemImage: "square.and.arrow.up") }
                Button {
                    Clipboard.copy(link.url)
                } label: {
                    Label("Copy Link", systemImage: "doc.on.doc")
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func create() {
        working = true
        problem = nil
        Task {
            do {
                link = try await sync.share(group: group.id, groupName: group.name,
                                            level: role.level, historyAccess: history,
                                            myName: myName)
            } catch {
                problem = sync.failureMessage ?? "That did not work. Try again."
            }
            working = false
        }
    }
}

// MARK: - Join

struct JoinSheet: View {
    @Bindable var sync: SyncCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var linkText: String
    @State private var myName = ""
    @State private var working = false
    @State private var problem: String?

    /// `linkText` opens the sheet with a link already pasted, for tests.
    init(sync: SyncCoordinator, linkText: String = "") {
        self.sync = sync
        _linkText = State(initialValue: linkText)
    }

    private var link: InviteLink? { InviteLink(parsing: linkText) }

    static func canJoin(linkText: String, myName: String, signedIn: Bool) -> Bool {
        signedIn && InviteLink(parsing: linkText) != nil
            && !myName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Join a Group")
                .font(.system(size: 17, weight: .semibold))

            Form {
                TextField("Invite link", text: $linkText, prompt: Text("Paste the link you were sent"))
                    .font(.money(12, weight: .regular))
                TextField("Your name", text: $myName, prompt: Text("How the group will see you"))
            }
            .formStyle(.grouped)

            if let link {
                Text(invitation(link))
                    .font(.system(size: 13))
            } else if !linkText.trimmingCharacters(in: .whitespaces).isEmpty {
                note("That is not a WellSpent invite link.", warning: true)
            }

            if !(sync.account != nil) {
                note("Sign in first, or create an account. Joining adds the group to your account.",
                     warning: true)
            } else if let problem {
                note(problem, warning: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(working ? "Joining…" : "Join") { join() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || !Self.canJoin(linkText: linkText, myName: myName,
                                                       signedIn: (sync.account != nil)))
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func invitation(_ link: InviteLink) -> String {
        let who = link.inviterName.isEmpty ? "Someone" : link.inviterName
        let what = link.groupName.isEmpty ? "a group" : "\u{201C}\(link.groupName)\u{201D}"
        return "\(who) invited you to \(what)."
    }

    private func join() {
        guard let link else { return }
        working = true
        problem = nil
        Task {
            do {
                try await sync.join(link, myName: myName)
                dismiss()
            } catch {
                problem = sync.failureMessage ?? "That did not work. Try again."
            }
            working = false
        }
    }
}

// MARK: - Bits

@ViewBuilder
private func note(_ text: String, warning: Bool) -> some View {
    Label(text, systemImage: warning ? "exclamationmark.triangle" : "info.circle")
        .font(.system(size: 12))
        .foregroundStyle(warning ? Palette.warning : Palette.muted)
        .fixedSize(horizontal: false, vertical: true)
}

enum Clipboard {
    static func copy(_ text: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }
}

extension SyncCoordinator {
    /// The reason the last action failed, in words, if it did.
    var failureMessage: String? {
        if case .failed(let why) = state { return why }
        return nil
    }
}
