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
