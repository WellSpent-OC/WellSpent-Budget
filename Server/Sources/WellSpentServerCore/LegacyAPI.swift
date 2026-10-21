import Foundation
import Vapor

/// /api/v1, the sealed sync, is gone since the switch to readable sync.
///
/// Every request under it, by any method, is answered 401 with a message the old
/// app shows word for word when someone presses Sync. 401 and not something final
/// on purpose: the old app treats 401 as something that may clear up, so it keeps
/// every queued edit and every invite instead of dropping them. A 403 would make
/// it found its groups again, and some answers would clear a deleted group's
/// queue. Nothing is lost on the Mac while it waits for the update.
///
/// The body is never read, so an old app's large push costs nothing.
enum LegacyAPI {
    static let refusal = """
        This version of WellSpent no longer syncs. Install the new version of WellSpent. \
        Your budgets on this Mac are safe.
        """

    static func register(on app: Application) {
        let old = app.grouped("api", "v1")
        for method: HTTPMethod in [.GET, .POST, .PUT, .PATCH, .DELETE] {
            old.on(method, "**", body: .stream) { _ async throws -> Response in
                throw Abort(.unauthorized, reason: refusal)
            }
        }
    }
}
