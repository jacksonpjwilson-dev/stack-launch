import SwiftUI
import Charts
import StackCore
struct DashboardView: View {
    @EnvironmentObject private var store: StackStore
    private var period: DateInterval { Calendar.current.dateInterval(of: .month, for: Date())! }
    var body: some View {
        let ledger = store.ledger
        let spending = Finance.spending(ledger.entries, start: period.start, end: period.end)
        let income = Finance.income(ledger.entries, start: period.start, end: period.end)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(Date(), format: .dateTime.month(.wide).year()).font(.subheadline).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Tracked balance · CAD").foregroundStyle(.secondary)
                    Text(money(ledger.accounts.filter { $0.currency == "CAD" }.reduce(0) { $0 + $1.balance })).font(.system(size: 38, weight: .semibold, design: .rounded))
                    Text("Recorded balances may be stale. Manual entries do not change account balances.").font(.caption).foregroundStyle(.secondary)
                }
                HStack { metric("Income", income); Spacer(); metric("Expenses", spending); Spacer(); metric("Cash flow", income - spending) }
                GroupBox("Spending by category · CAD") {
                    Chart(Finance.categories, id: \.self) { category in
                        let value = Finance.spending(ledger.entries, start: period.start, end: period.end, category: category, rules: ledger.rules)
                        if value > 0 { BarMark(x: .value("Amount", NSDecimalNumber(decimal: value).doubleValue), y: .value("Category", category)).foregroundStyle(.teal) }
                    }.frame(height: 220).padding(.top)
                    Text("Posted expenses less refunds; transfers excluded.").font(.caption).foregroundStyle(.secondary)
                }
                GroupBox("Budgets") {
                    if ledger.budgets.isEmpty { Text("Create a budget in Plan to track your spending.").foregroundStyle(.secondary).padding() }
                    ForEach(ledger.budgets.filter { $0.start <= Date() && $0.end > Date() }) { budget in
                        let used = Finance.spending(ledger.entries, start: budget.start, end: budget.end, category: budget.category == "All" ? nil : budget.category, rules: ledger.rules)
                        VStack(alignment: .leading) { HStack { Text(budget.category); Spacer(); Text(money(budget.limit - used) + " left") }; ProgressView(value: min(max(NSDecimalNumber(decimal: used / budget.limit).doubleValue, 0), 1)) }.padding(.vertical, 6)
                    }
                }
                GroupBox("Recent activity") { ForEach(ledger.entries.sorted { $0.date > $1.date }.prefix(5)) { EntryRow(entry: $0) }; if ledger.entries.isEmpty { Text("Add an expense or import a CSV to begin.").padding().foregroundStyle(.secondary) } }
                GroupBox("Account status") {
                    if ledger.sync.isEmpty { Label("No automatic bank connection configured", systemImage: "link.badge.plus").font(.subheadline).padding() }
                    ForEach(ledger.accounts) { account in HStack { Text(account.name); Spacer(); Text(account.currency).foregroundStyle(.secondary) }.padding(.vertical, 4) }
                }
            }.padding()
        }.navigationTitle("Stack")
    }
    func metric(_ label: String, _ amount: Decimal) -> some View { VStack(alignment: .leading, spacing: 6) { Text(label).font(.caption).foregroundStyle(.secondary); Text(money(amount)).font(.subheadline.bold()).minimumScaleFactor(0.6) } }
}
struct EntryRow: View {
    var entry: Entry
    var body: some View { HStack { VStack(alignment: .leading) { Text(entry.displayMerchant); Text(entry.date, style: .date).font(.caption).foregroundStyle(.secondary); if entry.splitsNeedReview { Text("Review split amounts").font(.caption).foregroundStyle(.orange) } }; Spacer(); VStack(alignment: .trailing) { Text(money(entry.amount, currency: entry.currency)); Text(entry.pending ? "Pending" : entry.accountingKind.rawValue.capitalized).font(.caption).foregroundStyle(.secondary) } }.padding(.vertical, 5) }
}
