-- board.lua - the match-3 rules, with no drawing in it at all.
--
-- Everything here is pure: it takes a grid and returns what happened. That
-- is deliberate. The animation layer is the part most likely to be wrong,
-- and if the rules live inside the animation you cannot test them without
-- a screen. tools/board-test.lua drives this file headlessly.
--
-- THE RULES, in full:
--   * a move swaps two orthogonally adjacent jewels
--   * the swap is legal ONLY if it creates a line of 3+ of a kind
--   * all matched groups clear at once, survivors fall, new jewels drop in
--   * repeat until nothing matches -- that is a cascade
--
-- The legality condition is the whole design. It means the player cannot
-- waste a turn or make the board worse, so exploring is free. An illegal
-- swap springs back and costs nothing.

local M = {}

M.W, M.H = 10, 8         -- 10 wide fits an HD screen with a real HUD beside it
M.KINDS  = 6             -- six jewel types, each a distinct SHAPE as well as colour

-- ── helpers ───────────────────────────────────────────────────────────

function M.newGrid(kinds)
  kinds = kinds or M.KINDS
  local g = {}
  for y = 1, M.H do
    g[y] = {}
    for x = 1, M.W do g[y][x] = love.math.random(kinds) end
  end
  return g
end

function M.inside(x, y)
  return x >= 1 and x <= M.W and y >= 1 and y <= M.H
end

-- ── matching ──────────────────────────────────────────────────────────

-- Every cell that is part of a horizontal or vertical run of 3+.
-- Returns a set keyed "x,y" plus the list of runs (runs carry the length,
-- which is what scoring and special-jewel rules care about).
function M.findMatches(g)
  local hit, runs = {}, {}

  local function scan(len, at)
    local run = 1
    for i = 2, len + 1 do
      local a = (i <= len) and at(i) or nil
      local b = at(i - 1)
      if a and b and a.k == b.k and a.k ~= 0 then
        run = run + 1
      else
        if run >= 3 then
          local cells = {}
          for j = i - run, i - 1 do
            local c = at(j)
            hit[c.x .. "," .. c.y] = true
            cells[#cells + 1] = { x = c.x, y = c.y }
          end
          runs[#runs + 1] = { n = run, cells = cells }
        end
        run = 1
      end
    end
  end

  for y = 1, M.H do
    scan(M.W, function(i) return { x = i, y = y, k = g[y][i] } end)
  end
  for x = 1, M.W do
    scan(M.H, function(i) return { x = x, y = i, k = g[i][x] } end)
  end

  return hit, runs
end

function M.anyMatch(g)
  local hit = M.findMatches(g)
  return next(hit) ~= nil
end

-- ── moves ─────────────────────────────────────────────────────────────

function M.swap(g, x1, y1, x2, y2)
  g[y1][x1], g[y2][x2] = g[y2][x2], g[y1][x1]
end

-- Is swapping these two adjacent cells legal? (i.e. does it match?)
function M.isLegal(g, x1, y1, x2, y2)
  if not (M.inside(x1, y1) and M.inside(x2, y2)) then return false end
  if math.abs(x1 - x2) + math.abs(y1 - y2) ~= 1 then return false end
  M.swap(g, x1, y1, x2, y2)
  local ok = M.anyMatch(g)
  M.swap(g, x1, y1, x2, y2)          -- always put it back; this is a query
  return ok
end

-- Every legal move on the board. Used for the hint button and, more
-- importantly, to detect a deadlock BEFORE the player can stare at one.
function M.legalMoves(g)
  local out = {}
  for y = 1, M.H do
    for x = 1, M.W do
      if x < M.W and M.isLegal(g, x, y, x + 1, y) then
        out[#out + 1] = { x = x, y = y, dx = 1, dy = 0 }
      end
      if y < M.H and M.isLegal(g, x, y, x, y + 1) then
        out[#out + 1] = { x = x, y = y, dx = 0, dy = 1 }
      end
    end
  end
  return out
end

-- ── gravity and refill ────────────────────────────────────────────────

-- Clear the matched cells, then let survivors fall and new jewels drop in.
-- Returns a description of the motion so the renderer can animate it:
--   cleared: list of {x,y,kind}
--   fell:    list of {x, fromY, toY}          (survivors sliding down)
--   spawned: list of {x, y, kind, fromY}      (new, entering from above)
-- fromY for a spawn is NEGATIVE -- it starts off the top of the board and
-- slides in, so a refill reads as jewels pouring in rather than appearing.
function M.collapse(g, hit, kinds)
  kinds = kinds or M.KINDS
  local cleared, fell, spawned = {}, {}, {}

  for key in pairs(hit) do
    local x, y = key:match("^(%d+),(%d+)$")
    x, y = tonumber(x), tonumber(y)
    cleared[#cleared + 1] = { x = x, y = y, kind = g[y][x] }
    g[y][x] = 0
  end

  for x = 1, M.W do
    -- walk bottom-up, packing survivors down
    local write = M.H
    for y = M.H, 1, -1 do
      if g[y][x] ~= 0 then
        if write ~= y then
          g[write][x] = g[y][x]
          g[y][x] = 0
          fell[#fell + 1] = { x = x, fromY = y, toY = write }
        end
        write = write - 1
      end
    end
    -- fill the gap at the top; the highest new jewel starts furthest above
    local above = 0
    for y = write, 1, -1 do
      above = above + 1
      g[y][x] = love.math.random(kinds)
      spawned[#spawned + 1] = { x = x, y = y, kind = g[y][x], fromY = -above }
    end
  end

  return cleared, fell, spawned
end

-- ── generation ────────────────────────────────────────────────────────

-- A fresh board with NO matches already on it and at least one legal move.
-- Starting on a board that immediately cascades would give the player points
-- they did not earn and, worse, make the opening look broken.
function M.newBoard(kinds)
  kinds = kinds or M.KINDS
  for _ = 1, 200 do
    local g = M.newGrid(kinds)
    while M.anyMatch(g) do
      local hit = M.findMatches(g)
      -- reroll just the offending cells; cheaper than a whole new board and
      -- it converges fast
      for key in pairs(hit) do
        local x, y = key:match("^(%d+),(%d+)$")
        g[tonumber(y)][tonumber(x)] = love.math.random(kinds)
      end
    end
    if #M.legalMoves(g) > 0 then return g end
  end
  error("could not generate a playable board")
end

-- Shuffle the existing jewels into a playable arrangement. Used when the
-- board deadlocks. NOTE this preserves the multiset of jewels rather than
-- rerolling: the player keeps what they had, it is just rearranged.
function M.reshuffle(g, kinds)
  kinds = kinds or M.KINDS
  local bag = {}
  for y = 1, M.H do for x = 1, M.W do bag[#bag + 1] = g[y][x] end end
  for attempt = 1, 400 do
    for i = #bag, 2, -1 do
      local j = love.math.random(i)
      bag[i], bag[j] = bag[j], bag[i]
    end
    local i = 0
    for y = 1, M.H do for x = 1, M.W do i = i + 1; g[y][x] = bag[i] end end
    if not M.anyMatch(g) and #M.legalMoves(g) > 0 then return true end
  end
  -- Pathological bag (e.g. almost all one kind). Fall back to a fresh board
  -- rather than hand back a dead one.
  local fresh = M.newBoard(kinds)
  for y = 1, M.H do for x = 1, M.W do g[y][x] = fresh[y][x] end end
  return false
end

-- ── scoring ───────────────────────────────────────────────────────────

-- A run is worth more per jewel the longer it is, and a cascade multiplies.
-- Both curves are gentle: this game has no fail state, so scoring is
-- feedback ("that was a good one"), not a resource.
function M.runScore(n, cascade)
  local base = 30 * n + 20 * math.max(0, n - 3) * n   -- 3->90, 4->200, 5->450
  return math.floor(base * (1 + 0.5 * (cascade - 1)))
end

return M
