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

public func configure(_ app: Application) async throws {
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
    app.lifecycle.use(Housekeeping())

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
                try? await purgeExpiredTokens(app)
                await app.rateLimiter.sweep(olderThan: sweepWindow)
            }
        }
    }

    func shutdownAsync(_ application: Application) async {
        task?.cancel()
        task = nil
    }
}
