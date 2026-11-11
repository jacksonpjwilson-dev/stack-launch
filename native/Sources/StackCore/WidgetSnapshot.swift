import Foundation

/// A minimal opt-in cache. No transactions, merchant descriptions, account identifiers, or tokens.
public struct WidgetSnapshot: Codable {
  public static let groupID = "group.dev.stack.finance"
  public var generatedAt: Date
  public var spending: Decimal?
  public var remainingBudget: Decimal?
  public var savings: Decimal?
  public var savingsTarget: Decimal?
  public var valuesVisible: Bool
  public init(
    ledger: Ledger, valuesVisible: Bool, now: Date = Date(), calendar: Calendar = .current
  ) {
    generatedAt = now
    self.valuesVisible = valuesVisible
    guard valuesVisible, let period = calendar.dateInterval(of: .month, for: now) else { return }
    spending = Finance.spending(ledger.entries, start: period.start, end: period.end)
    if let budget = ledger.budgets.first(where: {
      $0.category == "All" && $0.start <= now && $0.end > now
    }) {
      remainingBudget =
        budget.limit - Finance.spending(ledger.entries, start: budget.start, end: budget.end)
    }
    if let goal = ledger.goals.first {
      savings = goal.saved
      savingsTarget = goal.target
    }
  }
}
