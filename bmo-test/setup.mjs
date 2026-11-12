import readline from "node:readline";
import { createInterface } from "node:readline/promises";
import { execFileSync } from "node:child_process";
import { writeFile, chmod, access } from "node:fs/promises";
import path from "node:path";
import { storage } from "./storage.mjs";
async function hidden(prompt) {
  if (!process.stdin.isTTY) throw Error("RUN_SETUP_IN_TERMINAL");
  process.stdout.write(prompt);
  readline.emitKeypressEvents(process.stdin);
  process.stdin.setRawMode(true);
  process.stdin.resume();
  return new Promise((resolve, reject) => {
    let value = "";
    function finish(error) {
      process.stdin.off("keypress", onKey);
      process.stdin.setRawMode(false);
      process.stdin.pause();
      process.stdout.write("\n");
      error ? reject(error) : resolve(value);
    }
    function onKey(text, key = {}) {
      if (key.ctrl && ["c", "d"].includes(key.name))
        return finish(Error("SETUP_CANCELLED"));
      if (key.name === "return" || key.name === "enter") return finish();
      if (key.name === "backspace") value = value.slice(0, -1);
      else if (
        text &&
        !key.ctrl &&
        /^[\x21-\x7e]+$/.test(text) &&
        value.length + text.length <= 2000
      )
        value += text;
    }
    process.stdin.on("keypress", onKey);
  });
}
try {
  const store = await storage();
  console.log(
    "Production credentials stay on this Mac. Input is hidden. This setup makes no Plaid API calls.",
  );
  const clientID = await hidden("Plaid Production Client ID: ");
  const secret = await hidden("Plaid Production Secret: ");
  if (!/^[a-f0-9]{24}$/i.test(clientID) || !/^[a-f0-9]{20,200}$/i.test(secret))
    throw Error("CHECK_CREDENTIAL_FORMAT");
  const prompt = createInterface({
    input: process.stdin,
    output: process.stdout,
  });
  const redirect =
    (
      await prompt.question(
        "Registered OAuth redirect URI (Enter for https://localhost:8765/oauth): ",
      )
    ).trim() || "https://localhost:8765/oauth";
  prompt.close();
  if (redirect !== "https://localhost:8765/oauth")
    throw Error("THIS_LOCAL_TEST_REQUIRES_HTTPS_LOCALHOST_8765_OAUTH");
  await store.credentials.save({
    clientID,
    secret,
    redirect,
    environment: "production",
  });
  const cert = path.join(store.directory, "localhost.crt"),
    key = path.join(store.directory, "localhost.key");
  try {
    await access(cert);
    await access(key);
  } catch {
    const config = path.join(store.directory, "localhost-cert.cnf");
    await writeFile(
      config,
      "[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=localhost\n[ext]\nsubjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n",
      { mode: 0o600 },
    );
    execFileSync(
      "/usr/bin/openssl",
      [
        "req",
        "-x509",
        "-newkey",
        "rsa:2048",
        "-nodes",
        "-days",
        "90",
        "-keyout",
        key,
        "-out",
        cert,
        "-config",
        config,
      ],
      { stdio: "ignore" },
    );
    await chmod(key, 0o600);
  }
  console.log(
    "Setup complete. Generated encryption and local TLS keys are stored outside the repository.",
  );
  console.log(
    "Register https://localhost:8765/oauth in Plaid Dashboard → API/Link OAuth redirect URIs.",
  );
  console.log("Run: node bmo-test/server.mjs");
} catch (error) {
  console.error(
    /^[A-Z_]+$/.test(error.message) ? error.message : "SETUP_FAILED",
  );
  process.exitCode = 1;
}
