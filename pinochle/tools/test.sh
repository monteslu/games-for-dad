#!/usr/bin/env bash
# Every check pinochle has, cheapest first.
#
#   simulate  pure rules, no engine, no graphics   ~2s for 3000 hands
#   playhand  a real hand through the real cart    ~90s
#
# THE TWO PROVE DIFFERENT THINGS and neither replaces the other. simulate
# can play ten thousand hands and assert every invariant, but it never
# loads the cart -- so it cannot catch a game that deals correctly and then
# hangs on a confirm gate. playhand loads the cart and drives it with the
# pad, but plays one hand, so it cannot tell you the meld table is right.
#
# simulate needs a standalone Lua 5.4. Build one from the engine's own
# vendored copy if you have not:
#   cd ../../wasmcart-lua/runtime/vendor/lua && make linux
#
# playhand needs the romdev server on 127.0.0.1:7331 WITH a display --
# see docs/PINOCHLE.md for the Xauthority trap.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
LUA="${LUA:-$HERE/../../../wasmcart-lua/runtime/vendor/lua/src/lua}"

echo "=== rules simulation ==="
if [ -x "$LUA" ]; then
  "$LUA" "$HERE/simulate.lua" "${HANDS:-3000}"
else
  echo "no lua at $LUA -- set LUA=/path/to/lua (see the header)" >&2
  exit 1
fi

echo
echo "=== a hand through the cart ==="
node "$HERE/playhand.mjs"

echo
echo "ALL PASS"
