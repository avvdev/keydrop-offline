#!/usr/bin/env bash
set -euo pipefail

keydrop_script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
keydrop_repo_dir="$(dirname -- "$keydrop_script_dir")"
keydrop_mode="${1:-check}"
if test "$keydrop_mode" != check && test "$keydrop_mode" != --write; then
  echo 'usage: bash scripts/check-keydrop-build.sh [--write]' >&2
  exit 2
fi

keydrop_build_dir="$(mktemp -d /tmp/keydrop-build.XXXXXXXX)"
keydrop_cleanup() {
  case "$keydrop_build_dir" in
    /tmp/keydrop-build.*) rm -r -- "$keydrop_build_dir" ;;
    *) echo 'keydrop build cleanup refused' >&2 ;;
  esac
}
trap keydrop_cleanup EXIT HUP INT TERM

npm install --prefix "$keydrop_build_dir" \
  --save-exact --ignore-scripts --no-audit --no-fund --silent \
  esbuild-wasm@0.25.9 \
  libsodium-wrappers-sumo@0.8.4 \
  libsodium-sumo@0.8.4

node - "$keydrop_build_dir/package-lock.json" <<'NODE'
const fs = require("node:fs");
const lock = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const expected = {
  "node_modules/esbuild-wasm": [
    "0.25.9",
    "sha512-Jpv5tCSwQg18aCqCRD3oHIX/prBhXMDapIoG//A+6+dV0e7KQMGFg85ihJ5T1EeMjbZjON3TqFy0VrGAnIHLDA==",
  ],
  "node_modules/libsodium-wrappers-sumo": [
    "0.8.4",
    "sha512-ql7hcgulKZ3ekfa2DGAogcCKsWU0diA/0nArz1CFzh93WQdb46/Kj18ka/Hifq6uA3Ush34Pc6vU/6HXeRwUkg==",
  ],
  "node_modules/libsodium-sumo": [
    "0.8.4",
    "sha512-TMtHShQfVVsaxDygyapvUC3o7YsPgXa/hRWeIgzyFz6w5k/1hirGptCxp1U7XwW3rCskaTTYKgV10v86UiGgNw==",
  ],
};
for (const [name, [version, integrity]] of Object.entries(expected)) {
  const actual = lock.packages?.[name];
  if (!actual || actual.version !== version || actual.integrity !== integrity) {
    throw new Error(`unexpected build dependency: ${name}`);
  }
}
NODE

NODE_PATH="$keydrop_build_dir/node_modules" \
  "$keydrop_build_dir/node_modules/.bin/esbuild" \
  "$keydrop_repo_dir/cli/keydrop.mjs" \
  --bundle --platform=node --format=cjs --minify \
  --banner:js='#!/usr/bin/env node' \
  --outfile="$keydrop_build_dir/keydrop" \
  --log-level=warning

if test "$keydrop_mode" = --write; then
  install -m 0755 "$keydrop_build_dir/keydrop" "$keydrop_repo_dir/keydrop"
else
  cmp "$keydrop_repo_dir/keydrop" "$keydrop_build_dir/keydrop"
fi

printf '%s\n' 'PASS reproducible keydrop bundle'
