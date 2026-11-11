import Foundation

public enum TransactionKind: String, Codable, CaseIterable {
  case expense, income, transfer, refund
}
public struct Account: Identifiable, Codable, Equatable {
  public var id: String
  public var name: String
  public var currency = "CAD"
  public var balance: Decimal = 0
  public var available: Decimal?
  public init(id: String = UUID().uuidString, name: String) {
    self.id = id
    self.name = name
  }
}
public struct Entry: Identifiable, Codable, Equatable {
  public var id: String
  public var accountID: String
  public var provider: String
  public var merchant: String
  public var originalDescription: String
  /// Positive magnitude; kind determines accounting treatment.
  public var amount: Decimal
  public var currency: String
  public var date: Date
  public var kind: TransactionKind
  public var kindOverride: TransactionKind?
  public var accountingKind: TransactionKind { kindOverride ?? kind }
  public var pending: Bool
  public var pendingID: String?
  public var syncedAt: Date?
  public var correction: String?
  public var categoryOverride: String?
  public var notes = ""
  public var tags: [String] = []
  public var excluded = false
  public var splits: [Split] = []
  public var splitsNeedReview: Bool {
    !splits.isEmpty && splits.reduce(Decimal(0)) { $0 + $1.amount } != amount
  }
  public var displayMerchant: String { correction ?? merchant }
  public init(
    id: String = UUID().uuidString, accountID: String, provider: String = "manual",
    merchant: String, amount: Decimal, currency: String = "CAD", date: Date = Date(),
    kind: TransactionKind = .expense, pending: Bool = false, pendingID: String? = nil
  ) {
    self.id = id
    self.accountID = accountID
    self.provider = provider
    self.merchant = merchant
    self.originalDescription = merchant
    self.amount = amount
    self.currency = currency
    self.date = date
    self.kind = kind
    self.pending = pending
    self.pendingID = pendingID
  }
  public var key: String { provider + ":" + accountID + ":" + id }
}
public struct Split: Codable, Equatable {
  public var category: String
  public var amount: Decimal
  public init(category: String, amount: Decimal) {
    self.category = category
    self.amount = amount
  }
}
public struct CategoryRule: Identifiable, Codable {
  public var id = UUID()
  public var contains: String
  public var category: String
  public var priority: Int
  public init(contains: String, category: String, priority: Int = 0) {
    self.contains = contains
    self.category = category
    self.priority = priority
  }
}
public struct Budget: Identifiable, Codable {
  public var id = UUID()
  public var category: String
  public var limit: Decimal
  public var start: Date
  public var end: Date
  public init(category: String, limit: Decimal, start: Date, end: Date) {
    self.category = category
    self.limit = limit
    self.start = start
    self.end = end
  }
}
public struct Goal: Identifiable, Codable {
  public var id = UUID()
  public var name: String
  public var target: Decimal
  public var contributions: [Contribution] = []
  public var saved: Decimal { contributions.reduce(0) { $0 + $1.amount } }
  public init(name: String, target: Decimal) {
    self.name = name
    self.target = target
  }
}
public struct Contribution: Identifiable, Codable {
  public var id = UUID()
  public var date = Date()
  public var amount: Decimal
  public init(amount: Decimal) { self.amount = amount }
}
public struct SyncState: Codable {
  public var cursor: String?
  public var lastSuccess: Date?
  public var errorCode: String?
}
public struct Ledger: Codable {
  public var accounts: [Account] = []
  public var entries: [Entry] = []
  public var rules: [CategoryRule] = []
  public var budgets: [Budget] = []
  public var goals: [Goal] = []
  public var sync: [String: SyncState] = [:]
  public var imports: [String] = []
  public init() {}
}
public enum Finance {
  public static let categories = [
    "Groceries", "Restaurants", "Transportation", "Fuel", "Shopping", "Entertainment",
    "Subscriptions", "Fitness", "Healthcare", "Utilities", "Housing", "Income", "Transfers",
    "Savings", "Other",
  ]
  public static func category(_ entry: Entry, rules: [CategoryRule]) -> String {
    if let override = entry.categoryOverride { return override }
    if entry.accountingKind == .transfer { return "Transfers" }
    if entry.accountingKind == .income { return "Income" }
    let text = (entry.merchant + " " + entry.originalDescription).lowercased()
    let defaults = [
      CategoryRule(contains: "costco", category: "Groceries", priority: -1),
      CategoryRule(contains: "spotify", category: "Subscriptions", priority: -1),
    ]
    return (rules + defaults).sorted { $0.priority > $1.priority }.first {
      !$0.contains.isEmpty && text.contains($0.contains.lowercased())
    }?.category ?? "Other"
  }
  public static func spending(
    _ entries: [Entry], start: Date, end: Date, currency: String = "CAD", category: String? = nil,
    rules: [CategoryRule] = []
  ) -> Decimal {
    entries.filter {
      !$0.pending && !$0.excluded && $0.currency == currency && $0.date >= start && $0.date < end
        && ($0.accountingKind == .expense || $0.accountingKind == .refund)
    }.reduce(0) { total, e in
      let value: Decimal
      if let category, e.splitsNeedReview {
        value = category == "Other" ? e.amount : 0
      } else if let category, !e.splits.isEmpty {
        value = e.splits.filter { $0.category == category }.reduce(0) { $0 + $1.amount }
      } else {
        value = category == nil || self.category(e, rules: rules) == category ? e.amount : 0
      }
      return total + (e.accountingKind == .refund ? -value : value)
    }
  }
  public static func income(_ entries: [Entry], start: Date, end: Date, currency: String = "CAD")
    -> Decimal
  {
    entries.filter {
      $0.accountingKind == .income && !$0.pending && $0.currency == currency && $0.date >= start
        && $0.date < end
    }.reduce(0) { $0 + $1.amount }
  }
  public static func validate(_ entry: Entry) throws {
    guard entry.amount > 0, !entry.merchant.trimmingCharacters(in: .whitespaces).isEmpty,
      !entry.accountID.isEmpty, entry.currency.count == 3
    else { throw CoreError.invalidEntry }
    guard
      entry.splits.isEmpty
        || (entry.splits.allSatisfy { $0.amount > 0 }
          && entry.splits.reduce(Decimal(0)) { $0 + $1.amount } == entry.amount)
    else { throw CoreError.invalidSplit }
  }
}
public enum CoreError: Error {
  case invalidEntry, invalidSplit, invalidPage, disconnected, invalidCSV, duplicateHeaders
}
