import SwiftUI
import WellSpentCrypto

// MARK: - The toolbar buttons

/// Signed out it opens the account sheet. Signed in it signs out, which keeps the
/// budgets and the keys on this Mac and forgets only the session.
struct AccountButton: View {
    @Bindable var sync: SyncCoordinator
    @Binding var showingAccount: Bool

    var body: some View {
        Button {
            if sync.account != nil {
                Task { await sync.signOut() }
            } else {
                showingAccount = true
            }
        } label: {
            Label(Self.title(account: sync.account), systemImage: Self.icon(account: sync.account))
        }
        .disabled(sync.isBusy)
        .help(Self.help(account: sync.account))
    }

    static func title(account: String?) -> String {
        account == nil ? "Sign in" : "Sign out"
    }

    static func icon(account: String?) -> String {
        account == nil ? "person.crop.circle.badge.plus" : "rectangle.portrait.and.arrow.right"
    }

    static func help(account: String?) -> String {
        guard let account else { return "Sign in to sync this Mac with your other devices." }
        return "Signed in as \(account). Sign out keeps your budgets on this Mac."
    }
}

/// Syncs, and while it is working it says so. Shown only while signed in: signed
/// out, the account button beside it is the way in.
struct SyncButton: View {
    @Bindable var sync: SyncCoordinator
    @Binding var showingAccount: Bool

    var body: some View {
        Button {
            if sync.isSignedIn {
                Task { await sync.syncAll() }
            } else {
                showingAccount = true
            }
        } label: {
            Label {
                Text(title)
            } icon: {
                SpinningIcon(systemName: icon, spinning: Self.isSpinning(for: sync.state))
            }
        }
        .disabled(sync.isBusy)
        .help(help)
    }

    /// Spins while a sync runs, whoever started it, so a sync nobody clicked for
    /// is still visible.
    static func isSpinning(for state: SyncCoordinator.State) -> Bool {
        if case .busy = state { return true }
        return false
    }

    var title: String { Self.title(for: sync.state) }
    var icon: String { Self.icon(for: sync.state) }
    var help: String { Self.help(for: sync.state, lastSyncedAt: sync.lastSyncedAt) }

    static func title(for state: SyncCoordinator.State) -> String {
        switch state {
        case .signedOut: return "Sign in"
        case .busy(let what): return what
        case .signedIn: return "Sync"
        case .failed: return "Sync failed"
        }
    }

    static func icon(for state: SyncCoordinator.State) -> String {
        switch state {
        case .signedOut: return "person.crop.circle.badge.plus"
        case .busy, .signedIn: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.triangle"
        }
    }

    /// The tooltip carries the detail, because a toolbar button has no room for a
    /// sentence and a failure that says nothing is worse than no button at all.
    static func help(for state: SyncCoordinator.State, lastSyncedAt: Date?) -> String {
        switch state {
        case .signedOut: return "Sign in to sync this Mac with your other devices."
        case .busy(let what): return what
        case .failed(let why): return why
        case .signedIn(let email):
            guard let at = lastSyncedAt else { return "Signed in as \(email). Not synced yet." }
            return "Signed in as \(email). Last synced at "
                 + at.formatted(date: .omitted, time: .shortened) + "."
        }
    }
}

/// An SF Symbol that turns one full circle a second while `spinning`.
///
/// Driven by a clock rather than a repeating animation. A repeat-forever
/// animation keeps going after its condition turns false unless it is taken
/// apart carefully; a clock just stops, and the icon settles back upright.
struct SpinningIcon: View {
    let systemName: String
    let spinning: Bool

    var body: some View {
        TimelineView(.animation(paused: !spinning)) { context in
            Image(systemName: systemName)
                .rotationEffect(.degrees(spinning ? Self.angle(at: context.date) : 0))
        }
    }

    /// Clockwise, one turn a second.
    static func angle(at date: Date) -> Double {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360
    }
}

// MARK: - Signing in

struct AccountSheet: View {
    @Bindable var sync: SyncCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var creating = false

    /// A sign-in needs an address that parses, an email with an @ in it, and a
    /// password the server will not refuse. The server's floor is ten characters,
    /// and checking it here saves a round trip to be told so.
    static func canSubmit(email: String, password: String, server: String) -> Bool {
        guard email.contains("@"), !email.hasPrefix("@"), !email.hasSuffix("@") else { return false }
        guard password.count >= 10 else { return false }
        guard let url = URL(string: server.trimmingCharacters(in: .whitespaces)),
              url.scheme == "http" || url.scheme == "https", url.host != nil else { return false }
        return true
    }

    var canSubmit: Bool {
        Self.canSubmit(email: email, password: password, server: sync.serverAddress)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(creating ? "Create an account" : "Sign in")
                .font(.system(size: 17, weight: .semibold))

            Picker("", selection: $creating) {
                Text("Sign in").tag(false)
                Text("Create an account").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Form {
                TextField("Email", text: $email)
                SecureField("Password", text: $password)
                TextField("Server", text: Binding(get: { sync.serverAddress },
                                                  set: { sync.serverAddress = $0 }))
            }
            .formStyle(.grouped)

            if !creating && !sync.hasIdentity(for: email) {
                Label("""
                      This Mac has no key yet. Create the account here, or on the \
                      Mac that already has it: pairing a second device is not built.
                      """,
                      systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
            }

            if case .failed(let why) = sync.state {
                Label(why, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.warning)
            }

            HStack {
                Text("Your budgets are encrypted before they leave this Mac.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                Spacer()
                Button("Cancel") { dismiss() }
                Button(creating ? "Create" : "Sign in") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit || sync.isBusy)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    func submit() {
        let email = self.email, password = self.password, creating = self.creating
        Task {
            do {
                if creating {
                    try await sync.signUp(email: email, password: password)
                } else {
                    try await sync.signIn(email: email, password: password)
                }
                await sync.syncAll()
                dismiss()
            } catch {
                // `sync.state` already carries the reason, and the sheet shows it.
                // Staying open is the point: a closed sheet with an error behind it
                // is how people retype a password into nothing.
            }
        }
    }
}

// MARK: - The recovery code

/// Shown once, right after the account is made.
///
/// These twelve words are the only way back into the data if every device is
/// lost, and nothing on any server can substitute for them. That is what the
/// encryption buys and what it costs, so the screen says both.
struct RecoveryWordsSheet: View {
    @Bindable var sync: SyncCoordinator
    let enrolment: SyncCoordinator.Enrolment
    @Environment(\.dismiss) private var dismiss

    @State private var confirmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Write these twelve words down")
                .font(.system(size: 17, weight: .semibold))

            Text("""
                 They are the only way to get your budgets back if you lose every \
                 device. Nobody can reset them for you, including us: the server \
                 holds your data sealed and cannot open it.
                 """)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading),
                                     count: 3),
                      spacing: 8) {
                ForEach(Array(enrolment.recoveryWords.enumerated()), id: \.offset) { index, word in
                    HStack(spacing: 6) {
                        Text("\(index + 1)")
                            .font(.money(10, weight: .regular))
                            .foregroundStyle(Palette.muted)
                            .frame(width: 16, alignment: .trailing)
                        Text(word).font(.money(12))
                    }
                }
            }
            .padding(12)
            .background(Palette.ground, in: RoundedRectangle(cornerRadius: 8))

            Toggle("I have written them down somewhere safe", isOn: $confirmed)
                .font(.system(size: 12))

            HStack {
                Spacer()
                Button("Done") {
                    sync.recoveryWordsWereWrittenDown()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!confirmed)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
