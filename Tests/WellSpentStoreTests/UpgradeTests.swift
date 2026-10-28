import Foundation
import Testing
import WellSpentModel
import WellSpentStore

/// The upgrade every tester's Mac makes: a database written by an earlier
/// release opens in this one with everything in it. Each file in Fixtures/ was
/// written by that release's own code (Fixtures/README.md says how), so a new
/// migration that loses or bends anything fails here, before it ships.
@Suite("Upgrading from an earlier release")
struct UpgradeTests {
    /// 0.1.0, the first TestFlight builds. It ran migrations v1 to v10, so
    /// opening it runs every migration added since.
    @Test func aDatabaseFrom0_1_0OpensWithEveryGroupBudgetAndTransaction() throws {
        let store = try Self.open("wellspent-0.1.0")

        let groups = try store.groups()
        #expect(groups.map(\.name).sorted() == ["Home", "Road Trip"])
        let home = try #require(groups.first { $0.name == "Home" })
        let trip = try #require(groups.first { $0.name == "Road Trip" })

        let homeBudgets = try store.budgets(in: home.id)
        #expect(homeBudgets.map(\.name).sorted() == ["Eating Out", "Groceries"])
        let groceries = try #require(homeBudgets.first { $0.name == "Groceries" })
        let eatingOut = try #require(homeBudgets.first { $0.name == "Eating Out" })
        #expect(groceries.limit == Money(minorUnits: 50_000))
        #expect(eatingOut.limit == Money(minorUnits: 20_000))
        let fuel = try #require(try store.budgets(in: trip.id).first { $0.name == "Fuel" })
        #expect(fuel.limit == Money(minorUnits: 30_000))

        let shopping = try store.transactions(in: groceries.id)
        #expect(shopping.map(\.merchant).sorted() == ["Hilltop Grocery", "Market"])
        let hilltop = try #require(shopping.first { $0.merchant == "Hilltop Grocery" })
        // Spending is stored negative, as a budget counts money going out.
        #expect(hilltop.amount == Money(minorUnits: -4_200))
        #expect(hilltop.note == "weekly shop")
        #expect(hilltop.date == Date(timeIntervalSince1970: 1_760_000_000))
        #expect(try store.transactions(in: eatingOut.id).map(\.amount) == [Money(minorUnits: -1_875)])
        // 0.1.0 knew no kinds. Its rows were all money out, so they are all spending.
        #expect(shopping.allSatisfy { $0.kind == .spending })
        #expect(home.claimedBy == nil)

        // A transaction deleted in 0.1.0 stays deleted.
        #expect(try store.transactions(in: fuel.id).map(\.merchant) == ["Shell"])
        #expect(try store.transactions(in: fuel.id, includeDeleted: true).count == 2)

        // Changes waiting to sync are still waiting, so signing in later
        // still sends them.
        #expect(try store.outboxCount(in: home.id) == 6)
        #expect(try store.outboxCount(in: trip.id) == 4)
    }

    /// Opening it again finds nothing more to do and changes nothing.
    @Test func openingAnUpgradedDatabaseAgainChangesNothing() throws {
        let folder = try Self.copy("wellspent-0.1.0")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("budget.sqlite")
        let first = Store(database: try WellSpentDatabase.open(at: file))
        let before = try first.groups().map(\.name)

        let second = Store(database: try WellSpentDatabase.open(at: file))
        #expect(try second.groups().map(\.name) == before)
    }

    /// A copy of the fixture in a folder of its own, so the file in the
    /// package is never changed.
    private static func copy(_ name: String) throws -> URL {
        let fixture = try #require(Bundle.module.url(forResource: name, withExtension: "sqlite",
                                                     subdirectory: "Fixtures"))
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wellspent-upgrade-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: folder.appendingPathComponent("budget.sqlite"))
        return folder
    }

    private static func open(_ name: String) throws -> Store {
        let folder = try copy(name)
        return Store(database: try WellSpentDatabase.open(at: folder.appendingPathComponent("budget.sqlite")))
    }
}
