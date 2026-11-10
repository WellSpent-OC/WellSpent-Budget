import Foundation
import Observation
import WellSpentPlans

/// Deleting the account, the same on every app: what it says, the password
/// it asks for, and what went wrong. The words are the privacy policy's
/// ("Deleting your account"), as the design has them.
@MainActor
@Observable
public final class DeleteAccountScreen {
    public enum Words {
        public static let button = "Delete Account…"
        public static let title = "Delete your account?"
        public static let phoneTitle = "Delete account?"
        public static let server = "Your account and your budgets are deleted from our server, and from backups "
            + "in about a month."
        public static let shared = "In a shared group, the budgets belong to the group, so they stay for the "
            + "people still in it."
        public static let records = "We keep the record of each purchase (the plan, the price, the dates and the "
            + "store's purchase number) for 7 years after the year of the purchase, for our tax records. It's no "
            + "longer tied to your account."
        public static func device(_ device: String) -> String {
            "This \(device) keeps its own copy of your budgets. To remove it, delete the app."
        }
        public static func apple(_ plan: String) -> String {
            "Your \(plan) plan was bought through Apple, so deleting your account doesn't stop it. "
                + "Cancel it in your Apple account settings first."
        }
        public static func website(_ plan: String) -> String {
            "Your \(plan) plan, bought on our website, is canceled for you."
        }
        public static let openAppleSettings = "Open Apple Settings"
        public static let password = "Password"
        public static let passwordPrompt = "Type your password to delete your account."
        public static let cancel = "Cancel"
        public static let delete = "Delete Account"
        public static let wrongPassword = "That password isn't right."
        public static let planNotCanceled = "We couldn't cancel your plan on wellspent.space, so nothing was "
            + "deleted. Try again in a few minutes."
        public static let unreachable = "We couldn't reach our server, so nothing was deleted. Try again."
    }

    /// What's said, in order. An Apple plan's line is said in bold, with
    /// Open Apple Settings after it.
    public let lines: [String]
    /// The Apple plan's line, which the apps draw in bold. Nil otherwise.
    public let appleLine: String?
    public var showsOpenAppleSettings: Bool { appleLine != nil }

    public var password = ""
    public private(set) var isWorking = false
    public private(set) var failure: String?
    public private(set) var isDone = false

    private let delete: (String) async throws -> Void

    /// `device` is "Mac", "iPhone" or "computer". `delete` is the
    /// coordinator's `deleteAccount(password:)`.
    public init(answer: PlanAnswer?, device: String, delete: @escaping (String) async throws -> Void) {
        self.delete = delete
        let paid = answer.flatMap { $0.state == .free || $0.tier == .free ? nil : $0 }
        let name = paid.map { PlanWording.name($0.tier) } ?? ""
        var apple: String?
        var middle: [String] = []
        switch paid?.source {
        case .apple?: apple = Words.apple(name)
        case .paddle?: middle = [Words.website(name)]
        default: break
        }
        appleLine = apple
        lines = [Words.server, Words.shared] + (apple.map { [$0] } ?? []) + middle
            + [Words.records, Words.device(device)]
    }

    public var canDelete: Bool { !password.isEmpty && !isWorking }

    public func submit() async {
        guard canDelete else { return }
        isWorking = true
        failure = nil
        defer { isWorking = false }
        do {
            try await delete(password)
            isDone = true
        } catch SyncCoordinator.DeleteFailure.wrongPassword {
            failure = Words.wrongPassword
        } catch SyncCoordinator.DeleteFailure.planNotCanceled {
            failure = Words.planNotCanceled
        } catch {
            // A session that ended signs the device out on its own; the
            // sheet closes with the account.
            failure = Words.unreachable
        }
    }
}

extension DeleteAccountScreen: Identifiable {
    public nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}
