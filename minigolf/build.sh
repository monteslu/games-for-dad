#!/usr/bin/env bash
# Repack the cart. Regenerates assets.index first: a stale index is a
# directory listing that silently omits a file, and 3DreamEngine discovers
# its own modules by listing directories.
#
# NO HARDCODED PATHS. Everything resolves from this script's own location or
# from the environment, so the same script runs on a dev box and on a CI
# runner that has never heard of ~/code/cliemu.
#
#   WASMCART_LUA  a wasmcart-lua checkout (for the engine + gen-asset-index)
#                 default: ../../wasmcart-lua relative to the repo
#   ENGINE        an explicit engine.wasm, overriding WASMCART_LUA's build/
#   WASMCART_PACK the packer. Default resolves the npm 'wasmcart' package,
#                 so CI can 'npm i wasmcart' instead of cloning it.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

WASMCART_LUA="${WASMCART_LUA:-$ROOT/../wasmcart-lua}"
ENGINE="${ENGINE:-$WASMCART_LUA/build/engine.wasm}"
[ -f "$ENGINE" ] || { echo "no engine at $ENGINE (set ENGINE or WASMCART_LUA)" >&2; exit 1; }

# the packer: an explicit path, else the npm package, else a sibling checkout
if [ -z "${WASMCART_PACK:-}" ]; then
  WASMCART_PACK="$(node -e "process.stdout.write(require.resolve('wasmcart/bin/wasmcart-pack.js'))" 2>/dev/null || true)"
fi
[ -n "${WASMCART_PACK:-}" ] || WASMCART_PACK="$ROOT/../wasmcart/bin/wasmcart-pack.js"
[ -f "$WASMCART_PACK" ] || { echo "no packer at $WASMCART_PACK (npm i wasmcart)" >&2; exit 1; }

cp "$ENGINE" "$HERE/main.wasm"
node "$WASMCART_PACK" \
  --wasm "$HERE/main.wasm" --assets "$HERE/app" \
  --name "Minigolf" --width 1920 --height 1080 \
  -o "$HERE/minigolf.wasc" > /dev/null
echo "packed $(du -h "$HERE/minigolf.wasc" | cut -f1)"
