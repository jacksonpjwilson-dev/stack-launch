import SwiftUI
import StackCore
struct PlanningView: View {
    @EnvironmentObject private var store: StackStore
    @State private var category = "All"
    @State private var limit = ""
    @State private var start = Calendar.current.dateInterval(of: .month, for: Date())!.start
    @State private var end = Calendar.current.dateInterval(of: .month, for: Date())!.end
    @State private var goalName = ""
    @State private var target = ""
    @State private var merchant = ""
    @State private var ruleCategory = "Groceries"
    var body: some View {
        List {
            Section("Budgets · CAD") {
                ForEach(store.ledger.budgets) { budget in
                    let used = Finance.spending(store.ledger.entries, start: budget.start, end: budget.end, category: budget.category == "All" ? nil : budget.category, rules: store.ledger.rules)
                    VStack(alignment: .leading) { Text(budget.category).font(.headline); Text("\(money(used)) of \(money(budget.limit))"); Text("\(budget.start.formatted(date: .abbreviated, time: .omitted)) – \(budget.end.formatted(date: .abbreviated, time: .omitted)) (end exclusive)").font(.caption) }
                }.onDelete { offsets in store.update { $0.budgets.remove(atOffsets: offsets) } }
                Picker("Category", selection: $category) { Text("All").tag("All"); ForEach(Finance.categories, id: \.self) { Text($0).tag($0) } }
                TextField("Spending limit", text: $limit).keyboardType(.decimalPad)
                DatePicker("Start", selection: $start, displayedComponents: .date)
                DatePicker("End (exclusive)", selection: $end, displayedComponents: .date)
                Button("Add budget") { if let value = Decimal(string: limit, locale: .current), value > 0, end > start { store.update { $0.budgets.append(Budget(category: category, limit: value, start: start, end: end)) }; limit = "" } }.disabled((Decimal(string: limit, locale: .current) ?? 0) <= 0 || end <= start)
            }
            Section("Savings goals · tracked contributions") {
                ForEach(store.ledger.goals) { goal in NavigationLink { GoalView(goalID: goal.id) } label: { VStack(alignment: .leading) { Text(goal.name); Text("\(money(goal.saved)) / \(money(goal.target))").font(.caption); ProgressView(value: min(NSDecimalNumber(decimal: goal.saved / goal.target).doubleValue, 1)) } } }
                    .onDelete { offsets in store.update { $0.goals.remove(atOffsets: offsets) } }
                TextField("Goal name", text: $goalName); TextField("Target amount", text: $target).keyboardType(.decimalPad)
                Button("Add savings goal") { if let value = Decimal(string: target, locale: .current), value > 0, !goalName.isEmpty { store.update { $0.goals.append(Goal(name: goalName, target: value)) }; goalName = ""; target = "" } }.disabled(goalName.isEmpty || (Decimal(string: target, locale: .current) ?? 0) <= 0)
            }
            Section("Category rules · newer rules run first") {
                ForEach(store.ledger.rules.sorted { $0.priority > $1.priority }) { rule in Text("\(rule.contains) → \(rule.category)") }
                TextField("Merchant contains", text: $merchant)
                Picker("Assign category", selection: $ruleCategory) { ForEach(Finance.categories, id: \.self) { Text($0).tag($0) } }
                Button("Add rule") { store.update { $0.rules.append(CategoryRule(contains: merchant, category: ruleCategory, priority: ($0.rules.map(\.priority).max() ?? 0) + 1)) }; merchant = "" }.disabled(merchant.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            NavigationLink("Recurring payment candidates") { RecurringView() }
        }.navigationTitle("Your plan")
    }
}
struct GoalView: View {
    @EnvironmentObject private var store: StackStore
    var goalID: UUID
    @State private var amount = ""
    var body: some View {
        Form { if let goal = store.ledger.goals.first(where: { $0.id == goalID }) {
            Section(goal.name) { Text("Recorded: \(money(goal.saved))"); Text("Remaining: \(money(max(0, goal.target - goal.saved)))"); Text("Contributions are tracking records; no money is moved.").font(.caption) }
            Section("Contribution history") { ForEach(goal.contributions) { c in HStack { Text(c.date, style: .date); Spacer(); Text(money(c.amount)) } } }
            TextField("Contribution amount", text: $amount).keyboardType(.decimalPad)
            Button("Record contribution") { if let value = Decimal(string: amount, locale: .current), value > 0 { store.update { ledger in if let i = ledger.goals.firstIndex(where: { $0.id == goalID }) { ledger.goals[i].contributions.append(Contribution(amount: value)) } }; amount = "" } }.disabled((Decimal(string: amount, locale: .current) ?? 0) <= 0)
        } }.navigationTitle("Savings goal")
    }
}
