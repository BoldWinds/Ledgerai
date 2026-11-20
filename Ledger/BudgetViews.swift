import SwiftUI

struct BudgetDraft: Identifiable {
    let id = UUID()
    let budget: Budget?
}

struct BudgetEditor: View {
    @Environment(\.dismiss) private var dismiss
    let budget: Budget?
    let parents: [Budget]
    let save: (String, BudgetPeriod, UUID?, Decimal, Date) throws -> Void
    @State private var category: String
    @State private var period: BudgetPeriod
    @State private var amount: String
    @State private var effective: Date
    @State private var parentID: UUID?
    @State private var error: String?

    init(draft: BudgetDraft, at date: Date, book: LedgerBook,
         save: @escaping (String, BudgetPeriod, UUID?, Decimal, Date) throws -> Void) {
        budget = draft.budget
        parents = book.budgets.values.sorted { $0.category < $1.category }
        self.save = save
        _category = State(initialValue: draft.budget?.category ?? "")
        _period = State(initialValue: draft.budget?.period ?? .month)
        _effective = State(initialValue: date)
        _parentID = State(initialValue: draft.budget?.parentID)
        let limit = draft.budget.flatMap { book.balance($0, at: date)?.limit }
        _amount = State(initialValue: limit.map { NSDecimalNumber(decimal: $0).stringValue } ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                if budget == nil {
                    TextField("预算分类", text: $category)
                    Picker("周期", selection: $period) {
                        ForEach(BudgetPeriod.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Picker("父预算", selection: $parentID) {
                        Text("无").tag(nil as UUID?)
                        ForEach(parents) { Text($0.category).tag(Optional($0.id)) }
                    }
                } else {
                    LabeledContent("预算分类", value: category)
                }
                TextField("每" + period.rawValue + "额度（元）", text: $amount)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                DatePicker("从所在" + period.rawValue + "起生效", selection: $effective, displayedComponents: .date)
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(budget == nil ? "手建预算" : "调整额度")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do {
                            guard let value = Money.parse(amount) else { throw LedgerError.invalidBudget }
                            try save(category, period, parentID, value, effective)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }
        }
    }
}

struct BalanceRow: View {
    let value: BudgetBalance

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value.budget.category + " · " + value.budget.period.rawValue + "预算").font(.headline)
            let prefix = value.budget.period == .year ? "全年剩余 " : "本月剩余 "
            Text(prefix + Money.display(value.remaining)).monospacedDigit()
            if value.budget.period == .year {
                Text(value.firstRecord.map { "按已记录流水计算 · 记录始于 " + $0.formatted(date: .numeric, time: .omitted) }
                     ?? "按已记录流水计算 · 还没有记录").font(.caption)
            }
            Text("额度 " + Money.display(value.limit) + "　已用 " + Money.display(value.used)
                 + "（" + (value.used / value.limit).formatted(.percent.precision(.fractionLength(0...1))) + "）")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

struct BudgetConversation: View {
    @Environment(\.dismiss) private var dismiss
    let book: LedgerBook
    let date: Date
    let ask: (String, UUID?) throws -> BudgetQuery
    @State private var question = ""
    @State private var selected: UUID?
    @State private var answer: BudgetQuery?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("查询基准日 " + date.formatted(date: .numeric, time: .omitted)) {
                    Picker("当前预算", selection: $selected) {
                        Text("未指定").tag(nil as UUID?)
                        ForEach(book.budgets.values.sorted { $0.category < $1.category }) {
                            Text($0.category).tag(Optional($0.id))
                        }
                    }
                    TextField("这个月花了多少", text: $question)
                    Button("发送") {
                        do {
                            answer = try ask(question, selected)
                            failure = nil
                        } catch {
                            failure = error.localizedDescription
                            answer = nil
                        }
                    }.disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let failure { Text(failure).foregroundStyle(.red) }
                if let answer {
                    switch answer {
                    case .adjusted(let value):
                        Section("调额生效 " + value.interval.start.formatted(date: .numeric, time: .omitted)) {
                            BalanceRow(value: value)
                        }
                    case .balance(let value):
                        Section("预算余额") { BalanceRow(value: value) }
                        detail(value.rows)
                    case .spending(let interval, let rows):
                        Section("已记净支出") {
                            Text(Money.display(rows.netExpense))
                            Text(interval.start.formatted(date: .numeric, time: .omitted) + " 至 "
                                 + interval.end.addingTimeInterval(-1).formatted(date: .numeric, time: .omitted))
                        }
                        detail(rows)
                    }
                }
            }
            .navigationTitle("预算与消费查询")
            .toolbar { Button("完成") { dismiss() } }
        }
    }

    private func detail(_ rows: [Entry]) -> some View {
        Section("构成流水") {
            if rows.isEmpty { Text("本期没有记录") }
            ForEach(rows) { entry in
                LabeledContent(entry.date.formatted(date: .numeric, time: .omitted) + " · " + entry.purpose,
                               value: Money.display(entry.expenseDelta))
            }
        }
    }
}
