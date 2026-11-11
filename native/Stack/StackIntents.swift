import AppIntents
import Foundation
import StackCore

private enum IntentRecords {
  static func ledger() throws -> Ledger {
    try LedgerFile.load(URL.applicationSupportDirectory.appending(path: "Stack/ledger.json"))
  }
  static var month: DateInterval { Calendar.current.dateInterval(of: .month, for: Date())! }
  static func formatted(_ value: Decimal) -> String { value.formatted(.currency(code: "CAD")) }
}
struct MonthlySpendingIntent: AppIntent {
  static var title: LocalizedStringResource = "Show monthly spending"
  static var openAppWhenRun = true
  static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
  func perform() async throws -> some IntentResult & ProvidesDialog {
    let ledger = try IntentRecords.ledger()
    let month = IntentRecords.month
    let amount = Finance.spending(ledger.entries, start: month.start, end: month.end)
    return .result(
      dialog:
        "Recorded spending this month is \(IntentRecords.formatted(amount)). Pending transactions and transfers are excluded."
    )
  }
}
struct RemainingBudgetIntent: AppIntent {
  static var title: LocalizedStringResource = "Show remaining budget"
  static var openAppWhenRun = true
  static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
  func perform() async throws -> some IntentResult & ProvidesDialog {
    let ledger = try IntentRecords.ledger()
    guard
      let budget = ledger.budgets.first(where: {
        $0.category == "All" && $0.start <= Date() && $0.end > Date()
      })
    else { return .result(dialog: "Create an overall budget in Stack first.") }
    let used = Finance.spending(ledger.entries, start: budget.start, end: budget.end)
    return .result(
      dialog: "Your recorded remaining budget is \(IntentRecords.formatted(budget.limit - used)).")
  }
}
struct ShowGoalsIntent: AppIntent {
  static var title: LocalizedStringResource = "Show savings goals"
  static var openAppWhenRun = true
  static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
  func perform() async throws -> some IntentResult & ProvidesDialog {
    let goals = try IntentRecords.ledger().goals
    let summary = goals.prefix(3).map {
      $0.name + ": " + IntentRecords.formatted($0.saved) + " of "
        + IntentRecords.formatted($0.target)
    }.joined(separator: ". ")
    return .result(
      dialog: IntentDialog(
        stringLiteral: summary.isEmpty ? "No recorded savings goals yet." : summary))
  }
}
struct RecentTransactionsIntent: AppIntent {
  static var title: LocalizedStringResource = "Show recent transactions"
  static var openAppWhenRun = true
  static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
  func perform() async throws -> some IntentResult & ProvidesDialog {
    let entries = try IntentRecords.ledger().entries.sorted { $0.date > $1.date }.prefix(3)
    let summary = entries.map {
      $0.displayMerchant + ": " + $0.amount.formatted(.currency(code: $0.currency))
    }.joined(separator: ". ")
    return .result(
      dialog: IntentDialog(
        stringLiteral: summary.isEmpty ? "No recorded transactions yet." : summary))
  }
}
struct UpcomingBillsIntent: AppIntent {
  static var title: LocalizedStringResource = "Show upcoming bill candidates"
  static var openAppWhenRun = true
  static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
  func perform() async throws -> some IntentResult & ProvidesDialog {
    let candidates = Recurrence.candidates(try IntentRecords.ledger().entries).filter {
      $0.nextExpected >= Date()
    }
    guard let next = candidates.first else {
      return .result(dialog: "No upcoming recurring payment candidates in the recorded data.")
    }
    return .result(
      dialog:
        "A possible upcoming charge is \(next.merchant) on \(next.nextExpected.formatted(date: .abbreviated, time: .omitted)). Review it in Stack."
    )
  }
}
struct OpenStackIntent: AppIntent {
  static var title: LocalizedStringResource = "Open Stack"
  static var openAppWhenRun = true
  func perform() async throws -> some IntentResult { .result() }
}
struct StackShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: MonthlySpendingIntent(), phrases: ["Show monthly spending in \(.applicationName)"],
      shortTitle: "Monthly spending", systemImageName: "chart.bar")
    AppShortcut(
      intent: RemainingBudgetIntent(), phrases: ["Show remaining budget in \(.applicationName)"],
      shortTitle: "Remaining budget", systemImageName: "chart.pie")
    AppShortcut(
      intent: RecentTransactionsIntent(),
      phrases: ["Show recent transactions in \(.applicationName)"],
      shortTitle: "Recent transactions", systemImageName: "list.bullet")
    AppShortcut(
      intent: ShowGoalsIntent(), phrases: ["Show savings goals in \(.applicationName)"],
      shortTitle: "Savings goals", systemImageName: "target")
    AppShortcut(
      intent: UpcomingBillsIntent(), phrases: ["Show upcoming bills in \(.applicationName)"],
      shortTitle: "Upcoming bills", systemImageName: "calendar")
    AppShortcut(
      intent: OpenStackIntent(), phrases: ["Open \(.applicationName)"], shortTitle: "Open Stack",
      systemImageName: "square.grid.2x2")
  }
}
