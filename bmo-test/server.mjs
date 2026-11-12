import https from "node:https";
import http from "node:http";
import { readFile } from "node:fs/promises";
import { randomBytes, timingSafeEqual } from "node:crypto";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { storage } from "./storage.mjs";
import { ProductionPlaid, syncBatch, diagnostics } from "./plaid.mjs";
import { ProviderError } from "../backend/sync.mjs";
const equal = (a, b) => {
  if (typeof a !== "string") return false;
  const aa = Buffer.from(a),
    bb = Buffer.from(b);
  return aa.length === bb.length && timingSafeEqual(aa, bb);
};
const publicDir = new URL("./public/", import.meta.url);
export async function createTestServer({
  store,
  plaid,
  origin,
  tls,
  openBrowser = false,
  historyWait = (ms) => new Promise((r) => setTimeout(r, ms)),
  historyDeadlineMS = 120000,
}) {
  let state = (await store.load()) ?? {
    userID: randomBytes(24).toString("hex"),
    transactions: [],
  };
  await store.save(state);
  const bootstrap = randomBytes(32).toString("hex"),
    session = randomBytes(32).toString("hex");
  let bootstrapAvailable = true,
    busy = false,
    running = false,
    stopped = false,
    closing = false,
    syncTask = Promise.resolve();
  const expectedHost = new URL(origin).host;
  async function persist(next) {
    await store.save(next);
    state = next;
  }
  function report() {
    return diagnostics(state, {
      running,
      busy,
      paused:
        !!state.accessToken &&
        !running &&
        state.historyStatus !== "HISTORICAL_UPDATE_COMPLETE",
    });
  }
  function send(res, status, value) {
    res.writeHead(status, {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    });
    res.end(JSON.stringify(value));
  }
  async function recordError(error, stage = "sync") {
    const code = /^[A-Z_]{1,100}$/.test(error.code ?? error.message ?? "")
      ? (error.code ?? error.message)
      : "TEST_FAILED";
    const requestID = /^[A-Za-z0-9_-]{1,100}$/.test(error.requestID ?? "")
      ? error.requestID
      : null;
    await persist({
      ...state,
      errors: [
        ...(state.errors ?? []),
        { code, requestID, stage, at: new Date().toISOString() },
      ].slice(-20),
    });
    return code;
  }
  function checkStop() {
    if (stopped || closing) throw new ProviderError("SYNC_STOPPED");
  }
  async function runSync() {
    try {
      // Called ONLY by an authenticated explicit Synchronize action, never startup or Link success.
      const item = await plaid.call(
        "/item/get",
        { access_token: state.accessToken },
        () => stopped || closing,
      );
      checkStop();
      const institution = await plaid.call(
        "/institutions/get_by_id",
        { institution_id: item.item.institution_id, country_codes: ["CA"] },
        () => stopped || closing,
      );
      const name = institution.institution?.name ?? "";
      if (
        !/\bBMO\b|Bank of Montreal/i.test(name) ||
        !institution.institution?.country_codes?.includes("CA")
      )
        throw Error("SELECTED_INSTITUTION_IS_NOT_VERIFIED_CANADIAN_BMO");
      const products = (values) =>
        Array.isArray(values)
          ? values.filter(
              (v) => typeof v === "string" && /^[a-z_]{1,60}$/.test(v),
            )
          : [];
      await persist({
        ...state,
        institutionVerified: true,
        productAccess: {
          available: products(item.item.available_products),
          billed: products(item.item.billed_products),
          consented: products(item.item.consented_products),
        },
      });
      checkStop();
      try {
        const response = await plaid.call(
          "/accounts/get",
          { access_token: state.accessToken },
          () => stopped || closing,
        );
        if (!Array.isArray(response.accounts))
          throw Error("INVALID_ACCOUNTS_RESPONSE");
        await persist({
          ...state,
          accounts: response.accounts.map((a) => ({
            account_id: a.account_id,
            type: a.type,
            subtype: a.subtype,
            balanceRetrieved: false,
          })),
        });
      } catch (error) {
        if (error.code === "SYNC_STOPPED") throw error;
        await recordError(error, "accounts");
      }
      checkStop();
      try {
        const balances = await plaid.call(
          "/accounts/balance/get",
          { access_token: state.accessToken },
          () => stopped || closing,
        );
        const accounts = balances.accounts.map((a) => ({
          account_id: a.account_id,
          type: a.type,
          subtype: a.subtype,
          balanceRetrieved:
            !!a.balances &&
            (a.balances.current != null || a.balances.available != null),
        }));
        await persist({
          ...state,
          accounts,
          balanceCheckedAt: new Date().toISOString(),
        });
      } catch (error) {
        if (error.code === "SYNC_STOPPED") throw error;
        await recordError(error, "balance");
      }
      const deadline = Date.now() + historyDeadlineMS;
      do {
        try {
          await persist(
            await syncBatch(state, plaid, () => stopped || closing),
          );
        } catch (error) {
          if (error.code === "SYNC_STOPPED") break;
          if (error.code !== "PRODUCT_NOT_READY") throw error;
          await recordError(error);
        }
        if (
          state.historyStatus === "HISTORICAL_UPDATE_COMPLETE" ||
          stopped ||
          closing ||
          Date.now() >= deadline
        )
          break;
        await historyWait(5000);
      } while (!stopped && !closing && Date.now() < deadline);
    } catch (error) {
      if (error.code !== "SYNC_STOPPED")
        await recordError(error).catch(() => {});
    } finally {
      running = false;
      busy = false;
    }
  }
  const listener = async (req, res) => {
    res.setHeader("Cache-Control", "no-store");
    res.setHeader("X-Content-Type-Options", "nosniff");
    res.setHeader("Referrer-Policy", "no-referrer");
    res.setHeader("X-Frame-Options", "DENY");
    res.setHeader(
      "Content-Security-Policy",
      "default-src 'self'; script-src 'self' https://cdn.plaid.com; connect-src 'self' https://*.plaid.com; frame-src https://*.plaid.com; img-src 'self' data: https://*.plaid.com; style-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'",
    );
    try {
      if (req.headers.host !== expectedHost)
        return send(res, 403, { error: "HOST_NOT_ALLOWED" });
      const url = new URL(req.url, origin);
      if (
        req.method === "GET" &&
        ["/", "/oauth", "/app.js", "/style.css"].includes(url.pathname)
      ) {
        const filename = url.pathname.endsWith(".js")
          ? "app.js"
          : url.pathname.endsWith(".css")
            ? "style.css"
            : "index.html";
        res.setHeader(
          "Content-Type",
          filename.endsWith(".js")
            ? "text/javascript"
            : filename.endsWith(".css")
              ? "text/css"
              : "text/html",
        );
        return res.end(await readFile(new URL(filename, publicDir)));
      }
      if (req.method !== "GET" && req.headers.origin !== origin)
        return send(res, 403, { error: "ORIGIN_NOT_ALLOWED" });
      if (
        req.method !== "GET" &&
        !/^application\/json(?:;|$)/.test(req.headers["content-type"] ?? "")
      )
        return send(res, 415, { error: "JSON_REQUIRED" });
      const cookie = (req.headers.cookie ?? "")
        .split(";")
        .map((s) => s.trim())
        .find((s) => s.startsWith("stack_session="))
        ?.slice(14);
      if (url.pathname === "/api/unlock" && req.method === "POST") {
        if (
          !bootstrapAvailable ||
          !equal(req.headers.authorization, "Bearer " + bootstrap)
        )
          return send(res, 401, { error: "REOPEN_FROM_TERMINAL" });
        bootstrapAvailable = false;
        res.setHeader(
          "Set-Cookie",
          `stack_session=${session}; HttpOnly; ${tls ? "Secure; " : ""}SameSite=Strict; Path=/`,
        );
        return send(res, 200, { ok: true });
      }
      if (!equal(cookie, session))
        return send(res, 401, { error: "REOPEN_FROM_TERMINAL" });
      if (url.pathname === "/api/report" && req.method === "GET")
        return send(res, 200, report());
      if (url.pathname === "/api/stop" && req.method === "POST") {
        stopped = true;
        return send(res, 200, { ok: true });
      }
      if (req.method !== "POST") return send(res, 404, { error: "NOT_FOUND" });
      if (busy) return send(res, 409, { error: "OPERATION_IN_PROGRESS" });
      let body = "";
      for await (const chunk of req) {
        body += chunk;
        if (body.length > 12000)
          return send(res, 413, { error: "BODY_TOO_LARGE" });
      }
      let data;
      try {
        data = JSON.parse(body || "{}");
      } catch {
        return send(res, 400, { error: "INVALID_JSON" });
      }
      if (busy) return send(res, 409, { error: "OPERATION_IN_PROGRESS" });
      busy = true;
      try {
        if (url.pathname === "/api/link-token") {
          if (state.accessToken || state.exchangeStarted)
            return send(res, 409, {
              error: "ITEM_EXISTS_OR_EXCHANGE_REQUIRES_REVIEW",
            });
          if (data.confirm !== "AUTHORIZE_BMO_LINK")
            return send(res, 400, {
              error: "EXPLICIT_LINK_CONFIRMATION_REQUIRED",
            });
          const link = await plaid.link(state.userID);
          await persist({ ...state, linkToken: link.link_token });
          return send(res, 200, { link_token: link.link_token });
        }
        if (url.pathname === "/api/exchange") {
          if (state.accessToken || state.exchangeStarted)
            return send(res, 409, {
              error: "ITEM_EXISTS_OR_EXCHANGE_REQUIRES_REVIEW",
            });
          if (
            typeof data.public_token !== "string" ||
            !/^public-production-[a-zA-Z0-9-]+$/.test(data.public_token)
          )
            return send(res, 400, { error: "INVALID_PUBLIC_TOKEN" });
          await persist({ ...state, exchangeStarted: true });
          const exchanged = await plaid.call("/item/public_token/exchange", {
            public_token: data.public_token,
          });
          if (!exchanged.item_id || !exchanged.access_token)
            throw Error("INVALID_EXCHANGE_RESPONSE");
          await persist({
            ...state,
            itemID: exchanged.item_id,
            accessToken: exchanged.access_token,
            linkToken: null,
            cursor: null,
            historyStatus: "NOT_STARTED",
          });
          return send(res, 200, { connected: true });
        }
        if (url.pathname === "/api/sync") {
          if (!state.accessToken)
            return send(res, 409, { error: "AUTHORIZE_BMO_FIRST" });
          if (data.confirm !== "RETRIEVE_BALANCES_AND_HISTORY")
            return send(res, 400, {
              error: "EXPLICIT_RETRIEVAL_CONFIRMATION_REQUIRED",
            });
          stopped = false;
          running = true;
          syncTask = runSync();
          return send(res, 202, { started: true });
        }
        if (url.pathname === "/api/item-id")
          return send(res, 200, { itemID: state.itemID ?? null });
        if (url.pathname === "/api/disconnect") {
          if (data.confirm !== "REMOVE_PLAID_ITEM")
            return send(res, 400, {
              error: "EXPLICIT_REMOVAL_CONFIRMATION_REQUIRED",
            });
          if (state.accessToken)
            await plaid.call("/item/remove", {
              access_token: state.accessToken,
            });
          else if (state.exchangeStarted)
            return send(res, 409, {
              error: "UNKNOWN_ITEM_REVIEW_PLAID_DASHBOARD",
            });
          await persist({ userID: state.userID, transactions: [] });
          return send(res, 200, { removed: true });
        }
        return send(res, 404, { error: "NOT_FOUND" });
      } catch (error) {
        return send(res, 502, {
          error: await recordError(
            error,
            url.pathname === "/api/exchange" ? "exchange" : "link",
          ),
        });
      } finally {
        if (!running) busy = false;
      }
    } catch {
      send(res, 500, { error: "LOCAL_TEST_ERROR" });
    }
  };
  const server = tls
    ? https.createServer(tls, listener)
    : http.createServer(listener);
  return {
    server,
    bootstrap,
    report,
    finished: () => syncTask,
    stop: () => {
      closing = true;
      stopped = true;
    },
    open: () => {
      if (openBrowser) {
        const child = spawn(
          "/usr/bin/open",
          [origin + "/#unlock=" + bootstrap],
          { stdio: "ignore" },
        );
        child.on("error", () =>
          console.error("BROWSER_OPEN_FAILED_RESTART_TO_REOPEN"),
        );
      }
    },
  };
}
if (
  process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  try {
    const store = await storage(),
      credentials = await store.credentials.load();
    if (!credentials || credentials.environment !== "production")
      throw Error("RUN_NODE_BMO_TEST_SETUP_FIRST");
    await store.item.exclusive(async () => {
      const tls = {
        key: await readFile(path.join(store.directory, "localhost.key")),
        cert: await readFile(path.join(store.directory, "localhost.crt")),
        minVersion: "TLSv1.2",
      };
      const app = await createTestServer({
        store: store.item,
        plaid: new ProductionPlaid(credentials),
        origin: "https://localhost:8765",
        tls,
        openBrowser: true,
      });
      await new Promise((resolve, reject) => {
        app.server.once("error", reject);
        app.server.listen(8765, "127.0.0.1", () => {
          console.log(
            "Local BMO test: https://localhost:8765 — no Plaid calls until you initiate Link or synchronization.",
          );
          app.open();
        });
        const shutdown = () => {
          app.stop();
          app.server.close(() => {
            app.finished().then(resolve, reject);
          });
        };
        process.once("SIGINT", shutdown);
        process.once("SIGTERM", shutdown);
      });
    });
  } catch (error) {
    console.error(
      /^[A-Z_]+$/.test(error.message)
        ? error.message
        : "LOCAL_TEST_START_FAILED",
    );
    process.exitCode = 1;
  }
}
