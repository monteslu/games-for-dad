#!/usr/bin/env bash
# Play the REAL game headlessly and assert on what happened.
#
# The board rules already have their own suite (run-board-test.sh). This is
# the other half: it drives main.lua through the actual input path -- move
# the cursor, pick a jewel up, push it -- for hundreds of frames, and then
# asserts the game advanced. A rules bug shows up in the other suite; an
# INTEGRATION bug (animation never finishes, state machine wedges, cursor
# desyncs from the grid) only shows up here.
#
# The specific failure this is built to catch: the state machine getting
# stuck in "clearing" or "falling" and never returning to idle. That looks
# fine in a screenshot and is fatal in play.
#
# NO HARDCODED PATHS -- same contract as build.sh.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
CART="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$CART/.." && pwd)"

WASMCART_LUA="${WASMCART_LUA:-$ROOT/../wasmcart-lua}"
ENGINE="${ENGINE:-$WASMCART_LUA/build/engine.wasm}"
[ -f "$ENGINE" ] || { echo "no engine at $ENGINE" >&2; exit 1; }

if [ -z "${WASMCART_PACK:-}" ]; then
  WASMCART_PACK="$(node -e "process.stdout.write(require.resolve('wasmcart/bin/wasmcart-pack.js'))" 2>/dev/null || true)"
fi
[ -n "${WASMCART_PACK:-}" ] || WASMCART_PACK="$ROOT/../wasmcart/bin/wasmcart-pack.js"

ROMDEV="${ROMDEV:-http://127.0.0.1:7331}"
FRAMES="${FRAMES:-2400}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp -r "$CART/app" "$WORK/app"
cp "$CART/tools/playdriver.lua" "$WORK/app/playdriver.lua"

# Prepend the driver install to main.lua, and append the verdict check.
node -e '
const fs = require("fs");
const [mainPath, out, markFrame] = process.argv.slice(1);
const main = fs.readFileSync(mainPath, "utf8");
const head = `
-- installed by run-play-test.sh
local __drv = require("playdriver")
_G.JEWELS_DRIVER = function(frame) return __drv.step(frame) end
local __report_at = tonumber(os.getenv and "0" or "0") or 0
`;
const tail = `

-- verdict: printed once, late enough that plenty of moves have run
local __frames = 0
local __origDraw = love.draw
local __reported = false
local __seenStates = {}
local __maxScore = 0
love.draw = function()
  __origDraw()
  __frames = __frames + 1
  local s = _G.JEWELS_STATE
  __seenStates[s.state] = (__seenStates[s.state] or 0) + 1
  if s.score > __maxScore then __maxScore = s.score end
  if __frames == MARKFRAME and not __reported then
    __reported = true
    print("PLAYTEST frames=" .. __frames)
    print("PLAYTEST moves=" .. s.moves)
    print("PLAYTEST score=" .. s.score)
    print("PLAYTEST driverMoves=" .. __drv.movesPlayed())
    local order = {"idle","swapping","clearing","falling"}
    for _, k in ipairs(order) do
      print("PLAYTEST state." .. k .. "=" .. (__seenStates[k] or 0))
    end
    print("PLAYTEST finalState=" .. s.state)
  end
end
`;
fs.writeFileSync(out, (head + main + tail).replace("MARKFRAME", markFrame));
' "$CART/app/main.lua" "$WORK/app/main.lua" "$((FRAMES - 20))"

node "$WASMCART_PACK" --wasm "$ENGINE" --assets "$WORK/app" \
  --name JEWELSTEST --width 1920 --height 1080 -o "$WORK/t.wasc" > /dev/null

S="jewels-play-$$"
curl -s -X POST "$ROMDEV/tool/loadMedia" -H 'Content-Type: application/json' \
  -H "x-romdev-session: $S" \
  -d "{\"platform\":\"wasmcart\",\"path\":\"$WORK/t.wasc\"}" > /dev/null
curl -s -X POST "$ROMDEV/tool/frame" -H 'Content-Type: application/json' \
  -H "x-romdev-session: $S" -d "{\"op\":\"step\",\"frames\":$FRAMES}" > /dev/null
OUT="$(curl -s -X POST "$ROMDEV/tool/wasm" -H 'Content-Type: application/json' \
  -H "x-romdev-session: $S" -d '{"op":"events"}')"

echo "$OUT" | node -e '
let d=""; process.stdin.on("data",c=>d+=c).on("end",()=>{
  const j=JSON.parse(d);
  const log=(j.log||[]).map(l=>l.text);
  for (const t of log) if (!/^wasmcart-lua: boot/.test(t)) console.log(t);
  const get=k=>{const m=log.find(t=>t.startsWith("PLAYTEST "+k+"="));return m?Number(m.split("=")[1]):null;};
  const err=log.find(t=>/lua error/.test(t));
  let bad=false;
  if (err) { console.log("FAIL: lua error during play"); bad=true; }
  const moves=get("moves"), score=get("score"), fin=log.find(t=>t.startsWith("PLAYTEST finalState="));
  if (moves===null) { console.log("FAIL: driver never reported (game may have wedged before the mark)"); bad=true; }
  else {
    if (moves < 10) { console.log(`FAIL: only ${moves} moves completed -- state machine likely wedged`); bad=true; }
    if (score <= 0) { console.log(`FAIL: score never increased (${score})`); bad=true; }
    const idle=get("state.idle"), clearing=get("state.clearing"), falling=get("state.falling");
    if (!idle || idle<50) { console.log(`FAIL: board rarely idle (${idle} frames) -- never settles`); bad=true; }
    if (!clearing || clearing<10) { console.log(`FAIL: almost no clearing frames (${clearing})`); bad=true; }
    if (!falling || falling<10) { console.log(`FAIL: almost no falling frames (${falling})`); bad=true; }
  }
  console.log(bad ? "PLAY TEST FAILED" : "PLAY TEST OK");
  process.exit(bad?1:0);
});'
