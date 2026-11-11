# Repository recovery assessment — 2026-11-11

## Discovery and selection

The initial managed Linux workspace contained no usable Git checkout. Authorized GitHub discovery found:

- `jacksonpjwilson-dev/stack`: existing browser finance application with JavaScript data models, imports, account relinking, refresh worker, Firebase synchronization and tests.
- `jacksonpjwilson-dev/stack-launch`: promotional GitHub Pages website and screenshots. The owner explicitly selected this repository for native implementation after being asked which candidate to modify.
- A separate private BMO/Plaid feasibility test repository: minimal Node server and Plaid Link client. Source was inspected read-only; no live financial data or provider credentials were retrieved.

All eight visible branches of `stack` were inspected for native project/instruction/configuration paths: main, fix-1, fix-2, fix-mask-match, refresh-btn, revamp, revamp-2, widget-home. No Swift, Xcode, AGENTS.md, database schema, or Render configuration paths were found in those trees. The selected launch repository has no preexisting native project. Its original website files remain unchanged. No duplicate GitHub repository was created.

Development branch: `codex/native-stack-foundation`, based on `stack-launch/main` at `8a204741c5507ef24946b07ae3c5b1ec79d4bf06`.

## Preserved work and useful behavior

The original launch site, image assets and smoke checks are retained. The browser app and private feasibility backend have not been modified. Their existing pending-ID reconciliation, account identity handling, local import strategy and refresh-job behavior informed the new design. No claim is made that the browser app or Firebase deployment is currently operational: they have not been exercised against live services.

The original browser importer uses JavaScript Number accounting, snapshot import and heuristic pending matching. Those financial calculations were not copied into native accounting; new financial calculations use Decimal and explicit pending identifiers. The refresh worker delegates data retrieval to an external Finance/Penny routine and writes populated snapshot files; it is not itself a durable Plaid transaction provider and was not activated in this environment.

## BMO/Plaid findings from source

The feasibility backend:

- Calls production Plaid and requests the Transactions product with `country_codes: ['CA']` and `transactions.days_requested: 30` when creating Link tokens.
- Calls `/transactions/sync` with count 100, handles added/modified/removed and follows `has_more`, with at most 15 pages per invocation.
- Stores access token, Item ID, cursor, cached transactions and cookie-signing key only in process memory. A restart loses the local connection state even though the provider Item can remain active.
- Displays the most recent 20 cached transactions. This display cap alone cannot explain a total count of one, but can obscure the difference between returned rows and cached totals.
- Does not durably persist cursors or a complete pagination batch, recover pagination mutation errors, reconcile pending transaction IDs, ingest account metadata, register verified webhooks, or run scheduled ingestion.
- Starts data retrieval on request; successful Link does not prove that initial transaction ingestion is complete.

These are concrete reliability gaps, not a demonstrated explanation for the reported September 29 transaction. No deployment URL, live Item diagnostics, permissions, provider request IDs, transaction-update status or Render logs were available. HTTP 502 can originate at the deployment/proxy or unavailable application; source inspection cannot establish its cause. BMO's institution-specific available history and production eligibility have not been verified. No account relinking was attempted and no missing transactions were synthesized.

## Investigation to perform with authorized deployment access

1. Preserve the existing Item; inspect Transactions product access, granted accounts and initial/historical update status using authorized Plaid diagnostics.
2. Compare provider counts, earliest/latest dates, `has_more`, request IDs and cache totals without logging tokens or transaction payloads.
3. Verify that the existing cursor survives process restarts and that no date, account, display or pending-status filter truncates results.
4. Retry incomplete initialization rather than relinking. On pagination mutation restart the batch from its original cursor.
5. Inspect Render startup/health logs and durable volume configuration to distinguish 502 availability from data-ingestion issues.
6. If Plaid/BMO cannot supply older history, explain the verified limit and use CSV. Increasing a new Link history request is not evidence that the bank will supply that history and is not a reason to create duplicate Items.

## Verification boundaries

Local Node tests verify the ingestion engine using synthetic provider responses and encrypted temporary storage. The preserved launch site has its original smoke checks. Swift core tests and an Xcode simulator build are configured in a macOS GitHub Actions workflow. Record actual run outcomes in the PR; configuration alone is not a successful build. This Linux host has no Xcode, iOS SDK or simulator.

## Local validation

The final financial core built with the official Swift 6.0.3 Linux toolchain and all 29 tests passed. Six synthetic Node ingestion tests pass, along with 55 repository smoke checks. App and widget source syntax, property lists and entitlements were checked locally. These are not substitutes for Xcode compilation or device security validation; see the Native iOS workflow for the separate Apple build result. The attempted macos-14 runner was explicitly rejected as unsupported by GitHub; the workflow uses the supported macos-15 label.
