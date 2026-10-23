import Foundation
import WellSpentAppCore
import WellSpentCrypto
import WellSpentModel
import WellSpentSync

/// Credentials already used by the app under test, kept only in this test
/// process. Never printed or written to the app's data folder.
struct UITestSignedInAccount {
    let server: String
    let email: String
    let password: String
}

/// An already-sent link made through the retained production sync API.
/// This is setup for legacy-link, permissions and shared-data scenarios. It
/// does not replace the UI checks for sending an email invitation.
@MainActor
enum LegacyInviteFixture {
    static func make(account: UITestSignedInAccount, groupName: String, myName: String,
                     role: InviteRole, history: HistoryAccess = .all) async throws -> InviteLink {
        let fixture = try SecondAccount(server: account.server,
            settingsSuite: "app.wellspent.uitest.legacy.\(UUID().uuidString)")
        do {
            try await fixture.signIn(email: account.email, password: account.password)
            // The UI may have just queued the group's first sync.
            let deadline = Date().addingTimeInterval(30)
            var group = try fixture.sync.store.groups().first { $0.name == groupName }
            while group == nil, Date() < deadline {
                try await Task.sleep(for: .seconds(1))
                try await fixture.syncAll()
                group = try fixture.sync.store.groups().first { $0.name == groupName }
            }
            guard let group else { throw UITestError("the fixture group did not reach the server") }
            let link = try await fixture.sync.share(group: group.id, groupName: group.name,
                level: role.level, historyAccess: history, myName: myName)
            await fixture.cleanUp()
            return link
        } catch {
            await fixture.cleanUp()
            throw error
        }
    }
}
