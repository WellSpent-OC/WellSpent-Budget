// SPDX-License-Identifier: MIT
import Foundation
import Testing
import WarTableCore

@Suite("WarTable policy and core types")
struct WarTablePolicyTests {
    @Test func policyRoleOversight() {
        #expect(WTPolicy.oversees(.owner))
        #expect(WTPolicy.oversees(.admin))
        #expect(WTPolicy.oversees(.manager))
        #expect(!WTPolicy.oversees(.member))
        #expect(!WTPolicy.oversees(nil))
    }

    @Test func policyRolePermissions() {
        let ownerPerms = WTPolicy.permissions(.owner)
        #expect(ownerPerms.contains(.manageInstallation))
        #expect(ownerPerms.contains(.authorizeTask))
        #expect(ownerPerms.contains(.managePeople))
        #expect(ownerPerms.contains(.manageAgents))
        #expect(ownerPerms.contains(.readChat))

        let adminPerms = WTPolicy.permissions(.admin)
        #expect(!adminPerms.contains(.manageInstallation))
        #expect(adminPerms.contains(.managePeople))
        #expect(adminPerms.contains(.manageAgents))

        let managerPerms = WTPolicy.permissions(.manager)
        #expect(!managerPerms.contains(.managePeople))
        #expect(managerPerms.contains(.manageAgents))

        let memberPerms = WTPolicy.permissions(.member)
        #expect(!memberPerms.contains(.manageAgents))
        #expect(memberPerms.contains(.readChat))
        #expect(memberPerms.contains(.sendMessage))

        let nilPerms = WTPolicy.permissions(nil)
        #expect(nilPerms == [.readChat, .sendMessage, .readContext, .proposeTask])
    }

    @Test func policyPathValidationAndPermits() {
        #expect(WTPolicy.validPath("Sources/Foo.swift"))
        #expect(WTPolicy.validPath("README.md"))
        #expect(!WTPolicy.validPath("/absolute/path"))
        #expect(!WTPolicy.validPath("foo\\bar"))
        #expect(!WTPolicy.validPath(""))
        #expect(!WTPolicy.validPath("foo/../bar"))
        #expect(!WTPolicy.validPath("foo/\u{0007}/bar"))

        #expect(WTPolicy.permits("Sources/Foo.swift", within: ["Sources"]))
        #expect(WTPolicy.permits("Sources/Sub/Foo.swift", within: ["Sources"]))
        #expect(WTPolicy.permits("Sources", within: ["Sources"]))
        #expect(WTPolicy.permits("Sources/Foo.swift", within: ["."]))
        #expect(!WTPolicy.permits("Tests/FooTests.swift", within: ["Sources"]))
        #expect(!WTPolicy.permits("/Sources/Foo.swift", within: ["Sources"]))
    }

    @Test func policyLocalWriteAndMentions() {
        #expect(WTPolicy.isLocalWrite(.editBranch))
        #expect(WTPolicy.isLocalWrite(.runChecks))
        #expect(WTPolicy.isLocalWrite(.writeHandoff))
        #expect(!WTPolicy.isLocalWrite(.readChat))
        #expect(!WTPolicy.isLocalWrite(.merge))

        #expect(WTPolicy.mentions("Robin", in: "Hello @Robin, can you review?"))
        #expect(WTPolicy.mentions("robin", in: "Hello @ROBIN!"))
        #expect(!WTPolicy.mentions("Robin", in: "Hello Robin"))
        #expect(!WTPolicy.mentions("Robin", in: "email@robinhood.example"))
    }

    @Test func coreTypesCodableAndIdentifiable() throws {
        let installID = UUID(), groupID = UUID(), ownerID = UUID()
        let installation = WTInstallation(id: installID, groupID: groupID, ownerID: ownerID, isEnabled: true, revision: 1)
        #expect(installation.id == installID)
        #expect(installation.groupID == groupID)
        #expect(installation.ownerID == ownerID)
        #expect(installation.isEnabled)
        #expect(installation.revision == 1)

        let personID = UUID()
        let person = WTPerson(id: personID, displayName: "AgentOne", kind: .agent, role: .admin)
        #expect(person.id == personID)
        #expect(person.displayName == "AgentOne")
        #expect(person.kind == .agent)
        #expect(person.role == .admin)

        let agentID = UUID()
        let agent = WTAgent(id: agentID, name: "AgentOne", provider: "local", machine: "test-runner", status: .connected)
        #expect(agent.id == agentID)
        #expect(agent.name == "AgentOne")
        #expect(agent.provider == "local")
        #expect(agent.machine == "test-runner")
        #expect(agent.status == .connected)
        #expect(agent.executionProfile == "chat-only")

        let encoded = try JSONEncoder().encode(installation)
        let decoded = try JSONDecoder().decode(WTInstallation.self, from: encoded)
        #expect(decoded == installation)
    }
}
