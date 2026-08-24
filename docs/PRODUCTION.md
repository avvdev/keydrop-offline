# Production runbook

All commands below run on the VPS from the checked-out repository root. In the current OpenClaw layout that is:

```bash
cd /home/node/.openclaw/workspace/keydrop-offline-source
```

Use Node.js 22 or newer and pinned Wrangler `4.125.0`. Do not put the Cloudflare login, upload token, delivery passwords, real plaintext, or real `.enc` objects in Git.

## 1. One-time Cloudflare bootstrap

Login is interactive and changes Cloudflare account state. On the remote VPS use the device flow, then inspect the authenticated account before creating anything:

```bash
npx --yes wrangler@4.125.0 login --device
npx --yes wrangler@4.125.0 whoami --json
npx --yes wrangler@4.125.0 r2 bucket create keydrop-drops
```

Stop if `whoami --json` does not contain the expected account ID and name. A scoped noninteractive Cloudflare API token is also acceptable when supplied by the VPS secret manager; never place it in this repository or a committed dotenv file.

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

Add a lifecycle backstop for an object orphaned between R2 write and Durable Object initialization. Normal deletion still happens at ACK or TTL. The one-day rule schedules remaining `drops/` objects for expiry; Cloudflare may take additional time to physically delete expired objects, so this is not a strict 24-hour retention cap:

```bash
npx --yes wrangler@4.125.0 r2 bucket lifecycle add \
  keydrop-drops keydrop-orphan-backstop drops/ \
  --expire-days 1 --force
npx --yes wrangler@4.125.0 r2 bucket lifecycle list keydrop-drops
```

## 2. Pre-deploy gate

```bash
npx --yes wrangler@4.125.0 whoami --json
npx --yes wrangler@4.125.0 r2 bucket list
npx --yes wrangler@4.125.0 r2 bucket lifecycle list keydrop-drops
bash tests/smoke.sh
install -d -m 0700 /home/node/.local/state/keydrop/wrangler-dry-run
WRANGLER_SEND_METRICS=false npx --yes wrangler@4.125.0 deploy \
  --config worker/wrangler.jsonc \
  --dry-run \
  --outdir /home/node/.local/state/keydrop/wrangler-dry-run
```

The config must show bindings `DROP_SESSIONS`, `DROPS`, and `ASSETS`. Wrangler reads only the dedicated `worker/public` directory. It must report `Read 5 files`, matching this exact static allowlist:

```text
autoselect.js
decrypt.bundle.js
icon.svg
index.html
manifest.webmanifest
```

`smoke-not-a-secret.toml.enc` is an explicitly harmless fixture served by a fixed Worker route and checked against its pinned SHA-256 by the smoke test; it is not copied into the static directory. The recursive smoke assertion rejects nested paths and symlinks. The root `.assetsignore` is retained only as defense for an accidental legacy Wrangler invocation against the repository root; production publication does not depend on it.

For local Miniflare development, use an isolated `worker/.dev.vars`; it is ignored by Git. Never enable process-environment injection, because unrelated VPS secrets could become Worker bindings:

```bash
umask 077
printf 'UPLOAD_TOKEN=' > worker/.dev.vars
openssl rand -hex 32 >> worker/.dev.vars
CLOUDFLARE_INCLUDE_PROCESS_ENV=false WRANGLER_SEND_METRICS=false \
  npx --yes wrangler@4.125.0 dev --config worker/wrangler.jsonc
```

After stopping Wrangler, remove the local-only credential with `unlink worker/.dev.vars`. Do not use `CLOUDFLARE_INCLUDE_PROCESS_ENV=true` for this project.

## 3. Deploy and verify

Deployment is an external production change. Run it only after reviewing the gate:

```bash
WRANGLER_SEND_METRICS=false npx --yes wrangler@4.125.0 deploy \
  --config worker/wrangler.jsonc \
  --strict \
  --secrets-file /home/node/.config/keydrop/worker-secrets.env
```

Save the HTTPS origin printed by Wrangler, including no path, query, or fragment. Verify it without an upload secret:

```bash
curl -fsS https://keydrop.YOUR-SUBDOMAIN.workers.dev/healthz
curl -fsSI https://keydrop.YOUR-SUBDOMAIN.workers.dev/ \
  | grep -Ei 'content-security-policy|cache-control|referrer-policy|x-frame-options'
node scripts/live-canary.mjs \
  --endpoint https://keydrop.YOUR-SUBDOMAIN.workers.dev/ \
  --token-file /home/node/.config/keydrop/upload-token
```

The deployment is not accepted until the last command prints exactly `PASS keydrop live data-plane canary`. It creates only random fake plaintext, verifies upload → claim → checksum → shipped-browser-bundle decryption → ACK → idempotent ACK → replay `410`, prints no capability or password, and removes its local password artifact. On failure, any remote fake ciphertext is still bounded by the five-minute TTL and lifecycle backstop.

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

The automation uses the same CLI. Gate the generator before upload: a failing producer must not upload empty or partial output. A unique mode-`0700` job directory also gives every O_EXCL password path and bearer URL a fresh name:

```bash
set -euo pipefail
install -d -m 0700 /home/node/.local/state/keydrop/jobs
keydrop_job_dir="$(mktemp -d /home/node/.local/state/keydrop/jobs/job-XXXXXXXX)"
keydrop_plaintext="${keydrop_job_dir}/payload"
keydrop_password="${keydrop_job_dir}/delivery.pass"
keydrop_url_tmp="${keydrop_job_dir}/delivery.url.tmp"
keydrop_url="${keydrop_job_dir}/delivery.url"
keydrop_cleanup() {
  for keydrop_artifact in "$keydrop_plaintext" "$keydrop_password" "$keydrop_url_tmp" "$keydrop_url"; do
    test ! -e "$keydrop_artifact" || unlink "$keydrop_artifact"
  done
}
trap keydrop_cleanup EXIT HUP INT TERM

/absolute/path/to/generator > "$keydrop_plaintext"
test -s "$keydrop_plaintext"
./keydrop send "$keydrop_plaintext" \
  --endpoint https://keydrop.YOUR-SUBDOMAIN.workers.dev/ \
  --token-file /home/node/.config/keydrop/upload-token \
  --password-out "$keydrop_password" \
  --ttl 1800 > "$keydrop_url_tmp"
test "$(wc -l < "$keydrop_url_tmp")" -eq 1
grep -Eq '^https://[^[:space:]#?]+/#[A-Za-z0-9_-]{43}$' "$keydrop_url_tmp"
mv "$keydrop_url_tmp" "$keydrop_url"
unlink "$keydrop_plaintext"
trap - EXIT HUP INT TERM
printf '%s\n' "$keydrop_job_dir"
```

The notification layer reads only `delivery.url` and sends that URL. After confirmed Telegram delivery it unlinks the URL artifact; it must never attach `delivery.pass` or log the upload token. The password stays on the VPS for console retrieval or a separate channel and is unlinked after recipient confirmation. For Katya/OpenClaw, the normal reply in the active Telegram conversation carries the URL; no `sessions_send`, cron, systemd, or Telegram configuration change is required by Keydrop itself.

This reliable gate briefly writes plaintext into the private job directory. Cleanup remains the generator/operator's responsibility, and normal unlink is not secure erasure on SSD or copy-on-write storage. A stdin-only pipeline avoids that file but cannot prevent an already-started upload of partial output when its upstream producer fails.

## 6. Recipient flow

1. Open the URL in Brave or Fennec.
2. The fragment is removed from browser history immediately.
3. The page claims one lease and loads ciphertext directly into memory; Android's file picker is not used.
4. Enter the separately received password and decrypt.
5. Keep the page open until it says `Готово. Серверная копия удалена.`

If acknowledgement loses its response, the browser records an `ack` phase in `sessionStorage` and retries on the next open. The same winning lease receives `204` after confirmed R2 deletion, including an idempotent retry. A `410` closes the local capability but is not presented as proof of immediate physical deletion; TTL, alarm, and lifecycle cleanup remain the backstop. If Android fails to persist the decrypted download, retry decryption in the same still-open page before closing it.

## 7. Rotation, rollback, and cleanup

Rotate the upload credential without printing it. Apply the remote secret first, then replace each protected local copy with an atomic rename so a later `--secrets-file` deploy cannot restore the old value. The pair of renames is not one atomic transaction: if interrupted, keep and resume from the matching `.next` files before another deploy.

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

Do not roll back to a version from before the `v1` Durable Object migration; code rollback cannot undo a Durable Object class migration. Rollback also does not revert R2 objects, Durable Object data, bucket lifecycle rules, secrets, or other resources. Repeat the exact `scripts/live-canary.mjs` command from section 3 after rollback, not only `/healthz`.

After the recipient confirms success, remove the local password file:

```bash
unlink /home/node/.local/state/keydrop/passwords/delivery-001.pass
```

On CLI failure or `SIGINT`/`SIGTERM`/`SIGHUP`, Keydrop truncates and syncs the created password inode before unlinking its unchanged path. A local path-replacement race cannot make it delete the replacement. A remote ciphertext may still survive until TTL/lifecycle if a network outcome was ambiguous; it contains no password.

## 8. Operational checks

- `/healthz` proves Worker routing, not R2/DO health.
- The mandatory `scripts/live-canary.mjs` post-deploy and post-rollback gate uses fake plaintext and completes upload, claim, payload, shipped-bundle decrypt, idempotent ACK, and replay rejection.
- No drop-listing endpoint exists by design.
- Keep application observability free of URLs, fragments, authorization headers, password paths, filenames, payloads, and hashes tied to a recipient.
- Alert on upload `5xx`, missing/stale canary success, R2 lifecycle drift, or repeated cleanup failures; do not log secrets to make diagnosis easier.
