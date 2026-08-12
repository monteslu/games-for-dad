-- playdriver.lua - a scripted player, injected as JEWELS_DRIVER.
--
-- main.lua checks for a global JEWELS_DRIVER and, if present, takes its
-- button edges from there instead of the pad. That lets a whole game be
-- played headlessly through romdev and the RESULT asserted, rather than me
-- squinting at screenshots and declaring it works.
--
-- The driver plays real legal moves: it asks the board for one, walks the
-- cursor to it, picks the jewel up and pushes it. So this exercises the
-- actual input path -- cursor movement, selection, swap -- not a back door
-- into trySwap.

local B = require("board")

local M = {}

local plan, planPos = {}, 0
local movesPlayed = 0
local waitFrames = 0

-- The driver needs to see the live grid to choose a move. main.lua exposes
-- it as JEWELS_STATE once loaded.
local function state() return rawget(_G, "JEWELS_STATE") end

local function queue(btn, n)
  for _ = 1, (n or 1) do plan[#plan + 1] = btn end
end

-- Walk the cursor to (tx,ty), then pick up and push in (dx,dy).
local function planMove(cx, cy, m)
  local dx = m.x - cx
  local dy = m.y - cy
  queue("right", math.max(0, dx))
  queue("left",  math.max(0, -dx))
  queue("down",  math.max(0, dy))
  queue("up",    math.max(0, -dy))
  queue("a")                                    -- pick it up
  if m.dx == 1 then queue("right") elseif m.dx == -1 then queue("left") end
  if m.dy == 1 then queue("down")  elseif m.dy == -1 then queue("up")   end
end

-- Called once per frame with the frame number; returns a button name or nil.
-- Buttons must be spaced out: main.lua debounces at 9 frames, and a driver
-- that fires every frame would have most of its presses swallowed.
local SPACING = 11

function M.step(frame)
  local s = state()
  if not s then return nil end

  if waitFrames > 0 then waitFrames = waitFrames - 1; return nil end

  -- only act while the board is idle; animations must be allowed to finish
  if s.state ~= "idle" then return nil end

  if planPos >= #plan then
    -- plan exhausted: choose a new move
    plan, planPos = {}, 0
    local ms = B.legalMoves(s.grid)
    if #ms == 0 then return nil end
    local m = ms[love.math.random(#ms)]
    planMove(s.cur.x, s.cur.y, m)
    movesPlayed = movesPlayed + 1
    if #plan == 0 then return nil end
  end

  if frame % SPACING ~= 0 then return nil end
  planPos = planPos + 1
  return plan[planPos]
end

function M.movesPlayed() return movesPlayed end

return M
