import Testing
import Foundation
@testable import WellSpentAppCore
import WellSpentCrypto
import WellSpentKeyStore
import WellSpentModel
import WellSpentStore
import WellSpentSync

/// One person's computer on a shared in-memory server. Its Undo bar and its
/// automatic sync wait an hour, so nothing here races the clock: every sync
/// in these tests is one the test asks for.
@MainActor
private struct Person {
    let transport: StubReadableTransport
    let sync: SyncCoordinator
    let workspace: Workspace
    var model: AppModel { workspace.model }
    var store: Store { sync.store }

    /// A new account, its address confirmed, or with `again` another
    /// computer of an account that exists.
    init(_ email: String, on server: InMemoryReadableServer, again: Bool = false) async throws {
        let store = Store(database: try WellSpentDatabase.inMemory())
        let transport = StubReadableTransport(server: server)
        let sync = SyncCoordinator(store: store, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults(),
                                   makeTransport: { _ in transport })
        self.transport = transport
        self.sync = sync
        workspace = Workspace(model: AppModel(store: store, undoWindow: .seconds(3600)), sync: sync,
                              autoSync: AutoSync(sync: sync, quietPeriod: .seconds(3600), interval: .seconds(3600)))
        if again {
            try await sync.signIn(email: email, password: "a-long-password")
        } else {
            try await sync.signUp(email: email, password: "a-long-password")
            try await sync.verifyEmail(code: try #require(server.lastCode(for: email, purpose: .verify)))
        }
    }

    /// The row this person sees in a budget, as the list draws it.
    func row(_ merchant: String, in budget: BudgetID) -> BudgetScreen.Row? {
        model.selectedBudget = budget
        guard let summary = model.summary(for: budget) else { return nil }
        return BudgetScreen(summary: summary, model: model, me: sync.userID).rows.first { $0.merchant == merchant }
    }

    func stored(_ id: RecordID) throws -> Transaction { try #require(try store.transaction(id)) }
}

/// Robin's Household, with Groceries and Eating out, and “Hilltop Grocery”,
/// $142.08, in Groceries. Leslie joins at Add and adds “Costco”, $28.63.
/// Robin then moves her to `level`, and both sync.
@MainActor
private struct Household {
    let server: InMemoryReadableServer
    let robin: Person
    let leslie: Person
    let group: GroupID
    let groceries: BudgetID
    let eatingOut: BudgetID
    let hilltop: RecordID
    let costco: RecordID

    /// With `robinsName` empty, Robin sets no name for the group, and the
    /// list says "A member".
    init(leslieAt level: AccessLevel = .manage, robinsName: String = "Robin") async throws {
        let server = InMemoryReadableServer()
        let robin = try await Person("robin@example.com", on: server)
        let group = try #require(robin.model.addGroup(named: "Household"))
        let groceries = try #require(robin.model.addBudget(named: "Groceries", limit: .dollars(500), in: group))
        let eatingOut = try #require(robin.model.addBudget(named: "Eating out", limit: .dollars(200), in: group))
        robin.model.selectedBudget = groceries
        robin.model.addTransaction(merchant: "Hilltop Grocery", amount: Money(minorUnits: 14208), date: Date(),
                                   note: "")
        let hilltop = try #require(robin.model.transactions.first).id
        let link = try await robin.sync.share(group: group, groupName: "Household", level: .write,
                                              historyAccess: .all, myName: robinsName)

        let leslie = try await Person("leslie@example.com", on: server)
        try await leslie.sync.join(link, myName: "Leslie")
        leslie.model.selectedBudget = groceries
        leslie.model.addTransaction(merchant: "Costco", amount: Money(minorUnits: 2863), date: Date(), note: "")
        let costco = try #require(leslie.model.transactions.first { $0.merchant == "Costco" }).id
        await leslie.sync.syncAll()
        await robin.sync.syncAll()
        if level != .write {
            try await robin.sync.setLevel(level, of: try #require(leslie.sync.userID), in: group)
            await leslie.sync.syncAll()
            await robin.sync.syncAll()
        }
        (self.server, self.robin, self.leslie) = (server, robin, leslie)
        (self.group, self.groceries, self.eatingOut, self.hilltop, self.costco)
            = (group, groceries, eatingOut, hilltop, costco)
    }

    func syncBoth() async {
        await leslie.sync.syncAll()
        await robin.sync.syncAll()
    }

    /// Whether the server takes a change to an entry from this person,
    /// sent straight to it, past every check the app makes first.
    func serverTakesAChange(to id: RecordID, from person: Person) async throws -> Bool {
        let stored = try #require(server.records(in: group).first { $0.id == id })
        var entry = try RecordCodec.decoder.decode(Transaction.self, from: Data(stored.body.utf8))
        entry.note = "changed"
        let record = WireRecord(id: id, type: .transaction, budgetID: entry.budgetID, lamport: stored.lamport + 1,
                                clientID: DeviceID(), isDeleted: false,
                                body: String(decoding: try RecordCodec.encoder.encode(entry), as: UTF8.self))
        guard let result = try? await person.transport.push([record], group: group) else { return false }
        return result.accepted.contains(id)
    }
}

@Suite("Changing and deleting transactions, between two people", .serialized)
@MainActor
struct EntrySharingTests {
    // MARK: - Who may change what

    /// Ties the app's rule to the server's: at each level, on an entry of
    /// their own and on someone else's, a change is offered exactly where
    /// the stand-in server takes one. Robin is the Owner each time.
    @Test(arguments: [AccessLevel.read, .write, .manage, .admin])
    func eachLevelIsOfferedAChangeExactlyWhereTheServerTakesOne(level: AccessLevel) async throws {
        let home = try await Household(leslieAt: level)
        for person in [home.leslie, home.robin] {
            for id in [home.hilltop, home.costco] {
                let entry = try person.stored(id)
                let offered = person.model.access(to: entry).mayChange
                let taken = try await home.serverTakesAChange(to: id, from: person)
                #expect(offered == taken, "\(level), \(entry.merchant)")
            }
        }
        let onRobins = home.leslie.model.access(to: try home.leslie.stored(home.hilltop)).mayChange
        #expect(onRobins == (level >= .manage), "Robin's entry takes Manage")
    }

    /// Someone who added an entry and was then moved down to View.
    @Test func someoneMovedDownToViewIsToldTheyCanOnlyView() async throws {
        let home = try await Household(leslieAt: .read)

        let editor = try #require(EntryEditor(model: home.leslie.model, entry: home.costco))

        #expect(editor.isReadOnly && !editor.offersDelete)
        #expect(editor.readOnlyLine == "You can only view this group now, so you can't change what you added.")
        let row = try #require(home.leslie.row("Costco", in: home.groceries))
        #expect(MainScreen(workspace: home.leslie.workspace).entryMenu(row).isEmpty)
    }

    // MARK: - Change, move, delete and undo

    /// The change reaches Robin, and the entry is still his.
    @Test func aChangeReachesTheOtherPersonAndKeepsWhoAddedIt() async throws {
        let home = try await Household(leslieAt: .manage)
        let editor = try #require(EntryEditor(model: home.leslie.model, entry: home.hilltop))
        editor.amountText = "124.08"
        #expect(editor.save())

        await home.syncBoth()

        let robins = try #require(home.robin.row("Hilltop Grocery", in: home.groceries))
        #expect(robins.amount == "$124.08")
        #expect(robins.addedBy == "You", "still Robin's")
        #expect(home.leslie.row("Hilltop Grocery", in: home.groceries)?.addedBy == "Robin")
        #expect(home.robin.model.summary(for: home.groceries)?.spent == Money(minorUnits: 12408 + 2863))
    }

    /// Robin sees the entry in Eating out and not in Groceries.
    @Test func aMoveReachesTheOtherPerson() async throws {
        let home = try await Household(leslieAt: .manage)
        let editor = try #require(EntryEditor(model: home.leslie.model, entry: home.hilltop))
        editor.budgetID = home.eatingOut
        #expect(editor.save())

        await home.syncBoth()

        #expect(home.robin.row("Hilltop Grocery", in: home.groceries) == nil)
        #expect(home.robin.row("Hilltop Grocery", in: home.eatingOut)?.amount == "$142.08")
        #expect(home.robin.model.summary(for: home.eatingOut)?.spent == Money(minorUnits: 14208))
    }

    /// The delete reaches Robin, and Undo brings it back for both, with
    /// the same details and the same Added by.
    @Test func aDeleteReachesTheOtherPersonAndUndoBringsItBackForBoth() async throws {
        let home = try await Household(leslieAt: .manage)
        #expect(home.leslie.model.deleteEntry(home.hilltop) == .saved)
        await home.syncBoth()
        #expect(home.robin.row("Hilltop Grocery", in: home.groceries) == nil)

        home.leslie.model.undoDelete()
        await home.syncBoth()

        let robins = try #require(home.robin.row("Hilltop Grocery", in: home.groceries))
        let leslies = try #require(home.leslie.row("Hilltop Grocery", in: home.groceries))
        #expect(robins.amount == "$142.08" && leslies.amount == "$142.08")
        #expect(robins.addedBy == "You" && leslies.addedBy == "Robin")
    }

    /// Whichever is later wins, and both computers agree on which.
    @Test func anEditAndADeleteAtAboutTheSameTimeEndTheSameWayForBoth() async throws {
        let home = try await Household(leslieAt: .manage)
        #expect(home.robin.model.updateEntry(home.hilltop, EntryChange(amount: Money(minorUnits: 15000))) == .saved)
        #expect(home.leslie.model.deleteEntry(home.hilltop) == .saved)

        await home.syncBoth()
        await home.syncBoth()

        let his = try home.robin.stored(home.hilltop)
        let hers = try home.leslie.stored(home.hilltop)
        let servers = try #require(home.server.records(in: home.group).first { $0.id == home.hilltop })
        #expect(his.isDeleted == hers.isDeleted && hers.isDeleted == servers.isDeleted)
        #expect(his.amount == hers.amount)
    }

    // MARK: - Deleted while open

    @Test func savingAnEntryRobinDeletedMeanwhileSavesNothingAndSaysWhoDeletedIt() async throws {
        let home = try await Household(leslieAt: .manage)
        let saving = try #require(EntryEditor(model: home.leslie.model, entry: home.hilltop))
        let deleting = try #require(EntryEditor(model: home.leslie.model, entry: home.hilltop))
        saving.amountText = "124.08"
        #expect(home.robin.model.deleteEntry(home.hilltop) == .saved)
        await home.robin.sync.syncAll()
        await home.leslie.sync.syncAll()

        #expect(!saving.save())

        #expect(saving.result == .deletedMeanwhile(by: .someone(name: "Robin")))
        #expect(saving.isReadOnly && !saving.offersDelete)
        #expect(saving.readOnlyLine == "Robin deleted this while you had it open.")
        #expect(try home.leslie.stored(home.hilltop).isDeleted, "it does not come back")
        #expect(try home.leslie.store.outboxCount(in: home.group) == 0, "nothing to send")
        deleting.askDelete()
        #expect(deleting.pendingDelete == nil)
        #expect(deleting.readOnlyLine == "Robin deleted this while you had it open.")
    }

    // Scenario EDIT-12
    // The no-name line: Share and Join both ask for a name, so no UI test
    // can make a deleter without one.
    @Test func savingAnEntryDeletedBySomeoneWithNoNameSaysSomeone() async throws {
        let home = try await Household(leslieAt: .manage, robinsName: "")
        let editor = try #require(EntryEditor(model: home.leslie.model, entry: home.hilltop))
        editor.note = "milk"
        home.robin.model.deleteEntry(home.hilltop)
        await home.robin.sync.syncAll()
        await home.leslie.sync.syncAll()

        #expect(!editor.save())

        #expect(editor.readOnlyLine == "Someone deleted this while you had it open.")
    }

    @Test func savingAnEntryDeletedOnYourOtherComputerSaysSo() async throws {
        let home = try await Household(leslieAt: .manage)
        let editor = try #require(EntryEditor(model: home.leslie.model, entry: home.hilltop))
        editor.note = "milk"
        let laptop = try await Person("leslie@example.com", on: home.server, again: true)
        await laptop.sync.syncAll()
        #expect(laptop.model.deleteEntry(home.hilltop) == .saved)
        await laptop.sync.syncAll()
        await home.leslie.sync.syncAll()

        #expect(!editor.save())

        #expect(editor.result == .deletedMeanwhile(by: .you))
        #expect(editor.readOnlyLine == "You deleted this on another computer while it was open here.")
    }

    // MARK: - A change replaced, or refused

    /// Leslie's change waits offline while Robin's newer one reaches the
    /// server. Hers is replaced, and only she is told.
    @Test func aChangeThatLosesWhileWaitingLeavesANoteForItsAuthorOnly() async throws {
        let home = try await Household(leslieAt: .manage)
        #expect(home.leslie.model.updateEntry(home.hilltop, EntryChange(amount: Money(minorUnits: 12408))) == .saved)
        await home.robin.sync.syncAll()
        home.robin.model.updateEntry(home.hilltop, EntryChange(amount: Money(minorUnits: 15500)))
        home.robin.model.updateEntry(home.hilltop, EntryChange(amount: Money(minorUnits: 15000)))
        home.robin.model.updateEntry(home.hilltop, EntryChange(note: "for the party"))
        await home.robin.sync.syncAll()

        await home.leslie.sync.syncAll()

        let hers = try #require(home.leslie.row("Hilltop Grocery", in: home.groceries))
        #expect(hers.notice == "Your change didn't go through.")
        #expect(hers.amount == "$150.00" && hers.note == "for the party", "already the version everyone sees")
        await home.robin.sync.syncAll()
        #expect(home.robin.row("Hilltop Grocery", in: home.groceries)?.notice == nil,
                "the person whose change won sees no note")

        let editor = try #require(EntryEditor(model: home.leslie.model, entry: home.hilltop))
        #expect(editor.noticeLine == "Your last change to this didn't go through. This is the version everyone sees.")
        #expect(home.leslie.row("Hilltop Grocery", in: home.groceries)?.notice == nil, "opened, so the line goes")
        await home.leslie.sync.syncAll()
        #expect(home.leslie.row("Hilltop Grocery", in: home.groceries)?.notice == nil)
    }

    /// Leslie changes Robin's entry at Manage, and is moved down to Add
    /// before it syncs. The change is refused, the row goes back to the
    /// server's version in the same sync, and the note says so.
    @Test func aChangeRefusedAfterAMoveDownToAddLeavesANote() async throws {
        let home = try await Household(leslieAt: .manage)
        #expect(home.leslie.model.updateEntry(home.hilltop, EntryChange(amount: Money(minorUnits: 12408))) == .saved)
        try await home.robin.sync.setLevel(.write, of: try #require(home.leslie.sync.userID), in: home.group)

        await home.leslie.sync.syncAll()

        let hers = try #require(home.leslie.row("Hilltop Grocery", in: home.groceries))
        #expect(hers.notice == "Your change didn't go through.")
        #expect(hers.amount == "$142.08", "already the version everyone sees")
        await home.robin.sync.syncAll()
        #expect(home.robin.row("Hilltop Grocery", in: home.groceries)?.amount == "$142.08")
        #expect(home.robin.row("Hilltop Grocery", in: home.groceries)?.notice == nil)
    }

    /// At View the app sends nothing, so a waiting change is
    /// neither refused nor replaced. It stays here, and no note shows.
    @Test func atViewAWaitingChangeLeavesNoNote() async throws {
        let home = try await Household(leslieAt: .write)
        #expect(home.leslie.model.updateEntry(home.costco, EntryChange(note: "bulk")) == .saved)
        try await home.robin.sync.setLevel(.read, of: try #require(home.leslie.sync.userID), in: home.group)

        await home.leslie.sync.syncAll()

        let hers = try #require(home.leslie.row("Costco", in: home.groceries))
        #expect(hers.notice == nil)
        #expect(hers.note == "bulk", "kept on this computer only")
        await home.robin.sync.syncAll()
        #expect(home.robin.row("Costco", in: home.groceries)?.note == "")
    }

    // MARK: - Importing again

    /// Leslie imports a statement, then she deletes one line and Robin the
    /// other. Imported again through the review, both lines count as
    /// already imported, the import finishes, and both stay deleted.
    @Test func aStatementImportedAgainLeavesLinesEitherPersonDeletedDeleted() async throws {
        let home = try await Household(leslieAt: .manage)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wellspent-\(UUID().uuidString).csv")
        try """
        Date,Description,Amount
        10/02/2026,"TRADER JOES #123",-54.20
        10/03/2026,"CORNER BAKERY",-12.00
        """.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let review = ImportReviewScreen(model: home.leslie.model)
        home.leslie.model.selectedBudget = home.groceries
        home.leslie.model.prepareImport(from: url)
        review.choose(home.groceries, for: 0)
        review.choose(home.groceries, for: 1)
        review.commit()
        await home.syncBoth()
        func line(_ bank: String, of person: Person) throws -> Transaction {
            try #require(try person.store.transactions(in: home.groceries).first { $0.note == bank })
        }
        let joes = try line("TRADER JOES #123", of: home.leslie)
        let bakery = try line("CORNER BAKERY", of: home.robin)
        #expect(home.leslie.model.deleteEntry(joes.id) == .saved)
        #expect(home.robin.model.deleteEntry(bakery.id) == .saved)
        await home.syncBoth()
        await home.syncBoth()

        home.leslie.model.prepareImport(from: url)
        #expect(review.rows.map(\.status) == ["Already imported", "Already imported"])
        review.commit()

        #expect(home.leslie.model.errorMessage == nil)
        #expect(try home.leslie.stored(joes.id).isDeleted && home.leslie.stored(bakery.id).isDeleted)
        #expect(try home.leslie.store.transactions(in: home.groceries).map(\.merchant).sorted()
                == ["Costco", "Hilltop Grocery"])
    }

    /// Leslie files a statement line in Groceries, and Robin deletes
    /// Groceries before her next sync. The line is left live in a deleted
    /// budget on both computers, where no list shows it. Imported again, it
    /// is offered again and files in Eating out with no error. After that it
    /// counts as imported for both of them.
    @Test func aLineLeftInADeletedBudgetIsOfferedAgainThenCountsForBoth() async throws {
        let home = try await Household(leslieAt: .manage)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wellspent-\(UUID().uuidString).csv")
        try """
        Date,Description,Amount
        10/02/2026,"TRADER JOES #123",-54.20
        """.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let review = ImportReviewScreen(model: home.leslie.model)
        home.leslie.model.selectedBudget = home.groceries
        home.leslie.model.prepareImport(from: url)
        review.choose(home.groceries, for: 0)
        review.commit()
        let first = try #require(try home.leslie.store.transactions(in: home.groceries)
            .first { $0.note == "TRADER JOES #123" })
        home.robin.model.deleteBudget(home.groceries)
        await home.robin.sync.syncAll()
        await home.syncBoth()
        for person in [home.leslie, home.robin] {
            #expect(try person.stored(first.id).isDeleted == false, "left live")
            #expect(try person.store.budget(home.groceries)?.isDeleted == true, "in a deleted budget")
        }

        home.leslie.model.selectedBudget = home.eatingOut
        home.leslie.model.prepareImport(from: url)
        #expect(review.rows.map(\.status) == ["Needs a budget"])
        review.choose(home.eatingOut, for: 0)
        review.commit()

        #expect(home.leslie.model.errorMessage == nil)
        #expect(try home.leslie.store.transactions(in: home.eatingOut).map(\.note) == ["TRADER JOES #123"])
        await home.syncBoth()
        for person in [home.leslie, home.robin] {
            person.model.selectedBudget = home.eatingOut
            person.model.prepareImport(from: url)
            #expect(ImportReviewScreen(model: person.model).rows.map(\.status) == ["Already imported"])
            person.model.cancelImport()
        }
    }
}
