import Foundation
public struct RecurringCandidate: Identifiable {
    public var id: String; public var merchant: String; public var amount: Decimal; public var currency: String; public var intervalDays: Int; public var nextExpected: Date; public var priceIncreased: Bool
}
public enum Recurrence {
    /// Three posted expenses with two consistent intervals are a candidate, never confirmation.
    public static func candidates(_ entries: [Entry], calendar: Calendar = .current) -> [RecurringCandidate] {
        let groups = Dictionary(grouping: entries.filter { $0.accountingKind == .expense && !$0.pending && !$0.excluded }) { $0.accountID + ":" + $0.currency + ":" + $0.displayMerchant.lowercased() }
        return groups.compactMap { key, values in
            let sorted = values.sorted { $0.date < $1.date }
            guard sorted.count >= 3 else { return nil }
            let recent = Array(sorted.suffix(3))
            let a = calendar.dateComponents([.day], from: recent[0].date, to: recent[1].date).day ?? 0
            let b = calendar.dateComponents([.day], from: recent[1].date, to: recent[2].date).day ?? 0
            guard let interval = [7, 14, 30, 365].first(where: { abs(a - $0) <= ($0 == 30 ? 3 : 1) && abs(b - $0) <= ($0 == 30 ? 3 : 1) }), let last = recent.last else { return nil }
            let prior = recent[1].amount
            guard prior > 0, abs(recent[0].amount - prior) <= prior / 10 else { return nil }
            let next: Date?
            if interval == 30 { next = calendar.date(byAdding: .month, value: 1, to: last.date) }
            else if interval == 365 { next = calendar.date(byAdding: .year, value: 1, to: last.date) }
            else { next = calendar.date(byAdding: .day, value: interval, to: last.date) }
            guard let next else { return nil }
            return RecurringCandidate(id: key, merchant: last.displayMerchant, amount: last.amount, currency: last.currency, intervalDays: interval, nextExpected: next, priceIncreased: last.amount > prior)
        }.sorted { $0.nextExpected < $1.nextExpected }
    }
}
