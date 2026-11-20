import Foundation

enum EntryKind: String, CaseIterable, Codable {
    case expense = "支出"
    case reimbursement = "报销到账"
    case income = "收入"
    case transfer = "自有账户互转"
}

struct Entry: Identifiable, Codable, Equatable {
    var id = UUID()
    var kind: EntryKind
    var purpose: String
    var category: String
    var amount: Decimal
    var date: Date
    var originalID: UUID?
    var expectedReimbursement: Decimal?
}

enum Money {
    static func parse(_ input: String) -> Decimal? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"\A[0-9]{1,15}(\.[0-9]{1,2})?\z"#, options: .regularExpression) != nil,
              let amount = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")),
              amount > 0 else { return nil }
        return amount
    }

    static func isValid(_ amount: Decimal) -> Bool {
        parse(NSDecimalNumber(decimal: amount).stringValue) == amount
    }

    static func display(_ amount: Decimal) -> String {
        amount.formatted(.currency(code: "CNY").locale(Locale(identifier: "zh_CN")))
    }
}

struct Change: Identifiable, Codable {
    enum Source: String, Codable { case manual, undo }
    let id: UUID
    let time: Date
    let source: Source
    let before: Entry?
    let after: Entry?
    let reverses: UUID?
    var budgetBefore: Budget?
    var budgetAfter: Budget?
}

struct LedgerBook {
    private struct Journal: Codable {
        var version = 1
        var changes: [Change] = []
    }

    private let file: URL
    private var journal: Journal
    private(set) var entries: [UUID: Entry] = [:]
    private(set) var budgets: [UUID: Budget] = [:]
    let calendar: Calendar
    var history: [Change] { journal.changes }

    init(file: URL, calendar: Calendar = Calendar(identifier: .gregorian)) throws {
        self.calendar = calendar
        self.file = file
        do {
            journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: file))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            journal = Journal()
        }
        guard (1...2).contains(journal.version) else { throw CocoaError(.fileReadCorruptFile) }
        for change in journal.changes {
            try apply(change)
        }
    }

    private mutating func apply(_ change: Change) throws {
        if let id = change.budgetBefore?.id ?? change.budgetAfter?.id {
            guard budgets[id] == change.budgetBefore,
                  change.budgetAfter == nil || change.budgetAfter?.id == id else {
                throw CocoaError(.fileReadCorruptFile)
            }
            budgets[id] = change.budgetAfter
        } else {
            guard let id = change.before?.id ?? change.after?.id,
                  entries[id] == change.before,
                  change.after == nil || change.after?.id == id else {
                throw CocoaError(.fileReadCorruptFile)
            }
            entries[id] = change.after
        }
    }

    var undoable: Change? {
        let reversed = Set(history.compactMap(\.reverses))
        return history.last { $0.source == .manual && !reversed.contains($0.id) }
    }

    mutating func save(_ entry: Entry) throws {
        guard !entry.purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Money.isValid(entry.amount) else { throw LedgerError.invalidEntry }
        if let expected = entry.expectedReimbursement {
            guard entry.kind == .expense, Money.isValid(expected) else { throw LedgerError.invalidEntry }
        }
        if entry.kind == .reimbursement {
            guard let id = entry.originalID, id != entry.id, entries[id]?.kind == .expense else {
                throw LedgerError.missingOriginal
            }
        } else if entry.originalID != nil { throw LedgerError.invalidEntry }
        if entry.kind != .expense && hasReceipts(entry.id) { throw LedgerError.linkedReceipts }
        let before = entries[entry.id]
        if before != entry { try record(before: before, after: entry) }
    }

    mutating func delete(_ id: UUID) throws {
        guard !hasReceipts(id) else { throw LedgerError.linkedReceipts }
        if let before = entries[id] { try record(before: before, after: nil) }
    }

    mutating func undo() throws {
        if let change = undoable {
            try record(before: change.after, after: change.before, reverses: change.id,
                       budgetBefore: change.budgetAfter, budgetAfter: change.budgetBefore)
        }
    }

    private func hasReceipts(_ id: UUID) -> Bool {
        entries.values.contains { $0.originalID == id }
    }

    mutating func storeBudget(_ budget: Budget) throws {
        if budget != budgets[budget.id] {
            try record(before: nil, after: nil, budgetBefore: budgets[budget.id], budgetAfter: budget)
        }
    }

    private mutating func record(before: Entry?, after: Entry?, reverses: UUID? = nil,
                                 budgetBefore: Budget? = nil, budgetAfter: Budget? = nil) throws {
        let change = Change(id: UUID(), time: Date(), source: reverses == nil ? .manual : .undo,
                            before: before, after: after, reverses: reverses,
                            budgetBefore: budgetBefore, budgetAfter: budgetAfter)
        var next = self
        try next.apply(change)
        next.journal.version = 2
        next.journal.changes.append(change)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next.journal).write(to: file, options: .atomic)
        self = next
    }

    func records(in interval: DateInterval) -> [Entry] {
        entries.values.filter { $0.date >= interval.start && $0.date < interval.end }
            .map { entry in
                var row = entry
                if let id = entry.originalID, let original = entries[id] { row.category = original.category }
                return row
            }
            .sorted { ($0.date, $0.id.uuidString) > ($1.date, $1.id.uuidString) }
    }
}

enum LedgerError: LocalizedError {
    case invalidEntry
    case invalidBudget, missingOriginal, linkedReceipts
    var errorDescription: String? {
        switch self {
        case .invalidEntry: return "请填写用途和有效金额，金额最多保留两位小数。"
        case .invalidBudget: return "请使用唯一的预算分类、有效额度和已有的父预算。"
        case .missingOriginal: return "请选择报销对应的原支出。"
        case .linkedReceipts: return "这笔支出已有报销到账。请先处理关联的到账流水。"
        }
    }
}

extension Array where Element == Entry {
    func total(_ kind: EntryKind) -> Decimal {
        filter { $0.kind == kind }.reduce(Decimal.zero) { $0 + $1.amount }
    }
}
