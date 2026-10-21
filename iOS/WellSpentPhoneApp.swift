// The iPhone app's shell. Everything a person sees is drawn by the iPhone's
// own views in WellSpentAppCore, over the rules and words every app shares.
// This file only starts them: it opens this build's budgets, keeps them
// syncing and current from day to day, and says so on screen if they cannot
// be opened.
import SwiftUI
import UIKit
import WellSpentAppCore

@main
struct WellSpentPhoneApp: App {
    /// This build's budgets, or why they could not be opened.
    private let launch: Result<Workspace, any Error>
    /// The screen a staging build was asked to open on, for a test.
    private let start = StartingScreen.requested()
    /// The day of the month a staging build was asked to count as today, for
    /// a test of the money wheel.
    private let today = PinnedDay.requested()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // The words name this device, as in "Kept on this iPhone only". Set
        // before any screen is drawn.
        SyncWording.device = UIDevice.current.model
        // A phone shows a budget in place of the list, so only a tap opens one.
        launch = Result { try Workspace.launch(opensFirstBudget: false) }
        if case .success(let workspace) = launch {
            workspace.autoSync.start()
        }
    }

    var body: some Scene {
        WindowGroup {
            switch launch {
            case .success(let workspace):
                wellSpentPhoneRootView(workspace: workspace, startingOn: start, today: today)
                    // Midnight, the clocks moving or a new time zone: a new
                    // day may begin a new month, so the budgets are read
                    // again for it.
                    .onReceive(NotificationCenter.default.publisher(
                        for: UIApplication.significantTimeChangeNotification)) { _ in
                        workspace.dayChanged()
                    }
            case .failure(let error):
                ContentUnavailableView {
                    Label(MainScreen.Words.couldNotOpen(AppEnvironment.current.appName),
                          systemImage: "exclamationmark.triangle")
                } description: {
                    Text(String(describing: error))
                }
            }
        }
        // Coming to the front syncs, as on the Mac, or, signed out, reads the
        // budgets again. It happens at launch too.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, case .success(let workspace) = launch else { return }
            Task { await workspace.cameToFront() }
        }
    }
}
