import Foundation
import Fluent
import FluentPostgresDriver
import FluentSQLiteDriver
import Vapor

/// Deletes tokens whose expiry has passed.
func purgeExpiredTokens(_ app: Application) async throws {
    let removed = try await TokenRow.query(on: app.db)
        .filter(\.$expiresOn < Date())
        .delete()
    _ = removed
    app.logger.info("purged expired tokens")
}

/// Which WellSpent server this is. `/health` reports it, so an app can check that
/// it is talking to the server it was built for before anyone signs in.
public enum ServerEnvironment: String, Sendable, Equatable {
    case live, staging, development

    /// `WELLSPENT_ENVIRONMENT` when it is set. Otherwise live in production and
    /// development everywhere else, so the live server needs no new setting. A
    /// name that is not one of the three stops the server: a staging server that
    /// starts up calling itself live is the mistake this exists to catch.
    public static func resolve(_ variable: String?,
                               appEnvironment: Vapor.Environment) throws -> ServerEnvironment {
        guard let variable, !variable.isEmpty else {
            return appEnvironment == .production ? .live : .development
        }
        guard let named = ServerEnvironment(rawValue: variable) else {
            throw Abort(.internalServerError,
                        reason: "WELLSPENT_ENVIRONMENT must be live, staging or development, not \(variable)")
        }
        return named
    }
}

struct ServerEnvironmentKey: StorageKey {
    typealias Value = ServerEnvironment
}

public func configure(_ app: Application) async throws {
    let serverEnvironment = try ServerEnvironment.resolve(
        Environment.get("WELLSPENT_ENVIRONMENT"), appEnvironment: app.environment)
    app.storage[ServerEnvironmentKey.self] = serverEnvironment
    app.logger.notice("environment: \(serverEnvironment.rawValue)")

    // Three ways to get a database, in order of precedence.
    //
    // DATABASE_URL wins everywhere, so production and staging are explicit.
    // Tests get in-memory SQLite. Development gets a SQLite file, so
    // `swift run WellSpentServer` works on a machine with no Postgres, which is
    // what local integration testing against the Swift client needs.
    //
    // Production no longer falls back to guessing localhost. A server that
    // silently points at the wrong database is worse than one that refuses to
    // start.
    if let url = Environment.get("DATABASE_URL") {
        try app.databases.use(.postgres(url: url), as: .psql)
        app.logger.notice("database: postgres from DATABASE_URL")
    } else if app.environment == .testing {
        app.databases.use(.sqlite(.memory), as: .sqlite)
    } else if app.environment == .development {
        let path = Environment.get("WELLSPENT_SQLITE_PATH") ?? "wellspent-dev.sqlite"
        app.databases.use(.sqlite(.file(path)), as: .sqlite)
        app.logger.notice("database: sqlite at \(path). Set DATABASE_URL to use postgres.")
    } else {
        throw Abort(.internalServerError,
                    reason: "DATABASE_URL is not set. Refusing to start rather than guess.")
    }

    // Dates cross the wire in both directions and one of them is inside a
    // signature: MembershipLogEntry.at is covered by the author's signature,
    // truncated to whole seconds. If the two sides disagree about how a Date is
    // encoded, every signature fails to verify and the cause is not obvious.
    // Pinning ISO 8601 on both sides makes that a non-issue.
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    ContentConfiguration.global.use(encoder: encoder, for: .json)
    ContentConfiguration.global.use(decoder: decoder, for: .json)

    app.migrations.add(CreateSchema())
    app.migrations.add(AddGroupMaxLamport())
    app.migrations.add(AddReadableSync())

    // Migrating at boot is fine for one instance and wrong for several: two
    // starting at once will race on the same schema.
    //
    // Read this before setting SKIP_AUTO_MIGRATE on a database that does not
    // exist yet: `purgeExpiredTokens` below runs either way, and it queries a
    // `tokens` table the skipped migration would have created. The process dies
    // in `configure` before `WellSpentServer migrate` ever gets a chance to run.
    // Skipping only works against a database whose schema is already there.
    if Environment.get("SKIP_AUTO_MIGRATE") == nil {
        try await app.autoMigrate()
    } else {
        app.logger.notice("SKIP_AUTO_MIGRATE set; run `WellSpentServer migrate` yourself")
    }

    // A sealed record is a few hundred bytes; a receipt blob is not. This caps a
    // single push rather than letting one request hold a gigabyte of memory.
    app.routes.defaultMaxBodySize = "16mb"

    // Expired tokens are dead weight and a liability: a leaked database is worth
    // less when it holds fewer live sessions. Once here at boot, then hourly on
    // the Housekeeping timer below, which also bounds the rate limiter.
    app.databases.default(to: Environment.get("DATABASE_URL") != nil ? .psql : .sqlite)
    try await purgeExpiredTokens(app)
    try await purgeExpiredSessions(on: app.db)
    try await purgeExpiredEmailCodes(on: app.db)
    app.lifecycle.use(Housekeeping())

    // Both refuse to start a production server that is missing what readable
    // accounts need, rather than run one that cannot confirm an address or
    // reset a password.
    try app.configureMailer()
    // Staging's UI tests read the codes it emails to test addresses here.
    // Never on live, whatever is set.
    let mailboxVariable = Environment.get("TEST_MAILBOX_TOKEN")
    if let token = try TestMailboxChoice.token(server: serverEnvironment, variable: mailboxVariable) {
        try app.enableTestMailbox(token: token)
    } else if serverEnvironment == .live, !(mailboxVariable ?? "").isEmpty {
        app.logger.warning("TEST_MAILBOX_TOKEN is set on live and ignored: live never has a test mailbox")
    }
    try app.configureEmailCodeKey()
    // /api/v1 is gone, so LEGACY_API no longer opens or closes anything.
    if Environment.get("LEGACY_API") != nil {
        app.logger.notice("LEGACY_API is no longer read: /api/v1 is gone and asks old apps to update")
    }

    try registerRoutes(app)
}

/// The hourly work this file used to promise and nothing did.
///
/// Two jobs on one timer. Expired tokens are dead weight and a liability. The
/// rate limiter keeps one entry per caller address for the life of the process,
/// which is a slow leak in something meant to run for months, and this
/// deployment is exactly that: one long-lived container.
final class Housekeeping: LifecycleHandler, @unchecked Sendable {
    private let interval: Duration
    private let sweepWindow: TimeInterval
    private var task: Task<Void, Never>?

    init(every interval: Duration = .seconds(3600), sweepWindow: TimeInterval = 3600) {
        self.interval = interval
        self.sweepWindow = sweepWindow
    }

    func didBootAsync(_ app: Application) async throws {
        task = Task { [interval, sweepWindow] in
            while !Task.isCancelled {
                // Sleep first: configure() has already purged once by now.
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                // The limiter first: it is in memory and instant, so it is
                // never held up behind the database work.
                await app.rateLimiter.sweep(olderThan: sweepWindow)
                try? await purgeExpiredTokens(app)
                if Task.isCancelled { return }
                try? await purgeExpiredSessions(on: app.db)
                if Task.isCancelled { return }
                try? await purgeExpiredEmailCodes(on: app.db)
            }
        }
    }

    func shutdownAsync(_ application: Application) async {
        task?.cancel()
        task = nil
    }
}
