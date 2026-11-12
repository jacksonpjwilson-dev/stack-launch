"use strict";
const $ = (id) => document.getElementById(id);
let latest, handler, polling;
async function api(path, body) {
  const response = await fetch("/api/" + path, {
    method: body === undefined ? "GET" : "POST",
    headers: body === undefined ? {} : { "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
    credentials: "same-origin",
  });
  const data = await response.json();
  if (!response.ok) throw Error(data.error || "REQUEST_FAILED");
  return data;
}
function message(text) {
  $("message").textContent = text;
}
async function refresh() {
  latest = await api("report");
  $("report").textContent = JSON.stringify(latest, null, 2);
  $("connect").disabled =
    latest.connected || latest.exchangeUncertain || latest.busy;
  $("sync").disabled = !latest.connected || latest.busy;
  $("stop").disabled = !latest.running;
  $("item").disabled = !latest.connected;
  $("disconnect").disabled = !latest.connected || latest.busy;
  $("download").disabled = false;
  if (latest.running && !polling)
    polling = setInterval(
      () => refresh().catch((e) => message(e.message)),
      2000,
    );
  if (!latest.running && polling) {
    clearInterval(polling);
    polling = null;
    message(
      latest.historyComplete
        ? "Plaid reports historical backfilling complete. Coverage shown below is what was actually supplied."
        : latest.connected
          ? "Connected. Synchronization is not running. Start or continue explicitly when ready."
          : latest.exchangeUncertain
            ? "Token exchange outcome is uncertain. Check Plaid Dashboard; do not create another Item."
            : "Ready. No bank connection has been initiated.",
    );
  }
}
function openLink(token, redirect) {
  if (!window.Plaid) throw Error("PLAID_LINK_COULD_NOT_LOAD");
  sessionStorage.setItem("stackLinkToken", token);
  handler = Plaid.create({
    token,
    ...(redirect ? { receivedRedirectUri: redirect } : {}),
    onSuccess: async (publicToken) => {
      try {
        message("Securing the Item. No balance or transaction requests yet.");
        await api("exchange", { public_token: publicToken });
        sessionStorage.removeItem("stackLinkToken");
        await refresh();
        message(
          "BMO authorization completed. Click Retrieve when you explicitly want to start the data test.",
        );
      } catch (e) {
        message(e.message);
        await refresh();
      }
    },
    onExit: (error) => {
      message(
        error?.error_code || "Plaid Link closed. No app retrieval was started.",
      );
    },
  });
  if (redirect) history.replaceState(null, "", "/");
  handler.open();
}
$("connect").onclick = async () => {
  if (
    !confirm(
      "Open Production Plaid Link to authorize Canadian BMO? A new Item can use one trial connection. Do not reconnect an already linked Item.",
    )
  )
    return;
  $("connect").disabled = true;
  try {
    const r = await api("link-token", { confirm: "AUTHORIZE_BMO_LINK" });
    openLink(r.link_token);
  } catch (e) {
    message(e.message);
    await refresh();
  }
};
$("sync").onclick = async () => {
  if (
    !confirm(
      "Authorize this app to retrieve BMO balances and all available transaction history now?",
    )
  )
    return;
  try {
    await api("sync", { confirm: "RETRIEVE_BALANCES_AND_HISTORY" });
    message("Retrieving authorized data…");
    await refresh();
  } catch (e) {
    message(e.message);
  }
};
$("stop").onclick = async () => {
  await api("stop", {});
  message(
    "Stopping after the current request; durable progress will be preserved.",
  );
};
$("item").onclick = async () => {
  const r = await api("item-id", {});
  $("itemID").textContent = "Item ID (keep private): " + r.itemID;
};
$("disconnect").onclick = async () => {
  if (
    !confirm(
      "Remove this Plaid Item and erase this test’s stored connection and results?",
    )
  )
    return;
  try {
    await api("disconnect", { confirm: "REMOVE_PLAID_ITEM" });
    $("itemID").textContent = "";
    await refresh();
    message("Item removed.");
  } catch (e) {
    message(e.message);
  }
};
$("download").onclick = () => {
  const blob = new Blob([JSON.stringify(latest, null, 2)], {
      type: "application/json",
    }),
    url = URL.createObjectURL(blob),
    a = document.createElement("a");
  a.href = url;
  a.download = "stack-bmo-diagnostics.json";
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
};
(async () => {
  try {
    const fragment = new URLSearchParams(location.hash.slice(1)),
      unlock = fragment.get("unlock"),
      redirect = location.search.includes("oauth_state_id=")
        ? location.href
        : null;
    if (unlock) {
      history.replaceState(null, "", location.pathname + location.search);
      const response = await fetch("/api/unlock", {
        method: "POST",
        headers: {
          Authorization: "Bearer " + unlock,
          "Content-Type": "application/json",
        },
        body: "{}",
      });
      if (!response.ok) throw Error("RESTART_THE_TERMINAL_SERVER_TO_REOPEN");
    }
    await refresh();
    if (redirect) {
      const token = sessionStorage.getItem("stackLinkToken");
      if (!token) throw Error("OAUTH_SESSION_MISSING_USE_ORIGINAL_BROWSER_TAB");
      openLink(token, redirect);
    } else
      message(
        latest.connected
          ? "Existing connection restored. Retrieval requires your explicit action."
          : latest.exchangeUncertain
            ? "Exchange outcome uncertain. Review Plaid Dashboard before any new connection."
            : "Ready. Click Connect only when you want to authorize BMO.",
      );
  } catch (e) {
    message(e.message);
  }
})();
