import Foundation

/// Explicit allowlist: no balances, account IDs, merchants, or financial payloads.
public struct OperationalStatus: Codable {
  public var appVersion: String
  public var lastSuccessfulSync: Date?
  public var connectionHealth: String
  public var failedSyncJobs: Int
  public var backendAvailable: Bool?
  public var configurationIssues: [String]
}
public protocol OperationalMonitoringAdapter {
  func publish(_ status: OperationalStatus) async throws
}
