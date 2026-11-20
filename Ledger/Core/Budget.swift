import Foundation

enum BudgetPeriod: String, CaseIterable, Codable {
    case month = "月", year = "年"
    var component: Calendar.Component { self == .month ? .month : .year }

    func key(for date: Date, calendar: Calendar) -> Int {
        let year = calendar.component(.year, from: date)
        return self == .year ? year : year * 100 + calendar.component(.month, from: date)
    }
}

struct Budget: Identifiable, Codable, Equatable {
    struct Rate: Codable, Equatable {
        let periodKey: Int
        let amount: Decimal
    }
    var id = UUID()
    let category: String
    let period: BudgetPeriod
    let parentID: UUID?
    var rates: [Rate]
}

struct BudgetBalance {
    let budget: Budget
    let limit: Decimal
    let rows: [Entry]
    let firstRecord: Date?
    let interval: DateInterval
    var used: Decimal { rows.netExpense }
    var remaining: Decimal { limit - used }
}

extension Entry {
    var expenseDelta: Decimal {
        switch kind {
        case .expense: return amount
        case .reimbursement: return -amount
        default: return 0
        }
    }
}

extension Array where Element == Entry {
    var netExpense: Decimal { reduce(0) { $0 + $1.expenseDelta } }
}

extension LedgerBook {
    mutating func addBudget(category: String, period: BudgetPeriod, parentID: UUID? = nil,
                            limit: Decimal, from date: Date) throws {
        let name = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !budgets.values.contains(where: { $0.category == name }),
              parentID == nil || budgets.values.contains(where: { $0.id == parentID }) else {
            throw LedgerError.invalidBudget
        }
        var budget = Budget(category: name, period: period, parentID: parentID, rates: [])
        try setLimit(limit, for: &budget, from: date)
    }

    mutating func adjustBudget(_ id: UUID, limit: Decimal, from date: Date) throws {
        guard var budget = budgets[id] else { throw LedgerError.invalidBudget }
        try setLimit(limit, for: &budget, from: date)
    }

    private mutating func setLimit(_ limit: Decimal, for budget: inout Budget, from date: Date) throws {
        guard Money.isValid(limit) else { throw LedgerError.invalidBudget }
        let key = budget.period.key(for: date, calendar: calendar)
        budget.rates.removeAll { $0.periodKey == key }
        budget.rates.append(.init(periodKey: key, amount: limit))
        budget.rates.sort { $0.periodKey < $1.periodKey }
        try storeBudget(budget)
    }

    func visibleBudgets(on page: BudgetPeriod) -> [Budget] {
        budgets.values.filter { page == .month || $0.period == .year }.sorted { $0.category < $1.category }
    }

    func balance(_ budget: Budget, at date: Date) -> BudgetBalance? {
        let key = budget.period.key(for: date, calendar: calendar)
        guard let rate = budget.rates.last(where: { $0.periodKey <= key }),
              let interval = calendar.dateInterval(of: budget.period.component, for: date) else { return nil }

        var categories = Set([budget.category])
        var pending = [budget.id]
        while let parent = pending.popLast() {
            for child in budgets.values where child.parentID == parent && categories.insert(child.category).inserted {
                pending.append(child.id)
            }
        }
        let rows = records(in: interval).filter { $0.expenseDelta != 0 && categories.contains($0.category) }
        return BudgetBalance(budget: budget, limit: rate.amount, rows: rows,
                             firstRecord: entries.values.map(\.date).min(), interval: interval)
    }
}
