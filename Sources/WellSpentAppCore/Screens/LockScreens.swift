import Foundation
import WellSpentPlans

/// A group, a person or a property, as the lock and pick screens name it. The
/// server sends ids only, so each app brings the name from its own data.
public struct PlanItem: Equatable, Hashable, Sendable {
    public let id: UUID
    public let name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

/// What the server's answer locks. Each app asks this before it draws a group,
/// a person or a property, and draws a lock and "Locked" where it says so.
public struct PlanLocks: Equatable, Sendable {
    public static let mark = "Locked"

    private let groups: Set<UUID>
    private let people: Set<PlanAnswer.Person>
    private let houses: Set<UUID>

    public init(_ answer: PlanAnswer?) {
        let locked = answer?.locked
        groups = Set(locked?.groupIDs ?? [])
        people = Set(locked?.people ?? [])
        houses = Set(locked?.houseIDs ?? [])
    }

    public var isEmpty: Bool { groups.isEmpty && people.isEmpty && houses.isEmpty }
    public func isLocked(group: UUID) -> Bool { groups.contains(group) }
    public func isLocked(person: UUID, in group: UUID) -> Bool {
        people.contains(PlanAnswer.Person(groupID: group, userID: person))
    }
    public func isLocked(property: UUID) -> Bool { houses.contains(property) }
}

/// The open group can change once in this many days.
public enum OpenGroupRule {
    public static let days = 30

    /// The first day the open group can change again. Nil means it can now.
    public static func changeableOn(_ changedAt: Date?, now: Date, calendar: Calendar) -> Date? {
        guard let changedAt, let next = calendar.date(byAdding: .day, value: days, to: changedAt),
              next > now else { return nil }
        return next
    }
}

/// Pick what stays open: shown once when a paid plan ends, and from "Change
/// what stays open" after that. Three lists: the group, the person in that
/// group, and the properties. The first of each is ticked unless the server
/// says what is open.
public struct PickOpenScreen: Equatable, Sendable {
    public let title = "Pick what stays open"
    public let intro: String
    public let groupsHeading = "Group"
    public let peopleHeading = "Person in this group"
    public let propertiesHeading: String
    public let groupNote: String
    public let keep = "Keep These Open"
    public let skip = "Skip"

    public let groups: [PlanItem]
    public let propertyItems: [PlanItem]
    /// False within 30 days of the last change: the group list shows, but
    /// its choice can't change.
    public let canChangeGroup: Bool
    public let propertyLimit: Int

    public private(set) var group: UUID?
    public private(set) var person: UUID?
    public private(set) var properties: [UUID]

    private let peopleByGroup: [UUID: [PlanItem]]
    private let defaults: PlanPick

    /// `groups` are the groups this person pays for, in the order they were
    /// made. Groups they were invited into don't count. `people` are the
    /// invited people in each, in the order they were added.
    public init(answer: PlanAnswer, groups: [PlanItem], people: [UUID: [PlanItem]], properties: [PlanItem],
                now: Date = Date(), calendar: Calendar = AppLocale.calendar) {
        let limit = max(answer.limits.properties ?? 1, 1)
        self.groups = groups
        propertyItems = properties
        peopleByGroup = people
        propertyLimit = limit

        let open = answer.open
        let next = OpenGroupRule.changeableOn(open?.groupChangedAt, now: now, calendar: calendar)
        canChangeGroup = next == nil
        groupNote = next.map { "You can change the open group on \(PlanWording.day($0, now: now, calendar: calendar))." }
            ?? "You can change the open group once every \(OpenGroupRule.days) days."

        let ids = Set(groups.map(\.id))
        let group = open?.groupID.flatMap { ids.contains($0) ? $0 : nil } ?? groups.first?.id
        let inGroup = group.flatMap { people[$0] } ?? []
        let person = open?.person.flatMap { chosen in
            chosen.groupID == group && inGroup.contains { $0.id == chosen.userID } ? chosen.userID : nil
        } ?? inGroup.first?.id
        let known = Set(properties.map(\.id))
        let openHouses = (open?.houseIDs ?? []).filter(known.contains)
        let houses = Array((openHouses.isEmpty ? properties.map(\.id) : openHouses).prefix(limit))

        self.group = group
        self.person = person
        self.properties = houses
        defaults = PlanPick(groupID: group, person: Self.person(person, in: group), houseIDs: houses)

        propertiesHeading = limit == 1 ? "Property" : "Properties, up to \(limit)"
        intro = "Your free plan keeps 1 group, 1 person and \(PlanWording.properties(limit)) open. "
            + "The rest is locked until you pick a plan. \(PlanWording.nothingDeleted)"
    }

    /// The invited people in the chosen group.
    public var people: [PlanItem] { group.flatMap { peopleByGroup[$0] } ?? [] }

    /// "Skip keeps Home, Sam and Maple St open." It names the first ones, so
    /// Skip is never a surprise.
    public var skipNote: String {
        let names = [name(defaults.groupID, in: groups), name(defaults.person?.userID, in: defaultPeople)]
            .compactMap { $0 } + defaults.houseIDs.compactMap { name($0, in: propertyItems) }
        return names.isEmpty ? "Skip keeps things as they are." : "Skip keeps \(PlanWording.list(names)) open."
    }

    public mutating func choose(group id: UUID) {
        guard canChangeGroup, groups.contains(where: { $0.id == id }), id != group else { return }
        group = id
        person = peopleByGroup[id]?.first?.id
    }

    public mutating func choose(person id: UUID) {
        guard people.contains(where: { $0.id == id }) else { return }
        person = id
    }

    /// Ticks or unticks a property. With one allowed, ticking another moves
    /// the tick. Past the limit, ticking does nothing.
    public mutating func toggle(property id: UUID) {
        guard propertyItems.contains(where: { $0.id == id }) else { return }
        if let index = properties.firstIndex(of: id) {
            properties.remove(at: index)
        } else if propertyLimit == 1 {
            properties = [id]
        } else if properties.count < propertyLimit {
            properties.append(id)
        }
    }

    public func isChosen(property id: UUID) -> Bool { properties.contains(id) }

    /// What Keep These Open saves.
    public var pick: PlanPick {
        PlanPick(groupID: group, person: Self.person(person, in: group), houseIDs: properties)
    }

    /// What Skip saves: the first ones, or what the server already had open.
    public var skipPick: PlanPick { defaults }

    /// For the count: only whether they picked or left the default, never what.
    public var pickedSomethingElse: Bool { pick != defaults }

    private var defaultPeople: [PlanItem] { defaults.groupID.flatMap { peopleByGroup[$0] } ?? [] }

    private func name(_ id: UUID?, in items: [PlanItem]) -> String? {
        id.flatMap { id in items.first { $0.id == id }?.name }
    }

    private static func person(_ id: UUID?, in group: UUID?) -> PlanAnswer.Person? {
        guard let id, let group else { return nil }
        return PlanAnswer.Person(groupID: group, userID: id)
    }
}

/// The card that takes the place of something locked.
public struct LockedScreen: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A property past the plan. `open` names the properties still open.
        case property(open: [String])
        /// A group the payer kept locked. `open` names the open group.
        case ownGroup(open: String?)
        /// A group whose payer is past their plan, as a member sees it.
        case memberGroup(payer: String)
        /// A group this person is locked out of, because its payer shares
        /// with 1 person on the free plan.
        case lockedOut(payer: String)
    }

    public enum Action: Equatable, Sendable {
        case switchWhichIsOpen
        case changeWhatsOpen
        case seePlans
        /// Opens Choose a plan. Anyone in a locked group can pay to open it.
        case payForThisGroup

        public var title: String {
            switch self {
            case .switchWhichIsOpen: "Switch Which Is Open"
            case .changeWhatsOpen: "Change What's Open"
            case .seePlans: "See Plans"
            case .payForThisGroup: "Pay for This Group"
            }
        }
    }

    public let title: String
    public let lines: [String]
    /// In order. The last is the main button.
    public let actions: [Action]

    /// `groupChangedAt` is when the payer last changed the open group, from
    /// the server's answer.
    public init(_ kind: Kind, groupChangedAt: Date? = nil, now: Date = Date(),
                calendar: Calendar = AppLocale.calendar) {
        let payLine = "Paying opens it for everyone in it. Nobody else is charged."
        switch kind {
        case let .property(open):
            title = "This property is locked"
            lines = [open.isEmpty
                        ? "It's past what your free plan keeps open."
                        : "Your free plan keeps \(PlanWording.list(open)) open.",
                     "Pick a plan to open it again. \(PlanWording.nothingDeleted)"]
            actions = [.switchWhichIsOpen, .seePlans]
        case let .ownGroup(open):
            title = "This group is locked"
            let next = OpenGroupRule.changeableOn(groupChangedAt, now: now, calendar: calendar)
            lines = [open.map { "Your free plan keeps 1 group open: \($0)." }
                        ?? "Your free plan keeps 1 group open.",
                     "The people in this group can't see it either.",
                     next.map { "You can change the open group on \(PlanWording.day($0, now: now, calendar: calendar))." }
                        ?? "You can change the open group now.",
                     PlanWording.nothingDeleted]
            actions = next == nil ? [.changeWhatsOpen, .seePlans] : [.seePlans]
        case let .memberGroup(payer):
            title = "This group needs a paid plan"
            lines = ["\(payer)'s plan doesn't cover it right now.", payLine]
            actions = [.payForThisGroup]
        case let .lockedOut(payer):
            title = "This group needs a paid plan"
            lines = ["\(payer) is on the free plan, which shares a group with 1 person.", payLine]
            actions = [.payForThisGroup]
        }
    }
}

/// What the pick sheet says when the server refuses a pick.
public enum PickWording {
    public static let tooSoon = "The open group changed less than 30 days ago, so it stays for now."
    public static let notYours = "Something here isn't yours to pick any more. Close this and try again."
    public static let tooMany = "That's more properties than your plan keeps open."
    public static let unreachable = "We couldn't reach our server, so nothing changed. Try again."

    public static func failure(_ error: any Error) -> String {
        switch error as? PlanLockError {
        case .pickTooSoon?: tooSoon
        case .notYours?: notYours
        case .tooMany?: tooMany
        default: unreachable
        }
    }
}
