import SwiftUI
import UniformTypeIdentifiers
import StackCore
struct TextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .commaSeparatedText, .json] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws { text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}
struct SettingsView: View {
    @EnvironmentObject private var store: StackStore
    @AppStorage("biometricLock") private var biometricLock = false
    @State private var accountName = ""
    @State private var importing = false
    @State private var restoring = false
    @State private var restoreCandidate: Ledger?
    @State private var csvText: String?
    @State private var exporting = false
    @State private var exportType = UTType.commaSeparatedText
    @State private var exportDocument = TextDocument(text: "")
    @State private var deleteConfirmation = false
    var body: some View {
        Form {
            Section("Accounts") {
                ForEach(store.ledger.accounts) { account in VStack(alignment: .leading) { Text(account.name); Text("Manual · \(account.currency)").font(.caption).foregroundStyle(.secondary) } }
                TextField("New account name", text: $accountName)
                Button("Add manual CAD account") { store.update { $0.accounts.append(Account(name: accountName)) }; accountName = "" }.disabled(accountName.trimmingCharacters(in: .whitespaces).isEmpty)
                Text("Automatic bank connections are not configured. No banking credentials are stored by this app.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Security") { Toggle("Require device authentication", isOn: $biometricLock); Text("Uses Face ID, Touch ID, or your device passcode. Local records use complete file protection.").font(.caption) }
            Section("Your data") {
                Button("Import CSV from Files") { importing = true }.disabled(store.ledger.accounts.isEmpty)
                Button("Export transactions as CSV") { exportDocument = TextDocument(text: CSV.export(store.ledger.entries)); exportType = .commaSeparatedText; exporting = true }
                Button("Export complete backup") { do { let data = try JSONEncoder().encode(store.ledger); exportDocument = TextDocument(text: String(decoding: data, as: UTF8.self)); exportType = .json; exporting = true } catch { store.error = "Backup could not be encoded." } }
                Button("Restore backup") { restoring = true }
                Text("Backups and exports contain financial information. Save them to a location you trust. Restore replaces local records after confirmation.").font(.caption).foregroundStyle(.secondary)
                Button("Delete all local data", role: .destructive) { deleteConfirmation = true }
            }
            Section("Integration status") {
                LabeledContent("Bank provider", value: "Not connected")
                LabeledContent("Head Quarter", value: "Not configured")
                LabeledContent("iCloud", value: "Not enabled")
                LabeledContent("Currency", value: "CAD")
                Text("Offline records remain available. No balances or transactions are sent to monitoring services.").font(.caption)
            }
        }.navigationTitle("Settings")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in read(result) { csvText = $0 } }
        .fileImporter(isPresented: $restoring, allowedContentTypes: [.json]) { result in read(result) { text in
            do { let candidate = try JSONDecoder().decode(Ledger.self, from: Data(text.utf8)); try validateBackup(candidate); restoreCandidate = candidate } catch { store.error = "Invalid backup. Local records have not changed." }
        } }
        .sheet(isPresented: Binding(get: { csvText != nil }, set: { if !$0 { csvText = nil } })) { if let csvText { NavigationStack { CSVImportView(text: csvText) } } }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: exportType, defaultFilename: exportType == .json ? "Stack-backup" : "Stack-transactions") { result in if case .failure = result { store.error = "Export failed." } }
        .confirmationDialog("Replace all local data with this backup?", isPresented: Binding(get: { restoreCandidate != nil }, set: { if !$0 { restoreCandidate = nil } })) { Button("Replace local records", role: .destructive) { if let restoreCandidate { store.restore(restoreCandidate) }; restoreCandidate = nil } }
        .confirmationDialog("Delete all local financial data? This cannot be undone without a backup.", isPresented: $deleteConfirmation) { Button("Delete all local data", role: .destructive) { store.update { $0 = Ledger() } } }
    }
    func read(_ result: Result<URL, Error>, use: (String) -> Void) {
        do { let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }; let data = try Data(contentsOf: url); guard data.count <= 10_000_000, let text = String(data: data, encoding: .utf8) else { throw CoreError.invalidCSV }; use(text) } catch { store.error = "Could not read the selected file. Use a UTF-8 file smaller than 10 MB." }
    }
    func validateBackup(_ ledger: Ledger) throws {
        let accounts = Set(ledger.accounts.map(\.id))
        guard accounts.count == ledger.accounts.count, Set(ledger.entries.map(\.key)).count == ledger.entries.count, ledger.budgets.allSatisfy({ $0.limit > 0 && $0.end > $0.start }), ledger.goals.allSatisfy({ $0.target > 0 && $0.contributions.allSatisfy { $0.amount > 0 } }) else { throw CoreError.invalidEntry }
        for entry in ledger.entries { try Finance.validate(entry); guard accounts.contains(entry.accountID) else { throw CoreError.invalidEntry } }
    }
}
struct CSVImportView: View {
    @EnvironmentObject private var store: StackStore
    @Environment(\.dismiss) private var dismiss
    let text: String
    @State private var dateColumn = ""
    @State private var merchantColumn = ""
    @State private var amountColumn = ""
    @State private var debitColumn = ""
    @State private var creditColumn = ""
    @State private var splitColumns = false
    @State private var accountID = ""
    @State private var preview: [Entry]?
    @State private var error: String?
    var headers: [String] { (try? CSV.rows(text).first) ?? [] }
    var body: some View {
        Form {
            if let preview {
                Section("Preview · \(preview.count) rows") {
                    Text("\(preview.filter { e in store.ledger.entries.contains { $0.key == e.key } }.count) already imported rows will be skipped.").font(.caption)
                    ForEach(Array(preview.prefix(30))) { EntryRow(entry: $0) }
                    if preview.count > 30 { Text("Showing the first 30 rows.") }
                }
                Button("Confirm import") { store.update { $0 = CSV.merge(preview, into: $0) }; if store.error == nil { dismiss() } }
                Button("Change mapping") { self.preview = nil }
            } else {
                Text("Dates must use YYYY-MM-DD. Signed amounts use negative expenses and positive income. Debit/credit columns use positive amounts. Review the preview before importing.").font(.callout)
                Picker("Account", selection: $accountID) { ForEach(store.ledger.accounts) { Text($0.name).tag($0.id) } }
                column("Date", selection: $dateColumn); column("Merchant", selection: $merchantColumn)
                Toggle("Separate debit and credit columns", isOn: $splitColumns)
                if splitColumns { column("Debit", selection: $debitColumn); column("Credit", selection: $creditColumn) } else { column("Signed amount", selection: $amountColumn) }
                Button("Preview import") {
                    do { let mapping = CSVMapping(date: dateColumn, merchant: merchantColumn, amount: splitColumns ? nil : amountColumn, debit: splitColumns ? debitColumn : nil, credit: splitColumns ? creditColumn : nil); preview = try CSV.preview(text, mapping: mapping, accountID: accountID, currency: store.ledger.accounts.first { $0.id == accountID }?.currency ?? "CAD"); error = nil } catch { self.error = "Check column mapping, unique headers, ISO dates, and plain decimal amounts. No data was imported." }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
        }.navigationTitle("Import CSV").toolbar { Button("Cancel") { dismiss() } }
        .onAppear { accountID = store.ledger.accounts.first?.id ?? ""; dateColumn = headers.first ?? ""; merchantColumn = headers.dropFirst().first ?? ""; amountColumn = headers.dropFirst(2).first ?? "" }
    }
    func column(_ title: String, selection: Binding<String>) -> some View { Picker(title, selection: selection) { Text("Choose column").tag(""); ForEach(headers, id: \.self) { Text($0).tag($0) } } }
}
