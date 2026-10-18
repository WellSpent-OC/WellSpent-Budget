import Foundation
import WellSpentCrypto
import WellSpentModel
import WellSpentSync

// What the share and join sheets check and say, with no SwiftUI, so every
// desktop shares it.

/// The three things a person can be invited to do, in the words the screens use.
public enum InviteRole: CaseIterable, Identifiable {
    case view, add, manage

    public var id: Self { self }

    public var level: AccessLevel {
        switch self {
        case .view: return .read
        case .add: return .write
        case .manage: return .manage
        }
    }

    public var title: String {
        switch self {
        case .view: return "View"
        case .add: return "Add"
        case .manage: return "Manage"
        }
    }

    public var explanation: String {
        switch self {
        case .view: return "Sees every budget and transaction. Changes nothing."
        case .add: return "Adds transactions, and edits or deletes their own."
        case .manage: return "Edits budgets, edits or deletes anyone's transactions, and invites other people."
        }
    }

    public static func describing(_ level: AccessLevel) -> String {
        switch level {
        case .read: return "view this group"
        case .write: return "add transactions"
        default: return "manage this group"
        }
    }
}

/// What the share and join sheets require before their main button works.
public enum SharingRules {
    /// A link is made only for someone signed in, with a name to show.
    public static func canCreate(myName: String, signedIn: Bool) -> Bool {
        signedIn && !myName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// A join needs a sign-in, a link this build made, and a name.
    public static func canJoin(linkText: String, myName: String, signedIn: Bool,
                               in environment: AppEnvironment) -> Bool {
        signedIn && environment.invite(from: linkText) != nil
            && !myName.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

extension SyncCoordinator {
    /// The reason the last action failed, in words, if it did.
    public var failureMessage: String? {
        if case .failed(let why) = state { return why }
        return nil
    }
}
