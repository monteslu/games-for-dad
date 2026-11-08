#!/usr/bin/env bash
# Repack the cart from the engine committed beside it (main.wasm) and app/.
# The card games pin their own engine build, so this packs that one rather
# than wasmcart-lua's current engine.
#
# NO HARDCODED PATHS. Everything resolves from this script's own location or
# from the environment.
#
#   WASMCART_LUA  a wasmcart-lua checkout (for gen-asset-index)
#                 default: ../../wasmcart-lua relative to the repo
#   WASMCART_PACK the packer. Default resolves the npm 'wasmcart' package,
#                 else a wasmcart checkout beside this repo.
#   CART_VERSION  the cart's version. Unset, the packer takes it from this
#                 checkout's git tags (see the README, "Versions").
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

WASMCART_LUA="${WASMCART_LUA:-$ROOT/../wasmcart-lua}"
[ -x "$WASMCART_LUA/tools/gen-asset-index.sh" ] || { echo "no gen-asset-index.sh in $WASMCART_LUA (set WASMCART_LUA)" >&2; exit 1; }

# the packer: an explicit path, else the npm package, else a sibling checkout
if [ -z "${WASMCART_PACK:-}" ]; then
  WASMCART_PACK="$(node -e "process.stdout.write(require.resolve('wasmcart/bin/wasmcart-pack.js'))" 2>/dev/null || true)"
fi
[ -n "${WASMCART_PACK:-}" ] || WASMCART_PACK="$ROOT/../wasmcart/bin/wasmcart-pack.js"
[ -f "$WASMCART_PACK" ] || { echo "no packer at $WASMCART_PACK (npm i wasmcart)" >&2; exit 1; }

# assets.index lists app/ for the engine, which cannot list a cart's assets
"$WASMCART_LUA/tools/gen-asset-index.sh" "$HERE/app" > /dev/null
node "$WASMCART_PACK" \
  --wasm "$HERE/main.wasm" --assets "$HERE/app" \
  --name "FiveCardStud" --width 1920 --height 1080 ${CART_VERSION:+--version "$CART_VERSION"} \
  -o "$HERE/fivecardstud.wasc" > /dev/null
echo "packed $(du -h "$HERE/fivecardstud.wasc" | cut -f1)"
