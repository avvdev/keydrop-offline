#!/usr/bin/env bash
set -euo pipefail

expected_fixture_sha="6c4277f79eea8644f28ee6b0eb38486a1c8147610c38f6a83c0e6d02428a0201"
actual_fixture_sha="$(sha256sum smoke-not-a-secret.toml.enc | awk '{print $1}')"
test "$actual_fixture_sha" = "$expected_fixture_sha"
grep -F 'keydrop-offline-spike-v5' service-worker.js >/dev/null
grep -F 'id="download-and-select"' index.html >/dev/null
grep -F 'src="autoselect.js"' index.html >/dev/null

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
    navigator: {},
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
  constructor() { this.values = new Map(); }
  async put(key, body, options) {
    const bytes = new Uint8Array(await new Response(body).arrayBuffer());
    this.values.set(key, { bytes, options });
    return { size: bytes.length };
  }
  async get(key) {
    const value = this.values.get(key);
    return value ? { body: new Blob([value.bytes]).stream() } : null;
  }
  async delete(key) { this.values.delete(key); }
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

const payload = await worker.fetch(access("GET", "/api/v1/drop", token, winner), env);
assert.equal(payload.status, 200);
assert.equal(payload.headers.get("cache-control"), "no-store, private, max-age=0");
assert.deepEqual(new Uint8Array(await payload.arrayBuffer()), ciphertext);
assert.equal((await worker.fetch(access("POST", "/api/v1/drop/ack", token, winner), env)).status, 204);
assert.equal(bucket.values.size, 0);
assert.equal((await worker.fetch(access("GET", "/api/v1/drop", token, winner), env)).status, 410);

const assets = {
  async fetch() { return new Response("<html></html>", { headers: { "Content-Type": "text/html" } }); },
};
const page = await worker.fetch(new Request("https://drop.test/"), { ASSETS: assets });
assert.match(page.headers.get("content-security-policy"), /frame-ancestors 'none'/);
assert.equal(page.headers.get("referrer-policy"), "no-referrer");
assert.equal(page.headers.get("cache-control"), "no-store");
assert.ok(!(/console\.(log|error|warn)/).test(await (await import("node:fs/promises")).readFile("worker/index.mjs", "utf8")));
console.log("PASS Worker auth, fragment capability, atomic lease, no-store payload, acknowledgement cleanup");
NODE
