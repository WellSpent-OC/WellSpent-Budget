import Foundation
import Vapor

/// A sliding-window limiter for the endpoints an attacker hammers.
///
/// Sign-in had nothing in front of it, so a password could be guessed as fast as
/// the network allowed. Bcrypt makes each guess expensive for the server as well
/// as the attacker, which means an unthrottled sign-in endpoint is also a way to
/// exhaust the CPU of the box.
///
/// Deliberately in memory. That is correct for one instance and wrong for
/// several: each would keep its own counters, so N instances means N times the
/// allowance. Moving to Redis is the fix, and until then the deployment should
/// stay single-instance. Said plainly here rather than discovered later.
public actor RateLimiter {
    public struct Limit: Sendable {
        public let attempts: Int
        public let window: TimeInterval

        public init(attempts: Int, window: TimeInterval) {
            self.attempts = attempts
            self.window = window
        }

        /// Password guessing. Slow enough to make a dictionary attack useless,
        /// loose enough that a person who forgot their password is not locked out.
        public static let signIn = Limit(attempts: 10, window: 15 * 60)
        /// Account creation, to stop a script filling the table.
        public static let signUp = Limit(attempts: 5, window: 60 * 60)
        /// Invite lookup, which is a guessable 128-bit id but still worth slowing.
        public static let inviteLookup = Limit(attempts: 30, window: 60 * 60)
    }

    private var hits: [String: [Date]] = [:]
    private let clock: @Sendable () -> Date

    public init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
    }

    /// Records an attempt. Returns false when the caller has had enough.
    public func allow(_ key: String, limit: Limit) -> Bool {
        let now = clock()
        let cutoff = now.addingTimeInterval(-limit.window)

        var recent = (hits[key] ?? []).filter { $0 > cutoff }
        guard recent.count < limit.attempts else {
            hits[key] = recent
            return false
        }
        recent.append(now)
        hits[key] = recent
        return true
    }

    /// Drops keys whose attempts have all aged out, so the dictionary does not
    /// grow without bound on a long-running process.
    public func sweep(olderThan window: TimeInterval = 60 * 60) {
        let cutoff = clock().addingTimeInterval(-window)
        for (key, times) in hits {
            let recent = times.filter { $0 > cutoff }
            if recent.isEmpty { hits[key] = nil } else { hits[key] = recent }
        }
    }

    public func count(for key: String) -> Int { hits[key]?.count ?? 0 }
}

extension Application {
    private struct RateLimiterKey: StorageKey {
        typealias Value = RateLimiter
    }

    public var rateLimiter: RateLimiter {
        get {
            if let existing = storage[RateLimiterKey.self] { return existing }
            let created = RateLimiter()
            storage[RateLimiterKey.self] = created
            return created
        }
        set { storage[RateLimiterKey.self] = newValue }
    }
}

extension Request {
    /// The caller's address, preferring the proxy header when one is set.
    ///
    /// Only trust `X-Forwarded-For` when the app actually sits behind a proxy you
    /// control, which is what TRUSTED_PROXY signals. Otherwise a client can send
    /// the header itself and give itself a fresh allowance per request.
    public var callerAddress: String {
        if Environment.get("TRUSTED_PROXY") != nil {
            // The proxy's own view of the client, which a client cannot set:
            // Cloudflare writes CF-Connecting-IP and fly-proxy writes
            // Fly-Client-IP, and both overwrite whatever arrived.
            for name in ["CF-Connecting-IP", "Fly-Client-IP"] {
                if let value = headers.first(name: name)?
                    .trimmingCharacters(in: .whitespaces), !value.isEmpty {
                    return value
                }
            }
            // Otherwise the LAST X-Forwarded-For hop, not the first. Both of
            // those proxies append the address they observed to whatever the
            // client sent, so the last entry is what the proxy saw and the first
            // is attacker-chosen. Reading the first hop, which is what this did,
            // handed anyone a fresh allowance per request by rotating a header.
            if let last = headers.first(name: .xForwardedFor)?
                .split(separator: ",").last?
                .trimmingCharacters(in: .whitespaces), !last.isEmpty {
                return last
            }
        }
        // Not behind a proxy we control. Note that behind one, this is the
        // proxy's own address for every caller, which is one shared bucket and
        // why TRUSTED_PROXY has to be set in that deployment.
        return remoteAddress?.ipAddress ?? "unknown"
    }

    /// Throws 429 when the caller has used up their allowance.
    public func enforceRateLimit(_ limit: RateLimiter.Limit, scope: String) async throws {
        let key = "\(scope):\(callerAddress)"
        guard await application.rateLimiter.allow(key, limit: limit) else {
            throw Abort(.tooManyRequests,
                        reason: "Too many attempts. Try again in a few minutes.")
        }
    }
}
