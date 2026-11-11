import Foundation
import StackCore
import WidgetKit

@MainActor enum WidgetCache {
  static func publish(_ ledger: Ledger) {
    guard
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: WidgetSnapshot.groupID)
    else { return }
    let visible = UserDefaults.standard.bool(forKey: "widgetValuesVisible")
    let snapshot = WidgetSnapshot(ledger: ledger, valuesVisible: visible)
    do {
      try JSONEncoder().encode(snapshot).write(
        to: container.appendingPathComponent("snapshot.json"),
        options: [.atomic, .completeFileProtection])
      WidgetCenter.shared.reloadAllTimelines()
    } catch { /* Cache is optional; never log financial values. */  }
  }
}
