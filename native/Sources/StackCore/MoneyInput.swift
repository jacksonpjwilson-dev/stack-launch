import Foundation
public enum MoneyInput {
    /// Strict positive currency input. Reject partial parses, grouping, and sub-cent amounts.
    public static func parse(_ text: String, locale: Locale = .current) -> Decimal? {
        let separator = locale.decimalSeparator ?? "."
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: separator, with: ".")
        guard normalized.range(of: #"^\d+(\.\d{1,2})?$"#, options: .regularExpression) != nil,
              let value = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")), value > 0 else { return nil }
        return value
    }
}
