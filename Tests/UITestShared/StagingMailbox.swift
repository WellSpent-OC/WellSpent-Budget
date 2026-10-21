// What the Mac's and the iPhone's UI tests share for making an account: an
// address no person can own, and the code staging emails to it. Each
// platform's project compiles this folder into its own UI test bundle.
import Foundation
import XCTest
import WellSpentAppCore

/// Staging's test mailbox. Staging keeps the newest message to each address
/// at example.com for 15 minutes, and gives it back to a request bearing the
/// mailbox token. `make ui-test` passes the token to xcodebuild as a
/// TEST_RUNNER_ variable, as it does the accounts, so it is never on a
/// command line. Live has no mailbox.
struct StagingMailbox {
    static let tokenVariable = "WELLSPENT_UI_TEST_MAILBOX_TOKEN"

    let server: String
    let token: String

    /// Skips the test when the token is missing, so a run without it, such
    /// as a pull request from a fork, passes with nothing run.
    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment)
        throws -> StagingMailbox {
        guard let token = environment[tokenVariable], !token.isEmpty else {
            throw XCTSkip("\(tokenVariable) is not set. It reads the codes staging emails to the accounts "
                          + "a test makes; see the Makefile's ui-test target.")
        }
        let server = environment[TestAccounts.serverVariable].flatMap { $0.isEmpty ? nil : $0 }
        return StagingMailbox(server: server ?? AppEnvironment.staging.defaultServerAddress, token: token)
    }

    /// An address no run has used, at example.com, where no person can get
    /// mail, such as "mac-20261021-091502-3f2a-robin@example.com". It has no
    /// plus sign, which a query reads as a space.
    static func freshAddress(_ platform: String, for name: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let tail = UUID().uuidString.prefix(4)
        return "\(platform)-\(formatter.string(from: Date()))-\(tail)-\(name)@example.com".lowercased()
    }

    /// The code in the newest message staging sent to `address`, as
    /// "XXXX-XXXX". Staging emails it just after the request answers, so this
    /// asks again for up to `timeout` seconds. A code equal to `earlier` is
    /// passed over, for a test that asks for a second one. Throws with what
    /// the mailbox last said.
    func code(for address: String, after earlier: String? = nil, timeout: TimeInterval = 15) async throws -> String {
        // Every character but letters and digits encoded, the "@" too.
        let encoded = address.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? address
        guard let url = URL(string: "\(server)/test/mailbox?address=\(encoded)") else {
            throw UITestError("the test mailbox has no address on \(server)")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let deadline = Date().addingTimeInterval(timeout)
        var last = "nothing yet"
        repeat {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
                case 200:
                    let message = try JSONDecoder().decode(Message.self, from: data)
                    if let code = message.code, code != earlier { return code }
                    last = "its newest message, \"\(message.subject)\", has no new code"
                case 401:
                    throw UITestError("the test mailbox turned the token down")
                case 404:
                    last = "nothing kept for that address"
                case let status:
                    last = "the test mailbox answered \(status)"
                }
            } catch let error as URLError {
                last = "staging could not be reached: \(error.localizedDescription)"
            }
            try await Task.sleep(for: .milliseconds(500))
        } while Date() < deadline
        throw UITestError("no code reached \(address) in \(Int(timeout)) seconds: \(last)")
    }

    /// What a test needs of the mailbox's answer. It also holds the text and
    /// when it was sent.
    private struct Message: Decodable {
        let subject: String
        let code: String?
    }
}
