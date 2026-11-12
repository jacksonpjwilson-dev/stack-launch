import { ProviderError, synchronize } from "../backend/sync.mjs";
const safe = (value, fallback) =>
  typeof value === "string" && /^[A-Za-z0-9_-]{1,100}$/.test(value)
    ? value
    : fallback;
export class ProductionPlaid {
  constructor(
    credentials,
    fetchImpl = fetch,
    wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
  ) {
    this.credentials = credentials;
    this.fetch = fetchImpl;
    this.wait = wait;
  }
  async call(endpoint, body, shouldStop = () => false) {
    for (let attempt = 0; attempt < 4; attempt++) {
      if (shouldStop()) throw new ProviderError("SYNC_STOPPED");
      let response;
      try {
        response = await this.fetch("https://production.plaid.com" + endpoint, {
          method: "POST",
          signal: AbortSignal.timeout(45000),
          headers: {
            "Content-Type": "application/json",
            "Plaid-Version": "2020-09-14",
          },
          body: JSON.stringify({
            client_id: this.credentials.clientID,
            secret: this.credentials.secret,
            ...body,
          }),
        });
      } catch {
        if (endpoint === "/item/public_token/exchange")
          throw new ProviderError("EXCHANGE_OUTCOME_UNCERTAIN");
        if (attempt === 3) throw new ProviderError("NETWORK_UNAVAILABLE", true);
        await this.wait(500 * 2 ** attempt);
        continue;
      }
      let data;
      try {
        data = await response.json();
      } catch {
        throw new ProviderError("INVALID_PROVIDER_RESPONSE");
      }
      if (response.ok) return data;
      const error = new ProviderError(
        safe(data.error_code, "PROVIDER_ERROR"),
        response.status === 429 || response.status >= 500,
      );
      error.requestID = safe(data.request_id, null);
      // Token exchanges are not blindly retried: a response may have been lost after token consumption.
      if (
        endpoint === "/item/public_token/exchange" ||
        !error.retryable ||
        attempt === 3
      )
        throw error;
      const delay = Number(response.headers.get("retry-after"));
      await this.wait(
        delay > 0 ? Math.min(delay * 1000, 30000) : 500 * 2 ** attempt,
      );
    }
  }
  link(userID) {
    return this.call("/link/token/create", {
      client_name: "Stack private BMO test",
      user: { client_user_id: userID },
      products: ["transactions"],
      country_codes: ["CA"],
      language: "en",
      redirect_uri: this.credentials.redirect,
      transactions: { days_requested: 730 },
    });
  }
}
export async function syncBatch(state, plaid, shouldStop = () => false) {
  let pageCount = 0,
    updateStatus = "UNKNOWN",
    requests = [];
  const provider = {
    page: async (token, cursor) => {
      if (shouldStop()) throw new ProviderError("SYNC_STOPPED");
      const page = await plaid.call(
        "/transactions/sync",
        { access_token: token, ...(cursor ? { cursor } : {}), count: 500 },
        shouldStop,
      );
      pageCount++;
      updateStatus = safe(page.transactions_update_status, "UNKNOWN");
      if (page.request_id) requests.push(safe(page.request_id, "UNAVAILABLE"));
      // Store only fields needed for coverage diagnostics, never amounts or merchant details.
      const summarize = (t) => ({
        transaction_id: t.transaction_id,
        account_id: t.account_id,
        date: t.date,
        pending: !!t.pending,
        pending_transaction_id: t.pending_transaction_id ?? null,
      });
      return {
        ...page,
        added: page.added?.map(summarize),
        modified: page.modified?.map(summarize),
      };
    },
  };
  const next = await synchronize(state, provider);
  return {
    ...next,
    historyStatus: updateStatus,
    lastBatchPages: pageCount,
    requestIDs: requests.slice(-20),
  };
}
export function diagnostics(state = {}, activity = {}) {
  const accounts = state.accounts ?? [],
    transactions = state.transactions ?? [];
  const rows = accounts.map((account, index) => {
    const entries = transactions.filter(
      (t) => t.account_id === account.account_id,
    );
    const dates = entries
      .map((t) => t.date)
      .filter((d) => /^\d{4}-\d{2}-\d{2}$/.test(d ?? ""))
      .sort();
    return {
      account: `Account ${index + 1}`,
      type: account.type ?? "unknown",
      subtype: account.subtype ?? "unknown",
      transactionCount: entries.length,
      posted: entries.filter((t) => !t.pending).length,
      pending: entries.filter((t) => t.pending).length,
      earliestDate: dates[0] ?? null,
      latestDate: dates.at(-1) ?? null,
      balanceRetrieved: account.balanceRetrieved === true,
    };
  });
  const known = new Set(accounts.map((a) => a.account_id));
  return {
    environment: "production",
    institutionVerified: state.institutionVerified === true,
    productAccess: state.productAccess ?? null,
    balanceCheckedAt: state.balanceCheckedAt ?? null,
    connected: !!state.accessToken,
    exchangeUncertain: !!state.exchangeStarted && !state.accessToken,
    accountCount: accounts.length,
    totalTransactions: transactions.length,
    unassignedTransactionCount: transactions.filter(
      (t) => !known.has(t.account_id),
    ).length,
    accounts: rows,
    requestedHistoryDays: 730,
    historyStatus: state.historyStatus ?? "NOT_STARTED",
    historyComplete: state.historyStatus === "HISTORICAL_UPDATE_COMPLETE",
    lastSuccessfulSync: state.lastSuccess ?? null,
    lastBatchPages: state.lastBatchPages ?? 0,
    requestIDs: state.requestIDs ?? [],
    errors: state.errors ?? [],
    ...activity,
  };
}
