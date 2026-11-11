import LocalAuthentication
import StackCore
import SwiftUI

@MainActor final class StackStore: ObservableObject {
  @Published private(set) var ledger = Ledger()
  @Published var error: String?
  private let url = URL.applicationSupportDirectory.appending(path: "Stack/ledger.json")
  init() {
    do {
      ledger = try LedgerFile.load(url)
      WidgetCache.publish(ledger)
    } catch {
      self.error =
        "Stored data could not be read. It has been preserved; restore a backup before making changes."
      readFailed = true
    }
  }
  private var readFailed = false
  func restore(_ candidate: Ledger) {
    do {
      if readFailed && FileManager.default.fileExists(atPath: url.path) {
        let recovery = url.deletingLastPathComponent().appendingPathComponent(
          "unreadable-" + UUID().uuidString + ".json")
        try FileManager.default.copyItem(at: url, to: recovery)
      }
      try LedgerFile.save(candidate, to: url)
      ledger = candidate
      readFailed = false
      WidgetCache.publish(candidate)
    } catch { self.error = "Restore failed; existing records were preserved." }
  }
  func update(_ change: (inout Ledger) throws -> Void) {
    guard !readFailed else {
      error = "Resolve the unreadable data file before saving."
      return
    }
    do {
      var next = ledger
      try change(&next)
      try LedgerFile.save(next, to: url)
      ledger = next
      WidgetCache.publish(next)
    } catch {
      self.error = "Unable to save. Your previous data is preserved. \(error.localizedDescription)"
    }
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
  @State private var tab = 0
  var body: some View {
    Group {
      if phase != .active {
        VStack(spacing: 16) {
          Image(systemName: "square.stack.3d.up").font(.largeTitle)
          Text("Stack").font(.title)
        }
      } else if lock && !unlocked {
        VStack(spacing: 20) {
          Image(systemName: "lock.shield").font(.largeTitle)
          Text("Stack is locked").font(.title)
          Button("Unlock", action: authenticate)
        }
      } else {
        TabView(selection: $tab) {
          NavigationStack { DashboardView() }.tabItem {
            Label("Overview", systemImage: "square.grid.2x2")
          }.tag(0)
          NavigationStack { TransactionsView() }.tabItem {
            Label("Activity", systemImage: "list.bullet.rectangle")
          }.tag(1)
          NavigationStack { PlanningView() }.tabItem { Label("Plan", systemImage: "chart.pie") }
            .tag(2)
          NavigationStack { SettingsView() }.tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(3)
        }.tint(.teal)
      }
    }
    .privacySensitive()
    .onOpenURL { url in if url.scheme == "stack" && url.host == "overview" { tab = 0 } }
    .onChange(of: phase) { _, new in if new != .active { unlocked = false } }
    .alert(
      "Stack",
      isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })
    ) {
      Button("OK") { store.error = nil }
    } message: {
      Text(store.error ?? "")
    }
  }
  func authenticate() {
    let context = LAContext()
    context.evaluatePolicy(
      .deviceOwnerAuthentication, localizedReason: "Access your financial information"
    ) { success, _ in Task { @MainActor in unlocked = success } }
  }
}
func money(_ amount: Decimal, currency: String = "CAD") -> String {
  amount.formatted(.currency(code: currency))
}
