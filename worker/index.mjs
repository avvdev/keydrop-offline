const TOKEN_RE = /^[A-Za-z0-9_-]{43}$/;
const MAX_BYTES = 16 * 1024 * 1024;
const DEFAULT_TTL = 1800;
const MAX_TTL = 43200;
const LEASE_MS = 15 * 60 * 1000;
const TEST_FIXTURE_BASE64 = "ekRLTzZYWVhpb2MG5RiPwa8aXbSjTZVbtuJ0j74NTnvAxmjRcxXycCtY4g2Ecw6p8Ll3u49nassBW7o368B7W2JCgPG10oUIXDoTBMOF+la+iCXCssbXw/i9+/hULx5G0xY=";

export default {
  async fetch(request, env) {
    try {
      const url = new URL(request.url);
      if (request.method === "GET" && url.pathname === "/healthz") {
        return json({ ok: true });
      }
      if (request.method === "POST" && url.pathname === "/api/v1/drops") {
        return await upload(request, env);
      }
      const action = apiAction(request.method, url.pathname);
      if (action) return await dispatchDrop(request, env, action);
      if (request.method === "GET" && url.pathname === "/service-worker.js") {
        return retiredServiceWorker();
      }
      if (request.method === "GET" && url.pathname === "/smoke-not-a-secret.toml.enc") {
        return testFixture();
      }
      if (!env.ASSETS) return fail(404, "not_found");
      return secureAsset(await env.ASSETS.fetch(request), url.pathname);
    } catch {
      return fail(500, "internal_error");
    }
  },
};

export class DropSession {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env;
  }

  async fetch(request) {
    const action = new URL(request.url).pathname.slice(1);
    if (action === "init" && request.method === "POST") return this.init(request);
    if (action === "claim" && request.method === "POST") return this.claim(request);
    if (action === "payload" && request.method === "GET") return this.payload(request);
    if (action === "ack" && request.method === "POST") return this.ack(request);
    return fail(404, "not_found");
  }

  async init(request) {
    const state = await request.json();
    await this.ctx.storage.setAlarm(state.expiresAt);
    const created = await this.ctx.storage.transaction(async (tx) => {
      if (await tx.get("drop")) return false;
      await tx.put("drop", { ...state, status: "available" });
      return true;
    });
    if (!created) return fail(409, "exists");
    return new Response(null, { status: 204 });
  }

  async claim(request) {
    const lease = request.headers.get("x-keydrop-lease") || "";
    if (!TOKEN_RE.test(lease)) return fail(400, "invalid_lease");
    const leaseHash = await sha256Hex(lease);
    const now = Date.now();
    const result = await this.ctx.storage.transaction(async (tx) => {
      const state = await tx.get("drop");
      if (!state) return { status: 410 };
      if (state.expiresAt <= now) return { status: 410, expired: state };
      if (state.status === "consumed") return { status: 410 };
      if (state.status === "leased" && state.leaseUntil > now && state.leaseHash !== leaseHash) {
        return { status: 410 };
      }
      state.status = "leased";
      state.leaseHash = leaseHash;
      state.leaseUntil = Math.min(state.expiresAt, now + LEASE_MS);
      await tx.put("drop", state);
      return { status: 204 };
    });
    if (result.expired) await this.cleanup(result.expired);
    return new Response(null, { status: result.status });
  }

  async payload(request) {
    const result = await this.authorize(request, false);
    if (result.expired) await this.cleanup(result.expired);
    if (!result.state) return fail(410, "gone");
    const object = await this.env.DROPS.get(result.state.r2Key);
    if (!object) {
      await this.cleanup(result.state);
      return fail(410, "gone");
    }
    return new Response(object.body, {
      headers: noStoreHeaders({
        "Content-Type": "application/octet-stream",
        "Content-Length": String(result.state.size),
        "X-Keydrop-SHA256": result.state.sha256,
        "X-Content-Type-Options": "nosniff",
      }),
    });
  }

  async ack(request) {
    const result = await this.authorize(request, true);
    if (result.expired) await this.cleanup(result.expired);
    if (!result.state) return fail(410, "gone");
    await this.env.DROPS.delete(result.state.r2Key);
    return new Response(null, { status: 204, headers: noStoreHeaders() });
  }

  async authorize(request, consume) {
    const lease = request.headers.get("x-keydrop-lease") || "";
    if (!TOKEN_RE.test(lease)) return {};
    const leaseHash = await sha256Hex(lease);
    const now = Date.now();
    return this.ctx.storage.transaction(async (tx) => {
      const state = await tx.get("drop");
      if (!state) return {};
      if (state.expiresAt <= now) return { expired: state };
      if (state.status !== "leased" || state.leaseUntil <= now || state.leaseHash !== leaseHash) return {};
      if (consume) {
        state.status = "consumed";
        delete state.leaseHash;
        delete state.leaseUntil;
      } else {
        state.leaseUntil = Math.min(state.expiresAt, now + LEASE_MS);
      }
      await tx.put("drop", state);
      return { state };
    });
  }

  async cleanup(state) {
    await this.env.DROPS.delete(state.r2Key);
    await this.ctx.storage.deleteAll();
  }

  async alarm() {
    const state = await this.ctx.storage.get("drop");
    if (state) await this.env.DROPS.delete(state.r2Key);
    await this.ctx.storage.deleteAll();
  }
}

async function upload(request, env) {
  if (!(await uploadAuthorized(request, env.UPLOAD_TOKEN))) return fail(401, "unauthorized");
  const size = Number(request.headers.get("content-length"));
  if (!Number.isSafeInteger(size) || size < 1 || size > MAX_BYTES || !request.body) {
    return fail(413, "invalid_size");
  }
  const ttl = Number(request.headers.get("x-keydrop-ttl") || DEFAULT_TTL);
  if (!Number.isInteger(ttl) || ttl < 300 || ttl > MAX_TTL) return fail(400, "invalid_ttl");
  const checksum = request.headers.get("x-keydrop-sha256") || "";
  if (!/^[a-f0-9]{64}$/.test(checksum)) return fail(400, "invalid_checksum");

  const token = randomToken();
  const digest = await sha256Hex(token);
  const r2Key = `drops/${digest}`;
  const expiresAt = Date.now() + ttl * 1000;
  let initialized = false;
  try {
    const stored = await env.DROPS.put(r2Key, request.body, {
      customMetadata: { expiresAt: String(expiresAt) },
      httpMetadata: { contentType: "application/octet-stream" },
      sha256: hexBytes(checksum).buffer,
    });
    if (!stored || stored.size !== size) return fail(400, "invalid_size");
    const stub = env.DROP_SESSIONS.get(env.DROP_SESSIONS.idFromName(digest));
    const response = await stub.fetch(new Request("https://drop.internal/init", {
      method: "POST",
      body: JSON.stringify({ r2Key, expiresAt, size: stored.size, sha256: checksum }),
    }));
    if (!response.ok) return fail(503, "state_unavailable");
    initialized = true;
    return json({
      url: `${new URL(request.url).origin}/#${token}`,
      expiresAt: new Date(expiresAt).toISOString(),
      sha256: checksum,
    }, 201);
  } finally {
    if (!initialized) await env.DROPS.delete(r2Key);
  }
}

async function dispatchDrop(request, env, action) {
  const authorization = request.headers.get("authorization") || "";
  const token = authorization.startsWith("Keydrop ") ? authorization.slice(8) : "";
  const lease = request.headers.get("x-keydrop-lease") || "";
  if (!TOKEN_RE.test(token) || !TOKEN_RE.test(lease)) return fail(410, "gone");
  const digest = await sha256Hex(token);
  const stub = env.DROP_SESSIONS.get(env.DROP_SESSIONS.idFromName(digest));
  const forwarded = new Request(`https://drop.internal/${action}`, {
    method: action === "payload" ? "GET" : "POST",
    headers: { "x-keydrop-lease": lease },
  });
  return noStore(await stub.fetch(forwarded));
}

function apiAction(method, path) {
  if (method === "POST" && path === "/api/v1/drop/claim") return "claim";
  if (method === "GET" && path === "/api/v1/drop") return "payload";
  if (method === "POST" && path === "/api/v1/drop/ack") return "ack";
  return null;
}

async function uploadAuthorized(request, expected) {
  const header = request.headers.get("authorization") || "";
  const supplied = header.startsWith("Bearer ") ? header.slice(7) : "";
  if (!expected || supplied.length < 32 || supplied.length > 512) return false;
  const [left, right] = await Promise.all([sha256Bytes(supplied), sha256Bytes(expected)]);
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) difference |= left[index] ^ right[index];
  return difference === 0;
}

function secureAsset(response, path) {
  const secured = new Response(response.body, response);
  const headers = secured.headers;
  headers.set("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; manifest-src 'self'; worker-src 'self'; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'");
  headers.set("Referrer-Policy", "no-referrer");
  headers.set("X-Content-Type-Options", "nosniff");
  headers.set("X-Frame-Options", "DENY");
  headers.set("Cross-Origin-Opener-Policy", "same-origin");
  headers.set("Permissions-Policy", "camera=(), microphone=(), geolocation=()");
  if (path === "/" || path.endsWith(".html")) headers.set("Cache-Control", "no-store");
  return secured;
}

function retiredServiceWorker() {
  const source = `self.addEventListener("install",()=>self.skipWaiting());self.addEventListener("activate",event=>event.waitUntil((async()=>{await Promise.all((await caches.keys()).map(key=>caches.delete(key)));await self.clients.claim();const windows=await self.clients.matchAll({type:"window",includeUncontrolled:true});await self.registration.unregister();await Promise.allSettled(windows.map(client=>client.navigate(client.url)))})()));`;
  return new Response(source, { headers: noStoreHeaders({
    "Content-Type": "text/javascript; charset=utf-8",
    "Service-Worker-Allowed": "/",
  }) });
}

function testFixture() {
  const encoded = atob(TEST_FIXTURE_BASE64);
  const bytes = Uint8Array.from(encoded, (value) => value.charCodeAt(0));
  return new Response(bytes, { headers: noStoreHeaders({
    "Content-Type": "application/octet-stream",
    "Content-Length": String(bytes.length),
    "X-Content-Type-Options": "nosniff",
  }) });
}

function noStore(response) {
  const copy = new Response(response.body, response);
  for (const [key, value] of noStoreHeaders()) copy.headers.set(key, value);
  return copy;
}

function noStoreHeaders(extra = {}) {
  return new Headers({
    "Cache-Control": "no-store, private, max-age=0",
    "CDN-Cache-Control": "no-store",
    "Referrer-Policy": "no-referrer",
    ...extra,
  });
}

function json(value, status = 200) {
  return new Response(JSON.stringify(value), {
    status,
    headers: noStoreHeaders({ "Content-Type": "application/json" }),
  });
}

function fail(status, code) {
  return json({ error: code }, status);
}

function randomToken() {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

async function sha256Bytes(value) {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)));
}

async function sha256Hex(value) {
  return Array.from(await sha256Bytes(value), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function hexBytes(value) {
  return Uint8Array.from(value.match(/../g), (byte) => Number.parseInt(byte, 16));
}
