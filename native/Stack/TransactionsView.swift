import StackCore
import SwiftUI

struct TransactionsView: View {
  @EnvironmentObject private var store: StackStore
  @State private var search = ""
  @State private var account = "All"
  @State private var category = "All"
  @State private var sortAmount = false
  @State private var adding = false
  @State private var dateFilter = false
  @State private var from = Calendar.current.startOfDay(for: Date())
  @State private var through = Date()
  var filtered: [Entry] {
    store.ledger.entries.filter { e in
      (!dateFilter
        || (e.date >= from
          && e.date < Calendar.current.date(
            byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: through))!))
        && (search.isEmpty
          || (e.displayMerchant + " " + e.notes + " " + e.tags.joined(separator: " "))
            .localizedCaseInsensitiveContains(search))
        && (account == "All" || account == e.accountID)
        && (category == "All" || Finance.category(e, rules: store.ledger.rules) == category)
    }.sorted { sortAmount ? $0.amount > $1.amount : $0.date > $1.date }
  }
  var body: some View {
    List {
      Section {
        Picker("Account", selection: $account) {
          Text("All").tag("All")
          ForEach(store.ledger.accounts) { Text($0.name).tag($0.id) }
        }
        Picker("Category", selection: $category) {
          Text("All").tag("All")
          ForEach(Finance.categories, id: \.self) { Text($0).tag($0) }
        }
        Toggle("Filter dates", isOn: $dateFilter)
        if dateFilter {
          DatePicker("From", selection: $from, displayedComponents: .date)
          DatePicker("Through", selection: $through, in: from..., displayedComponents: .date)
        }
        Toggle("Largest amount first", isOn: $sortAmount)
      }
      Section {
        ForEach(filtered) { entry in
          NavigationLink {
            EntryEditor(existing: entry)
          } label: {
            EntryRow(entry: entry)
          }
        }
      }
      if filtered.isEmpty {
        ContentUnavailableView(
          "No transactions", systemImage: "tray",
          description: Text("Add a manual entry or import a CSV in Settings."))
      }
    }.searchable(text: $search).navigationTitle("Transactions")
      .toolbar {
        Button {
          adding = true
        } label: {
          Label("Add transaction", systemImage: "plus")
        }
      }
      .sheet(isPresented: $adding) { NavigationStack { EntryEditor() } }
  }
}
struct EntryEditor: View {
  @EnvironmentObject private var store: StackStore
  @Environment(\.dismiss) private var dismiss
  var existing: Entry?
  @State private var merchant = ""
  @State private var amount = ""
  @State private var accountID = ""
  @State private var kind = TransactionKind.expense
  @State private var category = "Other"
  @State private var date = Date()
  @State private var notes = ""
  @State private var excluded = false
  @State private var validation: String?
  @State private var tags = ""
  @State private var customCategory = ""
  @State private var splits: [Split] = []
  @State private var splitCategory = "Groceries"
  @State private var splitAmount = ""
  var body: some View {
    Form {
      if store.ledger.accounts.isEmpty {
        Text("Create an account in Settings first.").foregroundStyle(.secondary)
      }
      TextField("Merchant", text: $merchant)
      TextField("Amount (positive magnitude)", text: $amount).keyboardType(.decimalPad).disabled(
        existing != nil && existing?.provider != "manual")
      Picker("Account", selection: $accountID) {
        ForEach(store.ledger.accounts) { Text($0.name + " · " + $0.currency).tag($0.id) }
      }.disabled(existing != nil)
      DatePicker("Date", selection: $date, displayedComponents: .date).disabled(
        existing?.provider != "manual" && existing != nil)
      Picker("Type", selection: $kind) {
        ForEach(TransactionKind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
      }
      Picker("Category", selection: $category) {
        ForEach(Finance.categories, id: \.self) { Text($0).tag($0) }
      }
      TextField("Custom category (optional)", text: $customCategory)
      TextField("Notes", text: $notes, axis: .vertical)
      TextField("Tags, separated by commas", text: $tags)
      Section("Split categories · amounts must equal transaction total") {
        ForEach(splits.indices, id: \.self) { index in
          HStack {
            Text(splits[index].category)
            Spacer()
            Text(money(splits[index].amount))
          }
        }.onDelete { splits.remove(atOffsets: $0) }
        Picker("Split category", selection: $splitCategory) {
          ForEach(Finance.categories, id: \.self) { Text($0).tag($0) }
        }
        TextField("Split amount", text: $splitAmount).keyboardType(.decimalPad)
        Button("Add split") {
          if let value = MoneyInput.parse(splitAmount), value > 0 {
            splits.append(Split(category: splitCategory, amount: value))
            splitAmount = ""
          }
        }
        if existing?.splitsNeedReview == true {
          Text("The provider changed the total. Review these splits before saving.")
            .foregroundStyle(.orange)
        }
      }
      Toggle("Exclude from spending and budgets", isOn: $excluded)
      if let existing {
        Section("Original import") {
          Text(existing.originalDescription)
          Text("Source: \(existing.provider)")
          if existing.provider != "manual" {
            Text("Amount is preserved from the provider.").font(.caption)
          }
        }
      }
      if let validation { Text(validation).foregroundStyle(.red) }
      Button("Save transaction", action: save).disabled(store.ledger.accounts.isEmpty)
    }
    .navigationTitle(existing == nil ? "New transaction" : "Edit transaction")
    .onAppear {
      if let e = existing {
        merchant = e.displayMerchant
        amount = e.amount.formatted(.number.grouping(.never))
        accountID = e.accountID
        kind = e.accountingKind
        category = Finance.category(e, rules: store.ledger.rules)
        date = e.date
        notes = e.notes
        excluded = e.excluded
        tags = e.tags.joined(separator: ", ")
        splits = e.splits
        if !Finance.categories.contains(category) {
          customCategory = category
          category = "Other"
        }
      } else {
        accountID = store.ledger.accounts.first?.id ?? ""
      }
    }
  }
  func save() {
    guard let value = MoneyInput.parse(amount), value > 0,
      let account = store.ledger.accounts.first(where: { $0.id == accountID })
    else {
      validation = "Choose an account and enter a positive amount."
      return
    }
    var entry =
      existing
      ?? Entry(
        accountID: accountID, merchant: merchant, amount: value, currency: account.currency,
        date: date, kind: kind)
    if existing?.provider == "manual" {
      entry.amount = value
      entry.date = date
    }
    entry.correction = merchant
    entry.categoryOverride =
      customCategory.trimmingCharacters(in: .whitespaces).isEmpty ? category : customCategory
    entry.splits = splits
    entry.tags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter {
      !$0.isEmpty
    }
    entry.kindOverride = kind
    entry.notes = notes
    entry.excluded = excluded
    do { try Finance.validate(entry) } catch {
      validation = "Enter a merchant and a valid amount. Splits must equal the total."
      return
    }
    store.update { ledger in
      if let index = ledger.entries.firstIndex(where: { $0.key == entry.key }) {
        ledger.entries[index] = entry
      } else {
        ledger.entries.append(entry)
      }
    }
    if store.error == nil { dismiss() }
  }
}
