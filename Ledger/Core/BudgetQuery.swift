import Foundation

/// Local phrases supported by the budget and net-spending query field.
enum BudgetQuery {
    case balance(BudgetBalance)
    case spending(interval: DateInterval, rows: [Entry])
    case adjusted(BudgetBalance)
}

enum BudgetQueryError: LocalizedError {
    case unsupported, selectBudget, inactive
    var errorDescription: String? {
        switch self {
        case .unsupported: return "可以问「这个月花了多少」「游戏预算还剩多少」，或输入「下月起交通预算改成每月 500」。"
        case .selectBudget: return "请指定一个已有的预算分类。"
        case .inactive: return "该预算在所选期间尚未生效。"
        }
    }
}

extension LedgerBook {
    mutating func answer(_ input: String, at date: Date, selected: UUID? = nil) throws -> BudgetQuery {
        let text = input.filter { !$0.isWhitespace }.trimmingCharacters(in: CharacterSet(charactersIn: "？?。"))
        let monthly = ["这个月花了多少", "本月花了多少", "这个月净支出", "本月净支出"]
        let yearly = ["今年花了多少", "本年花了多少", "今年净支出", "本年净支出"]
        if monthly.contains(text) || yearly.contains(text) {
            let component: Calendar.Component = monthly.contains(text) ? .month : .year
            guard let interval = calendar.dateInterval(of: component, for: date) else { throw BudgetQueryError.unsupported }
            return .spending(interval: interval, rows: records(in: interval).filter { $0.expenseDelta != 0 })
        }
        if let match = text.wholeMatch(of: #/(?:下月|下个月)起(.*?)改成每月([0-9]+(?:\.[0-9]{1,2})?)/#) {
            let name = String(match.1)
            let matches = budgets.values.filter { budget in
                if name.isEmpty { return selected == budget.id }
                return name == budget.category || name == budget.category + "预算"
            }
            guard matches.count == 1, let budget = matches.first, budget.period == .month else {
                throw BudgetQueryError.selectBudget
            }
            guard let limit = Money.parse(String(match.2)),
                  let next = calendar.date(byAdding: .month, value: 1, to: date) else { throw LedgerError.invalidBudget }
            try adjustBudget(budget.id, limit: limit, from: next)
            guard let updated = budgets[budget.id], let value = balance(updated, at: next) else { throw BudgetQueryError.inactive }
            return .adjusted(value)
        }
        let suffixes = ["预算全年还剩多少", "预算还剩多少", "预算剩多少", "预算余额", "全年还剩多少"]
        for budget in budgets.values where suffixes.contains(where: { text == budget.category + $0 }) {
            guard let value = balance(budget, at: date) else { throw BudgetQueryError.inactive }
            return .balance(value)
        }
        throw BudgetQueryError.unsupported
    }
}
