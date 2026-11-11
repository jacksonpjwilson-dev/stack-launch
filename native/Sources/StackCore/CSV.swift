import Foundation
public struct CSVMapping {
    public var date: String; public var merchant: String; public var amount: String?; public var debit: String?; public var credit: String?
    public init(date: String, merchant: String, amount: String? = nil, debit: String? = nil, credit: String? = nil) { self.date = date; self.merchant = merchant; self.amount = amount; self.debit = debit; self.credit = credit }
}
public enum CSV {
    public static func rows(_ text: String) throws -> [[String]] {
        var result: [[String]] = [], row: [String] = [], field = "", quoted = false
        let chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")); var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                if quoted && i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 }
                else { quoted.toggle() }
            } else if c == "," && !quoted { row.append(field); field = "" }
            else if c == "\n" && !quoted { row.append(field); if row.contains(where: { !$0.isEmpty }) { result.append(row) }; row = []; field = "" }
            else { field.append(c) }; i += 1
        }
        guard !quoted else { throw CoreError.invalidCSV }
        row.append(field); if row.contains(where: { !$0.isEmpty }) { result.append(row) }
        return result
    }
    /// Signed amount convention: negative expense, positive income. Debit/credit columns are positive magnitudes.
    public static func preview(_ text: String, mapping: CSVMapping, accountID: String, currency: String = "CAD") throws -> [Entry] {
        var rows = try self.rows(text)
        guard let header = rows.first else { throw CoreError.invalidCSV }; rows.removeFirst()
        guard Set(header).count == header.count else { throw CoreError.duplicateHeaders }
        func column(_ name: String?) throws -> Int { guard let name, let index = header.firstIndex(of: name) else { throw CoreError.invalidCSV }; return index }
        let di = try column(mapping.date), mi = try column(mapping.merchant)
        let ai = try mapping.amount.map { try column($0) }, debit = try mapping.debit.map { try column($0) }, credit = try mapping.credit.map { try column($0) }
        guard ai != nil || (debit != nil && credit != nil) else { throw CoreError.invalidCSV }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        var occurrences: [String: Int] = [:]
        return try rows.map { row in
            guard row.count == header.count, let date = formatter.date(from: row[di]), formatter.string(from: date) == row[di] else { throw CoreError.invalidCSV }
            func decimal(_ index: Int, emptyZero: Bool = false) throws -> Decimal {
                let s = row[index].trimmingCharacters(in: .whitespaces)
                if emptyZero && s.isEmpty { return 0 }
                guard s.range(of: #"^[+-]?\d+(\.\d{1,2})?$"#, options: .regularExpression) != nil, let d = Decimal(string: s, locale: Locale(identifier: "en_US_POSIX")) else { throw CoreError.invalidCSV }; return d
            }
            let signed: Decimal
            if let ai { signed = try decimal(ai) }
            else {
                let d = try decimal(debit!, emptyZero: true), c = try decimal(credit!, emptyZero: true)
                guard d >= 0, c >= 0, d == 0 || c == 0 else { throw CoreError.invalidCSV }; signed = c - d
            }
            let canonical = [accountID, currency, row[di], row[mi], NSDecimalNumber(decimal: signed).stringValue].map { "\($0.utf8.count):\($0)" }.joined()
            let occurrence = occurrences[canonical, default: 0]; occurrences[canonical] = occurrence + 1
            // Full encoded key avoids platform-dependent hashes and preserves identical purchases within a file.
            let id = Data(canonical.utf8).base64EncodedString() + ":\(occurrence)"
            let e = Entry(id: id, accountID: accountID, provider: "csv", merchant: row[mi], amount: abs(signed), currency: currency, date: date, kind: signed < 0 ? .expense : .income)
            try Finance.validate(e); return e
        }
    }
    public static func merge(_ preview: [Entry], into ledger: Ledger) -> Ledger {
        var result = ledger; var keys = Set(ledger.entries.map(\.key))
        for entry in preview where keys.insert(entry.key).inserted { result.entries.append(entry) }
        result.imports.append("\(Date().timeIntervalSince1970):\(preview.count)")
        return result
    }
    public static func export(_ entries: [Entry]) -> String {
        func escaped(_ s: String) -> String {
            let safe = ["=", "+", "-", "@", "\t", "\r"].contains(where: { s.hasPrefix($0) }) ? "'" + s : s
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let f = ISO8601DateFormatter()
        return "Date,Merchant,Amount,Currency,Account,Type,Category,Notes\n" + entries.map { e in
            [f.string(from: e.date), e.displayMerchant, NSDecimalNumber(decimal: e.amount).stringValue, e.currency, e.accountID, e.kind.rawValue, e.categoryOverride ?? "", e.notes].map(escaped).joined(separator: ",")
        }.joined(separator: "\n")
    }
}
