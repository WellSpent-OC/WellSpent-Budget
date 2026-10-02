import Foundation
import Observation
import WellSpentStore

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

    public init(model: AppModel, sync: SyncCoordinator, autoSync: AutoSync? = nil) {
        self.model = model
        self.sync = sync
        self.autoSync = autoSync ?? AutoSync(sync: sync)
        // Whatever a sync brought in, including other people's transactions,
        // shows up without having to click anything.
        sync.didSync = { [weak self] in self?.model.reload() }
        sync.didSwitchStore = { [weak self] store in self?.model = AppModel(store: store) }
        watchForEdits()
    }

    /// Every edit syncs a moment later. Set again whenever the model is replaced,
    /// because signing in to another account brings a new one.
    private func watchForEdits() {
        model.didChange = { [weak self] in self?.autoSync.localChange() }
    }

    /// The real app: every account's budgets in Application Support, keys in the
    /// keychain, and whoever was signed in last signed in again.
    public static func launch() throws -> Workspace {
        try launch(accounts: try AccountDirectory.standard())
    }

    static func launch(accounts: AccountDirectory, defaults: UserDefaults = .standard,
                       makeTransport: (@Sendable (URL) -> any AccountTransport)? = nil) throws -> Workspace {
        let sync: SyncCoordinator
        if let makeTransport {
            sync = try SyncCoordinator(accounts: accounts, defaults: defaults, makeTransport: makeTransport)
        } else {
            sync = try SyncCoordinator(accounts: accounts, defaults: defaults)
        }
        let model = AppModel(store: sync.store)
        if sync.account == nil, model.groups.isEmpty, !accounts.samplesSeeded {
            try model.seedFirstRun()
        }
        // Set either way: an older install that already has budgets has had its
        // first run, and must not get samples after its data moves to an account.
        accounts.samplesSeeded = true
        return Workspace(model: model, sync: sync)
    }
}
