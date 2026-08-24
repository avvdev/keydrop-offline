# Keydrop

Keydrop delivers a small encrypted file through a short-lived, capability URL. The server stores only authenticated ciphertext; the password is created locally and never sent to the service. Decryption happens in Brave or Fennec with the existing offline-tested browser bundle.

```text
file or stdin -> local Argon2id + XChaCha20 encryption -> private R2
                                                        |
Telegram or console <- URL with 256-bit fragment <- Worker + Durable Object
                                                        |
password file (0600, separate channel) -> browser decrypt -> ACK -> delete
```

The repository contains:

- `keydrop`: standalone Node.js 22 CLI; stdout is only the delivery URL;
- `worker/`: Cloudflare Worker, private R2 binding, and Durable Object lease state;
- `index.html`, `autoselect.js`, `decrypt.bundle.js`: same-origin browser receiver;
- `scripts/check-keydrop-build.sh`: pinned, integrity-checked, ephemeral CLI rebuild;
- `tests/smoke.sh`: crypto round-trip, secret-lifecycle, race, API, and browser-flow tests.

Run the local suite from the repository root:

```bash
bash tests/smoke.sh
```

The suite builds `cli/keydrop.mjs` in a temporary directory with exact versions of `esbuild-wasm` and libsodium, verifies their registry SHA-512 values, and compares the result byte-for-byte with tracked `keydrop`. It leaves no dependency manifest or `node_modules` in the repository.

No Cloudflare resource is created by the tests. Production bootstrap, deployment, manual use, automation, rollback, and cleanup are documented in [docs/PRODUCTION.md](docs/PRODUCTION.md).

## Security boundary

The URL is a bearer capability and must be treated as secret. Send the URL and password through different channels. A winning browser lease may retry the ciphertext until acknowledgement; “one-time” means one recipient lease, then deletion after ACK or TTL, not one irreversible HTTP packet.

Limits: ciphertext is at most 16 MiB, TTL is 5 minutes to 12 hours, and the R2 lifecycle rule is a one-day orphan backstop. The CLI does not delete its input. Filesystems and SSDs do not promise secure erasure.

## Third-party notice

The generated `keydrop` and `decrypt.bundle.js` include `libsodium-wrappers-sumo` / `libsodium-sumo` 0.8.4 under the ISC license:

Copyright (c) 2015-2026<br>
Ahmad Ben Mrad &lt;batikhsouri at gmail dot org&gt;<br>
Frank Denis &lt;j at pureftpd dot org&gt;<br>
Ryan Lester &lt;ryan at cyph dot com&gt;

Permission to use, copy, modify, and/or distribute this software for any purpose with or without fee is hereby granted, provided that the above copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
