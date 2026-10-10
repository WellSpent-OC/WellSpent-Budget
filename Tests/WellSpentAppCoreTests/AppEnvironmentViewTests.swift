// SwiftUI and ViewInspector exist only on Apple systems.
#if canImport(SwiftUI)
import Testing
import Foundation
import SwiftUI
import ViewInspector
@testable import WellSpentAppCore
import WellSpentKeyStore
import WellSpentStore

/// The one difference between the builds that is drawn: the staging banner.
/// Kept apart from `AppEnvironmentTests`, which builds without SwiftUI.
@Suite("Live and staging builds, on screen", .serialized)
@MainActor
struct AppEnvironmentViewTests {
    @Test func onlyAStagingWindowHasTheBanner() throws {
        for environment in AppEnvironment.allCases {
            let model = AppModel(store: Store(database: try WellSpentDatabase.inMemory()))
            let sync = SyncCoordinator(store: model.store, keyStore: InMemoryKeyStore(),
                                       defaults: isolatedDefaults(), environment: environment)
            let root = RootView(workspace: Workspace(model: model, sync: sync))
            let texts = try root.inspect().findAll(ViewType.Text.self).map { try $0.string() }
            #expect(texts.contains(StagingBanner.text) == (environment == .staging), "\(environment)")
        }
    }
}

#endif
