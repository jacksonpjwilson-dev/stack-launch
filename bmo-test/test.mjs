import { test } from "node:test";
import http from "node:http";
import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, stat } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { createTestServer } from "./server.mjs";
import { storage } from "./storage.mjs";
import { ProductionPlaid, syncBatch, diagnostics } from "./plaid.mjs";
const page = (
  added = [],
  cursor = "cursor",
  more = false,
  status = "HISTORICAL_UPDATE_COMPLETE",
) => ({
  accounts: [],
  added,
  modified: [],
  removed: [],
  next_cursor: cursor,
  has_more: more,
  transactions_update_status: status,
  request_id: "synthetic-request",
});
const transaction = (id, extras = {}) => ({
  transaction_id: id,
  account_id: "account-a",
  date: "2026-01-02",
  pending: false,
  name: "SENSITIVE_MERCHANT",
  amount: 12345,
  ...extras,
});
const item = () => ({
  itemID: "synthetic-item",
  accessToken: "access-production-synthetic",
  transactions: [],
  cursor: null,
});
async function fixture(run) {
  const dir = await mkdtemp(path.join(os.tmpdir(), "stack-bmo-"));
  try {
    await run(await storage(dir));
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}
test("generated key is persistent, private; credentials and Item state are encrypted", async () =>
  fixture(async (store) => {
    await store.credentials.save({ secret: "SENSITIVE_SECRET" });
    await store.item.save(item());
    const key = await readFile(path.join(store.directory, "encryption.key"));
    assert.equal(key.length, 32);
    assert.equal(
      (await stat(path.join(store.directory, "encryption.key"))).mode & 0o777,
      0o600,
    );
    assert.ok(
      !(
        await readFile(path.join(store.directory, "credentials.enc"), "utf8")
      ).includes("SENSITIVE_SECRET"),
    );
    assert.ok(
      !(
        await readFile(path.join(store.directory, "item.enc"), "utf8")
      ).includes("access-production-synthetic"),
    );
    const reopened = await storage(store.directory);
    assert.deepEqual(await reopened.item.load(), item());
    assert.deepEqual(
      await readFile(path.join(store.directory, "encryption.key")),
      key,
    );
  }));
test("empty initial cursor means not ready, not a pagination failure or historical completion", async () => {
  const next = await syncBatch(item(), {
    call: async () => page([], "", false, "NOT_READY"),
  });
  assert.equal(next.cursor, null);
  assert.equal(next.historyStatus, "NOT_READY");
  assert.equal(diagnostics(next).historyComplete, false);
});
test("all pages are ingested, raw financial descriptions and values are discarded", async () => {
  let cursors = [];
  const next = await syncBatch(item(), {
    call: async (_, body) => {
      cursors.push(body.cursor);
      return !body.cursor
        ? page([transaction("a")], "page1", true, "INITIAL_UPDATE_COMPLETE")
        : page([transaction("b", { date: "2026-10-11" })], "done");
    },
  });
  assert.deepEqual(cursors, [undefined, "page1"]);
  assert.equal(next.transactions.length, 2);
  assert.equal(next.lastBatchPages, 2);
  assert.equal(next.cursor, "done");
  assert.ok(!JSON.stringify(next).includes("SENSITIVE_MERCHANT"));
  assert.ok(!JSON.stringify(next).includes("12345"));
  const report = diagnostics({
    ...next,
    accounts: [
      { account_id: "account-a", balanceRetrieved: true },
      { account_id: "zero" },
    ],
  });
  assert.equal(report.accountCount, 2);
  assert.equal(report.accounts[0].transactionCount, 2);
  assert.equal(report.accounts[0].earliestDate, "2026-01-02");
  assert.equal(report.accounts[0].latestDate, "2026-10-11");
  assert.equal(report.accounts[1].transactionCount, 0);
  assert.equal(report.historyComplete, true);
  assert.ok(!JSON.stringify(report).includes("account-a"));
  assert.ok(!JSON.stringify(report).includes("synthetic-item"));
});
test("production Link requests CA Transactions and maximum history; Balance is not passed as Link product", async () => {
  let sent;
  const plaid = new ProductionPlaid(
    {
      clientID: "synthetic",
      secret: "synthetic",
      redirect: "https://localhost:8765/oauth",
    },
    async (url, options) => {
      sent = { url, body: JSON.parse(options.body) };
      return Response.json({ link_token: "synthetic-link" });
    },
  );
  await plaid.link("opaque-user");
  assert.equal(sent.url, "https://production.plaid.com/link/token/create");
  assert.deepEqual(sent.body.products, ["transactions"]);
  assert.deepEqual(sent.body.country_codes, ["CA"]);
  assert.equal(sent.body.transactions.days_requested, 730);
});
test("failed/ambiguous token exchange is never automatically retried", async () => {
  let count = 0;
  const plaid = new ProductionPlaid(
    {},
    async () => {
      count++;
      throw Error("network with secret");
    },
    async () => {},
  );
  await assert.rejects(
    plaid.call("/item/public_token/exchange", {}),
    /EXCHANGE_OUTCOME_UNCERTAIN/,
  );
  assert.equal(count, 1);
});
test("provider failures expose only sanitized code and request ID", async () => {
  const plaid = new ProductionPlaid({}, async () =>
    Response.json(
      {
        error_code: "ITEM_LOGIN_REQUIRED",
        request_id: "safe-request",
        error_message: "SENSITIVE_PAYLOAD",
      },
      { status: 400 },
    ),
  );
  await assert.rejects(
    plaid.call("/item/get", {}),
    (e) =>
      e.code === "ITEM_LOGIN_REQUIRED" &&
      e.requestID === "safe-request" &&
      !e.message.includes("SENSITIVE"),
  );
});
async function localServer(store, plaid, run, options = {}) {
  const origin = "http://127.0.0.1:18765";
  const app = await createTestServer({
    store: store.item,
    plaid,
    origin,
    historyWait: async () => {},
    ...options,
  });
  await new Promise((resolve) =>
    app.server.listen(18765, "127.0.0.1", resolve),
  );
  async function request(
    route,
    data,
    { cookie, token, customOrigin = origin, host } = {},
  ) {
    return fetch(origin + "/api/" + route, {
      method: data === undefined ? "GET" : "POST",
      headers: {
        ...(data === undefined
          ? {}
          : { "Content-Type": "application/json", Origin: customOrigin }),
        ...(cookie ? { Cookie: cookie } : {}),
        ...(token ? { Authorization: "Bearer " + token } : {}),
        ...(host ? { Host: host } : {}),
      },
      body: data === undefined ? undefined : JSON.stringify(data),
    });
  }
  try {
    await run({
      app,
      request,
      unlock: async () => {
        const r = await request("unlock", {}, { token: app.bootstrap });
        assert.equal(r.status, 200);
        return r.headers.get("set-cookie").split(";")[0];
      },
    });
  } finally {
    app.stop();
    await app.finished();
    await new Promise((resolve) => app.server.close(resolve));
  }
}
test("startup/report never call Plaid; authentication, CSRF and Host checks prevent unauthorized actions", async () =>
  fixture(async (store) => {
    let calls = 0;
    const plaid = {
      link: async () => {
        calls++;
        return { link_token: "synthetic" };
      },
    };
    await localServer(store, plaid, async ({ request, unlock }) => {
      assert.equal(calls, 0);
      assert.equal((await request("report")).status, 401);
      const cookie = await unlock();
      assert.equal(
        (await request("report", undefined, { cookie })).status,
        200,
      );
      assert.equal(calls, 0);
      assert.equal(
        (
          await request(
            "link-token",
            { confirm: "AUTHORIZE_BMO_LINK" },
            { cookie, customOrigin: "https://evil.example" },
          )
        ).status,
        403,
      );
      const rejectedHost = await new Promise((resolve, reject) => {
        const req = http.request(
          "http://127.0.0.1:18765/api/report",
          { headers: { Host: "evil.example", Cookie: cookie } },
          (res) => {
            res.resume();
            resolve(res.statusCode);
          },
        );
        req.on("error", reject);
        req.end();
      });
      assert.equal(rejectedHost, 403);
      assert.equal((await request("link-token", {}, { cookie })).status, 400);
      assert.equal(calls, 0);
      assert.equal(
        (
          await request(
            "link-token",
            { confirm: "AUTHORIZE_BMO_LINK" },
            { cookie },
          )
        ).status,
        200,
      );
      assert.equal(calls, 1);
    });
  }));
test("Link exchange persists connection but does not retrieve data; repeated connection is blocked", async () =>
  fixture(async (store) => {
    const calls = [];
    const plaid = {
      call: async (endpoint) => {
        calls.push(endpoint);
        assert.equal(endpoint, "/item/public_token/exchange");
        return { item_id: "synthetic-item", access_token: "secret-token" };
      },
    };
    await localServer(store, plaid, async ({ request, unlock }) => {
      const cookie = await unlock();
      assert.equal(
        (
          await request(
            "exchange",
            { public_token: "public-production-synthetic" },
            { cookie },
          )
        ).status,
        200,
      );
      assert.deepEqual(calls, ["/item/public_token/exchange"]);
      assert.equal((await store.item.load()).accessToken, "secret-token");
      assert.equal(
        (
          await request(
            "exchange",
            { public_token: "public-production-other" },
            { cookie },
          )
        ).status,
        409,
      );
      assert.equal((await request("sync", {}, { cookie })).status, 400);
      assert.deepEqual(calls, ["/item/public_token/exchange"]);
      const report = await (
        await request("report", undefined, { cookie })
      ).json();
      assert.equal(report.connected, true);
      assert.equal(report.totalTransactions, 0);
      assert.ok(!JSON.stringify(report).includes("secret-token"));
    });
  }));
test("explicit retrieval verifies BMO, checks balances, polls historical completion and persists cursor", async () =>
  fixture(async (store) => {
    await store.item.save(item());
    let pages = 0,
      calls = [];
    const plaid = {
      call: async (endpoint) => {
        calls.push(endpoint);
        if (endpoint === "/item/get")
          return { item: { institution_id: "synthetic-ca" } };
        if (endpoint === "/institutions/get_by_id")
          return {
            institution: {
              name: "BMO Bank of Montreal",
              country_codes: ["CA"],
            },
          };
        if (endpoint === "/accounts/get") return { accounts: [] };
        if (endpoint === "/accounts/balance/get")
          return {
            accounts: [
              {
                account_id: "account-a",
                type: "depository",
                subtype: "checking",
                balances: { current: 999999 },
              },
            ],
          };
        if (endpoint === "/transactions/sync")
          return ++pages === 1
            ? page(
                [transaction("a")],
                "first",
                false,
                "INITIAL_UPDATE_COMPLETE",
              )
            : page([transaction("b")], "last");
        throw Error("unexpected endpoint");
      },
    };
    await localServer(store, plaid, async ({ request, unlock, app }) => {
      assert.equal(calls.length, 0);
      const cookie = await unlock();
      assert.equal(
        (
          await request(
            "sync",
            { confirm: "RETRIEVE_BALANCES_AND_HISTORY" },
            { cookie },
          )
        ).status,
        202,
      );
      await app.finished();
      const report = await (
        await request("report", undefined, { cookie })
      ).json();
      assert.equal(report.historyComplete, true);
      assert.equal(report.totalTransactions, 2);
      assert.equal(pages, 2);
      assert.equal(report.accounts[0].balanceRetrieved, true);
      const state = await store.item.load();
      assert.equal(state.cursor, "last");
      assert.ok(!JSON.stringify(state).includes("999999"));
    });
  }));
test("non-BMO institution is stopped before balance or transaction retrieval", async () =>
  fixture(async (store) => {
    await store.item.save(item());
    let calls = [];
    const plaid = {
      call: async (endpoint) => {
        calls.push(endpoint);
        return endpoint === "/item/get"
          ? { item: { institution_id: "other" } }
          : { institution: { name: "Other Bank", country_codes: ["CA"] } };
      },
    };
    await localServer(store, plaid, async ({ request, unlock, app }) => {
      const cookie = await unlock();
      await request(
        "sync",
        { confirm: "RETRIEVE_BALANCES_AND_HISTORY" },
        { cookie },
      );
      await app.finished();
      assert.deepEqual(calls, ["/item/get", "/institutions/get_by_id"]);
      assert.equal(
        app.report().errors[0].code,
        "SELECTED_INSTITUTION_IS_NOT_VERIFIED_CANADIAN_BMO",
      );
    });
  }));
test("incomplete backfill pauses without falsely claiming historical completion; process restart retains Item", async () =>
  fixture(async (store) => {
    await store.item.save(item());
    const plaid = {
      call: async (endpoint) => {
        if (endpoint === "/item/get") return { item: { institution_id: "ca" } };
        if (endpoint === "/institutions/get_by_id")
          return { institution: { name: "BMO", country_codes: ["CA"] } };
        if (endpoint === "/accounts/get") return { accounts: [] };
        if (endpoint === "/accounts/balance/get") return { accounts: [] };
        return page([], "", false, "NOT_READY");
      },
    };
    await localServer(
      store,
      plaid,
      async ({ request, unlock, app }) => {
        const cookie = await unlock();
        await request(
          "sync",
          { confirm: "RETRIEVE_BALANCES_AND_HISTORY" },
          { cookie },
        );
        await app.finished();
        assert.equal(app.report().historyComplete, false);
        assert.equal(app.report().historyStatus, "NOT_READY");
        assert.equal(app.report().paused, true);
      },
      { historyDeadlineMS: 0 },
    );
    await localServer(
      store,
      {
        call: () => {
          throw Error("NO_STARTUP_NETWORK_ALLOWED");
        },
      },
      async ({ app }) => {
        assert.equal(app.report().connected, true);
        assert.equal(app.report().historyStatus, "NOT_READY");
      },
    );
  }));
test("ambiguous exchange is durably blocked against repeated linking", async () =>
  fixture(async (store) => {
    const plaid = {
      call: async () => {
        throw Object.assign(Error("EXCHANGE_OUTCOME_UNCERTAIN"), {
          code: "EXCHANGE_OUTCOME_UNCERTAIN",
        });
      },
    };
    await localServer(store, plaid, async ({ request, unlock, app }) => {
      const cookie = await unlock();
      assert.equal(
        (
          await request(
            "exchange",
            { public_token: "public-production-test" },
            { cookie },
          )
        ).status,
        502,
      );
      assert.equal(app.report().exchangeUncertain, true);
      assert.equal(
        (
          await request(
            "link-token",
            { confirm: "AUTHORIZE_BMO_LINK" },
            { cookie },
          )
        ).status,
        409,
      );
    });
    assert.equal((await store.item.load()).exchangeStarted, true);
  }));
test("explicit disconnect removes provider Item and clears persisted connection", async () =>
  fixture(async (store) => {
    await store.item.save(item());
    let removed = false;
    await localServer(
      store,
      {
        call: async (endpoint) => {
          assert.equal(endpoint, "/item/remove");
          removed = true;
          return {};
        },
      },
      async ({ request, unlock, app }) => {
        const cookie = await unlock();
        assert.equal((await request("disconnect", {}, { cookie })).status, 400);
        assert.equal(removed, false);
        assert.equal(
          (
            await request(
              "disconnect",
              { confirm: "REMOVE_PLAID_ITEM" },
              { cookie },
            )
          ).status,
          200,
        );
        assert.equal(removed, true);
        assert.equal(app.report().connected, false);
        assert.equal((await store.item.load()).accessToken, undefined);
      },
    );
  }));
test("stopping pagination discards incomplete batch and keeps durable original cursor", async () => {
  let calls = 0;
  await assert.rejects(
    syncBatch(
      item(),
      {
        call: async () => {
          calls++;
          return page(
            [transaction("partial")],
            "partial-cursor",
            true,
            "INITIAL_UPDATE_COMPLETE",
          );
        },
      },
      () => calls > 0,
    ),
    /SYNC_STOPPED/,
  );
  assert.equal(calls, 1);
});
test("balance permission failure does not hide transaction feasibility or accounts with no transactions", async () =>
  fixture(async (store) => {
    await store.item.save(item());
    const plaid = {
      call: async (endpoint) => {
        if (endpoint === "/item/get")
          return {
            item: {
              institution_id: "ca",
              available_products: ["balance"],
              consented_products: ["transactions"],
            },
          };
        if (endpoint === "/institutions/get_by_id")
          return { institution: { name: "BMO", country_codes: ["CA"] } };
        if (endpoint === "/accounts/get")
          return {
            accounts: [
              { account_id: "account-a", type: "depository" },
              { account_id: "empty-account", type: "credit" },
            ],
          };
        if (endpoint === "/accounts/balance/get")
          throw Object.assign(Error("PRODUCT_NOT_ENABLED"), {
            code: "PRODUCT_NOT_ENABLED",
          });
        return page([transaction("a")]);
      },
    };
    await localServer(store, plaid, async ({ request, unlock, app }) => {
      const cookie = await unlock();
      await request(
        "sync",
        { confirm: "RETRIEVE_BALANCES_AND_HISTORY" },
        { cookie },
      );
      await app.finished();
      const report = app.report();
      assert.equal(report.historyComplete, true);
      assert.equal(report.accountCount, 2);
      assert.equal(report.accounts[1].transactionCount, 0);
      assert.equal(report.errors[0].stage, "balance");
      assert.equal(report.errors[0].code, "PRODUCT_NOT_ENABLED");
    });
  }));
test("stop prevents another provider retry after the current network request", async () => {
  let calls = 0,
    stopped = false;
  const plaid = new ProductionPlaid(
    {},
    async () => {
      calls++;
      return Response.json(
        { error_code: "INTERNAL_SERVER_ERROR" },
        { status: 500 },
      );
    },
    async () => {
      stopped = true;
    },
  );
  await assert.rejects(
    plaid.call("/accounts/get", {}, () => stopped),
    /SYNC_STOPPED/,
  );
  assert.equal(calls, 1);
});
