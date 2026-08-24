import sodium from "libsodium-wrappers-sumo";
import { createHash, randomBytes } from "node:crypto";
import { open, unlink } from "node:fs/promises";
import { constants, unlinkSync } from "node:fs";

const SIGNATURE = new TextEncoder().encode("zDKO6XYXioc");
const SALT_BYTES = 16, HEADER_BYTES = 24, AUTH_BYTES = 17;
const MAX_CIPHERTEXT = 16 * 1024 * 1024, MAX_PLAINTEXT = MAX_CIPHERTEXT - SIGNATURE.length - SALT_BYTES - HEADER_BYTES - AUTH_BYTES;
const TOKEN_RE = /^[A-Za-z0-9._~-]{32,512}$/, DELIVERY_RE = /^[A-Za-z0-9_-]{43}$/, ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
let incompletePasswordPath;

process.umask(0o077);
process.once("SIGINT", () => stop(130));
process.once("SIGTERM", () => stop(143));

function stop(code) {
  if (incompletePasswordPath) {
    try { unlinkSync(incompletePasswordPath); } catch {}
  }
  process.exit(code);
}

function parse(argv) {
  if (argv[0] !== "send" || !argv[1] || argv[1].startsWith("--")) {
    throw new Error("usage: keydrop send FILE|- --endpoint URL --token-file FILE --password-out FILE [--ttl SECONDS]");
  }
  const options = { input: argv[1], ttl: 1800 }, seen = new Set();
  for (let index = 2; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!value || !["--endpoint", "--token-file", "--password-out", "--ttl"].includes(flag)) {
      throw new Error("invalid arguments");
    }
    if (seen.has(flag)) throw new Error("duplicate option");
    seen.add(flag);
    const key = flag.slice(2).replace(/-([a-z])/g, (_, letter) => letter.toUpperCase());
    options[key] = value;
  }
  if (!options.endpoint || !options.tokenFile || !options.passwordOut) throw new Error("missing required option");
  options.ttl = Number(options.ttl);
  if (!Number.isInteger(options.ttl) || options.ttl < 300 || options.ttl > 43200) {
    throw new Error("ttl must be between 300 and 43200 seconds");
  }
  return options;
}

function endpoint(value) {
  let parsed;
  try { parsed = new URL(value); } catch { throw new Error("invalid endpoint"); }
  const localHttp = parsed.protocol === "http:" && ["localhost", "127.0.0.1", "[::1]"].includes(parsed.hostname);
  if (parsed.protocol !== "https:" && !localHttp) throw new Error("endpoint must use HTTPS");
  if (parsed.username || parsed.password || parsed.search || parsed.hash || parsed.pathname !== "/") {
    throw new Error("endpoint must be an origin URL");
  }
  return parsed;
}

async function uploadToken(path) {
  const handle = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const stat = await handle.stat();
    if (!stat.isFile() || (stat.mode & 0o077) !== 0) throw new Error("token file must be a private regular file");
    const token = (await handle.readFile("utf8")).trim();
    if (!TOKEN_RE.test(token)) throw new Error("invalid upload token file");
    return token;
  } finally {
    await handle.close();
  }
}

async function plaintext(input) {
  if (input !== "-") {
    const handle = await open(input, constants.O_RDONLY | constants.O_NOFOLLOW);
    try {
      const stat = await handle.stat();
      if (!stat.isFile() || stat.size > MAX_PLAINTEXT) throw new Error("input must be a regular file smaller than 16 MiB");
      const bytes = new Uint8Array(await handle.readFile());
      if (bytes.length > MAX_PLAINTEXT) throw new Error("input is too large");
      return bytes;
    } finally {
      await handle.close();
    }
  }
  const chunks = [];
  let size = 0;
  for await (const chunk of process.stdin) {
    size += chunk.length;
    if (size > MAX_PLAINTEXT) throw new Error("input is too large");
    chunks.push(chunk);
  }
  return new Uint8Array(Buffer.concat(chunks, size));
}

function password() {
  const bytes = randomBytes(16);
  let bits = 0;
  let value = 0;
  let encoded = "";
  for (const byte of bytes) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      encoded += ALPHABET[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits) encoded += ALPHABET[(value << (5 - bits)) & 31];
  bytes.fill(0);
  return encoded.match(/.{1,5}/g).join("-");
}

async function encrypt(input, passphrase) {
  await sodium.ready;
  const salt = sodium.randombytes_buf(SALT_BYTES);
  const key = sodium.crypto_pwhash(
    sodium.crypto_secretstream_xchacha20poly1305_KEYBYTES,
    passphrase,
    salt,
    sodium.crypto_pwhash_OPSLIMIT_INTERACTIVE,
    sodium.crypto_pwhash_MEMLIMIT_INTERACTIVE,
    sodium.crypto_pwhash_ALG_ARGON2ID13,
  );
  try {
    const initialized = sodium.crypto_secretstream_xchacha20poly1305_init_push(key);
    const encrypted = sodium.crypto_secretstream_xchacha20poly1305_push(
      initialized.state,
      input,
      null,
      sodium.crypto_secretstream_xchacha20poly1305_TAG_FINAL,
    );
    return concat([SIGNATURE, salt, initialized.header, encrypted]);
  } finally {
    sodium.memzero(key);
  }
}

function concat(parts) {
  const result = new Uint8Array(parts.reduce((total, part) => total + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    result.set(part, offset);
    offset += part.length;
  }
  return result;
}

async function savePassword(path, passphrase) {
  const handle = await open(path, "wx", 0o600);
  incompletePasswordPath = path;
  try {
    await handle.writeFile(`${passphrase}\n`, "utf8");
    await handle.sync();
  } finally {
    await handle.close();
  }
}

async function upload(origin, token, ttl, ciphertext) {
  const checksum = createHash("sha256").update(ciphertext).digest("hex");
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 30_000);
  let response;
  try {
    response = await fetch(new URL("/api/v1/drops", origin), {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Length": String(ciphertext.length),
        "Content-Type": "application/octet-stream",
        "X-Keydrop-SHA256": checksum,
        "X-Keydrop-TTL": String(ttl),
      },
      body: ciphertext,
      redirect: "error",
      referrerPolicy: "no-referrer",
      signal: controller.signal,
    });
  } catch {
    throw new Error("upload failed");
  } finally {
    clearTimeout(timeout);
  }
  if (response.status !== 201) throw new Error("upload rejected");
  const raw = await limitedBody(response, 8192);
  let receipt;
  try { receipt = JSON.parse(raw); } catch { throw new Error("invalid upload receipt"); }
  let delivery;
  try { delivery = new URL(receipt.url); } catch { throw new Error("invalid delivery URL"); }
  if (delivery.origin !== origin.origin || delivery.pathname !== "/" || delivery.search ||
      !DELIVERY_RE.test(delivery.hash.slice(1))) {
    throw new Error("invalid delivery URL");
  }
  return delivery.href;
}

async function limitedBody(response, limit) {
  const reader = response.body?.getReader();
  if (!reader) return "";
  const chunks = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.length;
    if (size > limit) throw new Error("upload receipt is too large");
    chunks.push(value);
  }
  return new TextDecoder().decode(concat(chunks));
}

async function main() {
  const options = parse(process.argv.slice(2));
  const origin = endpoint(options.endpoint);
  let cleartext;
  let ciphertext;
  let token;
  let passphrase;
  let succeeded = false;
  try {
    token = await uploadToken(options.tokenFile);
    cleartext = await plaintext(options.input);
    passphrase = password();
    ciphertext = await encrypt(cleartext, passphrase);
    await savePassword(options.passwordOut, passphrase);
    const delivery = await upload(origin, token, options.ttl, ciphertext);
    succeeded = true;
    incompletePasswordPath = undefined;
    process.stdout.write(`${delivery}\n`);
  } finally {
    if (!succeeded && incompletePasswordPath) {
      try { await unlink(incompletePasswordPath); } catch {}
      incompletePasswordPath = undefined;
    }
    cleartext?.fill(0);
    ciphertext?.fill(0);
    token = undefined;
    passphrase = undefined;
  }
}

main().catch((error) => {
  process.stderr.write(`keydrop: ${error.message || "failed"}\n`);
  process.exitCode = 1;
});
