import Testing
import WellSpentCrypto
import WellSpentModel

/// Who may change whom. The server enforces these same functions, so these
/// cases are what both the server and the apps answer.
@Suite("Membership rules")
struct MembershipRulesTests {
    @Test func invitingTakesManageAndAdminForTheHigherLevels() {
        #expect(MembershipRules.invite(at: .read, holding: .manage) == nil)
        #expect(MembershipRules.invite(at: .write, holding: .manage) == nil)
        #expect(MembershipRules.invite(at: .manage, holding: .manage) == .needs(.admin))
        #expect(MembershipRules.invite(at: .manage, holding: .admin) == nil)
        #expect(MembershipRules.invite(at: .admin, holding: .admin) == nil)
        #expect(MembershipRules.invite(at: .admin, holding: .superadmin) == nil)
        #expect(MembershipRules.invite(at: .read, holding: .write) == .needs(.manage))
        #expect(MembershipRules.invite(at: .read, holding: .none) == .needs(.manage))
        #expect(MembershipRules.invite(at: .superadmin, holding: .superadmin) == .notGrantable)
        #expect(MembershipRules.invite(at: .none, holding: .superadmin) == .notGrantable)
    }

    @Test func changingALevel() {
        #expect(MembershipRules.changeLevel(from: .write, to: .read, ofFounder: false, holding: .manage) == nil)
        #expect(MembershipRules.changeLevel(from: .read, to: .write, ofFounder: false, holding: .manage) == nil)
        #expect(MembershipRules.changeLevel(from: .write, to: .manage, ofFounder: false, holding: .manage)
                == .needs(.admin), "anything at Manage or above, on either side, takes Admin")
        #expect(MembershipRules.changeLevel(from: .manage, to: .write, ofFounder: false, holding: .manage)
                == .needs(.admin))
        #expect(MembershipRules.changeLevel(from: .write, to: .admin, ofFounder: false, holding: .admin) == nil)
        #expect(MembershipRules.changeLevel(from: .admin, to: .read, ofFounder: false, holding: .superadmin) == nil)
        #expect(MembershipRules.changeLevel(from: .write, to: .read, ofFounder: false, holding: .write)
                == .needs(.manage))
        #expect(MembershipRules.changeLevel(from: .superadmin, to: .admin, ofFounder: true, holding: .superadmin)
                == .founder, "the founder's level never changes")
        #expect(MembershipRules.changeLevel(from: .none, to: .read, ofFounder: false, holding: .admin) == .notAMember)
        #expect(MembershipRules.changeLevel(from: .read, to: .superadmin, ofFounder: false, holding: .superadmin)
                == .notGrantable, "nobody is given superadmin")
    }

    @Test func removingAndLeaving() {
        #expect(MembershipRules.remove(.write, ofFounder: false, isSelf: false, holding: .manage) == nil)
        #expect(MembershipRules.remove(.manage, ofFounder: false, isSelf: false, holding: .manage) == .needs(.admin))
        #expect(MembershipRules.remove(.admin, ofFounder: false, isSelf: false, holding: .admin) == nil)
        #expect(MembershipRules.remove(.read, ofFounder: false, isSelf: false, holding: .write) == .needs(.manage))
        #expect(MembershipRules.remove(.superadmin, ofFounder: true, isSelf: false, holding: .admin) == .founder)
        #expect(MembershipRules.remove(.read, ofFounder: false, isSelf: true, holding: .read) == nil,
                "anyone may leave")
        #expect(MembershipRules.remove(.superadmin, ofFounder: true, isSelf: true, holding: .superadmin) == .founder,
                "except the founder, whose group is deleted instead")
        #expect(MembershipRules.remove(.read, ofFounder: false, isSelf: false, holding: .none) == .notAMember)
    }
}
