// Optional end-to-end browser check. Every Plaid API and the Link SDK are mocked.
import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import os from "node:os";
import path from "node:path";
import { storage } from "./storage.mjs";
import { createTestServer } from "./server.mjs";
const { chromium } = await import(
  process.env.STACK_PLAYWRIGHT_MODULE || "playwright"
);
const dir = await mkdtemp(path.join(os.tmpdir(), "stack-bmo-browser-"));
let browser, app;
try {
  execFileSync(
    "openssl",
    [
      "req",
      "-x509",
      "-newkey",
      "rsa:2048",
      "-nodes",
      "-days",
      "1",
      "-subj",
      "/CN=localhost",
      "-keyout",
      path.join(dir, "test.key"),
      "-out",
      path.join(dir, "test.crt"),
    ],
    { stdio: "ignore" },
  );
  const store = await storage(dir),
    calls = [];
  const plaid = {
    link: async () => {
      calls.push("link");
      return { link_token: "synthetic-link" };
    },
    call: async (endpoint) => {
      calls.push(endpoint);
      switch (endpoint) {
        case "/item/public_token/exchange":
          return {
            access_token: "synthetic-private-token",
            item_id: "synthetic-item",
          };
        case "/item/get":
          return { item: { institution_id: "synthetic-institution" } };
        case "/institutions/get_by_id":
          return {
            institution: {
              name: "BMO Bank of Montreal",
              country_codes: ["CA"],
            },
          };
        case "/accounts/get":
          return {
            accounts: [
              {
                account_id: "private-account",
                type: "depository",
                subtype: "checking",
              },
            ],
          };
        case "/accounts/balance/get":
          return {
            accounts: [
              {
                account_id: "private-account",
                type: "depository",
                subtype: "checking",
                balances: { current: 111111 },
              },
            ],
          };
        case "/transactions/sync":
          return {
            added: [
              {
                transaction_id: "synthetic-tx",
                account_id: "private-account",
                date: "2026-01-01",
                amount: 222222,
                name: "DO_NOT_EXPOSE",
              },
            ],
            modified: [],
            removed: [],
            next_cursor: "final",
            has_more: false,
            transactions_update_status: "HISTORICAL_UPDATE_COMPLETE",
          };
        default:
          throw Error("UNEXPECTED_ENDPOINT");
      }
    },
  };
  app = await createTestServer({
    store: store.item,
    plaid,
    origin: "https://localhost:18766",
    tls: {
      key: await readFile(path.join(dir, "test.key")),
      cert: await readFile(path.join(dir, "test.crt")),
    },
  });
  await new Promise((resolve) =>
    app.server.listen(18766, "127.0.0.1", resolve),
  );
  browser = await chromium.launch({
    executablePath: process.env.STACK_BROWSER_EXECUTABLE || "/usr/bin/chromium",
    headless: true,
    args: ["--no-sandbox"],
  });
  const context = await browser.newContext({ ignoreHTTPSErrors: true }); // Local synthetic certificate only.
  await context.route("https://cdn.plaid.com/**", (route) =>
    route.fulfill({
      contentType: "text/javascript",
      body: "window.Plaid={create:options=>({open:()=>options.onSuccess('public-production-synthetic')})};",
    }),
  );
  const page = await context.newPage(),
    errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  page.on("dialog", (d) => d.accept());
  await page.goto("https://localhost:18766/#unlock=" + app.bootstrap);
  await page.waitForFunction(
    () => !document.getElementById("connect").disabled,
  );
  assert.equal(calls.length, 0);
  await page.locator("#connect").click();
  await page.waitForFunction(() => !document.getElementById("sync").disabled);
  assert.deepEqual(calls, ["link", "/item/public_token/exchange"]);
  assert.ok(!page.url().includes("unlock="));
  await page.locator("#sync").click();
  await page.waitForFunction(() =>
    document
      .getElementById("report")
      .textContent.includes('"historyComplete": true'),
  );
  const text = await page.locator("#report").innerText();
  for (const sensitive of [
    "synthetic-private-token",
    "private-account",
    "DO_NOT_EXPOSE",
    "111111",
    "222222",
  ])
    assert.ok(!text.includes(sensitive));
  assert.deepEqual(errors, []);
  if (process.env.STACK_SCREENSHOT)
    await page.screenshot({
      path: process.env.STACK_SCREENSHOT,
      fullPage: true,
    });
  console.log(
    "Browser test passed: HTTPS session, explicit Link consent, separate retrieval, redacted report, no page errors. All providers mocked.",
  );
} finally {
  if (browser) await browser.close();
  if (app) {
    app.stop();
    await app.finished();
    await new Promise((resolve) => app.server.close(resolve));
  }
  await rm(dir, { recursive: true, force: true });
}
