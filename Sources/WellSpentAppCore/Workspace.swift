import Foundation
import Observation
import WellSpentStore
import WellSpentSync

/// What the window shows: one account's budgets, or "This Mac"'s, and the sync
/// that goes with them. Signing in or out swaps the budgets underneath.
@MainActor
@Observable
public final class Workspace {
    public private(set) var model: AppModel {
        didSet { watchForEdits() }
    }
    public let sync: SyncCoordinator
    public let autoSync: AutoSync
    /// Which build this is. A staging window has an orange banner, and its Dock
    /// icon a badge.
    public var environment: AppEnvironment { sync.environment }

    public init(model: AppModel, sync: SyncCoordinator, autoSync: AutoSync? = nil) {
        self.model = model
        self.sync = sync
        self.autoSync = autoSync ?? AutoSync(sync: sync)
        // Whatever a sync brought in, including other people's transactions,
        // shows up without having to click anything.
        sync.didSync = { [weak self] in self?.model.reload() }
        // The new account's budgets keep the Undo bar's window.
        sync.didSwitchStore = { [weak self] store in
            guard let self else { return }
            self.model = AppModel(store: store, undoWindow: self.model.undoWindow)
        }
        watchForEdits()
    }

    /// Every edit syncs a moment later, and what this person may add or
    /// change comes from the server's levels. Set again whenever the model
    /// is replaced, because signing in to another account brings a new one.
    private func watchForEdits() {
        model.didChange = { [weak self] in self?.autoSync.localChange() }
        model.mayAddEntries = { [sync] group in sync.mayAddEntries(in: group) }
        // Changing anyone's entries takes Manage, the same level as budgets.
        model.mayManageEntries = { [sync] group in sync.mayManageBudgets(in: group) }
        model.me = { [sync] in sync.userID }
        model.thisDevice = { [sync] in sync.clientID }
    }

    /// The real app: every account's budgets in Application Support, keys in the
    /// keychain, and whoever was signed in last signed in again. All of it named
    /// for this build, live or staging, so the two never share anything.
    ///
    /// `processEnvironment` is the process's own unless a test hands one in. A
    /// staging build with `AccountDirectory.dataRootVariable` set keeps all of
    /// it under that folder instead; see `AccountDirectory.standard`.
    public static func launch(processEnvironment: [String: String] = ProcessInfo.processInfo.environment)
        throws -> Workspace {
        let environment = AppEnvironment.current
        if environment == .live, let bareRun = UserDefaults(suiteName: AppEnvironment.bareRunSuiteName) {
            AppEnvironment.carryOver(from: bareRun, into: environment.defaults)
        }
        let accounts = try AccountDirectory.standard(for: environment, processEnvironment: processEnvironment)
        // The directory's own settings, which are this build's unless a UI
        // test pointed it at a folder. The same thing for a normal launch.
        return try launch(accounts: accounts, defaults: accounts.defaults, environment: environment,
                          undoWindow: undoWindow(for: environment, in: processEnvironment))
    }

    /// The environment variable a UI test sets so the Undo bar after a
    /// delete stays longer than 10 seconds, in whole seconds. A slow test
    /// runner can then still reach its button. A live build never reads it.
    nonisolated public static let undoWindowVariable = "WELLSPENT_UNDO_SECONDS"

    /// How long the Undo bar stays: what the variable says, for a staging
    /// build, and 10 seconds otherwise.
    public static func undoWindow(for environment: AppEnvironment,
                                  in processEnvironment: [String: String]) -> Duration {
        guard environment == .staging, let text = processEnvironment[undoWindowVariable],
              let seconds = Int(text), seconds > 0 else { return AppModel.defaultUndoWindow }
        return .seconds(seconds)
    }

    /// With no `defaults`, the environment's own. Public for the Linux app,
    /// which hands in its own folder, settings and keyring, and then starts up
    /// exactly as the Mac app does.
    /// `undoWindow` is how long the Undo bar after a delete stays.
    public static func launch(accounts: AccountDirectory, defaults: UserDefaults? = nil,
                       environment: AppEnvironment = .current,
                       makeTransport: (@Sendable (URL) -> any ReadableAccountTransport)? = nil,
                       undoWindow: Duration = AppModel.defaultUndoWindow) throws -> Workspace {
        let defaults = defaults ?? environment.defaults
        let sync: SyncCoordinator
        if let makeTransport {
            sync = try SyncCoordinator(accounts: accounts, defaults: defaults,
                                       environment: environment, makeTransport: makeTransport)
        } else {
            sync = try SyncCoordinator(accounts: accounts, defaults: defaults, environment: environment)
        }
        let model = AppModel(store: sync.store, undoWindow: undoWindow)
        if sync.account == nil, model.groups.isEmpty, !accounts.samplesSeeded {
            try accounts.noteSamples(try model.seedFirstRun(), in: model.store)
        }
        // Set either way: an older install that already has budgets has had its
        // first run, and must not get samples after its data moves to an account.
        accounts.samplesSeeded = true
        return Workspace(model: model, sync: sync)
    }
}
