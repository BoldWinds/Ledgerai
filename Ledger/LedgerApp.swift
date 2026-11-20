import SwiftUI

@main
struct LedgerApp: App {
    var body: some Scene {
        WindowGroup { LedgerHome() }
    }
}

private struct LedgerHome: View {
    @State private var book: LedgerBook?
    @State private var error: String?
    @State private var period = BudgetPeriod.month
    @State private var budgetDraft: BudgetDraft?
    @State private var showQuery = false
    @State private var anchor = Date()
    @State private var editing: Entry?
    @State private var showHistory = false
    private let calendar = Calendar(identifier: .gregorian)

    var body: some View {
        NavigationStack {
            Group {
                if let book, let interval = calendar.dateInterval(of: period.component, for: anchor) {
                    report(book, interval)
                } else {
                    Button("重新打开账本", action: open)
                }
            }
            .navigationTitle("我的账本")
            .toolbar {
                if let book {
                    Button { showHistory = true } label: { Label("操作历史", systemImage: "clock") }
                    Button {
                        do { try mutate { try $0.undo() } }
                        catch { self.error = error.localizedDescription }
                    } label: { Label("撤销上次操作", systemImage: "arrow.uturn.backward") }
                    .disabled(book.undoable == nil)
                    Button {
                        editing = Entry(kind: .expense, purpose: "", category: "", amount: 0, date: Date())
                    } label: { Label("记一笔", systemImage: "plus") }
                }
            }
            .sheet(item: $editing) { entry in
                if let book {
                    EntryEditor(entry: entry, book: book,
                            save: { value in try mutate { try $0.save(value) } },
                            delete: { try mutate { try $0.delete(entry.id) } })
                }
            }
            .sheet(item: $budgetDraft) { draft in
                if let book {
                    BudgetEditor(draft: draft, at: anchor, book: book) { name, cycle, parent, amount, date in
                        try mutate {
                            if let budget = draft.budget { try $0.adjustBudget(budget.id, limit: amount, from: date) }
                            else { try $0.addBudget(category: name, period: cycle, parentID: parent, limit: amount, from: date) }
                        }
                    }
                }
            }
            .sheet(isPresented: $showQuery) {
                if let book {
                    BudgetConversation(book: book, date: anchor) { text, selected in
                        try mutate { try $0.answer(text, at: anchor, selected: selected) }
                    }
                }
            }
            .sheet(isPresented: $showHistory) {
                NavigationStack {
                    List((book?.history ?? []).reversed()) { change in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(change.source == .undo ? "撤销操作" : "手动记账").font(.headline)
                            if let budget = change.budgetAfter ?? change.budgetBefore {
                                Text("预算 · " + budget.category)
                                if let before = change.budgetBefore { Text("原额度　" + describeRates(before)) }
                                if let after = change.budgetAfter { Text("新额度　" + describeRates(after)) }
                            }
                            Text(change.time.formatted()).font(.caption)
                            if let before = change.before { Text("原值　" + describe(before)) }
                            if let after = change.after { Text("新值　" + describe(after)) }
                        }
                    }
                    .navigationTitle("操作历史")
                    .toolbar { Button("完成") { showHistory = false } }
                }
            }
            .alert("账本操作失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好") { error = nil }
            } message: { Text(error ?? "") }
            .task { if book == nil { open() } }
        }
    }

    private func describeRates(_ budget: Budget) -> String {
        budget.rates.map { String($0.periodKey) + " 起 " + Money.display($0.amount) }.joined(separator: "，")
    }

    private func describe(_ entry: Entry) -> String {
        [entry.date.formatted(), entry.kind.rawValue, entry.purpose, entry.category, Money.display(entry.amount)]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func open() {
        do {
            let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
            book = try LedgerBook(file: root.appendingPathComponent("Ledger/book.json"))
        } catch { self.error = error.localizedDescription }
    }

    @discardableResult
    private func mutate<T>(_ action: (inout LedgerBook) throws -> T) throws -> T {
        guard var current = book else { throw CocoaError(.fileReadUnknown) }
        let result = try action(&current)
        book = current
        return result
    }

    private func report(_ book: LedgerBook, _ interval: DateInterval) -> some View {
        let rows = book.records(in: interval)
        let expenses = Dictionary(grouping: rows.filter { $0.expenseDelta != 0 }, by: \.category)
        return List {
            Section {
                Picker("查看期间", selection: $period) {
                    ForEach(BudgetPeriod.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                HStack {
                    Button { shift(-1, from: interval.start) } label: { Label("上一期", systemImage: "chevron.left").labelStyle(.iconOnly) }
                    Spacer()
                    Text(period == .month ? anchor.formatted(.dateTime.year().month()) : anchor.formatted(.dateTime.year()))
                    Spacer()
                    Button { shift(1, from: interval.start) } label: { Label("下一期", systemImage: "chevron.right").labelStyle(.iconOnly) }
                }.buttonStyle(.borderless)
                LabeledContent("已记净支出", value: Money.display(rows.netExpense))
                LabeledContent("已记收入", value: Money.display(rows.total(.income)))
                if let first = book.entries.values.map(\.date).min() {
                    Text("记录始于 " + first.formatted(date: .numeric, time: .omitted)).font(.caption)
                }
            }
            Section("预算") {
                Button("手建预算") { budgetDraft = BudgetDraft(budget: nil) }
                Button("查询或调整预算") { showQuery = true }
                ForEach(book.visibleBudgets(on: period)) { budget in
                    Button { budgetDraft = BudgetDraft(budget: budget) } label: {
                        if let balance = book.balance(budget, at: anchor) {
                            BalanceRow(value: balance)
                        } else {
                            Text(budget.category + " · 尚未生效")
                        }
                    }.buttonStyle(.plain)
                }
            }
            if !expenses.isEmpty {
                Section("分类支出") {
                    ForEach(expenses.keys.sorted(), id: \.self) { category in
                        LabeledContent(category, value: Money.display(expenses[category, default: []].netExpense))
                    }
                }
            }
            Section("流水") {
                if rows.isEmpty {
                    Text(book.entries.isEmpty ? "还没有记录" : "本期没有记录").foregroundStyle(.secondary)
                }
                ForEach(rows) { entry in
                    Button { editing = entry } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(entry.purpose)
                                Text([entry.date.formatted(date: .numeric, time: .omitted), entry.kind.rawValue, entry.category]
                                    .filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(Money.display(entry.kind == .reimbursement ? -entry.amount : entry.amount)).monospacedDigit()
                        }
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private func shift(_ count: Int, from start: Date) {
        if let date = calendar.date(byAdding: period.component, value: count, to: start) { anchor = date }
    }
}

private struct EntryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var entry: Entry
    let book: LedgerBook
    var existing: Bool { book.entries[entry.id] != nil }
    @State private var expected: String
    let save: (Entry) throws -> Void
    let delete: () throws -> Void
    @State private var amount: String
    @State private var failure: String?
    @State private var confirmDelete = false

    init(entry: Entry, book: LedgerBook, save: @escaping (Entry) throws -> Void, delete: @escaping () throws -> Void) {
        _entry = State(initialValue: entry)
        _amount = State(initialValue: book.entries[entry.id] != nil ? NSDecimalNumber(decimal: entry.amount).stringValue : "")
        self.book = book
        _expected = State(initialValue: entry.expectedReimbursement.map { NSDecimalNumber(decimal: $0).stringValue } ?? "")
        self.save = save
        self.delete = delete
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("类型", selection: $entry.kind) {
                    ForEach(EntryKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                TextField("用途", text: $entry.purpose)
                TextField("人民币金额", text: $amount)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                if entry.kind == .reimbursement {
                    Picker("关联原支出", selection: $entry.originalID) {
                        Text("请选择").tag(nil as UUID?)
                        ForEach(book.entries.values.filter { $0.kind == .expense && $0.id != entry.id }
                            .sorted { $0.date > $1.date }) { expense in
                            Text(expense.date.formatted(date: .numeric, time: .omitted) + " · " + expense.purpose
                                 + " · " + Money.display(expense.amount)).tag(Optional(expense.id))
                        }
                    }
                    if let id = entry.originalID, let original = book.entries[id] {
                        LabeledContent("冲减分类", value: original.category)
                    }
                } else {
                    TextField("分类", text: $entry.category)
                    if !book.budgets.isEmpty {
                        Menu("选用预算分类") {
                            ForEach(book.budgets.values.sorted { $0.category < $1.category }) { budget in
                                Button(budget.category) { entry.category = budget.category }
                            }
                        }
                    }
                }
                if entry.kind == .expense {
                    TextField("预计报销金额（可选）", text: $expected)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                    ForEach(book.entries.values.filter { $0.originalID == entry.id }.sorted { $0.date < $1.date }) { receipt in
                        LabeledContent("已到账 · " + receipt.date.formatted(date: .numeric, time: .omitted) + " · " + receipt.purpose,
                                       value: Money.display(receipt.amount))
                    }
                }
                DatePicker("发生时间", selection: $entry.date)
                if existing {
                    Button("删除流水", role: .destructive) { confirmDelete = true }
                        .confirmationDialog("删除这笔流水？", isPresented: $confirmDelete) {
                            Button("删除", role: .destructive) { perform(delete) }
                        }
                }
                if let failure { Text(failure).foregroundStyle(.red) }
            }
            .navigationTitle(existing ? "编辑流水" : "记一笔")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard let value = Money.parse(amount) else { failure = LedgerError.invalidEntry.localizedDescription; return }
                        entry.expectedReimbursement = nil
                        if entry.kind == .expense && !expected.isEmpty {
                            guard let estimate = Money.parse(expected) else { failure = "请填写有效的预计报销金额。"; return }
                            entry.expectedReimbursement = estimate
                        }
                        if entry.kind == .reimbursement {
                            if let id = entry.originalID, let original = book.entries[id] {
                                entry.category = original.category
                                if entry.purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    entry.purpose = original.purpose + "报销"
                                }
                            }
                        } else { entry.originalID = nil }
                        entry.amount = value
                        entry.purpose = entry.purpose.trimmingCharacters(in: .whitespacesAndNewlines)
                        if entry.category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { entry.category = "未分类" }
                        perform { try save(entry) }
                    }
                }
            }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action(); dismiss() } catch { failure = error.localizedDescription }
    }
}
