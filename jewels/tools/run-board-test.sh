#!/usr/bin/env bash
# Run tools/board-test.lua through the ACTUAL wasmcart-lua engine.
#
# There is no system `lua` here, and that turns out to be the better
# outcome: this runs the rules on the exact Lua VM the shipped game runs
# on, so a VM-specific difference (integer division, # on a table with
# holes, pairs order) cannot hide between test and game.
#
# NO HARDCODED PATHS -- resolves from this script's own location, same
# contract as build.sh.
#
#   WASMCART_LUA  a wasmcart-lua checkout (for build/engine.wasm)
#   ENGINE        an explicit engine.wasm
#   ROMDEV        romdev MCP base URL (default http://127.0.0.1:7331)
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
CART="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$CART/.." && pwd)"

WASMCART_LUA="${WASMCART_LUA:-$ROOT/../wasmcart-lua}"
ENGINE="${ENGINE:-$WASMCART_LUA/build/engine.wasm}"
[ -f "$ENGINE" ] || { echo "no engine at $ENGINE (set ENGINE or WASMCART_LUA)" >&2; exit 1; }

if [ -z "${WASMCART_PACK:-}" ]; then
  WASMCART_PACK="$(node -e "process.stdout.write(require.resolve('wasmcart/bin/wasmcart-pack.js'))" 2>/dev/null || true)"
fi
[ -n "${WASMCART_PACK:-}" ] || WASMCART_PACK="$ROOT/../wasmcart/bin/wasmcart-pack.js"
[ -f "$WASMCART_PACK" ] || { echo "no packer at $WASMCART_PACK (npm i wasmcart)" >&2; exit 1; }

ROMDEV="${ROMDEV:-http://127.0.0.1:7331}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/app"

cp "$CART/app/board.lua" "$WORK/app/"
cp "$CART/app/conf.lua"  "$WORK/app/"

# Wrap the test as a cart. The test is written to run standalone under a
# plain interpreter too, so strip the bits that only apply there.
node -e '
const fs = require("fs");
let s = fs.readFileSync(process.argv[1], "utf8");
s = s.replace(/package\.path = .*\n/, "");
s = s.replace(/-- minimal love shim[\s\S]*?math\.randomseed\([0-9]+\)\n/, "");
s = s.replace(/os\.exit\(1\)/, "error(\"BOARD TEST FAILED\")");
fs.writeFileSync(process.argv[2],
  "local ok, err = pcall(function()\n" + s +
  "\nend)\nif not ok then print(\"ERROR: \" .. tostring(err)) end\n" +
  "function love.draw() end\n");
' "$CART/tools/board-test.lua" "$WORK/app/main.lua"

node "$WASMCART_PACK" --wasm "$ENGINE" --assets "$WORK/app" \
  --name BOARDTEST --width 640 --height 360 -o "$WORK/boardtest.wasc" > /dev/null

S="board-test-$$"
curl -s -X POST "$ROMDEV/tool/loadMedia" -H 'Content-Type: application/json' \
  -H "x-romdev-session: $S" \
  -d "{\"platform\":\"wasmcart\",\"path\":\"$WORK/boardtest.wasc\"}" > /dev/null
curl -s -X POST "$ROMDEV/tool/frame" -H 'Content-Type: application/json' \
  -H "x-romdev-session: $S" -d '{"op":"step","frames":3}' > /dev/null
OUT="$(curl -s -X POST "$ROMDEV/tool/wasm" -H 'Content-Type: application/json' \
  -H "x-romdev-session: $S" -d '{"op":"events"}')"

echo "$OUT" | node -e '
let d = ""; process.stdin.on("data", c => d += c).on("end", () => {
  const j = JSON.parse(d);
  for (const l of (j.log || [])) if (!/^wasmcart-lua: boot/.test(l.text)) console.log(l.text);
});'

echo "$OUT" | grep -q "BOARD TEST OK" || { echo "board test FAILED" >&2; exit 1; }
