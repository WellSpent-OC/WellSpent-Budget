import Foundation
import Vapor

/// Closes /api/v1, the sealed sync, at the switch to readable sync.
///
/// Every /api/v1 request is then answered 401 with a message the old app shows
/// word for word when someone presses Sync. 401 and not something final on
/// purpose: the old app treats 401 as something that may clear up, so it keeps
/// every queued edit and every invite instead of dropping them. A 403 would make
/// it found its groups again, and some answers would clear a deleted group's
/// queue. Nothing is lost on the Mac while it waits for the update.
///
/// Open by default, so tests and development are unchanged. A server marks the
/// switch with `LEGACY_API=off`.
struct LegacyAPIGate: AsyncMiddleware {
    static let refusal = """
        This version of WellSpent no longer syncs. Install the new version of WellSpent. \
        Your budgets on this Mac are safe.
        """

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard request.application.legacyAPIOpen else {
            throw Abort(.unauthorized, reason: Self.refusal)
        }
        return try await next.respond(to: request)
    }

    /// `on` or unset keeps /api/v1 open; `off` closes it. Anything else stops the
    /// server rather than guess which was meant.
    static func parse(_ value: String?) throws -> Bool {
        switch value?.trimmingCharacters(in: .whitespaces).lowercased() {
        case nil, "", "on": return true
        case "off": return false
        default:
            throw Abort(.internalServerError, reason: "LEGACY_API must be on or off")
        }
    }
}

extension Application {
    private struct LegacyAPIOpenKey: StorageKey {
        typealias Value = Bool
    }

    /// Read on every request, so a test can close it after `configure`.
    var legacyAPIOpen: Bool {
        get { storage[LegacyAPIOpenKey.self] ?? true }
        set { storage[LegacyAPIOpenKey.self] = newValue }
    }
}
