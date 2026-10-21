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
    /// The invitation page an opened invite link put up, on the right where
    /// a budget opens. Nil when no link is open. It stays through signing in,
    /// signing up and confirming the email, until the person joins, picks a
    /// budget or a group on the left, or opens another link (`MainScreen`).
    public private(set) var invitation: JoinScreen?
    /// What else runs once a sync's changes are in, or another account's
    /// budgets are: a screen holding something they can take away, such as
    /// a group's page (`MainScreen`).
    @ObservationIgnored var afterReload: [@MainActor () -> Void] = []
    /// The day of the month a staging UI test put the money wheel on
    /// (`pinnedDayVariable`), or nil, so the wheel reads the clock.
    public let pinnedDay: Int?

    /// `notifications` is where the system says the day changed: the
    /// process's own, unless a test hands in one of its own.
    public init(model: AppModel, sync: SyncCoordinator, autoSync: AutoSync? = nil, pinnedDay: Int? = nil,
                notifications: NotificationCenter = .default) {
        self.model = model
        self.sync = sync
        self.autoSync = autoSync ?? AutoSync(sync: sync)
        self.pinnedDay = pinnedDay
        // Whatever a sync brought in, including other people's transactions,
        // shows up without having to click anything.
        sync.didSync = { [weak self] in
            self?.model.reload()
            self?.afterReload.forEach { $0() }
        }
        // The new account's budgets keep the Undo bar's window, and open the
        // way this device's always do.
        sync.didSwitchStore = { [weak self] store in
            guard let self else { return }
            self.model = AppModel(store: store, undoWindow: self.model.undoWindow,
                                  opensFirstBudget: self.model.opensFirstBudget)
            self.afterReload.forEach { $0() }
        }
        watchForEdits()
        // A new day moves every wheel's day and tick, and on the 1st starts a
        // new period. A sync reads the budgets again, but signed out nothing
        // syncs, so a window left open overnight would show the new day over
        // yesterday's money. So the budgets are read again when the system
        // says the day changed: at midnight, or on waking after it. The Mac
        // and the iPhone say so. Linux does not, and a sync or an edit still
        // reads them there.
        _ = notifications.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.reload() }
        }
    }

    /// Every edit syncs a moment later, what this person may add or change
    /// comes from the server's levels, and today is the clock's or the pinned
    /// day. Set again whenever the model is replaced, because signing in to
    /// another account brings a new one.
    private func watchForEdits() {
        model.didChange = { [weak self] in self?.autoSync.localChange() }
        model.mayAddEntries = { [sync] group in sync.mayAddEntries(in: group) }
        // Changing anyone's entries takes Manage, the same level as budgets.
        model.mayManageEntries = { [sync] group in sync.mayManageBudgets(in: group) }
        model.me = { [sync] in sync.userID }
        model.thisDevice = { [sync] in sync.clientID }
        model.today = { [pinnedDay] in Workspace.today(pinnedTo: pinnedDay) }
    }

    // MARK: - The day the money wheel reads

    /// The environment variable a UI test sets to put the money wheel on one
    /// day of this month, whatever day the test runs, so the pace words it
    /// checks always show. A whole number from 1 to 31. A live build never
    /// reads it.
    nonisolated public static let pinnedDayVariable = "WELLSPENT_DAY_OF_MONTH"

    /// The day the variable pins, for a staging build. Nil for a live build,
    /// and for anything that is not a day of a month.
    public static func pinnedDay(for environment: AppEnvironment, in processEnvironment: [String: String]) -> Int? {
        guard environment == .staging, let text = processEnvironment[pinnedDayVariable],
              let day = Int(text), (1 ... 31).contains(day) else { return nil }
        return day
    }

    /// Today for the money wheel: `now`, or with a day pinned, that day of
    /// `now`'s month at noon. A day past the month's end is its last day.
    nonisolated public static func today(pinnedTo day: Int?, now: Date = Date(),
                                         calendar: Calendar = .autoupdatingCurrent) -> Date {
        guard let day, let days = calendar.range(of: .day, in: .month, for: now) else { return now }
        var parts = calendar.dateComponents([.era, .year, .month], from: now)
        parts.day = min(max(day, days.lowerBound), days.upperBound - 1)
        parts.hour = 12
        return calendar.date(from: parts) ?? now
    }

    // MARK: - Coming to the front

    /// The app came to the front, which happens at launch too. Signed in, it
    /// syncs, and the sync reads the budgets again when it is done. Signed
    /// out, nothing syncs, so the budgets are read again here: a day or a
    /// month may have begun while the app was away, and this does not wait
    /// for the system to say the day changed.
    public func cameToFront() async {
        if sync.account == nil { model.reload() }
        await autoSync.syncIfIdle()
    }

    // MARK: - Opened links

    /// Opens a link the system handed the app: a click on one of this
    /// build's invite links, whether it started the app or the app was
    /// running. The one way in for every desktop: each hands it the link it
    /// was given.
    /// The Mac does it from its app delegate. On Linux it is the link in the
    /// launch arguments, or one a second launch passed to the copy already
    /// running.
    ///
    /// It puts up the invitation page at once, in `invitation`, which
    /// `MainScreen.invitation` shows: who invited this person, to which
    /// group, a Your name field, and Join. Then it asks the server what the
    /// invite offers, and the page adds the level, what it lets them do, and
    /// how much of the group they would see. Signed out, or with the email
    /// not confirmed yet, the page says so in place of Join, with a way to
    /// do it (`JoinScreen.notice`). A link with part of it missing says so,
    /// plainly, and asks the server nothing (`JoinScreen.linkProblem`).
    /// Join goes through `MainScreen.joinInvitation()`.
    ///
    /// Call it in a Task: the page is up before the server answers. Safe
    /// with anything: a link that does not read as an invite never stops the
    /// app. Another link replaces the page that is up.
    public func open(_ url: URL) async {
        let page = JoinScreen(actions: sync, opened: url)
        invitation = page
        await page.lookUp()
    }

    /// The link a launch was given on its command line, for `open(_:)`. On
    /// Linux the desktop starts the app for a clicked link with the link as
    /// its argument. The last argument that reads as a link, with a type in
    /// front such as `wellspent-staging:`, counts, as the last of several
    /// does on the Mac. It need not be this build's, so the page can say
    /// which app a link is for. Nil when there is none: a plain start, or
    /// one given only an option or a file, opens no page.
    nonisolated public static func openedLink(in arguments: [String]) -> URL? {
        for argument in arguments.dropFirst().reversed() {
            let text = argument.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.hasPrefix("-"), let url = URL(string: text), let scheme = url.scheme,
                  !scheme.isEmpty else { continue }
            return url
        }
        return nil
    }

    /// Takes the invitation page down, when the person goes elsewhere or has
    /// joined. `MainScreen` decides when.
    func closeInvitation() {
        invitation = nil
    }

    /// The real app: every account's budgets in Application Support, keys in the
    /// keychain, and whoever was signed in last signed in again. All of it named
    /// for this build, live or staging, so the two never share anything.
    ///
    /// `processEnvironment` is the process's own unless a test hands one in. A
    /// staging build with `AccountDirectory.dataRootVariable` set keeps all of
    /// it under that folder instead; see `AccountDirectory.standard`.
    ///
    /// A phone passes false for `opensFirstBudget`. See `AppModel.opensFirstBudget`.
    public static func launch(processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
                              opensFirstBudget: Bool = true) throws -> Workspace {
        let environment = AppEnvironment.current
        if environment == .live, let bareRun = UserDefaults(suiteName: AppEnvironment.bareRunSuiteName) {
            AppEnvironment.carryOver(from: bareRun, into: environment.defaults)
        }
        let accounts = try AccountDirectory.standard(for: environment, processEnvironment: processEnvironment)
        // The directory's own settings, which are this build's unless a UI
        // test pointed it at a folder. The same thing for a normal launch.
        return try launch(accounts: accounts, defaults: accounts.defaults, environment: environment,
                          undoWindow: undoWindow(for: environment, in: processEnvironment),
                          pinnedDay: pinnedDay(for: environment, in: processEnvironment),
                          opensFirstBudget: opensFirstBudget)
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
    /// `pinnedDay` puts the money wheel on that day of this month.
    public static func launch(accounts: AccountDirectory, defaults: UserDefaults? = nil,
                       environment: AppEnvironment = .current,
                       makeTransport: (@Sendable (URL) -> any ReadableAccountTransport)? = nil,
                       undoWindow: Duration = AppModel.defaultUndoWindow,
                       pinnedDay: Int? = nil,
                       opensFirstBudget: Bool = true) throws -> Workspace {
        let defaults = defaults ?? environment.defaults
        let sync: SyncCoordinator
        if let makeTransport {
            sync = try SyncCoordinator(accounts: accounts, defaults: defaults,
                                       environment: environment, makeTransport: makeTransport)
        } else {
            sync = try SyncCoordinator(accounts: accounts, defaults: defaults, environment: environment)
        }
        let model = AppModel(store: sync.store, undoWindow: undoWindow, opensFirstBudget: opensFirstBudget)
        if sync.account == nil, model.groups.isEmpty, !accounts.samplesSeeded {
            try accounts.noteSamples(try model.seedFirstRun(), in: model.store)
        }
        // Set either way: an older install that already has budgets has had its
        // first run, and must not get samples after its data moves to an account.
        accounts.samplesSeeded = true
        return Workspace(model: model, sync: sync, pinnedDay: pinnedDay)
    }
}
