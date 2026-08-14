#!/usr/bin/env bash
# Every check bowling has, in the order they get cheapest-first.
#
#   rack     pure arithmetic, no emulator      milliseconds
#   framing  two screenshots                   ~20s
#   playgame a complete ten-frame game         ~3min
#
# playgame and framing need the romdev server on 127.0.0.1:7331 with a real
# GL context. A headless shell will fail at loadMedia with "failed to create
# EGL context" -- start the server with DISPLAY and the LIVE Xauthority
# cookie (the one Xwayland is actually running with, which is not always
# what $XAUTHORITY points at).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "=== rack geometry ==="
node "$HERE/rack.mjs"

echo
echo "=== camera framing ==="
node "$HERE/framing.mjs"

echo
echo "=== ten-frame game ==="
node "$HERE/playgame.mjs"

echo
echo "ALL PASS"
