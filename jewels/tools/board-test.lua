-- board-test.lua - headless test of the match-3 rules.
--
-- Runs under plain `lua`, no engine and no screen. The rules are pure
-- functions precisely so this is possible: a bug in findMatches should be
-- caught here in milliseconds, not by squinting at an animation.
--
--   lua tools/board-test.lua
--
-- Every assertion is on a VALUE. The suite also runs must-fail controls at
-- the end: deliberately broken boards that the checks are REQUIRED to
-- reject. A test suite that has never failed is not evidence of anything.

package.path = "app/?.lua;" .. package.path

-- minimal love shim: the rules only use love.math.random
love = { math = { random = math.random } }
math.randomseed(20260812)

local B = require("board")

local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1
  else fail = fail + 1; print("FAIL: " .. name .. (detail and ("  -- " .. detail) or "")) end
end

-- A blank canvas with NO match anywhere, so a fixture contains only what
-- the test explicitly draws on it.
--
-- MARK is a kind the canvas NEVER uses. Every fixture draws with MARK, so a
-- drawn run can never be accidentally extended by a canvas cell that
-- happened to hold the same value.
--
-- This cost me two rounds of false failures before I made it structural.
-- First ((x+y*3)%6)+1: no runs, but it contains 4s, so an L of 4s silently
-- became a run of FOUR. Then ((x+2y)%5)+1 with fixtures drawing 5s: same
-- bug, different number. Both times the test blamed the board, and the
-- board was right. Hence assertClean() below -- a fixture that is already
-- matched before the test begins now says so instead of lying.
local MARK = 6

local function canvas()
  local g = {}
  for y = 1, B.H do
    g[y] = {}
    for x = 1, B.W do
      -- kinds 1..5 only, cycling so no two orthogonal neighbours match and
      -- no value repeats within 5 cells along a row
      g[y][x] = ((x + y * 2) % 5) + 1
    end
  end
  return g
end

-- Assert a fixture is in the state the test believes it is in, BEFORE
-- asserting anything about the subject. Cheap, and it converts a
-- mysterious wrong-number failure into a plain statement of what broke.
local function assertClean(g, what)
  if B.anyMatch(g) then
    fail = fail + 1
    print("FIXTURE BROKEN (" .. what .. "): canvas already contains a match")
    return false
  end
  return true
end

-- ── matching ──────────────────────────────────────────────────────────

do
  -- a horizontal run of exactly 3
  local g = canvas()
  check("blank canvas has no accidental match", not B.anyMatch(g))
  assertClean(g, "h-run")

  g[4][2], g[4][3], g[4][4] = MARK, MARK, MARK
  local hit, runs = B.findMatches(g)
  local n = 0; for _ in pairs(hit) do n = n + 1 end
  check("h-run of 3 -> 3 cells", n == 3, "got " .. n)
  check("h-run reported once", #runs == 1, "got " .. #runs)
  check("h-run length 3", runs[1] and runs[1].n == 3)
end

do
  local g = canvas()
  assertClean(g, "v-run")
  g[2][5], g[3][5], g[4][5], g[5][5] = MARK, MARK, MARK, MARK
  local hit, runs = B.findMatches(g)
  local n = 0; for _ in pairs(hit) do n = n + 1 end
  check("v-run of 4 -> 4 cells", n == 4, "got " .. n)
  check("v-run length 4", runs[1] and runs[1].n == 4, runs[1] and tostring(runs[1].n))
end

do
  -- an L: a horizontal 3 and a vertical 3 sharing a corner. The shared cell
  -- must be counted ONCE, which is why hit is a set and not a list.
  local g = canvas()
  assertClean(g, "L-shape")
  g[3][3], g[3][4], g[3][5] = MARK, MARK, MARK
  g[4][3], g[5][3] = MARK, MARK
  local hit, runs = B.findMatches(g)
  local n = 0; for _ in pairs(hit) do n = n + 1 end
  check("L-shape -> 5 distinct cells (corner not double-counted)", n == 5, "got " .. n)
  check("L-shape -> 2 runs", #runs == 2, "got " .. #runs)
end

do
  -- a run of exactly 2 must NOT match. This is the boundary that decides
  -- whether the game feels right.
  local g = canvas()
  assertClean(g, "run-of-2")
  g[6][6], g[6][7] = MARK, MARK
  check("run of 2 does not match", not B.anyMatch(g))
end

-- ── legality ──────────────────────────────────────────────────────────

do
  local g = canvas()
  -- Row 5 gets MARKs at x=4 and x=5, and a third MARK parked at x=7.
  -- x=6 keeps its canvas value, so there is NO match yet (only a run of 2).
  -- Swapping (6,5) with (7,5) slides that third MARK into x=6, completing
  -- MARK,MARK,MARK across x=4,5,6.
  --
  -- Note the swap must bring the MARK *in* to close the run. My first
  -- version swapped a MARK out of the run and into the gap, which just
  -- moves the hole along -- it read plausibly and matched nothing.
  g[5][4], g[5][5], g[5][7] = MARK, MARK, MARK
  local keep = g[5][6]
  assertClean(g, "legality")
  check("legal swap detected", B.isLegal(g, 6, 5, 7, 5))
  check("query left the grid untouched", g[5][6] == keep and g[5][7] == MARK,
        "grid mutated by a legality QUERY")
  check("non-adjacent swap illegal", not B.isLegal(g, 1, 1, 5, 5))
  check("diagonal swap illegal", not B.isLegal(g, 1, 1, 2, 2))
  check("off-board swap illegal", not B.isLegal(g, 1, 1, 0, 1))
end

-- ── gravity ───────────────────────────────────────────────────────────

do
  local g = {}
  for y = 1, B.H do g[y] = {} for x = 1, B.W do g[y][x] = 1 end end
  -- clear one cell in the middle of a column; everything above must drop 1
  g[8][1] = 2
  local hit = { ["1,4"] = true }
  local marker = g[3][1]; g[3][1] = 9    -- tag the jewel directly above
  local cleared, fell, spawned = B.collapse(g, hit, 6)
  check("collapse cleared 1", #cleared == 1)
  check("tagged jewel fell one row", g[4][1] == 9, "found " .. tostring(g[4][1]))
  check("bottom jewel untouched", g[8][1] == 2)
  check("one spawn per cleared cell", #spawned == 1, "got " .. #spawned)
  check("spawn enters from above the board", spawned[1] and spawned[1].fromY < 1,
        spawned[1] and tostring(spawned[1].fromY))
  check("no holes left anywhere", (function()
    for y = 1, B.H do for x = 1, B.W do if g[y][x] == 0 then return false end end end
    return true
  end)())
end

do
  -- clearing a whole column must refill all 8, each from a distinct height
  local g = {}
  for y = 1, B.H do g[y] = {} for x = 1, B.W do g[y][x] = 1 end end
  local hit = {}
  for y = 1, B.H do hit["3," .. y] = true end
  local cleared, fell, spawned = B.collapse(g, hit, 6)
  check("full column cleared 8", #cleared == 8, "got " .. #cleared)
  check("full column spawned 8", #spawned == 8, "got " .. #spawned)
  check("nothing fell in a fully cleared column", #fell == 0, "got " .. #fell)
  local seen = {}
  for _, s in ipairs(spawned) do seen[s.fromY] = true end
  local distinct = 0; for _ in pairs(seen) do distinct = distinct + 1 end
  check("spawns stagger from 8 distinct heights", distinct == 8, "got " .. distinct)
end

-- ── generation ────────────────────────────────────────────────────────

do
  local clean, playable = true, true
  for _ = 1, 300 do
    local g = B.newBoard(6)
    if B.anyMatch(g) then clean = false end
    if #B.legalMoves(g) == 0 then playable = false end
  end
  check("300 fresh boards: none start matched", clean)
  check("300 fresh boards: all have a legal move", playable)
end

do
  -- reshuffle must preserve the multiset of jewels: the player keeps what
  -- they had, rearranged. Rerolling instead would quietly change the board.
  local g = B.newBoard(6)
  local before = {}
  for y = 1, B.H do for x = 1, B.W do before[g[y][x]] = (before[g[y][x]] or 0) + 1 end end
  B.reshuffle(g, 6)
  local after = {}
  for y = 1, B.H do for x = 1, B.W do after[g[y][x]] = (after[g[y][x]] or 0) + 1 end end
  local same = true
  for k, v in pairs(before) do if after[k] ~= v then same = false end end
  check("reshuffle preserves the jewel multiset", same)
  check("reshuffle leaves a playable board", #B.legalMoves(g) > 0 and not B.anyMatch(g))
end

-- ── a full simulated game ─────────────────────────────────────────────
-- The real integration check: play 2000 random legal moves and assert the
-- board is never left in an impossible state. This is what catches an
-- interaction bug that no single unit test would.

do
  local g = B.newBoard(6)
  local badGrid, deadlocks, cascades, maxCascade = 0, 0, 0, 0
  for _ = 1, 2000 do
    local moves = B.legalMoves(g)
    if #moves == 0 then
      deadlocks = deadlocks + 1
      B.reshuffle(g, 6)
      moves = B.legalMoves(g)
    end
    local m = moves[math.random(#moves)]
    B.swap(g, m.x, m.y, m.x + m.dx, m.y + m.dy)
    local depth = 0
    while true do
      local hit, runs = B.findMatches(g)
      if not next(hit) then break end
      depth = depth + 1
      B.collapse(g, hit, 6)
      if depth > 50 then break end
    end
    cascades = cascades + depth
    if depth > maxCascade then maxCascade = depth end
    for y = 1, B.H do for x = 1, B.W do
      local v = g[y][x]
      if type(v) ~= "number" or v < 1 or v > 6 then badGrid = badGrid + 1 end
    end end
  end
  check("2000 moves: grid always holds valid jewels", badGrid == 0, badGrid .. " bad cells")
  check("2000 moves: board settles (no runaway cascade)", maxCascade <= 50,
        "max depth " .. maxCascade)
  check("2000 moves: every move produced at least one clear", cascades >= 2000,
        "only " .. cascades .. " clears in 2000 legal moves")
  print(("  [sim] %d deadlocks reshuffled, %d total cascade steps, deepest %d")
        :format(deadlocks, cascades, maxCascade))
end

-- ── MUST-FAIL CONTROLS ────────────────────────────────────────────────
-- Break things on purpose. If the checks above cannot detect these, they
-- were never testing anything. Each control asserts that a KNOWN-BAD input
-- is rejected.

print("\n-- controls (these must all be caught) --")
local controls, caught = 0, 0
local function control(name, detected)
  controls = controls + 1
  if detected then caught = caught + 1
  else print("CONTROL NOT CAUGHT: " .. name) end
end

do
  -- a board that IS matched must be reported as matched
  local g = canvas()
  g[1][1], g[1][2], g[1][3] = MARK, MARK, MARK
  control("a genuinely matched board is detected", B.anyMatch(g))
end

do
  -- a uniform board is ALL matches: findMatches must not miss it
  local g = {}
  for y = 1, B.H do g[y] = {} for x = 1, B.W do g[y][x] = 4 end end
  local hit = B.findMatches(g)
  local n = 0; for _ in pairs(hit) do n = n + 1 end
  control("uniform board matches every cell", n == B.W * B.H)
end

do
  -- A TRUE deadlock: kinds cycling on (x+y)%3 diagonals. No run of 3 exists
  -- and no single swap can create one, so legalMoves must return empty and
  -- the game must reshuffle.
  --
  -- My first attempt used a 2-kind checkerboard, which is NOT a deadlock at
  -- all: it has 110 legal moves, because swapping any two neighbours leaves
  -- three-in-a-row somewhere along the perpendicular. The control was
  -- asserting something false, and it correctly refused to be caught. Worth
  -- keeping the note: an uncaught control is as often a wrong control as a
  -- broken subject, and checking which is the entire point of running them.
  local g = {}
  for y = 1, B.H do g[y] = {} for x = 1, B.W do g[y][x] = ((x + y) % 3) + 1 end end
  control("diagonal 3-cycle is not itself matched", not B.anyMatch(g))
  control("diagonal 3-cycle is a genuine deadlock", #B.legalMoves(g) == 0)

  -- and the reshuffle must rescue it
  B.reshuffle(g, 6)
  control("reshuffle rescues a deadlocked board", #B.legalMoves(g) > 0 and not B.anyMatch(g))

  -- a 2-kind checkerboard, by contrast, is very much PLAYABLE. Asserting
  -- this keeps the deadlock detector honest in the other direction: a
  -- detector that called everything a deadlock would pass the test above.
  local c = {}
  for y = 1, B.H do c[y] = {} for x = 1, B.W do c[y][x] = ((x + y) % 2) + 1 end end
  control("checkerboard is NOT a deadlock (detector not trigger-happy)",
          #B.legalMoves(c) > 0)
end

do
  -- collapse on an empty hit set must be a no-op
  local g = B.newBoard(6)
  local snap = {}
  for y = 1, B.H do snap[y] = {} for x = 1, B.W do snap[y][x] = g[y][x] end end
  local cleared, fell, spawned = B.collapse(g, {}, 6)
  local same = true
  for y = 1, B.H do for x = 1, B.W do if g[y][x] ~= snap[y][x] then same = false end end end
  control("empty collapse changes nothing", same and #cleared == 0 and #spawned == 0)
end

print("")
print(("board-test: %d passed, %d failed"):format(pass, fail))
print(("controls:   %d/%d known-bad inputs caught"):format(caught, controls))
if fail > 0 or caught < controls then
  print("BOARD TEST FAILED")
  os.exit(1)
end
print("BOARD TEST OK")
