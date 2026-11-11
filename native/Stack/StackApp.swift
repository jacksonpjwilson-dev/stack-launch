import SwiftUI
import LocalAuthentication
import StackCore

@MainActor final class StackStore: ObservableObject {
    @Published private(set) var ledger = Ledger()
    @Published var error: String?
    private let url = URL.applicationSupportDirectory.appending(path: "Stack/ledger.json")
    init() { do { ledger = try LedgerFile.load(url) } catch { self.error = "Stored data could not be read. It has been preserved; restore a backup before making changes."; readFailed = true } }
    private var readFailed = false
    func restore(_ candidate: Ledger) {
        do {
            if readFailed && FileManager.default.fileExists(atPath: url.path) {
                let recovery = url.deletingLastPathComponent().appendingPathComponent("unreadable-" + UUID().uuidString + ".json")
                try FileManager.default.copyItem(at: url, to: recovery)
            }
            try LedgerFile.save(candidate, to: url); ledger = candidate; readFailed = false
        } catch { self.error = "Restore failed; existing records were preserved." }
    }
    func update(_ change: (inout Ledger) throws -> Void) {
        guard !readFailed else { error = "Resolve the unreadable data file before saving."; return }
        do { var next = ledger; try change(&next); try LedgerFile.save(next, to: url); ledger = next } catch { self.error = "Unable to save. Your previous data is preserved. \(error.localizedDescription)" }
    }
}
@main struct StackApp: App {
    @StateObject private var store = StackStore()
    var body: some Scene { WindowGroup { StackRoot().environmentObject(store) } }
}
struct StackRoot: View {
    @EnvironmentObject private var store: StackStore
    @Environment(\.scenePhase) private var phase
    @AppStorage("biometricLock") private var lock = false
    @State private var unlocked = false
    var body: some View {
        Group {
            if phase != .active {
                VStack(spacing: 16) { Image(systemName: "square.stack.3d.up").font(.largeTitle); Text("Stack").font(.title) }
            } else if lock && !unlocked {
                VStack(spacing: 20) { Image(systemName: "lock.shield").font(.largeTitle); Text("Stack is locked").font(.title); Button("Unlock", action: authenticate) }
            } else {
                TabView {
                    NavigationStack { DashboardView() }.tabItem { Label("Overview", systemImage: "square.grid.2x2") }
                    NavigationStack { TransactionsView() }.tabItem { Label("Activity", systemImage: "list.bullet.rectangle") }
                    NavigationStack { PlanningView() }.tabItem { Label("Plan", systemImage: "chart.pie") }
                    NavigationStack { SettingsView() }.tabItem { Label("Settings", systemImage: "gearshape") }
                }.tint(.teal)
            }
        }
        .privacySensitive()
        .onChange(of: phase) { _, new in if new != .active { unlocked = false } }
        .alert("Stack", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
    }
    func authenticate() {
        let context = LAContext()
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Access your financial information") { success, _ in Task { @MainActor in unlocked = success } }
    }
}
func money(_ amount: Decimal, currency: String = "CAD") -> String { amount.formatted(.currency(code: currency)) }
