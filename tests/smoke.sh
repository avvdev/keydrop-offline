#!/usr/bin/env bash
set -euo pipefail

expected_fixture_sha="6c4277f79eea8644f28ee6b0eb38486a1c8147610c38f6a83c0e6d02428a0201"
actual_fixture_sha="$(sha256sum smoke-not-a-secret.toml.enc | awk '{print $1}')"
test "$actual_fixture_sha" = "$expected_fixture_sha"
grep -F 'self.registration.unregister()' service-worker.js >/dev/null
grep -F 'client.navigate(client.url)' service-worker.js >/dev/null
! grep -F 'serviceWorker.register' decrypt.bundle.js >/dev/null
! grep -F 'serviceWorker.register' worker/public/decrypt.bundle.js >/dev/null
grep -F 'id="download-and-select"' index.html >/dev/null
grep -F 'src="autoselect.js"' index.html >/dev/null
test "$(grep '^!' .assetsignore | cut -c2- | sort)" = "$(printf '%s\n' autoselect.js decrypt.bundle.js icon.svg index.html manifest.webmanifest smoke-not-a-secret.toml.enc | sort)"
grep -Fx '*' .assetsignore >/dev/null
for private_path in keydrop cli tests worker .git service-worker.js; do
  ! grep -Fx "!${private_path}" .assetsignore >/dev/null
done
grep -F '"directory": "./public"' worker/wrangler.jsonc >/dev/null
test "$(find worker/public -maxdepth 1 -type f -printf '%f\n' | sort)" = "$(printf '%s\n' autoselect.js decrypt.bundle.js icon.svg index.html manifest.webmanifest | sort)"
for public_asset in autoselect.js decrypt.bundle.js icon.svg index.html manifest.webmanifest; do
  cmp "worker/public/${public_asset}" "${public_asset}"
done
test ! -e worker/public/smoke-not-a-secret.toml.enc
grep -Fx '.dev.vars' worker/.gitignore >/dev/null
grep -Fx '.wrangler/' worker/.gitignore >/dev/null

node <<'NODE'
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");

function element() {
  return {
    dataset: {},
    files: [],
    textContent: "",
    type: "",
    value: "",
    handlers: {},
    addEventListener(name, handler) {
      this.handlers[name] = handler;
    },
    dispatchEvent(event) {
      if (this.handlers[event.type]) this.handlers[event.type](event);
      return true;
    },
  };
}

class TestFile extends Blob {
  constructor(parts, name, options) {
    super(parts, options);
    this.name = name;
  }
}

class TestDataTransfer {
  constructor() {
    this.files = [];
    this.items = {
      add: (file) => this.files.push(file),
    };
  }
}

async function main() {
  const encrypted = fs.readFileSync("smoke-not-a-secret.toml.enc");
  const elements = {
    "#decrypt-form": element(),
    "#download-and-select": element(),
    "#encrypted-file": element(),
    "#file-info": element(),
    "#password": element(),
    "#fill-test-password": element(),
    "#toggle-password": element(),
    "#status": element(),
  };
  elements["#download-and-select"].href = "https://example.test/smoke-not-a-secret.toml.enc";
  elements["#download-and-select"].download = "smoke-not-a-secret.toml.enc";
  let downloadedBlob;
  const context = {
    ArrayBuffer,
    Blob,
    DataTransfer: TestDataTransfer,
    DataView,
    Promise,
    Event: class TestEvent {
      constructor(type) {
        this.type = type;
      }
    },
    File: TestFile,
    TextDecoder,
    TextEncoder,
    Uint8Array,
    Uint16Array,
    Uint32Array,
    atob,
    btoa,
    console,
    crypto: globalThis.crypto,
    document: {
      currentScript: null,
      querySelector(selector) {
        return elements[selector];
      },
      createElement() {
        return {
          click() {},
          download: "",
          href: "",
        };
      },
    },
    fetch: async () => ({
      ok: true,
      status: 200,
      async blob() {
        return new Blob([encrypted]);
      },
    }),
    history: { replaceState() {} },
    location: { hash: "", pathname: "/", search: "" },
    navigator: {},
    sessionStorage: {
      getItem() { return null; },
      setItem() {},
      removeItem() {},
    },
    setImmediate,
    setTimeout(callback) {
      queueMicrotask(callback);
      return 0;
    },
    clearTimeout() {},
    queueMicrotask,
    URL: {
      createObjectURL(blob) {
        downloadedBlob = blob;
        return "blob:test";
      },
      revokeObjectURL() {},
    },
  };
  context.globalThis = context;
  context.self = context;
  context.window = context;
  vm.createContext(context);
  vm.runInContext(fs.readFileSync("decrypt.bundle.js", "utf8"), context, {
    filename: "decrypt.bundle.js",
    timeout: 120_000,
  });
  vm.runInContext(fs.readFileSync("autoselect.js", "utf8"), context, {
    filename: "autoselect.js",
    timeout: 120_000,
  });

  await elements["#download-and-select"].handlers.click();
  assert.equal(elements["#encrypted-file"].files[0].name, "smoke-not-a-secret.toml.enc");
  assert.equal(elements["#status"].textContent, "Файл скачан и уже выбран. Проводник Android не нужен.");
  elements["#fill-test-password"].handlers.click();
  await elements["#decrypt-form"].handlers.submit({ preventDefault() {} });

  assert.equal(elements["#status"].textContent, "Готово. Файл расшифрован на этом устройстве.");
  assert.equal(await downloadedBlob.text(), "[smoke]\nnot_a_real_key = true\n");
  console.log("PASS browser-like bundle decrypt and offline fixture integrity");
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
NODE

test -x keydrop
node --input-type=module <<'NODE'
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import vm from "node:vm";

function run(args, onSpawn) {
  return new Promise((resolve, reject) => {
    const child = spawn("./keydrop", args, { stdio: ["ignore", "pipe", "pipe"] });
    const timer = setTimeout(() => { child.kill("SIGKILL"); reject(new Error("CLI timeout")); }, 20_000);
    onSpawn?.(child);
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.once("error", reject);
    child.once("close", (code) => { clearTimeout(timer); resolve({ code, stdout, stderr }); });
  });
}

async function decryptWithBrowserBundle(encrypted, password) {
  function element() {
    return {
      dataset: {}, files: [], textContent: "", type: "", value: "", handlers: {},
      addEventListener(name, handler) { this.handlers[name] = handler; },
    };
  }
  class TestFile extends Blob {
    constructor(parts, name, options) { super(parts, options); this.name = name; }
  }
  const elements = {
    "#decrypt-form": element(), "#encrypted-file": element(), "#file-info": element(),
    "#password": element(), "#fill-test-password": element(), "#toggle-password": element(),
    "#status": element(),
  };
  elements["#encrypted-file"].files = [new TestFile([encrypted], "delivery.enc")];
  elements["#password"].value = password;
  let downloaded;
  const context = {
    ArrayBuffer, Blob, DataView, File: TestFile, Promise, TextDecoder, TextEncoder,
    Uint8Array, Uint16Array, Uint32Array, atob, btoa, console, crypto: globalThis.crypto,
    document: {
      currentScript: null,
      querySelector(selector) { return elements[selector]; },
      createElement() { return { click() {}, download: "", href: "" }; },
    },
    navigator: {},
    setImmediate,
    setTimeout(callback) { queueMicrotask(callback); return 0; },
    clearTimeout() {}, queueMicrotask,
    URL: {
      createObjectURL(blob) { downloaded = blob; return "blob:test"; },
      revokeObjectURL() {},
    },
  };
  context.globalThis = context;
  context.self = context;
  context.window = context;
  vm.createContext(context);
  vm.runInContext(fs.readFileSync("decrypt.bundle.js", "utf8"), context, {
    filename: "decrypt.bundle.js", timeout: 120_000,
  });
  await elements["#decrypt-form"].handlers.submit({ preventDefault() {} });
  assert.equal(elements["#status"].textContent, "Готово. Файл расшифрован на этом устройстве.");
  return new Uint8Array(await downloaded.arrayBuffer());
}

const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "keydrop-cli-test-"));
const token = "upload-token-for-smoke-test-only-1234567890";
const secret = Buffer.from("CLI roundtrip plaintext that must never reach the server");
const tokenFile = path.join(temporary, "upload-token");
const inputFile = path.join(temporary, "input.bin");
const passwordFile = path.join(temporary, "delivery.pass");
fs.writeFileSync(tokenFile, `${token}\n`, { mode: 0o600 });
fs.writeFileSync(inputFile, secret, { mode: 0o600 });

let captured;
let behavior = "ok";
let uploadArrived;
let releaseUpload;
let origin;
const deliveryToken = "A".repeat(43);
const server = http.createServer(async (request, response) => {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  const body = Buffer.concat(chunks);
  captured = { url: request.url, headers: request.headers, body };
  if (behavior.startsWith("pause")) {
    uploadArrived();
    await new Promise((resolve) => { releaseUpload = resolve; });
  }
  if (behavior.endsWith("reject")) {
    response.writeHead(503).end("unavailable");
    return;
  }
  response.writeHead(201, { "Content-Type": "application/json" });
  const delivery = behavior === "credentials" ? origin.replace("//", "//user:pass@") + `#${deliveryToken}` : `${origin}#${deliveryToken}`;
  response.end(JSON.stringify({ url: delivery }));
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
origin = `http://127.0.0.1:${server.address().port}/`;

try {
  const result = await run([
    "send", inputFile, "--endpoint", origin, "--token-file", tokenFile,
    "--password-out", passwordFile, "--ttl", "300",
  ]);
  const expectedUrl = `${origin}#${deliveryToken}\n`;
  assert.equal(result.code, 0);
  assert.equal(result.stdout, expectedUrl);
  assert.equal(result.stderr, "");
  assert.equal(captured.url, "/api/v1/drops");
  assert.equal(captured.headers.authorization, `Bearer ${token}`);
  assert.equal(captured.headers["x-keydrop-ttl"], "300");
  assert.equal(captured.headers["x-keydrop-sha256"], createHash("sha256").update(captured.body).digest("hex"));
  assert.equal(captured.body.subarray(0, 11).toString(), "zDKO6XYXioc");
  assert.equal(captured.body.includes(secret), false);

  const password = fs.readFileSync(passwordFile, "utf8").trim();
  assert.match(password, /^(?:[0123456789ABCDEFGHJKMNPQRSTVWXYZ]{5}-){5}[0123456789ABCDEFGHJKMNPQRSTVWXYZ]$/);
  assert.equal(fs.statSync(passwordFile).mode & 0o777, 0o600);
  assert.equal(result.stdout.includes(password), false);
  assert.equal(result.stderr.includes(password), false);
  assert.equal(captured.body.includes(Buffer.from(password)), false);
  assert.equal(result.stdout.includes(token), false);
  assert.equal(result.stderr.includes(token), false);
  assert.deepEqual(await decryptWithBrowserBundle(captured.body, password), new Uint8Array(secret));

  behavior = "pause-reject";
  const failedPassword = path.join(temporary, "failed.pass");
  const movedPassword = path.join(temporary, "moved.pass");
  const arrived = new Promise((resolve) => { uploadArrived = resolve; });
  const pendingFailure = run([
    "send", inputFile, "--endpoint", origin, "--token-file", tokenFile,
    "--password-out", failedPassword, "--ttl", "300",
  ]);
  await arrived;
  fs.renameSync(failedPassword, movedPassword);
  fs.writeFileSync(failedPassword, "replacement", { mode: 0o600 });
  releaseUpload();
  const failed = await pendingFailure;
  assert.equal(failed.code, 1);
  assert.equal(failed.stdout, "");
  assert.match(failed.stderr, /^keydrop: upload rejected\n$/);
  assert.equal(fs.readFileSync(failedPassword, "utf8"), "replacement");
  assert.equal(fs.statSync(movedPassword).size, 0);
  assert.equal(failed.stderr.includes(token), false);

  behavior = "credentials";
  const credentialPassword = path.join(temporary, "credentials.pass");
  const credentialed = await run([
    "send", inputFile, "--endpoint", origin, "--token-file", tokenFile,
    "--password-out", credentialPassword, "--ttl", "300",
  ]);
  assert.equal(credentialed.code, 1);
  assert.match(credentialed.stderr, /^keydrop: invalid delivery URL\n$/);
  assert.equal(fs.existsSync(credentialPassword), false);

  const oversizedToken = path.join(temporary, "oversized-token");
  const oversizedPassword = path.join(temporary, "oversized.pass");
  fs.writeFileSync(oversizedToken, "x".repeat(600), { mode: 0o600 });
  const oversized = await run([
    "send", inputFile, "--endpoint", origin, "--token-file", oversizedToken,
    "--password-out", oversizedPassword, "--ttl", "300",
  ]);
  assert.equal(oversized.code, 1);
  assert.match(oversized.stderr, /^keydrop: invalid upload token file\n$/);
  assert.equal(fs.existsSync(oversizedPassword), false);

  behavior = "pause-ok";
  const signalPassword = path.join(temporary, "signal.pass");
  const signalArrived = new Promise((resolve) => { uploadArrived = resolve; });
  let signalChild;
  const signalledRun = run([
    "send", inputFile, "--endpoint", origin, "--token-file", tokenFile,
    "--password-out", signalPassword, "--ttl", "300",
  ], (child) => { signalChild = child; });
  await signalArrived;
  signalChild.kill("SIGHUP");
  const signalled = await signalledRun;
  releaseUpload();
  assert.equal(signalled.code, 129);
  assert.equal(fs.existsSync(signalPassword), false);
  console.log("PASS standalone CLI secrecy, mode 0600 password, failure cleanup, browser-compatible roundtrip");
} finally {
  server.close();
  fs.rmSync(temporary, { recursive: true, force: true });
}
NODE

node --input-type=module <<'NODE'
import assert from "node:assert/strict";
import { createHash, randomBytes } from "node:crypto";
import worker, { DropSession } from "./worker/index.mjs";

class Storage {
  constructor() {
    this.values = new Map();
    this.tail = Promise.resolve();
  }
  async get(key) { return structuredClone(this.values.get(key)); }
  async put(key, value) { this.values.set(key, structuredClone(value)); }
  async deleteAll() { this.values.clear(); }
  async setAlarm(value) { this.alarm = value; }
  async transaction(callback) {
    const previous = this.tail;
    let release;
    this.tail = new Promise((resolve) => { release = resolve; });
    await previous;
    try { return await callback(this); } finally { release(); }
  }
}

class Bucket {
  constructor() { this.values = new Map(); this.failDeleteOnce = false; }
  async put(key, body, options) {
    const bytes = new Uint8Array(await new Response(body).arrayBuffer());
    this.values.set(key, { bytes, options });
    return { size: bytes.length };
  }
  async get(key) {
    const value = this.values.get(key);
    return value ? { body: new Blob([value.bytes]).stream() } : null;
  }
  async delete(key) {
    if (this.failDeleteOnce) {
      this.failDeleteOnce = false;
      throw new Error("temporary R2 delete failure");
    }
    this.values.delete(key);
  }
}

class Sessions {
  constructor(bucket) {
    this.bucket = bucket;
    this.sessions = new Map();
  }
  idFromName(name) { return name; }
  get(id) {
    if (!this.sessions.has(id)) {
      const ctx = { storage: new Storage() };
      this.sessions.set(id, new DropSession(ctx, { DROPS: this.bucket }));
    }
    return this.sessions.get(id);
  }
}

function lease() {
  return randomBytes(32).toString("base64url");
}

function access(method, path, token, recipientLease) {
  return new Request(`https://drop.test${path}`, {
    method,
    headers: {
      Authorization: `Keydrop ${token}`,
      "X-Keydrop-Lease": recipientLease,
    },
  });
}

const bucket = new Bucket();
const sessions = new Sessions(bucket);
const secret = "u".repeat(48);
const env = { DROPS: bucket, DROP_SESSIONS: sessions, UPLOAD_TOKEN: secret };
const ciphertext = new TextEncoder().encode("dummy authenticated ciphertext");
const checksum = createHash("sha256").update(ciphertext).digest("hex");

const denied = await worker.fetch(new Request("https://drop.test/api/v1/drops", {
  method: "POST",
  body: ciphertext,
  headers: {
    Authorization: "Bearer wrong",
    "Content-Length": String(ciphertext.length),
    "X-Keydrop-SHA256": checksum,
  },
}), env);
assert.equal(denied.status, 401);

const uploaded = await worker.fetch(new Request("https://drop.test/api/v1/drops", {
  method: "POST",
  body: ciphertext,
  headers: {
    Authorization: `Bearer ${secret}`,
    "Content-Length": String(ciphertext.length),
    "X-Keydrop-SHA256": checksum,
    "X-Keydrop-TTL": "300",
  },
}), env);
assert.equal(uploaded.status, 201);
const receipt = await uploaded.json();
const delivery = new URL(receipt.url);
const token = delivery.hash.slice(1);
assert.equal(delivery.pathname, "/");
assert.match(token, /^[A-Za-z0-9_-]{43}$/);
assert.equal(bucket.values.size, 1);
const [storedKey] = bucket.values.keys();
assert.match(storedKey, /^drops\/[a-f0-9]{64}$/);
assert.ok(!storedKey.includes(token));

const leases = Array.from({ length: 50 }, lease);
const claims = await Promise.all(leases.map((value) => worker.fetch(
  access("POST", "/api/v1/drop/claim", token, value), env,
)));
assert.equal(claims.filter((response) => response.status === 204).length, 1);
assert.equal(claims.filter((response) => response.status === 410).length, 49);
const winner = leases[claims.findIndex((response) => response.status === 204)];
assert.equal((await worker.fetch(access("POST", "/api/v1/drop/claim", token, winner), env)).status, 204);
assert.equal((await worker.fetch(access("GET", "/api/v1/drop", token, lease()), env)).status, 410);

const session = sessions.sessions.get(storedKey.slice("drops/".length));
const expiredLease = await session.ctx.storage.get("drop");
expiredLease.leaseUntil = Date.now() - 1;
await session.ctx.storage.put("drop", expiredLease);
const replacement = lease();
assert.equal((await worker.fetch(access("POST", "/api/v1/drop/claim", token, replacement), env)).status, 204);
assert.equal((await worker.fetch(access("POST", "/api/v1/drop/ack", token, winner), env)).status, 410);

const payload = await worker.fetch(access("GET", "/api/v1/drop", token, replacement), env);
assert.equal(payload.status, 200);
assert.equal(payload.headers.get("cache-control"), "no-store, private, max-age=0");
assert.deepEqual(new Uint8Array(await payload.arrayBuffer()), ciphertext);
assert.equal((await worker.fetch(access("POST", "/api/v1/drop/ack", token, replacement), env)).status, 204);
assert.equal(bucket.values.size, 0);
assert.equal((await worker.fetch(access("POST", "/api/v1/drop/ack", token, replacement), env)).status, 204);
assert.equal((await worker.fetch(access("GET", "/api/v1/drop", token, replacement), env)).status, 410);

const retryUpload = await worker.fetch(new Request("https://drop.test/api/v1/drops", {
  method: "POST", body: ciphertext,
  headers: {
    Authorization: `Bearer ${secret}`, "Content-Length": String(ciphertext.length),
    "X-Keydrop-SHA256": checksum, "X-Keydrop-TTL": "300",
  },
}), env);
const retryToken = new URL((await retryUpload.json()).url).hash.slice(1);
const retryLease = lease();
assert.equal((await worker.fetch(access("POST", "/api/v1/drop/claim", retryToken, retryLease), env)).status, 204);
bucket.failDeleteOnce = true;
assert.equal((await worker.fetch(access("POST", "/api/v1/drop/ack", retryToken, retryLease), env)).status, 500);
assert.equal(bucket.values.size, 1);
assert.equal((await worker.fetch(access("POST", "/api/v1/drop/ack", retryToken, retryLease), env)).status, 204);
assert.equal(bucket.values.size, 0);

const failedBucket = new Bucket();
const failedEnv = {
  DROPS: failedBucket,
  UPLOAD_TOKEN: secret,
  DROP_SESSIONS: { idFromName(value) { return value; }, get() { return { async fetch() { throw new Error("do unavailable"); } }; } },
};
const failedUpload = await worker.fetch(new Request("https://drop.test/api/v1/drops", {
  method: "POST", body: ciphertext,
  headers: {
    Authorization: `Bearer ${secret}`, "Content-Length": String(ciphertext.length),
    "X-Keydrop-SHA256": checksum, "X-Keydrop-TTL": "300",
  },
}), failedEnv);
assert.equal(failedUpload.status, 500);
assert.equal(failedUpload.headers.get("cache-control"), "no-store, private, max-age=0");
assert.equal(failedBucket.values.size, 0);

const assets = {
  async fetch() { return new Response("<html></html>", { headers: { "Content-Type": "text/html" } }); },
};
const page = await worker.fetch(new Request("https://drop.test/"), { ASSETS: assets });
assert.match(page.headers.get("content-security-policy"), /frame-ancestors 'none'/);
assert.equal(page.headers.get("referrer-policy"), "no-referrer");
assert.equal(page.headers.get("cache-control"), "no-store");
const retired = await worker.fetch(new Request("https://drop.test/service-worker.js"), {});
assert.match(await retired.text(), /client\.navigate\(client\.url\)/);
assert.equal(retired.headers.get("cache-control"), "no-store, private, max-age=0");
const fixture = await worker.fetch(new Request("https://drop.test/smoke-not-a-secret.toml.enc"), {});
assert.equal(fixture.status, 200);
assert.equal(fixture.headers.get("content-type"), "application/octet-stream");
assert.equal(fixture.headers.get("cache-control"), "no-store, private, max-age=0");
assert.deepEqual(
  new Uint8Array(await fixture.arrayBuffer()),
  new Uint8Array(await (await import("node:fs/promises")).readFile("smoke-not-a-secret.toml.enc")),
);
assert.ok(!(/console\.(log|error|warn)/).test(await (await import("node:fs/promises")).readFile("worker/index.mjs", "utf8")));
console.log("PASS Worker auth, fragment capability, atomic lease, no-store payload, acknowledgement cleanup");
NODE

node --input-type=module <<'NODE'
import assert from "node:assert/strict";
import { createHash, randomBytes } from "node:crypto";
import fs from "node:fs";
import vm from "node:vm";

function element() {
  return {
    dataset: {}, files: [], handlers: {}, hidden: false, textContent: "",
    addEventListener(name, handler) { this.handlers[name] = handler; },
    dispatchEvent(event) { this.handlers[event.type]?.(event); },
  };
}

class TestFile extends Blob {
  constructor(parts, name, options) { super(parts, options); this.name = name; }
}

class TestTransfer {
  constructor() {
    this.files = [];
    this.items = { add: (file) => this.files.push(file) };
  }
}

const token = randomBytes(32).toString("base64url");
const encrypted = new TextEncoder().encode("one network payload");
const checksum = createHash("sha256").update(encrypted).digest("hex");
const selectors = [
  "#download-and-select", "#encrypted-file", "#file-info", "#status", "#intro",
  "#download-help", "#fill-test-password", "h1",
];
const elements = Object.fromEntries(selectors.map((selector) => [selector, element()]));
const calls = [];
const stored = new Map();
const observers = [];
let replacedWith = null;
let ackAttempts = 0;

const context = {
  Blob,
  DataTransfer: TestTransfer,
  Event: class TestEvent { constructor(type) { this.type = type; } },
  File: TestFile,
  Headers,
  MutationObserver: class TestObserver {
    constructor(callback) { this.callback = callback; observers.push(this); }
    observe() {}
    disconnect() { this.disconnected = true; }
  },
  Response,
  TextEncoder,
  Uint8Array,
  btoa,
  crypto: globalThis.crypto,
  document: { querySelector(selector) { return elements[selector]; } },
  fetch: async (path, options) => {
    calls.push({ path, options });
    if (path.endsWith("/claim")) return new Response(null, { status: 204 });
    if (path.endsWith("/ack")) {
      ackAttempts += 1;
      if (ackAttempts === 1) throw new Error("response lost");
      return new Response(null, { status: 204 });
    }
    return new Response(encrypted, { headers: {
      "Content-Length": String(encrypted.length),
      "X-Keydrop-SHA256": checksum,
    } });
  },
  history: { replaceState(_state, _title, path) { replacedWith = path; context.location.hash = ""; } },
  location: { hash: `#${token}`, pathname: "/", search: "" },
  sessionStorage: {
    getItem(key) { return stored.get(key) ?? null; },
    setItem(key, value) { stored.set(key, value); },
    removeItem(key) { stored.delete(key); },
  },
};
context.globalThis = context;
context.window = context;
vm.createContext(context);
vm.runInContext(fs.readFileSync("autoselect.js", "utf8"), context, { filename: "autoselect.js" });
await vm.runInContext("productionReady", context);

assert.equal(replacedWith, "/");
assert.equal(calls.length, 2);
assert.deepEqual(calls.map((call) => call.path), ["/api/v1/drop/claim", "/api/v1/drop"]);
assert.ok(calls.every((call) => !call.path.includes(token)));
assert.ok(calls.every((call) => call.options.cache === "no-store"));
assert.ok(calls.every((call) => call.options.credentials === "omit"));
assert.ok(calls.every((call) => call.options.redirect === "error"));
assert.equal(elements["#encrypted-file"].files[0].name, "delivery.enc");
assert.equal(await elements["#encrypted-file"].files[0].text(), "one network payload");
assert.equal(elements["#fill-test-password"].hidden, true);
assert.equal(elements["#status"].textContent, "Файл получен и выбран. Введи пароль доставки.");

elements["#status"].textContent = "Готово. Файл расшифрован на этом устройстве.";
observers[0].callback();
await new Promise((resolve) => setImmediate(resolve));
assert.equal(calls.length, 3);
assert.equal(calls[2].path, "/api/v1/drop/ack");
assert.equal(calls[2].options.keepalive, true);
assert.equal(JSON.parse(stored.get("keydrop-active-v1")).phase, "ack");
assert.match(elements["#status"].textContent, /повторится/);

await vm.runInContext("startProduction()", context);
assert.equal(calls.length, 4);
assert.equal(calls[3].path, "/api/v1/drop/ack");
assert.equal(stored.size, 0);
assert.equal(elements["#status"].textContent, "Готово. Серверная копия удалена.");

stored.set("keydrop-active-v1", JSON.stringify({ token, lease: randomBytes(32).toString("base64url"), phase: "ack" }));
context.fetch = async () => new Response(null, { status: 410 });
await vm.runInContext("startProduction()", context);
assert.equal(stored.size, 0);
assert.match(elements["#status"].textContent, /не подтверждено/);
assert.equal(elements["#status"].dataset.error, "true");
console.log("PASS fragment erased, one payload fetch, in-memory selection, recoverable acknowledgement");
NODE
