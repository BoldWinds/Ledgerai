import Foundation
import Testing
@testable import LedgerCore

final class BudgetAcceptanceTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private var file: URL { directory.appendingPathComponent("book.json") }
    private let calendar: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }()
    deinit { try? FileManager.default.removeItem(at: directory) }
    private func open() throws -> LedgerBook { try LedgerBook(file: file, calendar: calendar) }
    private func date(_ year: Int, _ month: Int, _ day: Int = 1) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    @Test("A08 下月调额，月页显示年度余额")
    func effectivePeriod() throws {
        let today = date(2026, 11, 18)
        var book = try open()
        try book.addBudget(category: "交通", period: .month, limit: 400, from: today)
        let traffic = try #require(book.budgets.values.first)
        let reply = try book.answer("下月起改成每月 500", at: today, selected: traffic.id)
        guard case .adjusted(let next) = reply else { Issue.record("应返回调额回执"); return }
        #expect(next.limit == 500)
        #expect(next.interval.start == date(2026, 12))
        try book.addBudget(category: "游戏", period: .year, limit: 5200, from: today)
        try book.save(Entry(kind: .expense, purpose: "买游戏", category: "游戏", amount: 600, date: today))
        book = try open()
        let saved = try #require(book.budgets[traffic.id])
        #expect(book.balance(saved, at: today)?.limit == 400)
        #expect(book.balance(saved, at: date(2026, 12))?.limit == 500)
        #expect(book.balance(saved, at: date(2027, 1))?.limit == 500)
        let games = try #require(book.visibleBudgets(on: .month).first { $0.category == "游戏" })
        #expect(book.balance(games, at: today)?.remaining == 4600)
        #expect(book.balance(games, at: today)?.interval.start == date(2026, 1))
    }

    @Test("A09 预计报销、实际到账及双向关联")
    func estimateAndReceipt() throws {
        let today = date(2026, 11, 18)
        var book = try open()
        try book.addBudget(category: "订阅", period: .month, limit: 1000, from: today)
        let budget = try #require(book.budgets.values.first)
        var expense = Entry(kind: .expense, purpose: "订阅费", category: "订阅", amount: 720, date: today)
        try book.save(expense)
        expense.expectedReimbursement = 360
        try book.save(expense)
        #expect(book.balance(budget, at: today)?.used == 720)
        let receipt = Entry(kind: .reimbursement, purpose: "公司报销", category: "订阅", amount: 360,
                            date: date(2026, 11, 25), originalID: expense.id)
        try book.save(receipt)
        book = try open()
        let result = try #require(book.balance(budget, at: today))
        #expect(result.used == 360)
        #expect(result.rows.total(.income) == 0)
        #expect(result.rows.map(\.id) == [receipt.id, expense.id])
        #expect(book.entries[receipt.id]?.originalID == expense.id)
        #expect(book.entries[expense.id]?.expectedReimbursement == 360)
        #expect(throws: LedgerError.self) { try book.delete(expense.id) }
        try book.undo()
        #expect(book.balance(budget, at: today)?.used == 720)
    }

    @Test("A14 到账日冲减，预算、流水与查询一致", arguments: [BudgetPeriod.month, .year])
    func acrossPeriods(period: BudgetPeriod) throws {
        let paid = period == .month ? date(2026, 11, 30) : date(2026, 12, 31)
        let received = period == .month ? date(2026, 12) : date(2027, 1)
        var book = try open()
        try book.addBudget(category: "订阅", period: period, limit: 1000, from: paid)
        let expense = Entry(kind: .expense, purpose: "订阅", category: "订阅", amount: 720, date: paid)
        try book.save(expense)
        try book.save(Entry(kind: .reimbursement, purpose: "到账", category: "订阅", amount: 360,
                            date: received, originalID: expense.id))
        book = try open()
        let budget = try #require(book.budgets.values.first)
        for (date, used, remaining) in [(paid, Decimal(720), Decimal(280)), (received, -360, 1360)] {
            let value = try #require(book.balance(budget, at: date))
            #expect(value.used == used)
            #expect(value.remaining == remaining)
            #expect(book.records(in: value.interval).netExpense == used)
            let question = period == .month ? "这个月花了多少" : "今年花了多少"
            guard case .spending(let interval, let rows) = try book.answer(question, at: date) else {
                Issue.record("应返回期间内的流水"); return
            }
            #expect(interval == value.interval)
            #expect(rows.count == 1)
            #expect(rows.netExpense == used)
        }
    }

    @Test("A17 年中启用，月页、年页和查询共用全年余额及记录起点")
    func midyear() throws {
        let start = date(2026, 11, 18)
        var book = try open()
        try book.addBudget(category: "游戏", period: .year, limit: 5200, from: start)
        try book.save(Entry(kind: .expense, purpose: "买游戏", category: "游戏", amount: 600, date: start))
        book = try open()
        guard case .balance(let reply) = try book.answer("游戏预算还剩多少？", at: start) else {
            Issue.record("应返回预算余额"); return
        }
        var values = [reply]
        for page in [BudgetPeriod.month, .year] {
            let budget = try #require(book.visibleBudgets(on: page).first)
            values.append(try #require(book.balance(budget, at: start)))
        }
        for value in values {
            #expect(value.limit == 5200)
            #expect(value.remaining == 4600)
            #expect(value.firstRecord == start)
        }
    }

    @Test("A12 手建父子预算，纠正原分类同步移动报销")
    func hierarchyAndReclassification() throws {
        let today = date(2026, 11, 18)
        var book = try open()
        try book.addBudget(category: "日常", period: .year, limit: 2000, from: today)
        let parent = try #require(book.budgets.values.first)
        try book.addBudget(category: "交通", period: .month, parentID: parent.id, limit: 400, from: today)
        let child = try #require(book.budgets.values.first { $0.category == "交通" })
        var entry = Entry(kind: .expense, purpose: "车费", category: "交通", amount: 80, date: today)
        try book.save(entry)
        for budget in [parent, child] { #expect(book.balance(budget, at: today)?.used == 80) }
        #expect(book.records(in: try #require(calendar.dateInterval(of: .year, for: today))).netExpense == 80)
        try book.save(Entry(kind: .reimbursement, purpose: "到账", category: "交通", amount: 20,
                            date: today, originalID: entry.id))
        #expect(book.balance(parent, at: today)?.used == 60)
        entry.category = "其他"
        try book.save(entry)
        #expect(book.balance(parent, at: today)?.used == 0)
        try book.undo()
        #expect(book.balance(parent, at: today)?.used == 60)
    }

    @Test("A05 手动改账及撤销后同步重算预算")
    func correctedExpense() throws {
        let today = date(2026, 11, 18)
        var book = try open()
        try book.addBudget(category: "游戏", period: .year, limit: 5200, from: today)
        let budget = try #require(book.budgets.values.first)
        var game = Entry(kind: .expense, purpose: "Steam", category: "游戏", amount: 298, date: today)
        try book.save(game)
        #expect(book.balance(budget, at: today)?.used == 298)
        game.amount = 268
        try book.save(game)
        #expect(book.balance(budget, at: today)?.used == 268)
        try book.undo()
        book = try open()
        #expect(book.balance(budget, at: today)?.used == 298)
    }

    @Test("调额分类有歧义时保持原额度")
    func ambiguousAdjustment() throws {
        let today = date(2026, 11, 18)
        var book = try open()
        for category in ["交通", "交通预算"] {
            try book.addBudget(category: category, period: .month, limit: 400, from: today)
        }
        #expect(throws: BudgetQueryError.self) { try book.answer("下月起交通预算改成每月500", at: today) }
        book = try open()
        #expect(book.history.count == 2)
        for budget in book.budgets.values { #expect(book.balance(budget, at: date(2026, 12))?.limit == 400) }
    }

    @Test("旧账本升级后可调额、重启、撤销并继续使用")
    func legacyJournal() throws {
        let id = UUID()
        let data = """
        {"version":1,"changes":[{"id":"\(UUID())","source":"manual","time":0,"after":{"id":"\(id)","kind":"支出","amount":80,"category":"交通","purpose":"车费","date":0}}]}
        """
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(data.utf8).write(to: file)
        var book = try open()
        let original = try #require(book.entries[id])
        try book.addBudget(category: "交通", period: .month, limit: 400, from: original.date)
        let budget = try #require(book.budgets.values.first)
        try book.adjustBudget(budget.id, limit: 500, from: original.date)
        book = try open()
        try book.undo()
        let restored = try #require(book.budgets[budget.id])
        #expect(book.balance(restored, at: original.date)?.remaining == 320)
        try book.undo()
        book = try open()
        #expect(book.budgets.isEmpty)
        #expect(book.entries[id] == original)
    }
}
