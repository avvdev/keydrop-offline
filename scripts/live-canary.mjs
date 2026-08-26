#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import {
  closeSync,
  existsSync,
  fstatSync,
  fsyncSync,
  ftruncateSync,
  mkdtempSync,
  openSync,
  readFileSync,
  rmSync,
  statSync,
  unlinkSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const USAGE = "usage: node scripts/live-canary.mjs --endpoint URL --token-file FILE";
const TOKEN_RE = /^[A-Za-z0-9_-]{43}$/;
const root = dirname(dirname(fileURLToPath(import.meta.url)));

process.umask(0o077);

function parse(argv) {
  if (argv.length === 1 && ["-h", "--help"].includes(argv[0])) return null;
  const options = {};
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!value || !["--endpoint", "--token-file"].includes(flag) || options[flag]) {
      throw new Error("invalid arguments");
    }
    options[flag] = value;
  }
  if (!options["--endpoint"] || !options["--token-file"]) throw new Error("missing required option");
  let endpoint;
  try { endpoint = new URL(options["--endpoint"]); } catch { throw new Error("invalid endpoint"); }
  const local = endpoint.protocol === "http:" && ["localhost", "127.0.0.1", "[::1]"].includes(endpoint.hostname);
  if (endpoint.protocol !== "https:" && !local) throw new Error("endpoint must use HTTPS");
  if (endpoint.username || endpoint.password || endpoint.pathname !== "/" || endpoint.search || endpoint.hash) {
    throw new Error("endpoint must be an origin URL");
  }
  return { endpoint, tokenFile: options["--token-file"] };
}

async function request(endpoint, path, options = {}) {
  return fetch(new URL(path, endpoint), {
    cache: "no-store",
    credentials: "omit",
    redirect: "error",
    referrerPolicy: "no-referrer",
    signal: AbortSignal.timeout(30_000),
    ...options,
  });
}

async function decryptWithBrowserBundle(ciphertext, password) {
  function element() {
    return {
      dataset: {},
      files: [],
      handlers: {},
      textContent: "",
      type: "",
      value: "",
      addEventListener(name, handler) { this.handlers[name] = handler; },
    };
  }

  class CanaryFile extends Blob {
    constructor(parts, name, options) {
      super(parts, options);
      this.name = name;
    }
  }

  const elements = {
    "#decrypt-form": element(),
    "#encrypted-file": element(),
    "#file-info": element(),
    "#password": element(),
    "#fill-test-password": element(),
    "#toggle-password": element(),
    "#status": element(),
  };
  elements["#encrypted-file"].files = [new CanaryFile([ciphertext], "canary.enc")];
  elements["#password"].value = password;
  let downloaded;
  const context = {
    ArrayBuffer,
    Blob,
    DataView,
    File: CanaryFile,
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
      querySelector(selector) { return elements[selector]; },
      createElement() { return { click() {}, download: "", href: "" }; },
    },
    navigator: {},
    queueMicrotask,
    setImmediate,
    setTimeout(callback) { queueMicrotask(callback); return 0; },
    clearTimeout() {},
    URL: {
      createObjectURL(blob) { downloaded = blob; return "blob:canary"; },
      revokeObjectURL() {},
    },
  };
  context.globalThis = context;
  context.self = context;
  context.window = context;
  vm.createContext(context);
  vm.runInContext(readFileSync(join(root, "decrypt.bundle.js"), "utf8"), context, {
    filename: "decrypt.bundle.js",
    timeout: 120_000,
  });
  await elements["#decrypt-form"].handlers.submit({ preventDefault() {} });
  if (elements["#status"].textContent !== "Готово. Файл расшифрован на этом устройстве." || !downloaded) {
    throw new Error("canary decryption failed");
  }
  return new Uint8Array(await downloaded.arrayBuffer());
}

function scrub(path) {
  if (!existsSync(path)) return;
  let fd;
  try {
    fd = openSync(path, "r+");
    ftruncateSync(fd, 0);
    fsyncSync(fd);
  } catch {
  } finally {
    if (fd !== undefined) try { closeSync(fd); } catch {}
  }
  try { unlinkSync(path); } catch {}
}

async function main() {
  const options = parse(process.argv.slice(2));
  if (!options) {
    process.stdout.write(`${USAGE}\n`);
    return;
  }

  const temporary = mkdtempSync(join(tmpdir(), "keydrop-live-canary-"));
  const passwordPath = join(temporary, "delivery.pass");
  const plaintext = Buffer.from(`keydrop live canary ${randomBytes(16).toString("hex")}\n`);
  let ciphertext;
  let repeatedCiphertext;
  try {
    const sent = spawnSync(join(root, "keydrop"), [
      "send", "-",
      "--endpoint", options.endpoint.href,
      "--token-file", options.tokenFile,
      "--password-out", passwordPath,
      "--ttl", "300",
    ], { input: plaintext, encoding: "utf8", timeout: 60_000, maxBuffer: 16 * 1024 });
    if (sent.error || sent.status !== 0 || sent.stderr !== "") throw new Error("canary CLI upload failed");
    const lines = sent.stdout.split(/\r?\n/);
    if (lines.length !== 2 || lines[1] !== "") throw new Error("invalid canary receipt");

    let delivery;
    try { delivery = new URL(lines[0]); } catch { throw new Error("invalid canary receipt"); }
    const token = delivery.hash.slice(1);
    if (delivery.origin !== options.endpoint.origin || delivery.pathname !== "/" || delivery.search ||
        delivery.username || delivery.password || !TOKEN_RE.test(token)) throw new Error("invalid canary receipt");
    const passwordStat = statSync(passwordPath);
    if (!passwordStat.isFile() || (passwordStat.mode & 0o077) !== 0) throw new Error("unsafe canary password file");
    const password = readFileSync(passwordPath, "utf8").trim();
    const uploadToken = readFileSync(options.tokenFile, "utf8").trim();
    if (uploadToken.length < 32 || uploadToken.length > 512) throw new Error("invalid upload token file");
    const firstHeaders = {
      Authorization: `Keydrop ${token}`,
      "X-Keydrop-Lease": randomBytes(32).toString("base64url"),
    };
    const secondHeaders = {
      Authorization: `Keydrop ${token}`,
      "X-Keydrop-Lease": randomBytes(32).toString("base64url"),
    };

    const firstClaim = await request(options.endpoint, "/api/v1/drop/claim", { method: "POST", headers: firstHeaders });
    const secondClaim = await request(options.endpoint, "/api/v1/drop/claim", { method: "POST", headers: secondHeaders });
    if (firstClaim.status !== 204 || secondClaim.status !== 204) throw new Error("canary repeatable claim failed");
    const payload = await request(options.endpoint, "/api/v1/drop", { headers: firstHeaders });
    if (payload.status !== 200) throw new Error("canary payload failed");
    const expectedSize = Number(payload.headers.get("content-length"));
    const expectedHash = payload.headers.get("x-keydrop-sha256") || "";
    ciphertext = new Uint8Array(await payload.arrayBuffer());
    if (!Number.isSafeInteger(expectedSize) || expectedSize !== ciphertext.length || !/^[a-f0-9]{64}$/.test(expectedHash)) {
      throw new Error("invalid canary payload metadata");
    }
    const actualHash = createHash("sha256").update(ciphertext).digest("hex");
    if (actualHash !== expectedHash) throw new Error("canary checksum failed");
    const decrypted = await decryptWithBrowserBundle(ciphertext, password);
    if (decrypted.length !== plaintext.length || !timingSafeEqual(Buffer.from(decrypted), plaintext)) {
      throw new Error("canary plaintext mismatch");
    }
    decrypted.fill(0);

    const repeated = await request(options.endpoint, "/api/v1/drop", { headers: secondHeaders });
    if (repeated.status !== 200) throw new Error("canary repeat download failed");
    repeatedCiphertext = new Uint8Array(await repeated.arrayBuffer());
    if (repeatedCiphertext.length !== ciphertext.length ||
        !timingSafeEqual(Buffer.from(repeatedCiphertext), Buffer.from(ciphertext))) {
      throw new Error("canary repeat payload mismatch");
    }

    const legacyAck = await request(options.endpoint, "/api/v1/drop/ack", { method: "POST", headers: firstHeaders });
    if (legacyAck.status !== 409) throw new Error("canary legacy acknowledgement was not rejected");
    const afterAck = await request(options.endpoint, "/api/v1/drop", { headers: secondHeaders });
    if (afterAck.status !== 200) throw new Error("legacy acknowledgement destroyed repeatable drop");
    await afterAck.arrayBuffer();

    const revokeHeaders = { Authorization: `Bearer ${uploadToken}`, "X-Keydrop-Token": token };
    const revoke = await request(options.endpoint, "/api/v1/drop", { method: "DELETE", headers: revokeHeaders });
    if (revoke.status !== 204) throw new Error("canary revoke failed");
    const retry = await request(options.endpoint, "/api/v1/drop", { method: "DELETE", headers: revokeHeaders });
    if (retry.status !== 204) throw new Error("canary revoke retry failed");
    const replay = await request(options.endpoint, "/api/v1/drop", { headers: secondHeaders });
    if (replay.status !== 410) throw new Error("canary replay was not rejected");
    process.stdout.write("PASS keydrop live data-plane canary\n");
  } finally {
    plaintext.fill(0);
    ciphertext?.fill(0);
    repeatedCiphertext?.fill(0);
    scrub(passwordPath);
    rmSync(temporary, { recursive: true, force: true });
  }
}

main().catch((error) => {
  process.stderr.write(`keydrop-canary: ${error.message || "failed"}\n`);
  process.exitCode = 1;
});
