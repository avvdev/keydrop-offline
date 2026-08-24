# Production runbook

All commands below run on the VPS from the checked-out repository root. In the current OpenClaw layout that is:

```bash
cd /home/node/.openclaw/workspace/keydrop-offline-source
```

Use Node.js 22 or newer and pinned Wrangler `4.125.0`. Do not put the Cloudflare login, upload token, delivery passwords, real plaintext, or real `.enc` objects in Git.

## 1. One-time Cloudflare bootstrap

Login is interactive and changes Cloudflare account state:

```bash
npx --yes wrangler@4.125.0 login
npx --yes wrangler@4.125.0 r2 bucket create keydrop-drops
```

Create one local upload token without printing it. Keep a raw copy for the CLI and a protected dotenv copy for an atomic first deploy:

```bash
install -d -m 0700 /home/node/.config/keydrop
umask 077
openssl rand -hex 32 > /home/node/.config/keydrop/upload-token
chmod 0600 /home/node/.config/keydrop/upload-token
awk '{ print "UPLOAD_TOKEN=" $0 }' \
  /home/node/.config/keydrop/upload-token \
  > /home/node/.config/keydrop/worker-secrets.env
chmod 0600 /home/node/.config/keydrop/worker-secrets.env
```

Add a lifecycle backstop for an object orphaned between R2 write and Durable Object initialization. Normal deletion still happens at ACK or TTL; this rule removes any remaining `drops/` object after one day:

```bash
npx --yes wrangler@4.125.0 r2 bucket lifecycle add \
  keydrop-drops keydrop-orphan-backstop drops/ \
  --expire-days 1 --force
npx --yes wrangler@4.125.0 r2 bucket lifecycle list keydrop-drops
```

## 2. Pre-deploy gate

```bash
bash tests/smoke.sh
install -d -m 0700 /home/node/.local/state/keydrop/wrangler-dry-run
WRANGLER_SEND_METRICS=false npx --yes wrangler@4.125.0 deploy \
  --config worker/wrangler.jsonc \
  --dry-run \
  --outdir /home/node/.local/state/keydrop/wrangler-dry-run
```

The config must show bindings `DROP_SESSIONS`, `DROPS`, and `ASSETS`. `.assetsignore` is deny-by-default. Only these six assets may be public:

```text
autoselect.js
decrypt.bundle.js
icon.svg
index.html
manifest.webmanifest
smoke-not-a-secret.toml.enc
```

Wrangler may report how many paths it scanned before ignore rules; that number is not the public count. Run with `WRANGLER_LOG=debug` when auditing and verify that `keydrop`, `cli`, `tests`, `worker`, `.git`, and `service-worker.js` are all logged as ignored.

## 3. Deploy and verify

Deployment is an external production change. Run it only after reviewing the gate:

```bash
WRANGLER_SEND_METRICS=false npx --yes wrangler@4.125.0 deploy \
  --config worker/wrangler.jsonc \
  --secrets-file /home/node/.config/keydrop/worker-secrets.env
```

Save the HTTPS origin printed by Wrangler, including no path, query, or fragment. Verify it without an upload secret:

```bash
curl -fsS https://keydrop.YOUR-SUBDOMAIN.workers.dev/healthz
curl -fsSI https://keydrop.YOUR-SUBDOMAIN.workers.dev/ \
  | grep -Ei 'content-security-policy|cache-control|referrer-policy|x-frame-options'
```

`workers_dev` is intentionally enabled for the first deployment. If a custom domain is later configured, set `workers_dev` to `false` and verify the `workers.dev` origin is no longer a bypass.

## 4. Manual send from the console

Prepare a private password directory once:

```bash
install -d -m 0700 /home/node/.local/state/keydrop/passwords
```

For each file choose a new password output path. The command prints exactly one URL and leaves the password in a new mode-`0600` file:

```bash
./keydrop send /absolute/path/generated-file \
  --endpoint https://keydrop.YOUR-SUBDOMAIN.workers.dev/ \
  --token-file /home/node/.config/keydrop/upload-token \
  --password-out /home/node/.local/state/keydrop/passwords/delivery-001.pass \
  --ttl 1800
```

Copy stdout as the Telegram link. Read the password only from the console or send it through a separately trusted channel:

```bash
sed -n '1p' /home/node/.local/state/keydrop/passwords/delivery-001.pass
```

Do not paste URL and password into the same Telegram message if protection against a captured Telegram account matters.

## 5. Automated send

The automation uses the same CLI. Prefer stdin so generated plaintext never needs a temporary file:

```bash
umask 077
/absolute/path/to/generator \
  | ./keydrop send - \
      --endpoint https://keydrop.YOUR-SUBDOMAIN.workers.dev/ \
      --token-file /home/node/.config/keydrop/upload-token \
      --password-out /home/node/.local/state/keydrop/passwords/job-001.pass \
      --ttl 1800 \
  > /home/node/.local/state/keydrop/job-001.url
```

The notification layer reads only `job-001.url` and sends that URL. It must not attach the password file or log the upload token. For Katya/OpenClaw, the normal reply in the active Telegram conversation carries the URL; the password stays on the VPS for console retrieval or a separate channel. No `sessions_send`, cron, systemd, or Telegram configuration change is required by Keydrop itself.

If a generator writes plaintext to disk, cleanup remains the generator/operator's responsibility. Keydrop never deletes caller-owned input. Prefer a private directory and a normal unlink after use; do not claim secure erasure on SSD or copy-on-write storage.

## 6. Recipient flow

1. Open the URL in Brave or Fennec.
2. The fragment is removed from browser history immediately.
3. The page claims one lease and loads ciphertext directly into memory; Android's file picker is not used.
4. Enter the separately received password and decrypt.
5. Keep the page open until it says `Готово. Серверная копия удалена.`

If acknowledgement loses its response, the browser records an `ack` phase in `sessionStorage` and retries on the next open. A `410` during that retry is treated as already consumed. If Android fails to persist the decrypted download, retry decryption in the same still-open page before closing it.

## 7. Rotation, rollback, and cleanup

Rotate the upload credential without printing it. Apply the remote secret first, then atomically replace both protected local copies so a later `--secrets-file` deploy cannot restore the old value:

```bash
umask 077
openssl rand -hex 32 > /home/node/.config/keydrop/upload-token.next
awk '{ print "UPLOAD_TOKEN=" $0 }' \
  /home/node/.config/keydrop/upload-token.next \
  > /home/node/.config/keydrop/worker-secrets.env.next
npx --yes wrangler@4.125.0 secret put UPLOAD_TOKEN \
  --config worker/wrangler.jsonc \
  < /home/node/.config/keydrop/upload-token.next
mv /home/node/.config/keydrop/upload-token.next /home/node/.config/keydrop/upload-token
mv /home/node/.config/keydrop/worker-secrets.env.next /home/node/.config/keydrop/worker-secrets.env
```

List deployments and roll back to a reviewed version:

```bash
npx --yes wrangler@4.125.0 deployments list --config worker/wrangler.jsonc
npx --yes wrangler@4.125.0 rollback VERSION_ID \
  --config worker/wrangler.jsonc \
  --message "rollback keydrop" --yes
```

After the recipient confirms success, remove the local password file:

```bash
unlink /home/node/.local/state/keydrop/passwords/delivery-001.pass
```

On CLI failure or `SIGINT`/`SIGTERM`/`SIGHUP`, Keydrop truncates and syncs the created password inode before unlinking its unchanged path. A local path-replacement race cannot make it delete the replacement. A remote ciphertext may still survive until TTL/lifecycle if a network outcome was ambiguous; it contains no password.

## 8. Operational checks

- `/healthz` proves Worker routing, not R2/DO health.
- A canary must use fake plaintext and complete upload, claim, payload, decrypt, and ACK.
- No drop-listing endpoint exists by design.
- Keep application observability free of URLs, fragments, authorization headers, password paths, filenames, payloads, and hashes tied to a recipient.
- Alert on upload `5xx`, missing/stale canary success, R2 lifecycle drift, or repeated cleanup failures; do not log secrets to make diagnosis easier.
