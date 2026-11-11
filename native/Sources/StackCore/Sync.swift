import Foundation

public struct SyncPage {
  public var entries: [Entry]
  public var removedIDs: [String]
  public var nextCursor: String
  public var hasMore: Bool
  public init(entries: [Entry], removedIDs: [String] = [], nextCursor: String, hasMore: Bool) {
    self.entries = entries
    self.removedIDs = removedIDs
    self.nextCursor = nextCursor
    self.hasMore = hasMore
  }
}
public protocol FinancialProvider {
  var id: String { get }
  func page(accountID: String, cursor: String?) async throws -> SyncPage
}
public enum Synchronizer {
  /// Stage the complete pagination batch. Caller must persist ledger + cursor atomically.
  public static func synchronize(
    _ ledger: Ledger, accountID: String, provider: any FinancialProvider
  ) async throws -> Ledger {
    guard ledger.accounts.contains(where: { $0.id == accountID }) else {
      throw CoreError.disconnected
    }
    var staged = ledger
    let scope = provider.id + ":" + accountID
    var cursor = ledger.sync[scope]?.cursor
    var seen = Set<String>()
    for _ in 0..<1000 {
      let page = try await provider.page(accountID: accountID, cursor: cursor)
      guard !page.nextCursor.isEmpty, !seen.contains(page.nextCursor),
        !page.hasMore || page.nextCursor != cursor
      else { throw CoreError.invalidPage }
      seen.insert(page.nextCursor)
      for var entry in page.entries {
        guard entry.accountID == accountID, entry.provider == provider.id else {
          throw CoreError.invalidPage
        }
        try Finance.validate(entry)
        let index =
          staged.entries.firstIndex { $0.key == entry.key }
          ?? staged.entries.firstIndex {
            $0.provider == provider.id && $0.accountID == accountID && $0.pending
              && $0.id == entry.pendingID
          }
        let previous =
          index.map { staged.entries[$0] }
          ?? ledger.entries.first {
            $0.provider == provider.id && $0.accountID == accountID
              && ($0.id == entry.id || ($0.pending && $0.id == entry.pendingID))
          }
        entry.syncedAt = Date()
        if let old = previous {
          entry.kindOverride = old.kindOverride
          entry.correction = old.correction
          entry.categoryOverride = old.categoryOverride
          entry.notes = old.notes
          entry.tags = old.tags
          entry.excluded = old.excluded
          // Preserve corrections. Invalid splits are reported and counted as Other until reviewed.
          entry.splits = old.splits
        }
        if let index { staged.entries[index] = entry } else { staged.entries.append(entry) }
        if !entry.pending, let pendingID = entry.pendingID {
          staged.entries.removeAll {
            $0.provider == provider.id && $0.accountID == accountID && $0.pending
              && $0.id == pendingID
          }
        }
      }
      staged.entries.removeAll {
        $0.provider == provider.id && $0.accountID == accountID && page.removedIDs.contains($0.id)
      }
      cursor = page.nextCursor
      if !page.hasMore {
        staged.sync[scope] = SyncState(cursor: cursor, lastSuccess: Date(), errorCode: nil)
        return staged
      }
    }
    throw CoreError.invalidPage
  }
}
public enum LedgerFile {
  public static func load(_ url: URL) throws -> Ledger {
    guard FileManager.default.fileExists(atPath: url.path) else { return Ledger() }
    return try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: url))
  }
  public static func save(_ ledger: Ledger, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(ledger)
    #if os(iOS)
      try data.write(to: url, options: [.atomic, .completeFileProtection])
    #else
      try data.write(to: url, options: .atomic)
    #endif
  }
}
