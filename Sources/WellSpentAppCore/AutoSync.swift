import Foundation

/// Syncs without anyone pressing the button.
///
/// Three triggers. An edit on this Mac syncs a moment later, once the edits stop,
/// so typing out five transactions is one sync rather than five. The app coming
/// to the front syncs, which covers launch too. And while the app is open it syncs
/// on a timer, because other people's changes live only on the server and the
/// only way to see them is to ask.
///
/// Every one of these is quiet: a failure puts back the state it found instead of
/// showing an error. The Sync button is still there, and a click still says why.
@MainActor
public final class AutoSync {
    /// How long after the last edit to wait before syncing.
    public static let defaultQuietPeriod: Duration = .seconds(2)
    /// How often to check for other people's changes while the app is open.
    public static let defaultInterval: Duration = .seconds(120)

    private let sync: SyncCoordinator
    private let quietPeriod: Duration
    private let interval: Duration

    /// The sync waiting for edits to stop. Each edit replaces it. Internal so a
    /// test can wait for it instead of guessing how long to sleep.
    private(set) var pending: Task<Void, Never>?
    private var ticking: Task<Void, Never>?

    /// How many syncs this has started, for tests.
    private(set) var runs = 0

    public init(sync: SyncCoordinator,
                quietPeriod: Duration = AutoSync.defaultQuietPeriod,
                interval: Duration = AutoSync.defaultInterval) {
        self.sync = sync
        self.quietPeriod = quietPeriod
        self.interval = interval
    }

    /// Something on this Mac changed. Restarts the wait.
    public func localChange() {
        pending?.cancel()
        pending = Task { [weak self, quietPeriod] in
            try? await Task.sleep(for: quietPeriod)
            guard !Task.isCancelled else { return }
            await self?.syncAfterChange()
        }
    }

    /// A change must not be dropped because a sync was already running, since that
    /// sync may have started before the change was saved. So wait for it to finish.
    private func syncAfterChange() async {
        while sync.isBusy {
            try? await Task.sleep(for: quietPeriod)
            if Task.isCancelled { return }
        }
        await syncIfIdle()
    }

    /// For launch, the app coming to the front, and the timer. Does nothing when
    /// signed out or when a sync is already running.
    public func syncIfIdle() async {
        guard sync.account != nil, !sync.isBusy else { return }
        runs += 1
        await sync.syncAll(quietly: true)
    }

    /// Starts the timer. Calling it again restarts it.
    public func start() {
        ticking?.cancel()
        ticking = Task { [weak self, interval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.syncIfIdle()
            }
        }
    }

    public func stop() {
        ticking?.cancel()
        ticking = nil
        pending?.cancel()
        pending = nil
    }
}
