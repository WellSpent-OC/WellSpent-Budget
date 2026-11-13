import Foundation
import WellSpentPlans

/// The kind of device a group is kept on, for "only on this Mac".
public enum ThisDevice: Equatable, Sendable {
    case mac
    case iPhone
    case computer

    public var phrase: String {
        switch self {
        case .mac: "this Mac"
        case .iPhone: "this iPhone"
        case .computer: "this computer"
        }
    }
}

/// A group made on this device that the free plan kept off the server
/// (PLAN-18). The server makes one group on the free plan and refuses the
/// rest. The refused group stays here, kept, and says so: a marker beside
/// its name, and a notice at the top of its page saying why.
public struct HeldGroupScreen: Equatable, Sendable {
    /// Beside the group's name in the list.
    public let marker: String
    /// At the top of the group's page.
    public let notice: String
    /// Opens Choose a plan.
    public let action = "See Plans"

    /// - Parameters:
    ///   - group: the held group's name.
    ///   - synced: the name of the group the free plan does sync, when there is one.
    ///   - buyingIsOpen: whether Choose a plan can sell a plan, on any platform.
    ///     While it says "Coming soon", the notice doesn't tell people to pick one.
    public init(group: String, synced: String?, device: ThisDevice,
                buyingIsOpen: Bool = PlanBuying.isOpen()) {
        marker = "Only on \(device.phrase)"
        var words = "\(group) is only on \(device.phrase). Your free plan syncs 1 group"
        words += synced.map { ", and \($0) is that group. " } ?? ". "
        words += "Nothing in \(group) is deleted. "
        words += buyingIsOpen ? "Choose a plan to sync it too." : "Paid plans are coming soon."
        notice = words
    }
}
