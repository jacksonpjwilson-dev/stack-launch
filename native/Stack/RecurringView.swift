import SwiftUI
import StackCore
struct RecurringView: View {
    @EnvironmentObject private var store: StackStore
    var body: some View {
        List {
            Section { Text("Candidates use three recorded charges with consistent intervals. Review dates and amounts before treating them as subscriptions. Expected dates can be past due when data is stale.").font(.callout).foregroundStyle(.secondary) }
            let candidates = Recurrence.candidates(store.ledger.entries)
            ForEach(candidates) { c in VStack(alignment: .leading, spacing: 6) { Text(c.merchant).font(.headline); Text("\(money(c.amount, currency: c.currency)) · approximately every \(c.intervalDays) days"); Text("Next expected: \(c.nextExpected.formatted(date: .abbreviated, time: .omitted))").font(.caption); if c.priceIncreased { Label("Possible price increase", systemImage: "arrow.up").foregroundStyle(.orange) } } }
            if candidates.isEmpty { Text("No recurring payment candidates yet.").foregroundStyle(.secondary) }
        }.navigationTitle("Recurring payments")
    }
}
