import Foundation
import WellSpentPlans

/// What Restore Purchases found, as a small sheet: the plan is back, or there
/// was nothing to restore.
public struct RestoreResultScreen: Equatable, Sendable {
    public let title: String
    public let lines: [String]
    /// "Done" when a plan came back, "OK" when nothing did.
    public let close: String
    public let found: Bool

    /// `device` is "Mac" or "iPhone".
    public init(answer: PlanAnswer?, device: String) {
        if let answer, answer.state != .free, answer.tier != .free {
            found = true
            title = "Restored"
            lines = ["Your \(PlanWording.name(answer.tier)) plan is back on this \(device)."]
            close = "Done"
        } else {
            found = false
            title = "Nothing to restore"
            lines = ["This Apple account has no WellSpent plan. You're on the free plan.",
                     "If you paid on wellspent.space, sign in with that email instead. "
                        + "The plan follows your WellSpent account."]
            close = "OK"
        }
    }
}

/// The line under Choose a plan's buttons while buying, or after it failed.
public enum PlanStatusWording {
    /// Nil when there's nothing to say.
    public static func line(_ status: PurchaseCoordinator.Status) -> String? {
        switch status {
        case .idle: nil
        case .working: "Working with the App Store…"
        case .waitingForApproval: "Waiting for approval. Your plan starts once it's approved."
        case .failed(let failure): line(failure)
        }
    }

    public static func line(_ failure: PurchaseCoordinator.Failure) -> String {
        switch failure {
        case .noStore: "On this device you pay on wellspent.space."
        case .notReady: "Your plan hasn't loaded yet. Check your connection and try again."
        case .paddlePlanLive: "Your plan was bought on wellspent.space, so change it there."
        case .notGenuine: "Apple's record of that purchase didn't check out. Try Restore Purchases, or email us."
        case .unreachable:
            "We couldn't reach our server. Apple keeps your purchase, and it goes through when you're back online."
        case .storeFailed: "The App Store couldn't finish. Try again."
        }
    }

    /// Whether the status is a failure, for the warning colour.
    public static func isWarning(_ status: PurchaseCoordinator.Status) -> Bool {
        if case .failed = status { return true }
        return false
    }
}
