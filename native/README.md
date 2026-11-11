# Stack native iOS foundation

A real SwiftUI iOS 17 application alongside the preserved launch website. No sample transactions are loaded. This is an initial functional implementation, not a completed banking product.

## Run on a Mac

1. Install Xcode 16 or later. Open `native/Stack.xcodeproj`.
2. Select the **Stack** scheme and an iPhone simulator, then Run.
3. For a physical device, choose your signing team and a unique bundle identifier in Signing & Capabilities. Device installation and distribution require appropriate Apple signing configuration; App Store distribution requires Apple Developer membership.
4. In Settings add a manual CAD account. Add transactions in Activity, budgets/goals in Plan, or import CSV in Settings.

The local `StackCore` Swift package resolves without third-party dependencies. Run core tests with `swift test --package-path native`. Build without signing with:

```sh
xcodebuild -project native/Stack.xcodeproj -scheme Stack -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

## Accounting and persistence

Money uses Foundation Decimal throughout accounting. Chart rendering converts already-calculated Decimal amounts to Double only for presentation. CAD is the default; transactions keep their currency, account, source, stable provider ID, original description and timestamps. No exchange-rate conversion is performed. Dashboard and budgets aggregate CAD only. Manual account balances initially equal zero and are separate from transaction totals.

Transaction amounts are positive magnitudes; expense/income/transfer/refund determines treatment. Spending uses posted expenses less refunds, excluding transfers and user exclusions. Periods are start-inclusive and end-exclusive. Pending transactions never count in posted spending. Imported merchant/category/type corrections, notes, tags, and splits survive synchronization. If a provider changes a split transaction's amount, splits are preserved and marked for review; until corrected, category calculations assign the full amount to Other.

A single Codable ledger is atomically replaced under Application Support with complete iOS file protection. Sync stages all pages and commits data and cursor together through the persistence layer; a failed page does not advance the original cursor. Provider IDs are scoped by source/account. FinancialProvider is a replaceable data-source protocol, not a configured bank connection. The backend's Plaid cursor is Item-scoped, whereas the generic app sync abstraction is account-scoped: a future bridge must distribute durable server changes to each account, rather than independently advancing a Plaid Item cursor for each account.

Corrupt local files are never silently reset. A validated restore retains the unreadable file as a recovery copy before replacement. Backup exports include records, edits, rules, goals, budgets and sync metadata; they contain financial information. Device lock uses LocalAuthentication with device passcode fallback. Keychain support is available for future app session tokens, with this-device-only access. No provider secrets or banking passwords belong in this app.

## CSV

Import uses UTF-8, comma delimiters, unique column headings, quoted fields, ISO YYYY-MM-DD dates, and plain decimal amounts (at most two fractional digits). Map date, merchant, and either signed amount (negative expense/positive income) or positive debit and credit columns. Choose the account; currency comes from that account. Preview precedes every import. Invalid rows reject the entire preview.

Stable keys use account/currency/date/merchant/amount plus occurrence number within the file. Reimporting the same rows is idempotent, including identical purchases in one file. Overlapping exports with different subsets of identical purchases can be ambiguous; review the preview and original bank statement. CSV imports do not reconcile against bank-provider transactions. Refund and transfer types can be corrected after importing. Export includes explicit magnitude and type columns and escapes spreadsheet formula prefixes. The export is for analysis; use JSON backup for exact restore.

## Current limitations

- No configured automatic bank connection or native Plaid Link flow. No live BMO, Plaid, Render, or alternate-provider validation has occurred.
- Backend ingestion exists as an encrypted single-owner job; authenticated API delivery into iOS, accounts/balance ingestion, webhook verification, multiuser authorization, APNs and deployment are still required.
- No WidgetKit, watchOS, ActivityKit, notification scheduling or iCloud targets yet. Six App Intents expose spending, budget, goals, recent records, bill candidates and Open Stack with device authentication for financial queries; manual-entry intents remain pending. Siri/device behavior requires validation.
- No budget rollover, historical budget versioning/editing, income schedules, dashboard card reordering, full insights engine or subscription confirmation/reminders.
- Rules can be added; rule editing/reordering/removal and custom category management need further work. Budgets can be created for custom periods and deleted; editing/versioning is pending.
- Recurrence detection produces suspected candidates after three charges; it cannot establish that a service remains active. Goal contributions are manually recorded, not bank transfers.
- Head Quarter exposes only an allowlisted protocol/data structure; no adapter is connected and no telemetry is transmitted.
- Device authentication, accessibility, UI behavior, Apple signing and file protection need simulator/device validation. Unit tests do not establish UI or banking correctness.

See `docs/REPOSITORY-ASSESSMENT.md` and `backend/README.md` at repository root for discovery and integration findings.
