import SwiftUI
import WidgetKit
import StackCore
struct StackTimelineEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}
struct StackTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> StackTimelineEntry { hidden() }
    func getSnapshot(in context: Context, completion: @escaping (StackTimelineEntry) -> Void) { completion(context.isPreview ? hidden() : read()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<StackTimelineEntry>) -> Void) {
        completion(Timeline(entries: [read()], policy: .after(Date().addingTimeInterval(3600))))
    }
    private func hidden() -> StackTimelineEntry { StackTimelineEntry(date: Date(), snapshot: WidgetSnapshot(ledger: Ledger(), valuesVisible: false)) }
    private func read() -> StackTimelineEntry {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetSnapshot.groupID)?.appendingPathComponent("snapshot.json"), let data = try? Data(contentsOf: url), let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return hidden() }
        return StackTimelineEntry(date: Date(), snapshot: snapshot)
    }
}
struct StackWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: StackTimelineEntry
    var savingsMode: Bool
    var body: some View {
        Group {
            if !entry.snapshot.valuesVisible {
                Label("Open Stack", systemImage: "lock.shield").font(.caption)
            } else if family == .accessoryInline {
                Text(savingsMode ? "Savings \(formatted(entry.snapshot.savings))" : "Budget \(formatted(entry.snapshot.remainingBudget))")
            } else if family == .accessoryCircular {
                VStack { Image(systemName: savingsMode ? "target" : "chart.pie"); Text(formatted(savingsMode ? entry.snapshot.savings : entry.snapshot.remainingBudget)).font(.caption2).minimumScaleFactor(0.5) }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label(savingsMode ? "Tracked savings" : "Budget remaining", systemImage: savingsMode ? "target" : "chart.pie").font(.caption).foregroundStyle(.secondary)
                    Text(formatted(savingsMode ? entry.snapshot.savings : entry.snapshot.remainingBudget)).font(.title2.bold()).minimumScaleFactor(0.5)
                    if family == .systemMedium || family == .systemLarge {
                        Text("Monthly spending: \(formatted(entry.snapshot.spending))").font(.subheadline)
                    }
                    if family == .systemLarge {
                        Divider(); Text("Savings: \(formatted(entry.snapshot.savings)) of \(formatted(entry.snapshot.savingsTarget))").font(.subheadline)
                        Text("Recorded data only. Open Stack to review accounts and recent activity.").font(.caption).foregroundStyle(.secondary)
                    }
                    if family != .accessoryRectangular { Text(entry.snapshot.generatedAt, style: .relative).font(.caption2).foregroundStyle(.secondary); Text("Cached · CAD").font(.caption2).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.privacySensitive().containerBackground(.background, for: .widget).widgetURL(URL(string: "stack://overview"))
    }
    private func formatted(_ value: Decimal?) -> String { value.map { $0.formatted(.currency(code: "CAD")) } ?? "—" }
}
struct BudgetWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "StackBudget", provider: StackTimelineProvider()) { StackWidgetView(entry: $0, savingsMode: false) }
            .configurationDisplayName("Stack budget").description("A private cached budget and spending summary.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryInline, .accessoryCircular, .accessoryRectangular])
    }
}
struct SavingsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "StackSavings", provider: StackTimelineProvider()) { StackWidgetView(entry: $0, savingsMode: true) }
            .configurationDisplayName("Stack savings").description("Recorded progress toward your first savings goal.")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryInline, .accessoryCircular, .accessoryRectangular])
    }
}
@main struct StackWidgets: WidgetBundle { var body: some Widget { BudgetWidget(); SavingsWidget() } }
