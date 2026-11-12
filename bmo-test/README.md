# Private Canadian BMO / Plaid Production test

A temporary, single-owner **local HTTPS** interface. It reuses Stack's encrypted state and staged pagination engine. It does not change or serve the existing Stack website, modify `main`, connect the iOS app, or depend on Codex remaining online. No npm dependencies are required to run it.

**No real BMO connection or financial retrieval has been performed during implementation.** All automated tests use synthetic responses. Your reported active Free Trial is not independently verified by code; actual BMO availability, eligible accounts, product access and trial limits are determined by your Plaid account and Link.

## Launch on your Mac

1. Install **Node.js LTS 22 or newer** from https://nodejs.org if it is not installed. macOS supplies the other required tool, `/usr/bin/openssl`.
2. Obtain the dedicated branch in a separate folder, leaving your usual Stack checkout untouched:

   ```sh
   git clone --branch codex/bmo-production-test https://github.com/jacksonpjwilson-dev/stack-launch.git stack-bmo-test
   cd stack-bmo-test
   ```

3. In Plaid Dashboard, confirm **Production / Free Trial** access to **Transactions**, **Balance**, and Canadian institutions. If using a Link customization, enable Canada and English for it. Do not switch to Sandbox keys. Under **API / Link → Allowed redirect URIs** (labels may vary), register exactly:

   ```text
   https://localhost:8765/oauth
   ```

   Plaid requires HTTPS for Production OAuth redirects. The URI has no query string. This local URI must be accepted by your Dashboard and the relevant OAuth flow; if it is rejected, stop and use the hosting guidance below rather than creating extra Items.

4. Run the one-time credential setup:

   ```sh
   node bmo-test/setup.mjs
   ```

   Paste your **Production Client ID** and **Production Secret** only into these Terminal prompts. Both inputs are hidden, including pasted text. Press Enter to accept the default redirect URI. Do not put credentials into a command, chat, GitHub, an `.env` file in the checkout, or the test page. Setup validates the format locally, generates a random 256-bit encryption key and a localhost TLS key/certificate, and encrypts the credentials. **It makes no Plaid API calls.** Rerunning setup updates credentials but preserves the encryption key and Item.

5. Start the test:

   ```sh
   node bmo-test/server.mjs
   ```

   Alternatively, double-click `bmo-test/Start-BMO-Test.command` after setup. Keep Terminal open. Your browser opens **https://localhost:8765** with a one-use unlock fragment, which the page removes immediately. The unlock value is never printed. Only `127.0.0.1` is bound; the service is not publicly accessible. Do not share its launch URL or forward its port.

6. The first visit uses the certificate generated on your Mac, so your browser will show a certificate warning. Allow **this localhost certificate only**. If Safari requires Keychain trust, open `~/Library/Application Support/Stack BMO Test/localhost.crt`, import into your login Keychain, and set its SSL trust in Keychain Access. This setup does not alter system certificate trust automatically. Never bypass a certificate warning for Plaid or your bank. If the first visit loses its unlock fragment, stop the server with Control-C and restart to reopen it.

7. When ready, click **Connect Canadian BMO through Plaid**, confirm the dialog, choose Canadian BMO, and authorize your selected accounts in **Plaid Link**, not in this page. If BMO is absent or access is denied, stop and retain the redacted error code. Do not create repeated Items. OAuth returns to `/oauth` in the same browser tab and resumes the saved Link session.

8. After Link finishes, the page reports **Connected**. The Item ID and access token have been encrypted, but this app has not called balances, accounts, Item diagnostics or transaction endpoints yet. **Plaid itself can begin its initial ingestion after your Link consent**, because Transactions is initialized by Link. That provider behavior cannot be deferred by the separate retrieval button.

9. Only when you want the real data test to begin, click **Retrieve balances and synchronize history** and confirm. This explicitly authorizes the app to verify the Canadian BMO institution, inspect product access, retrieve account metadata and fresh balances, and consume `/transactions/sync` pages. Each click can incur a Balance request under your Plaid plan. The browser's report refresh reads the local cache and never calls Plaid itself.

10. If historical backfilling is still pending, the job pauses after roughly two minutes between complete batches; in-flight requests, retries or a long pagination batch can take longer. Click the same retrieval button later to continue from the durable cursor. **Do not relink.** The Stop button stops further requests after the current request completes; an unfinished pagination batch is discarded and the prior durable cursor is retained.

No hosting is needed for this local flow if the redirect is accepted. The interface must remain open on your Mac for OAuth return and explicit synchronization.

## Storage and recovery

All runtime material is outside the repository:

```text
~/Library/Application Support/Stack BMO Test/
  encryption.key       random 32-byte key, permissions 0600
  credentials.enc      AES-256-GCM encrypted Production credentials
  item.enc             encrypted Item ID, access token, cursor and diagnostic state
  item.enc.lock        single-process lock while the test server is running
  localhost.key        private localhost TLS key, permissions 0600
  localhost.crt        public localhost certificate (90-day lifetime)
```

The directory is owned by your macOS account with permissions 0700. Secrets are never sent to the browser except Plaid's short-lived Link/public tokens, which Link requires. The access token and Production secret remain server-side. Requests and raw provider payloads are not logged. Stored transaction summaries contain only IDs, dates, pending flags and account associations—no amounts, names or merchant descriptions. Balance values are fetched to establish feasibility but discarded, not displayed or persisted.

The encryption key is protected by local account/file permissions, **not by hardware-backed Keychain storage**. Someone with access to both this directory and your account can decrypt its contents. Keep the directory private; use your Mac's disk encryption for protection at rest. Do not copy it into the checkout or shared folders. Back up the complete directory privately if needed: losing the encryption key makes existing encrypted state unreadable. Setup refuses to generate a replacement key over existing encrypted files.

Control-C closes the server and releases the lock after active work finishes. A crash can leave a stale lock. After confirming that **all copies of this test server are stopped**, remove only the stale lock and restart:

```sh
rm "$HOME/Library/Application Support/Stack BMO Test/item.enc.lock"
node bmo-test/server.mjs
```

Never remove the key or Item file to fix a login problem. If token exchange has an ambiguous outcome, the test blocks new linking because an Item might already exist. Inspect your Plaid Dashboard and resolve that Item before clearing anything. The local **Reveal Item ID** button supplies the debugger identifier after a successful exchange; it is excluded from exported reports.

Use **Remove connected Plaid Item and local results** to call `/item/remove` and clear the stored token, cursor and summaries. Closing the browser/server does not disconnect BMO. Only after successful removal, stop the server and delete the private data directory if you want to erase credentials and keys too. Remove the localhost trust entry in Keychain if you added one and no longer need it.

## What the diagnostic report proves

The downloadable aggregate JSON contains:

- Found-account count, including accounts with zero transactions.
- Opaque `Account 1`, `Account 2` labels, type/subtype and whether a balance was retrieved.
- Total, per-account, posted/pending and unassigned transaction counts.
- Earliest/latest transaction dates per account; no artificial date filter or 20-row display cap.
- Requested history (730 days), last successful sync, last batch page count, redacted request IDs, product-access metadata and stage-specific provider error codes.
- Plaid's actual `transactions_update_status`; **only `HISTORICAL_UPDATE_COMPLETE` is treated as completed backfilling**. `NOT_READY`, `INITIAL_UPDATE_COMPLETE`, unknown status or `has_more: false` alone is not completion.

Pagination, additions, modifications, removals and pending-to-posted reconciliation use stable IDs. Data and cursor are committed atomically per complete batch; mutation-during-pagination errors restart at the original cursor. Empty initial cursors are allowed while the provider is not ready. Network/429/5xx retries are bounded; exchanges are not blindly retried. A Balance failure is reported separately and does not prevent checking Transactions. There is no webhook/public receiver: while explicitly running, polling reads the sync status that Plaid documents as carrying the same historical-update information.

A completed historical update means Plaid finished its available pull, **not that BMO supplied 730 days or all lifetime transactions**. More than one transaction on this fresh Item would establish current feasibility, but would not by itself prove why the old Item returned one transaction: the history request, time window and Item differ. If a completed pull still contains one transaction, the report and request IDs support a Plaid investigation; client-side pagination is tested, but attributing the limit specifically to Plaid versus BMO still requires provider diagnostics/support. The earlier implementation's confirmed gaps remain its 30-day request, in-memory state and 20-row display cap.

Do not upload real reports to GitHub. You may share the aggregate report privately for diagnosis if comfortable with its counts and dates. Never share the local data directory, tokens, Production secret or bank credentials.

## If public HTTPS hosting becomes necessary

This code intentionally accepts **localhost only**. Do not expose it using port forwarding or a public tunnel as-is. If your Plaid/BMO OAuth flow rejects localhost, the simplest hosting direction is one small Node web service with managed HTTPS and a **private persistent disk**, for example a paid Render web service with its disk option. Free/sleeping hosts with ephemeral storage can lose connection state or interrupt backfilling. Hosting and Plaid charges depend on current plans; no service was purchased or deployed here.

Before using a public host, this local harness must be adapted for a fixed registered HTTPS origin, durable separately managed secrets/encryption key, strong owner authentication/session expiry, and hosted OAuth return. We should implement and review that configuration rather than assume this local-only server is internet-ready. Codex is not the persistent host.

## Automated verification

```sh
node --test backend/sync.test.mjs bmo-test/test.mjs
node ci/smoke.mjs
```

The 22 synthetic tests cover encryption/restart persistence, consent boundaries, authentication, Host/Origin checks, full pagination, initialization, history completion, stopping, ambiguous exchange protection, sanitized errors, balance-permission failures and explicit removal. The optional `browser-test.mjs` additionally exercises HTTPS, the interface and consent sequence with a completely mocked Link SDK and mocked provider. It requires Playwright and Chromium for development only; neither is needed for your real local test.

API behavior was checked against Plaid's official OpenAPI specification:
https://github.com/plaid/plaid-openapi/blob/master/2020-09-14.yml

See also:
https://plaid.com/docs/link/oauth/
https://plaid.com/docs/api/products/transactions/#transactionssync
https://plaid.com/docs/api/products/balance/#accountsbalanceget
