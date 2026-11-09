import Foundation

/// Keeps the last plan answer in the app's own settings. It holds no secret:
/// only what the plan card shows.
public final class DefaultsPlanCache: PlanCache, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "plan.lastAnswer") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> PlanAnswer? {
        defaults.data(forKey: key).flatMap { try? PlanAnswer.decode($0) }
    }

    public func save(_ answer: PlanAnswer) {
        if let data = try? answer.encoded() { defaults.set(data, forKey: key) }
    }
}
