import Foundation

public struct RecurringCandidate: Identifiable {
  public var id: String
  public var merchant: String
  public var amount: Decimal
  public var currency: String
  public var intervalDays: Int
  public var nextExpected: Date
  public var priceIncreased: Bool
}
public enum Recurrence {
  /// Three posted expenses with two consistent intervals are a candidate, never confirmation.
  public static func candidates(_ entries: [Entry], calendar: Calendar = .current)
    -> [RecurringCandidate]
  {
    var groups: [String: [Entry]] = [:]
    for entry in entries where entry.accountingKind == .expense && !entry.pending && !entry.excluded
    {
      let key = [entry.accountID, entry.currency, entry.displayMerchant.lowercased()].joined(
        separator: ":")
      groups[key, default: []].append(entry)
    }
    var result: [RecurringCandidate] = []
    for (key, values) in groups {
      if let candidate = candidate(key: key, values: values, calendar: calendar) {
        result.append(candidate)
      }
    }
    return result.sorted { $0.nextExpected < $1.nextExpected }
  }
  private static func candidate(key: String, values: [Entry], calendar: Calendar)
    -> RecurringCandidate?
  {
    let sorted = values.sorted { $0.date < $1.date }
    guard sorted.count >= 3 else { return nil }
    let recent = Array(sorted.suffix(3))
    let a = calendar.dateComponents([.day], from: recent[0].date, to: recent[1].date).day ?? 0
    let b = calendar.dateComponents([.day], from: recent[1].date, to: recent[2].date).day ?? 0
    var interval: Int?
    for days in [7, 14, 30, 365] {
      let tolerance = days == 30 ? 3 : 1
      if abs(a - days) <= tolerance && abs(b - days) <= tolerance {
        interval = days
        break
      }
    }
    guard let interval else { return nil }
    let last = recent[2]
    let prior = recent[1].amount
    let difference: Decimal = abs(recent[0].amount - prior)
    let allowedDifference: Decimal = prior / Decimal(10)
    guard prior > 0, difference <= allowedDifference else { return nil }
    let next: Date?
    switch interval {
    case 30: next = calendar.date(byAdding: .month, value: 1, to: last.date)
    case 365: next = calendar.date(byAdding: .year, value: 1, to: last.date)
    default: next = calendar.date(byAdding: .day, value: interval, to: last.date)
    }
    guard let next else { return nil }
    return RecurringCandidate(
      id: key, merchant: last.displayMerchant, amount: last.amount, currency: last.currency,
      intervalDays: interval, nextExpected: next, priceIncreased: last.amount > prior)
  }
}
