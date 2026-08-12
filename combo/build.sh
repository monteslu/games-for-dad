#!/usr/bin/env bash
# Repack the cart. Regenerates assets.index first: a stale index is a
# directory listing that silently omits a file, and 3DreamEngine discovers
# its own modules by listing directories.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ENGINE="${ENGINE:-/home/monteslu/code/cliemu/wasmcart-lua/build/engine.wasm}"
cp "$ENGINE" "$HERE/main.wasm"
/home/monteslu/code/cliemu/wasmcart-lua/tools/gen-asset-index.sh "$HERE/app" > /dev/null
node /home/monteslu/code/cliemu/wasmcart/bin/wasmcart-pack.js \
  --wasm "$HERE/main.wasm" --assets "$HERE/app" \
  --name "Combo" --width 1920 --height 1080 \
  -o "$HERE/combo.wasc" > /dev/null
echo "packed $(du -h "$HERE/combo.wasc" | cut -f1)"
