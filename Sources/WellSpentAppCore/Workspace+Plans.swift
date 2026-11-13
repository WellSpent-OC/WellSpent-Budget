import Foundation
import WellSpentCrypto
import WellSpentExtensionKit
import WellSpentPlans

/// The lock and pick screens, built from the plan answer and this device's
/// groups and people, so the Mac, iPhone and Linux draw the same thing. The
/// server sends ids only; the names come from here.
extension Workspace {
    /// What the plan answer locks, for the "Locked" marks.
    public var planLocks: PlanLocks { PlanLocks(plans.answer) }

    /// Pick what stays open, or nil with no plan answer.
    public func pickScreen(now: Date = Date(), calendar: Calendar = AppLocale.calendar) -> PickOpenScreen? {
        guard let answer = plans.answer else { return nil }
        let mine = paidForGroups()
        let properties = planProperties(in: mine)
        var people: [UUID: [PlanItem]] = [:]
        for group in mine {
            people[group.id] = invitedPeople(in: GroupID(group.id))
        }
        return PickOpenScreen(answer: answer, groups: mine, people: people, properties: properties,
                              now: now, calendar: calendar)
    }

    /// The card that takes a locked group's place, or nil when it isn't locked.
    /// Whose card depends on who pays: the payer, a member, or an invited
    /// person who is locked out.
    public func lockedScreen(group: GroupID, now: Date = Date(),
                             calendar: Calendar = AppLocale.calendar) -> LockedScreen? {
        guard let answer = plans.answer, let me = sync.userID else { return nil }
        let locks = PlanLocks(answer)
        let lockedOut = locks.isLocked(person: me.uuid, in: group.uuid)
        guard locks.isLocked(group: group.uuid) || lockedOut else { return nil }
        let founder = sync.founder(of: group)
        if founder == me {
            let open = answer.open?.groupID.flatMap { id in model.groups.first { $0.id.uuid == id }?.name }
            return LockedScreen(.ownGroup(open: open), groupChangedAt: answer.open?.groupChangedAt,
                                now: now, calendar: calendar)
        }
        let payer = founder.flatMap { sync.memberNames(in: group)[$0] } ?? "The person who pays"
        return LockedScreen(lockedOut ? .lockedOut(payer: payer) : .memberGroup(payer: payer),
                            now: now, calendar: calendar)
    }

    /// PLAN-18: the marker and notice for a group the free plan kept on this
    /// device, or nil when the server has it. The synced group named is one
    /// the server does have.
    public func heldScreen(group: GroupID, device: ThisDevice,
                           buyingIsOpen: Bool = PlanBuying.isOpen()) -> HeldGroupScreen? {
        let held = sync.heldOnThisDevice
        guard held.contains(group), let name = model.groups.first(where: { $0.id == group })?.name else { return nil }
        let synced = model.groups.first { !held.contains($0.id) && sync.founder(of: $0.id) != nil }?.name
        return HeldGroupScreen(group: name, synced: synced, device: device,
                               buyingIsOpen: buyingIsOpen)
    }

    /// The card that takes a locked property's place, or nil when it's open.
    /// `record` is the property's record id, as the Properties extension asks.
    public func lockedScreen(property record: String) -> LockedScreen? {
        guard let answer = plans.answer, let id = UUID(uuidString: record),
              PlanLocks(answer).isLocked(property: id) else { return nil }
        let houses = planProperties(in: paidForGroups())
        let open = (answer.open?.houseIDs ?? []).compactMap { open in houses.first { $0.id == open }?.name }
        return LockedScreen(.property(open: open))
    }

    /// What the plan card's "Open now" names, in its order: the open group,
    /// the open properties, then the open person. Empty with nothing open.
    public var planOpenNames: [String] {
        guard let open = plans.answer?.open else { return [] }
        let mine = paidForGroups()
        let group = open.groupID.flatMap { id in mine.first { $0.id == id }?.name }
        let houses = planProperties(in: mine)
        let houseNames = open.houseIDs.compactMap { id in houses.first { $0.id == id }?.name }
        let person = open.person.flatMap { chosen in
            invitedPeople(in: GroupID(chosen.groupID)).first { $0.id == chosen.userID }?.name
        }
        return [group].compactMap { $0 } + houseNames + [person].compactMap { $0 }
    }

    /// The properties in these groups, from the Properties extension when
    /// it's on. The core never reads a house record itself.
    func planProperties(in groups: [PlanItem]) -> [PlanItem] {
        let records = model.extensionSlots?.planRecords(in: Set(groups.map { $0.id.uuidString })) ?? []
        return records.compactMap { house in UUID(uuidString: house.id).map { PlanItem(id: $0, name: house.name) } }
    }

    /// The groups this person made and pays for, oldest first. Groups they
    /// were invited into don't count toward their own limit.
    func paidForGroups() -> [PlanItem] {
        guard let me = sync.userID else { return [] }
        return model.groups
            .filter { !$0.isDeleted && sync.founder(of: $0.id) == me }
            .sorted { $0.createdAt < $1.createdAt }
            .map { PlanItem(id: $0.id.uuid, name: $0.name) }
    }

    /// The people invited into a group, everyone but its founder, by name.
    func invitedPeople(in group: GroupID) -> [PlanItem] {
        let founder = sync.founder(of: group)
        let names = sync.memberNames(in: group)
        return sync.members(of: group).keys
            .filter { $0 != founder }
            .map { PlanItem(id: $0.uuid, name: names[$0] ?? "Someone") }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
