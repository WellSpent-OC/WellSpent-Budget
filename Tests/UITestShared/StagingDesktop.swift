// What the Mac's and the iPhone's UI tests share for an account made on
// another device: a connection to staging with no window. Each platform's
// project compiles this folder into its own UI test bundle.
import Foundation
import WellSpentAppCore
import WellSpentSync

/// Robin's other computer: a connection to the server, checked to be staging
/// before any password goes to it, as the app checks.
enum StagingDesktop {
    static func connect(at address: String) async throws -> ReadableHTTPTransport {
        guard let url = URL(string: address) else { throw UITestError("\(address) is not a server address") }
        if let why = AppEnvironment.staging.refusal(ofServerAt: url) { throw UITestError(why) }
        let desktop = ReadableHTTPTransport(baseURL: url)
        if let why = AppEnvironment.staging.refusal(ofServerSaying: try await desktop.health().environment) {
            throw UITestError(why)
        }
        return desktop
    }
}
