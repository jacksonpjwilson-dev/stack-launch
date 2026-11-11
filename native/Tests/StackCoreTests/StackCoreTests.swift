import XCTest
@testable import StackCore

private struct MockProvider: FinancialProvider {
    let id = "mock"
    var pages: [String: SyncPage]
    func page(accountID: String, cursor: String?) async throws -> SyncPage {
        guard let page = pages[cursor ?? "initial"] else { throw CoreError.disconnected }
        return page
    }
}
final class StackCoreTests: XCTestCase {
    func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s + "T12:00:00Z")! }
    func entry(_ id: String = "one", amount: String = "12.34", kind: TransactionKind = .expense, provider: String = "mock", pending: Bool = false, pendingID: String? = nil) -> Entry {
        Entry(id: id, accountID: "a", provider: provider, merchant: "Synthetic merchant", amount: Decimal(string: amount)!, date: date("2026-10-10"), kind: kind, pending: pending, pendingID: pendingID)
    }
    func ledger() -> Ledger { var ledger = Ledger(); ledger.accounts = [Account(id: "a", name: "Synthetic account")]; return ledger }
    var start: Date { date("2026-10-01") }; var end: Date { date("2026-11-01") }
    func testWidgetValuesAreOptInAndCacheContainsNoTransactions() throws {
        var original = ledger(); original.entries = [entry(amount: "123.45")]
        let hidden = WidgetSnapshot(ledger: original, valuesVisible: false)
        XCTAssertNil(hidden.spending); XCTAssertNil(hidden.remainingBudget); XCTAssertNil(hidden.savings)
        let payload = String(decoding: try JSONEncoder().encode(hidden), as: UTF8.self)
        XCTAssertFalse(payload.contains("123.45")); XCTAssertFalse(payload.contains("Synthetic merchant")); XCTAssertFalse(payload.contains("accountID"))
        let visible = WidgetSnapshot(ledger: original, valuesVisible: true, now: date("2026-10-20"))
        XCTAssertEqual(visible.spending, Decimal(string: "123.45"))
    }
    func testStrictLocalizedMoneyInput() {
        XCTAssertEqual(MoneyInput.parse("12,34", locale: Locale(identifier: "fr_CA")), Decimal(string: "12.34"))
        XCTAssertNil(MoneyInput.parse("12.34junk", locale: Locale(identifier: "en_CA")))
        XCTAssertNil(MoneyInput.parse("0.001", locale: Locale(identifier: "en_CA")))
        XCTAssertNil(MoneyInput.parse("-2", locale: Locale(identifier: "en_CA")))
    }
    func testDecimalPrecision() {
        let entries = [entry("1", amount: "0.10"), entry("2", amount: "0.20")]
        XCTAssertEqual(Finance.spending(entries, start: start, end: end), Decimal(string: "0.30"))
    }
    func testTransfersAndPendingExcluded() {
        XCTAssertEqual(Finance.spending([entry(kind: .transfer), entry("p", pending: true)], start: start, end: end), 0)
        XCTAssertEqual(Finance.income([entry(kind: .transfer)], start: start, end: end), 0)
    }
    func testRefundsReduceSpendingNotIncome() {
        XCTAssertEqual(Finance.spending([entry(amount: "10"), entry("r", amount: "3", kind: .refund)], start: start, end: end), 7)
        XCTAssertEqual(Finance.income([entry(kind: .refund)], start: start, end: end), 0)
    }
    func testCurrencyIsolation() {
        var other = entry(); other.currency = "USD"
        XCTAssertEqual(Finance.spending([other], start: start, end: end), 0)
    }
    func testPeriodEndIsExclusive() {
        var last = entry(); last.date = end
        XCTAssertEqual(Finance.spending([last], start: start, end: end), 0)
    }
    func testUserExclusion() {
        var e = entry(); e.excluded = true
        XCTAssertEqual(Finance.spending([e], start: start, end: end), 0)
    }
    func testIncome() { XCTAssertEqual(Finance.income([entry(kind: .income), entry("t", kind: .transfer)], start: start, end: end), Decimal(string: "12.34")) }
    func testRulePriorityAndOverride() {
        var e = entry(); e.merchant = "COSTCO"
        XCTAssertEqual(Finance.category(e, rules: []), "Groceries")
        XCTAssertEqual(Finance.category(e, rules: [CategoryRule(contains: "costco", category: "Fuel", priority: 4)]), "Fuel")
        e.categoryOverride = "Shopping"
        XCTAssertEqual(Finance.category(e, rules: []), "Shopping")
    }
    func testSplitValidationAndBudget() throws {
        var e = entry(amount: "10"); e.splits = [Split(category: "Fuel", amount: 4), Split(category: "Groceries", amount: 6)]
        try Finance.validate(e)
        XCTAssertEqual(Finance.spending([e], start: start, end: end, category: "Fuel"), 4)
        e.splits.append(Split(category: "Other", amount: 1))
        XCTAssertThrowsError(try Finance.validate(e))
    }
    func testInvalidEntryRejected() { XCTAssertThrowsError(try Finance.validate(entry(amount: "0"))) }
    func testPaginationAndCursorPersistence() async throws {
        let provider = MockProvider(pages: ["initial": SyncPage(entries: [entry("1")], nextCursor: "p1", hasMore: true), "p1": SyncPage(entries: [entry("2")], nextCursor: "done", hasMore: false)])
        let result = try await Synchronizer.synchronize(ledger(), accountID: "a", provider: provider)
        XCTAssertEqual(result.entries.count, 2); XCTAssertEqual(result.sync["mock:a"]?.cursor, "done")
        let data = try JSONEncoder().encode(result)
        XCTAssertEqual(try JSONDecoder().decode(Ledger.self, from: data).sync["mock:a"]?.cursor, "done")
    }
    func testIncrementalDedupAndEditsSurvive() async throws {
        var original = ledger(); var old = entry(); old.notes = "Private user note"; old.categoryOverride = "Fitness"; old.kindOverride = .transfer; original.entries = [old]; original.sync["mock:a"] = SyncState(cursor: "previous")
        let provider = MockProvider(pages: ["previous": SyncPage(entries: [entry(amount: "18")], nextCursor: "new", hasMore: false)])
        let result = try await Synchronizer.synchronize(original, accountID: "a", provider: provider)
        XCTAssertEqual(result.entries.count, 1); XCTAssertEqual(result.entries[0].amount, 18); XCTAssertEqual(result.entries[0].notes, old.notes); XCTAssertEqual(result.entries[0].categoryOverride, "Fitness"); XCTAssertEqual(result.entries[0].accountingKind, .transfer)
    }
    func testPendingBecomesPosted() async throws {
        var original = ledger(); var pending = entry("pending", pending: true); pending.notes = "Keep me"; original.entries = [pending]
        let provider = MockProvider(pages: ["initial": SyncPage(entries: [entry("posted", pendingID: "pending")], removedIDs: ["pending"], nextCursor: "done", hasMore: false)])
        let result = try await Synchronizer.synchronize(original, accountID: "a", provider: provider)
        XCTAssertEqual(result.entries.count, 1); XCTAssertEqual(result.entries.first?.id, "posted"); XCTAssertEqual(result.entries.first?.notes, "Keep me")
    }
    func testPendingRemovedOnEarlierPagePreservesEdits() async throws {
        var original = ledger(); var pending = entry("pending", pending: true); pending.notes = "Keep across pages"; original.entries = [pending]
        let provider = MockProvider(pages: [
            "initial": SyncPage(entries: [], removedIDs: ["pending"], nextCursor: "p1", hasMore: true),
            "p1": SyncPage(entries: [entry("posted", pendingID: "pending")], nextCursor: "done", hasMore: false)
        ])
        let result = try await Synchronizer.synchronize(original, accountID: "a", provider: provider)
        XCTAssertEqual(result.entries.count, 1); XCTAssertEqual(result.entries[0].notes, "Keep across pages")
        XCTAssertNotNil(result.entries[0].syncedAt)
    }
    func testChangedProviderAmountPreservesSplitsForReview() async throws {
        var original = ledger(); var old = entry(amount: "10"); old.splits = [Split(category: "Fuel", amount: 10)]; original.entries = [old]
        let provider = MockProvider(pages: ["initial": SyncPage(entries: [entry(amount: "12")], nextCursor: "done", hasMore: false)])
        let result = try await Synchronizer.synchronize(original, accountID: "a", provider: provider)
        XCTAssertEqual(result.entries[0].splits, old.splits); XCTAssertTrue(result.entries[0].splitsNeedReview)
        XCTAssertEqual(Finance.spending(result.entries, start: start, end: end, category: "Other"), 12)
        XCTAssertEqual(Finance.spending(result.entries, start: start, end: end, category: "Fuel"), 0)
    }
    func testProviderRemoval() async throws {
        var original = ledger(); original.entries = [entry()]
        let provider = MockProvider(pages: ["initial": SyncPage(entries: [], removedIDs: ["one"], nextCursor: "done", hasMore: false)])
        let result = try await Synchronizer.synchronize(original, accountID: "a", provider: provider)
        XCTAssertTrue(result.entries.isEmpty)
    }
    func testPageFailureDoesNotAdvanceOriginalCursor() async {
        var original = ledger(); original.sync["mock:a"] = SyncState(cursor: "old")
        let provider = MockProvider(pages: ["old": SyncPage(entries: [entry()], nextCursor: "missing", hasMore: true)])
        do { _ = try await Synchronizer.synchronize(original, accountID: "a", provider: provider); XCTFail("Expected failure") } catch { }
        XCTAssertTrue(original.entries.isEmpty); XCTAssertEqual(original.sync["mock:a"]?.cursor, "old")
    }
    func testCrossAccountPageRejected() async {
        var e = entry(); e.accountID = "unauthorized"
        let provider = MockProvider(pages: ["initial": SyncPage(entries: [e], nextCursor: "done", hasMore: false)])
        do { _ = try await Synchronizer.synchronize(ledger(), accountID: "a", provider: provider); XCTFail("Expected boundary rejection") } catch { }
    }
    func testDisconnectedAccountRejected() async {
        do { _ = try await Synchronizer.synchronize(Ledger(), accountID: "missing", provider: MockProvider(pages: [:])); XCTFail("Expected disconnect") } catch { }
    }
    func testRepeatedCursorRejected() async {
        let provider = MockProvider(pages: ["initial": SyncPage(entries: [], nextCursor: "same", hasMore: true), "same": SyncPage(entries: [], nextCursor: "same", hasMore: true)])
        do { _ = try await Synchronizer.synchronize(ledger(), accountID: "a", provider: provider); XCTFail("Expected pagination failure") } catch { }
    }
    func testDuplicateCSVImportAndIdenticalPurchases() throws {
        let csv = "Date,Merchant,Amount\n2026-10-10,Sample,-4.25\n2026-10-10,Sample,-4.25\n"
        let preview = try CSV.preview(csv, mapping: CSVMapping(date: "Date", merchant: "Merchant", amount: "Amount"), accountID: "a")
        XCTAssertEqual(preview.count, 2); XCTAssertNotEqual(preview[0].id, preview[1].id)
        let first = CSV.merge(preview, into: ledger()); let second = CSV.merge(preview, into: first)
        XCTAssertEqual(second.entries.count, 2)
    }
    func testCSVQuotedFieldsAndDebitCredit() throws {
        let csv = "Date,Merchant,Debit,Credit\r\n2026-10-10,\"Sample, Inc\",2.50,\r\n2026-10-11,Payroll,,100.00"
        let rows = try CSV.preview(csv, mapping: CSVMapping(date: "Date", merchant: "Merchant", debit: "Debit", credit: "Credit"), accountID: "a")
        XCTAssertEqual(rows[0].merchant, "Sample, Inc"); XCTAssertEqual(rows[0].kind, .expense); XCTAssertEqual(rows[1].kind, .income)
    }
    func testCSVInvalidInputDoesNotPartiallyImport() {
        XCTAssertThrowsError(try CSV.preview("Date,Merchant,Amount\n2026-10-10,Sample,-2\ninvalid,Other,-3", mapping: CSVMapping(date: "Date", merchant: "Merchant", amount: "Amount"), accountID: "a"))
        XCTAssertThrowsError(try CSV.rows("Date,Merchant\n\"unterminated"))
    }
    func testCSVFormulaEscaping() { var e = entry(); e.correction = "=1+1"; XCTAssertTrue(CSV.export([e]).contains("'=1+1")) }
    func testOfflinePersistence() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("ledger.json"); var original = ledger(); original.entries = [entry()]
        try LedgerFile.save(original, to: url)
        XCTAssertEqual(try LedgerFile.load(url).entries, original.entries)
    }
    func testCorruptPersistenceThrows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("broken".utf8).write(to: url)
        XCTAssertThrowsError(try LedgerFile.load(url))
    }
    func testRecurringCandidateRequiresEvidence() {
        var a = entry("1", amount: "10"), b = entry("2", amount: "10"), c = entry("3", amount: "12")
        a.date = date("2026-08-10"); b.date = date("2026-09-10"); c.date = date("2026-10-10")
        XCTAssertTrue(Recurrence.candidates([a,b]).isEmpty)
        let candidates = Recurrence.candidates([a,b,c]); XCTAssertEqual(candidates.count, 1); XCTAssertEqual(candidates.first?.priceIncreased, true)
    }
}
