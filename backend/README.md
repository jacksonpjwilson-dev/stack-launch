# Optional read-only ingestion foundation

Node 20+; no dependencies. `node --test backend/sync.test.mjs` tests pagination, mutation restarts, idempotent updates/removals, pending reconciliation, retries, encrypted persistence, and single-writer locking with synthetic data.

This is a scheduled single-owner job, not an exposed production API or configured bank connection. No deployment or live provider testing has been performed. It improves the architectural gaps observed in the separate feasibility backend without modifying that experiment or creating extra Items.

The host must provide secret environment bindings (never source files):

- `PLAID_CLIENT_ID`, `PLAID_SECRET`, `PLAID_ENV` (`sandbox` by default; explicitly choose `production` only for authorized existing production access).
- `STACK_ENCRYPTION_KEY`: base64 encoding of exactly 32 cryptographically random bytes, stored in a secret manager. Keep a secured recovery copy; losing this key makes the stored data unrecoverable.
- `STACK_STATE_FILE`: absolute filename on a private durable volume outside any repository, e.g. `/var/lib/stack/state.enc`.
- On first initialization only: `PLAID_ACCESS_TOKEN`, `PLAID_ITEM_ID` for an already-authorized Item. The job never creates or relinks an Item. Remove bootstrap bindings after encrypted state is established.

Run `node backend/job.mjs` via the host's scheduler. Choose an interval consistent with provider limits and the account's service plan; running more often does not force BMO to refresh. Preserve the volume across deployments. State includes sensitive provider transactions and tokens encrypted with AES-256-GCM, mode 0600, and atomic replacement. Cursors are committed only with their complete batch. The encryption key must be managed separately. Local encryption does not substitute for host authorization or backups.

A file lock prevents concurrent jobs. A crash may leave a lock: first verify no job is running, then remove only the stale lock. This is not a distributed lock; use a transactional database and distributed job claiming before multiple workers. The current file persistence is designed for process restarts, not a power-loss durability guarantee. There is no public health or data endpoint to accidentally expose records.

Failures keep previous transactions and cursor, record a sanitized code, and return a nonzero exit status. Retries cover network errors, 429 and 5xx, with timeouts and bounded backoff. Transactions-sync mutation restarts the entire staged pagination sequence from its original cursor. Incomplete initial data is not described as complete history merely because `has_more` becomes false. Item cursors are shared across all accounts in the Item.

## Still required for production/mobile integration

- Owner identity/session system; native provider-approved Link flow; secure token exchange and disconnect/Item removal controls.
- Authenticated HTTPS API and per-owner/per-account authorization, delivering normalized Decimal-safe amounts and stable IDs to iOS. Never put Plaid credentials or access tokens in the client.
- Account metadata/balances, initial/history readiness diagnostics, provider request IDs in redacted diagnostics and configured-account permissions.
- Verified provider webhooks, durable database/job queue for multiworker hosting, validated server configuration, backups and deletion/retention policy.
- Optional APNs delivery only after authenticated device registration and Apple signing/key configuration.
- Real authorized sandbox tests followed by explicit production feasibility checks. No BMO support claim follows from mocked tests.

Plaid production eligibility and fees depend on the provider agreement; costs and available BMO history are unverified. Hosting, durable storage and any APNs infrastructure can add costs. CSV/manual entry works without a banking subscription. Alternative Canadian providers need separately verified BMO coverage and eligibility; none has been claimed or configured.
