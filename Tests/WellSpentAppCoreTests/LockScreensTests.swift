import Foundation
import Testing
import WellSpentAppCore
import WellSpentPlans

private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text + "T12:00:00Z")! }
private let now = date("2026-11-09")

private func item(_ name: String) -> PlanItem { PlanItem(id: UUID(), name: name) }

private let home = item("Home")
private let cabin = item("Cabin")
private let sam = item("Sam")
private let jo = item("Jo")
private let kit = item("Kit")
private let maple = item("Maple St")
private let pine = item("Pine Rd")
private let oak = item("Oak Ave")

/// The free answer after a paid plan ended, with what the server keeps open.
private func ended(open: PlanAnswer.Open? = nil, properties: Int = 1, locked: PlanAnswer.Locked? = nil) -> PlanAnswer {
    PlanAnswer(tier: .free, period: .none, state: .free, source: .none, paidUntil: nil, renews: false, nextTier: nil,
               limits: .init(properties: properties, groups: 1, invitedPerGroup: 1),
               used: .init(properties: 3, groups: 2, invitedPerGroup: 2), extensionsOpen: [], canSyncPriceLabs: false,
               refreshMinutes: 60, appleAccountToken: UUID(),
               lastPlan: .init(tier: .growth, endedOn: now, reason: .ended), locked: locked, open: open)
}

private func pick(_ answer: PlanAnswer = ended()) -> PickOpenScreen {
    PickOpenScreen(answer: answer, groups: [home, cabin], people: [home.id: [sam, jo], cabin.id: [kit]],
                   properties: [maple, pine, oak], now: now, calendar: utc)
}

struct PickOpenScreenTests {
    @Test func theFirstOfEachIsTickedAndSkipNamesThem() {
        let screen = pick()
        #expect(screen.group == home.id)
        #expect(screen.person == sam.id)
        #expect(screen.properties == [maple.id])
        #expect(screen.people == [sam, jo])
        #expect(screen.skipNote == "Skip keeps Home, Sam and Maple St open.")
        #expect(screen.intro == "Your free plan keeps 1 group, 1 person and 1 property open. "
            + "The rest is locked until you pick a plan. Nothing was deleted.")
        #expect(screen.propertiesHeading == "Property")
        #expect(screen.groupNote == "You can change the open group once every 30 days.")
        #expect(!screen.pickedSomethingElse)
        #expect(screen.skipPick == screen.pick)
    }

    @Test func whatTheServerKeepsOpenIsTicked() {
        let open = PlanAnswer.Open(groupID: cabin.id, person: .init(groupID: cabin.id, userID: kit.id),
                                   houseIDs: [oak.id])
        let screen = pick(ended(open: open))
        #expect(screen.group == cabin.id)
        #expect(screen.person == kit.id)
        #expect(screen.properties == [oak.id])
        #expect(screen.skipNote == "Skip keeps Cabin, Kit and Oak Ave open.")
    }

    @Test func anOpenItemThatIsGoneFallsBackToTheFirst() {
        let open = PlanAnswer.Open(groupID: UUID(), person: .init(groupID: UUID(), userID: UUID()), houseIDs: [UUID()])
        let screen = pick(ended(open: open))
        #expect(screen.group == home.id)
        #expect(screen.person == sam.id)
        #expect(screen.properties == [maple.id])
    }

    @Test func choosingAnotherGroupTicksItsFirstPerson() {
        var screen = pick()
        screen.choose(group: cabin.id)
        #expect(screen.group == cabin.id)
        #expect(screen.people == [kit])
        #expect(screen.person == kit.id)
        #expect(screen.pickedSomethingElse)
        #expect(screen.pick == PlanPick(groupID: cabin.id, person: .init(groupID: cabin.id, userID: kit.id),
                                        houseIDs: [maple.id]))
        #expect(screen.skipNote == "Skip keeps Home, Sam and Maple St open.")
    }

    @Test func aPersonOutsideTheGroupCantBeChosen() {
        var screen = pick()
        screen.choose(person: kit.id)
        #expect(screen.person == sam.id)
        screen.choose(person: jo.id)
        #expect(screen.person == jo.id)
    }

    @Test func withOnePropertyTickingAnotherMovesTheTick() {
        var screen = pick()
        screen.toggle(property: pine.id)
        #expect(screen.properties == [pine.id])
        #expect(screen.isChosen(property: pine.id) && !screen.isChosen(property: maple.id))
    }

    @Test func aPaidPlansLimitAllowsThatManyAndNoMore() {
        var screen = pick(ended(properties: 2))
        #expect(screen.properties == [maple.id, pine.id])
        #expect(screen.propertiesHeading == "Properties, up to 2")
        screen.toggle(property: oak.id)
        #expect(screen.properties == [maple.id, pine.id])
        screen.toggle(property: maple.id)
        screen.toggle(property: oak.id)
        #expect(screen.properties == [pine.id, oak.id])
    }

    @Test func theOpenGroupWaits30DaysBetweenChanges() {
        let open = PlanAnswer.Open(groupID: home.id, person: nil, houseIDs: [], groupChangedAt: date("2026-11-01"))
        var screen = pick(ended(open: open))
        #expect(!screen.canChangeGroup)
        #expect(screen.groupNote == "You can change the open group on Dec 1.")
        screen.choose(group: cabin.id)
        #expect(screen.group == home.id)
        var later = PickOpenScreen(answer: ended(open: open), groups: [home, cabin], people: [:], properties: [],
                                   now: date("2026-12-01"), calendar: utc)
        #expect(later.canChangeGroup)
        later.choose(group: cabin.id)
        #expect(later.group == cabin.id)
    }

    @Test func nothingToPickStillReads() {
        let screen = PickOpenScreen(answer: ended(), groups: [], people: [:], properties: [], now: now, calendar: utc)
        #expect(screen.group == nil && screen.person == nil && screen.properties.isEmpty)
        #expect(screen.skipNote == "Skip keeps things as they are.")
        #expect(screen.pick == PlanPick(groupID: nil, person: nil, houseIDs: []))
    }
}

struct LockedScreenTests {
    @Test func aLockedProperty() {
        let screen = LockedScreen(.property(open: ["Maple St"]), now: now, calendar: utc)
        #expect(screen.title == "This property is locked")
        #expect(screen.lines == ["Your free plan keeps Maple St open.",
                                 "Pick a plan to open it again. Nothing was deleted."])
        #expect(screen.actions == [.switchWhichIsOpen, .seePlans])
        #expect(screen.actions.map(\.title) == ["Switch Which Is Open", "See Plans"])
        #expect(LockedScreen(.property(open: [])).lines.first == "It's past what your free plan keeps open.")
    }

    @Test func thePayersLockedGroupSaysWhenTheOpenGroupCanChange() {
        let waiting = LockedScreen(.ownGroup(open: "Home"), groupChangedAt: date("2026-11-01"), now: now, calendar: utc)
        #expect(waiting.title == "This group is locked")
        #expect(waiting.lines == ["Your free plan keeps 1 group open: Home.",
                                  "The people in this group can't see it either.",
                                  "You can change the open group on Dec 1.", "Nothing was deleted."])
        #expect(waiting.actions == [.seePlans])
        let free = LockedScreen(.ownGroup(open: "Home"), now: now, calendar: utc)
        #expect(free.lines[2] == "You can change the open group now.")
        #expect(free.actions == [.changeWhatsOpen, .seePlans])
    }

    @Test func aMemberAndALockedOutPersonCanPayForTheGroup() {
        let member = LockedScreen(.memberGroup(payer: "Robin"))
        #expect(member.title == "This group needs a paid plan")
        #expect(member.lines == ["Robin's plan doesn't cover it right now.",
                                 "Paying opens it for everyone in it. Nobody else is charged."])
        #expect(member.actions == [.payForThisGroup])
        let out = LockedScreen(.lockedOut(payer: "Robin"))
        #expect(out.lines.first == "Robin is on the free plan, which shares a group with 1 person.")
        #expect(out.actions.map(\.title) == ["Pay for This Group"])
    }
}

struct PlanLocksTests {
    @Test func itSaysWhatTheAnswerLocks() {
        let person = PlanAnswer.Person(groupID: home.id, userID: jo.id)
        let locks = PlanLocks(ended(locked: .init(groupIDs: [cabin.id], people: [person], houseIDs: [oak.id])))
        #expect(locks.isLocked(group: cabin.id) && !locks.isLocked(group: home.id))
        #expect(locks.isLocked(person: jo.id, in: home.id) && !locks.isLocked(person: jo.id, in: cabin.id))
        #expect(locks.isLocked(property: oak.id) && !locks.isLocked(property: maple.id))
        #expect(!locks.isEmpty)
        #expect(PlanLocks.mark == "Locked")
    }

    @Test func noAnswerLocksNothing() {
        #expect(PlanLocks(nil).isEmpty)
        #expect(PlanLocks(ended()).isEmpty)
    }
}

struct PlanPickTests {
    @Test func theOpenGroupsLastChangeIsReadWhenSentAndNilWhenNot() throws {
        let sent = #"{"groupID":"\#(home.id)","houseIDs":[],"groupChangedAt":"2026-11-01T12:00:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(PlanAnswer.Open.self, from: Data(sent.utf8)).groupChangedAt == date("2026-11-01"))
        let bare = #"{"groupID":null,"houseIDs":[]}"#
        #expect(try decoder.decode(PlanAnswer.Open.self, from: Data(bare.utf8)).groupChangedAt == nil)
    }
}
