#!/usr/bin/env bash
set -euo pipefail

expected_fixture_sha="6c4277f79eea8644f28ee6b0eb38486a1c8147610c38f6a83c0e6d02428a0201"
actual_fixture_sha="$(sha256sum smoke-not-a-secret.toml.enc | awk '{print $1}')"
test "$actual_fixture_sha" = "$expected_fixture_sha"
grep -F 'keydrop-offline-spike-v4' service-worker.js >/dev/null

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
  };
}

async function main() {
  const elements = {
    "#decrypt-form": element(),
    "#encrypted-file": element(),
    "#file-info": element(),
    "#password": element(),
    "#fill-test-password": element(),
    "#toggle-password": element(),
    "#status": element(),
  };
  let downloadedBlob;
  const context = {
    ArrayBuffer,
    Blob,
    DataView,
    Promise,
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

  const encrypted = fs.readFileSync("smoke-not-a-secret.toml.enc");
  elements["#encrypted-file"].files = [{
    name: "smoke-not-a-secret.toml.enc",
    size: encrypted.length,
    async arrayBuffer() {
      return encrypted.buffer.slice(encrypted.byteOffset, encrypted.byteOffset + encrypted.byteLength);
    },
  }];
  await elements["#encrypted-file"].handlers.change();
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
