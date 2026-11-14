import Foundation
import Observation
import WellSpentCrypto
import WellSpentStore
import WellSpentSync
import WellSpentPlans
#if canImport(WellSpentPropertiesViews)
import WellSpentPropertiesViews
#endif

/// What the window shows: one account's budgets, or "This Mac"'s, and the sync
/// that goes with them. Signing in or out swaps the budgets underneath.
@MainActor
@Observable
public final class Workspace {
    public private(set) var model: AppModel {
        didSet {
            // Its slots hold it, so the one signed out of lets them go.
            oldValue.install(nil)
            watchForEdits()
        }
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
    /// Told when a person adds a budget, whichever account's model is showing.
    @ObservationIgnored var afterBudgetAdded: [@MainActor (GroupID) -> Void] = []
    /// The day of the month a staging UI test put the money wheel on
    /// (`pinnedDayVariable`), or nil, so the wheel reads the clock.
    public let pinnedDay: Int?
    /// Which experimental or in-progress features are turned on.
    public let features: FeatureFlags
    /// Which extensions this person turned on, on this device, per account.
    public let extensionSwitches: ExtensionSwitches
    /// Buying, restoring and showing a plan. The Mac and iPhone hand in Apple's
    /// store; Linux has none and pays on the website.
    public let plans: PurchaseCoordinator
    /// Where today's date comes from: the system's clock, or in a staging
    /// test build, a file a UI test moves (`clockFileVariable`).
    public let clock: AppClock
    /// Whether a test moved the clock. Linux can then check for a new day
    /// every second rather than every 30, so a test need not wait.
    public var clockIsPinned: Bool { clock.isPinned }
    @ObservationIgnored private var lastCheckedDay: DateComponents
    /// The last day the test clock's watch said began (`watchTheTestClock`).
    @ObservationIgnored private var lastAnnouncedDay: DateComponents

    /// `notifications` is where the system says the day changed: the
    /// process's own, unless a test hands in one of its own.
    public init(model: AppModel, sync: SyncCoordinator, autoSync: AutoSync? = nil, pinnedDay: Int? = nil,
                features: FeatureFlags? = nil, planStore: (any PlanStore)? = nil,
                pinnedPlan: PinnedPlanService? = nil, clock: AppClock = .system, announcesDays: Bool = true,
                notifications: NotificationCenter = .default) {
        self.clock = clock
        let today = AppLocale.calendar.dateComponents([.era, .year, .month, .day], from: clock.now())
        self.lastCheckedDay = today
        self.lastAnnouncedDay = today
        self.model = model
        self.sync = sync
        self.plans = PurchaseCoordinator(store: planStore,
                                         service: pinnedPlan ?? sync,
                                         cache: DefaultsPlanCache(defaults: sync.defaults))
        self.autoSync = autoSync ?? AutoSync(sync: sync)
        self.pinnedDay = pinnedDay
        self.features = features ?? FeatureFlags.resolve(for: sync.environment, defaults: sync.defaults)
        self.extensionSwitches = ExtensionSwitches(defaults: sync.defaults, account: { [sync] in
            sync.userID.map { "\($0)" }
        })
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
            // Signing in asks for the new account's plan; signing out forgets the old one's.
            if self.sync.account == nil {
                self.plans.forget()
            } else {
                Task { await self.plans.refresh() }
            }
        }
        watchForEdits()
        // Paying, or a pick, opened what was locked: read it all again.
        plans.didOpen = { [weak self] in
            guard let self else { return }
            self.sync.readEverythingAgain()
            Task { await self.sync.syncAll(quietly: true) }
        }
        // Purchases Apple reports while the app runs, including one made
        // before the server could be reached, go to the server here.
        if plans.canBuyInApp {
            Task { [plans] in await plans.listen() }
        }
        // A new day moves every wheel's day and tick, and on the 1st starts a
        // new period. A sync reads the budgets again, but signed out nothing
        // syncs, so a window left open overnight would show the new day over
        // yesterday's money. So the budgets are read again when the system
        // says the day changed: at midnight, or on waking after it. The Mac
        // and the iPhone say so. Linux checks the clock through
        // checkForNewDay instead. The watch is only on Apple's systems: on Linux
        // it would never fire, and Linux's Foundation runs a main-queue
        // watcher by waiting on the main thread, which hangs when the post
        // comes from the main thread.
        #if !os(Linux)
        _ = notifications.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteNewDay() }
        }
        #if DEBUG
        if clock.isPinned, announcesDays { watchTheTestClock(notifications) }
        #endif
        #endif
    }

    #if DEBUG && !os(Linux)
    /// The system says a day began from its own clock, which a test can't
    /// move. So with the test clock set, this says it instead, in the same
    /// words and to the same watcher, once a second when the clock's day has
    /// changed. Only the clock's source is swapped. What the system does
    /// itself, saying so at midnight or on waking, no test here can show.
    /// `WELLSPENT_CLOCK_ANNOUNCES=0` turns it off, so a test can show what
    /// coming to the front does on its own (#209).
    private func watchTheTestClock(_ notifications: NotificationCenter) {
        Task { @MainActor [weak self, clock] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                let day = AppLocale.calendar.dateComponents([.era, .year, .month, .day], from: clock.now())
                guard day != self.lastAnnouncedDay else { continue }
                self.lastAnnouncedDay = day
                notifications.post(name: .NSCalendarDayChanged, object: nil)
            }
        }
    }
    #endif

    /// Every edit syncs a moment later, what this person may add or change
    /// comes from the server's levels, and today is the clock's or the pinned
    /// day. Set again whenever the model is replaced, because signing in to
    /// another account brings a new one.
    private func watchForEdits() {
        model.didChange = { [weak self] in self?.autoSync.localChange() }
        model.didAddBudget = { [weak self] group in self?.afterBudgetAdded.forEach { $0(group) } }
        model.mayAddEntries = { [sync] group in sync.mayAddEntries(in: group) }
        // Changing anyone's entries takes Manage, the same level as budgets.
        model.mayManageEntries = { [sync] group in sync.mayManageBudgets(in: group) }
        model.me = { [sync] in sync.userID }
        model.thisDevice = { [sync] in sync.clientID }
        model.today = { [pinnedDay, clock] in Workspace.today(pinnedTo: pinnedDay, now: clock.now()) }
        // The model first loaded before it had this day, so read again for a pinned one.
        if pinnedDay != nil { model.reload() }
        installExtensionSlots()
    }

    /// What extensions add to the app's own screens, following Properties'
    /// switch. Called on turning it on or off, and for each account's model.
    func installExtensionSlots() {
        if TestExtensionSlots.isOn() {
            let model = self.model
            model.install(TestExtensionSlots { [weak model] group in
                guard let model else { return }
                AppExtensionHost(model: model).newEntry(linkedTo: nil, in: group)
            })
            return
        }
        #if canImport(WellSpentPropertiesViews)
        let isOn = features.isPropertiesEnabled && extensionSwitches.isOn(PropertiesRegistration.id)
        model.install(isOn ? PropertiesSlots(host: AppExtensionHost(model: model)) : nil)
        #endif
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

    #if DEBUG
    /// The environment variable a UI test sets to a file holding one local
    /// date and time, such as `2026-12-14T09:00:00`. A staging test build then
    /// reads today from that file each time it asks, so a test moves the
    /// whole date, day, month and year, by writing it again, with no
    /// relaunch (`AppClock.file`). Test builds only: a release build is
    /// compiled without it, and the release check fails the build if this
    /// name is in the app.
    nonisolated public static let clockFileVariable = "WELLSPENT_CLOCK_FILE"

    /// Set to "0" with the clock file, so the app doesn't say a new day began
    /// when the file's day changes (`watchTheTestClock`). A test can then show
    /// what coming to the front does by itself. Test builds only, like the
    /// clock file.
    nonisolated public static let clockAnnouncesVariable = "WELLSPENT_CLOCK_ANNOUNCES"
    #endif

    /// The clock today comes from: the file the variable names, in a staging
    /// test build, and otherwise the system's.
    nonisolated public static func clock(for environment: AppEnvironment,
                                         in processEnvironment: [String: String]) -> AppClock {
        #if DEBUG
        guard environment == .staging, let path = processEnvironment[clockFileVariable], !path.isEmpty else {
            return .system
        }
        return .file(path)
        #else
        return .system
        #endif
    }

    /// Whether the test clock's watch says when its day changes. Always, but
    /// for a staging test build launched with the variable at "0".
    nonisolated public static func clockAnnouncesDays(for environment: AppEnvironment,
                                                      in processEnvironment: [String: String]) -> Bool {
        #if DEBUG
        return !(environment == .staging && processEnvironment[clockAnnouncesVariable] == "0")
        #else
        return true
        #endif
    }

    /// Today for the money wheel: `now`, or with a day pinned, that day of
    /// `now`'s month at noon. A day past the month's end is its last day.
    nonisolated public static func today(pinnedTo day: Int?, now: Date = Date(),
                                         calendar: Calendar = AppLocale.calendar) -> Date {
        guard let day, let days = calendar.range(of: .day, in: .month, for: now) else { return now }
        var parts = calendar.dateComponents([.era, .year, .month], from: now)
        parts.day = min(max(day, days.lowerBound), days.upperBound - 1)
        parts.hour = 12
        return calendar.date(from: parts) ?? now
    }

    // MARK: - The plan a UI test shows

    /// The environment variable a UI test sets to a JSON file holding a plan
    /// answer, in the server's shape. A staging build then shows that answer
    /// in place of the server's, so a test can put the app in any plan state:
    /// grace, billing problem, canceled, ended, refunded, or bought on the
    /// website. A live build never reads it.
    nonisolated public static let pinnedPlanVariable = "WELLSPENT_PLAN_ANSWER_FILE"

    /// A service reading the file the variable names, for a staging build.
    /// Nil for a live build and when it's unset. It reads the file on every
    /// call, so a test can change the state without a relaunch.
    nonisolated public static func pinnedPlan(for environment: AppEnvironment,
                                              in processEnvironment: [String: String]) -> PinnedPlanService? {
        guard environment == .staging, let path = processEnvironment[pinnedPlanVariable], !path.isEmpty else {
            return nil
        }
        return PinnedPlanService(file: path)
    }

    // MARK: - Coming to the front

    /// A desktop without calendar-day notifications checks periodically and
    /// on waking. Read again only when the local date changes, even signed
    /// out. Compare date components so a time-zone change that moves the
    /// calendar to another day counts too, in either direction.
    /// With no `now`, the app's clock (`clock`).
    public func checkForNewDay(now: Date? = nil, calendar: Calendar = AppLocale.calendar) {
        let day = calendar.dateComponents([.era, .year, .month, .day], from: now ?? clock.now())
        guard day != lastCheckedDay else { return }
        lastCheckedDay = day
        reloadForNewDay()
    }

    /// The system said a day began. It may say so a moment early, so this
    /// reads again without comparing days, and remembers today as checked.
    private func noteNewDay() {
        lastCheckedDay = AppLocale.calendar.dateComponents([.era, .year, .month, .day], from: clock.now())
        reloadForNewDay()
    }

    private func reloadForNewDay() {
        // Equal summaries do not notify observers. The wheel still needs
        // to redraw its day, tick and pace even when no money changed.
        model.today = { [pinnedDay, clock] in Workspace.today(pinnedTo: pinnedDay, now: clock.now()) }
        model.reload()
    }

    /// The app came to the front, which happens at launch too. Signed in, it
    /// syncs, and the sync reads the budgets again when it is done. Signed
    /// out, nothing syncs, so the budgets are read again here: a day or a
    /// month may have begun while the app was away, and this does not wait
    /// for the system to say the day changed.
    ///
    /// First it checks the date, on every platform. A read of the budgets
    /// that changes no money redraws a budget's page but not a group's, so
    /// without this a group's wheel kept yesterday's day after a night in the
    /// background until the system said a day began (#209). Linux also checks
    /// on every focus change, so there the second check finds nothing new.
    public func cameToFront() async {
        checkForNewDay()
        if sync.account == nil { model.reload() }
        await autoSync.syncIfIdle()
        // The plan may have changed elsewhere: bought on the website, renewed,
        // or ended. Every platform asks here, so none drifts.
        if sync.account != nil { await plans.refresh() }
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
                          autoSyncInterval: autoSyncInterval(for: environment, in: processEnvironment),
                          pinnedDay: pinnedDay(for: environment, in: processEnvironment),
                          pinnedPlan: pinnedPlan(for: environment, in: processEnvironment),
                          clock: clock(for: environment, in: processEnvironment),
                          announcesDays: clockAnnouncesDays(for: environment, in: processEnvironment),
                          planStore: appStore(for: environment, in: processEnvironment),
                          features: FeatureFlags.resolve(for: environment, defaults: accounts.defaults,
                                                         processEnvironment: processEnvironment),
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

    #if DEBUG
    /// The environment variable a UI test sets so the app's timed sync, every
    /// 2 minutes, comes less or more often, in whole seconds. A test that
    /// needs the phone not to hear of a change for a moment, such as one made
    /// elsewhere just before a Save, can then count on it, and a test can make
    /// syncs come often (#199). Test builds only: a release build is compiled
    /// without it, and the release check fails the build if this name is in
    /// the app.
    nonisolated public static let autoSyncIntervalVariable = "WELLSPENT_AUTOSYNC_SECONDS"
    #endif

    /// How often the app syncs while open: what the variable says, for a
    /// staging test build, and every 2 minutes otherwise (`AutoSync`).
    public static func autoSyncInterval(for environment: AppEnvironment,
                                        in processEnvironment: [String: String]) -> Duration {
        #if DEBUG
        guard environment == .staging, let text = processEnvironment[autoSyncIntervalVariable],
              let seconds = Int(text), seconds > 0 else { return AutoSync.defaultInterval }
        return .seconds(seconds)
        #else
        return AutoSync.defaultInterval
        #endif
    }

    /// With no `defaults`, the environment's own. Public for the Linux app,
    /// which hands in its own folder, settings and keyring, and then starts up
    /// exactly as the Mac app does.
    /// `undoWindow` is how long the Undo bar after a delete stays.
    /// `autoSyncInterval` is how often the app syncs while open.
    /// `pinnedDay` puts the money wheel on that day of this month.
    public static func launch(accounts: AccountDirectory, defaults: UserDefaults? = nil,
                       environment: AppEnvironment = .current,
                       makeTransport: (@Sendable (URL) -> any ReadableAccountTransport)? = nil,
                       undoWindow: Duration = AppModel.defaultUndoWindow,
                       autoSyncInterval: Duration = AutoSync.defaultInterval,
                       pinnedDay: Int? = nil,
                       pinnedPlan: PinnedPlanService? = nil,
                       clock: AppClock = .system,
                       announcesDays: Bool = true,
                       planStore: (any PlanStore)? = nil,
                       features: FeatureFlags? = nil,
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
        // The samples are dated from today, so from the clock a test moved.
        model.today = { [clock] in Workspace.today(pinnedTo: pinnedDay, now: clock.now()) }
        if sync.account == nil, model.groups.isEmpty, !accounts.samplesSeeded {
            try accounts.noteSamples(try model.seedFirstRun(), in: model.store)
        }
        // Set either way: an older install that already has budgets has had its
        // first run, and must not get samples after its data moves to an account.
        accounts.samplesSeeded = true
        let resolvedFeatures = features ?? FeatureFlags.resolve(for: environment, defaults: defaults)
        return Workspace(model: model, sync: sync, autoSync: AutoSync(sync: sync, interval: autoSyncInterval),
                         pinnedDay: pinnedDay, features: resolvedFeatures, planStore: planStore,
                         pinnedPlan: pinnedPlan, clock: clock, announcesDays: announcesDays)
    }

    /// Apple's App Store on the Mac and iPhone. Linux has none: it pays on
    /// the website.
    nonisolated static func appStore() -> (any PlanStore)? {
        #if canImport(StoreKit)
        return AppleStore()
        #else
        return nil
        #endif
    }

    /// The environment variable a UI test sets to "empty" so the app's store
    /// has nothing in it (`EmptyPlanStore`). A live build never reads it.
    nonisolated public static let emptyStoreVariable = "WELLSPENT_PLAN_STORE"

    /// The store this launch uses: an empty one for a staging test that asks,
    /// otherwise Apple's where there is one.
    nonisolated static func appStore(for environment: AppEnvironment,
                                     in processEnvironment: [String: String]) -> (any PlanStore)? {
        guard environment == .staging, processEnvironment[emptyStoreVariable] == "empty" else { return appStore() }
        return appStore() == nil ? nil : EmptyPlanStore()
    }
}
