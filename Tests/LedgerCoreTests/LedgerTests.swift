import Foundation
import Testing
@testable import LedgerCore

final class LedgerTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private var file: URL { directory.appendingPathComponent("book.json") }

    deinit { try? FileManager.default.removeItem(at: directory) }

    @Test
    func testEditDeleteAndUndoAcrossLaunches() throws {
        var book = try LedgerBook(file: file)
        var entry = Entry(kind: .expense, purpose: "Steam", category: "游戏", amount: 298, date: Date())
        try book.save(entry)
        entry.amount = 268
        try book.save(entry)
        try book.delete(entry.id)
        book = try LedgerBook(file: file)
        #expect(book.entries.isEmpty)
        try book.undo()
        #expect(book.entries[entry.id]?.amount == 268)
        try book.undo()
        book = try LedgerBook(file: file)
        #expect(book.entries[entry.id]?.amount == 298)
        #expect(book.history.count == 5)
        try book.undo()
        #expect(book.undoable == nil)
        #expect(book.entries.isEmpty)
    }

    @Test
    func testIndependentEntriesRetryAndBoundaries() throws {
        let start = Date(timeIntervalSince1970: 1000)
        let end = start.addingTimeInterval(100)
        var book = try LedgerBook(file: file)
        var coffee = Entry(kind: .expense, purpose: "咖啡", category: "饮食", amount: 18, date: start)
        try book.save(coffee)
        try book.save(coffee)
        #expect(book.history.count == 1)
        coffee.id = UUID()
        try book.save(coffee)
        try book.save(Entry(kind: .transfer, purpose: "充值", category: "", amount: 2000, date: start))
        try book.save(Entry(kind: .income, purpose: "工资", category: "", amount: 100, date: end))
        let rows = book.records(in: DateInterval(start: start, end: end))
        #expect(rows.count == 3)
        #expect(rows.total(.expense) == 36)
        #expect(rows.total(.income) == 0)
    }

    @Test
    func testFailedWriteAndUnreadableLedger() throws {
        var book = try LedgerBook(file: file)
        try Data([0]).write(to: directory)
        let entry = Entry(kind: .expense, purpose: "测试", category: "", amount: 1, date: Date())
        #expect(throws: (any Error).self) { try book.save(entry) }
        #expect(book.entries.isEmpty)
        #expect(book.history.isEmpty)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([0]).write(to: file)
        #expect(throws: (any Error).self) { try LedgerBook(file: file) }
        #expect(try Data(contentsOf: file) == Data([0]))
    }

    @Test
    func testMoneyInput() {
        #expect(Money.parse(" 0.01 ") == Decimal(1) / 100)
        for invalid in ["", "0", "-12", "1.001", "12xyz", "1e3", "."] {
            #expect(Money.parse(invalid) == nil)
        }
    }
}
