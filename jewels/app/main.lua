-- Jewels - a match-three for my dad.
--
-- THE ONE DESIGN RULE: nothing on this board moves unless he moves it.
-- No timer, no falling pieces, no shot clock, no fail state. He can look
-- at the board for two minutes, get up for coffee, come back, and the
-- position is exactly as he left it. That is the whole reason this genre
-- works for him where Tetris does not -- Tetris changes the board WHILE
-- you think, and that is the part that excludes an 85-year-old.
--
-- Bejeweled's publishers were alarmed by its untimed mode; they thought a
-- match-3 with no clock "didn't require any skill". They had it backwards.
-- Removing the pressure does not remove the pattern-finding, and the
-- pattern-finding was always the fun. (Juul, "Swap Adjacent Gems to Make
-- Sets of Three", 2007.)
--
-- Consequences that follow, and that must not be quietly undone later:
--   * an illegal swap springs back and costs nothing
--   * the hint is free, unlimited, and on its own button
--   * a deadlocked board reshuffles itself, silently -- never a game over
--   * the score only ever goes up

local theme  = require("lib.theme")
local ui     = require("lib.ui")
local anim   = require("lib.anim")
local sounds = require("lib.sounds")
local B      = require("board")
local jewels = require("jewels")
local fx     = require("fx")

-- ── layout ────────────────────────────────────────────────────────────
-- 10x8 at 1920x1080: 120px cells leave a 624px HUD panel on the right.
-- 120px is enormous by match-3 standards (a phone is ~90px held at arm's
-- length) and that is the point: this is a TV seen from a couch.

local CELL   = 120
local MARGIN = 60
local BOARD_W, BOARD_H = B.W * CELL, B.H * CELL
local BX, BY = MARGIN, MARGIN                    -- board origin
local PANEL_X = BX + BOARD_W + 48
local PANEL_W = 1920 - PANEL_X - MARGIN

local function cellCX(x) return BX + (x - 0.5) * CELL end
local function cellCY(y) return BY + (y - 0.5) * CELL end
local JEWEL_R = CELL * 0.40

-- ── state ─────────────────────────────────────────────────────────────

local grid                       -- grid[y][x] = kind
local view                       -- view[y][x] = {dx,dy,scale,alpha,spin} render offsets
local cur = { x = 5, y = 4 }     -- cursor
local sel = nil                  -- {x,y} first-picked cell, or nil
local score, best = 0, 0
local moves = 0
local cascade = 0
local state = "idle"             -- idle | swapping | clearing | falling | reverting
local hintMove, hintTimer, hintPulse = nil, 0, 0
local reshuffleFlash = 0
local lastGain, lastGainT = 0, 0
local padUsed = false
local statusText, statusTimer = nil, 0

local IDLE_HINT_AFTER = 8.0      -- seconds of no input before a hint offers itself

-- view cells carry the animation. The GRID is always the truth; view is
-- only ever a visual offset from it, which means a dropped frame or an
-- interrupted animation can never corrupt the board.
local function resetView()
  view = {}
  for y = 1, B.H do
    view[y] = {}
    for x = 1, B.W do
      view[y][x] = { dx = 0, dy = 0, scale = 1, alpha = 1, spin = 0, glow = 0 }
    end
  end
end

local function setStatus(t, secs)
  statusText, statusTimer = t, secs or 2.4
end

-- ── input ─────────────────────────────────────────────────────────────
-- Same idiom as every other game in the family: d-pad moves, one button
-- confirms. Debounced by hand, because a resting thumb or a flaky host
-- mapping can double-fire and here that costs a swap.

local prevDown, edges, lastEdgeFrame, frameNo = {}, {}, {}, 0
local DEBOUNCE = 9
local AUTO = rawget(_G, "JEWELS_DRIVER")

local BUTTONS = { "a", "b", "x", "y", "left", "right", "up", "down" }

local function readEdges()
  frameNo = frameNo + 1
  for k in pairs(edges) do edges[k] = nil end
  if AUTO then
    local b = AUTO(frameNo)
    if b then edges[b] = true end
    return
  end
  for _, b in ipairs(BUTTONS) do
    local d = love.pad.isDown(b)
    local edge = d and not prevDown[b]
    if edge and (frameNo - (lastEdgeFrame[b] or -100)) < DEBOUNCE then edge = false end
    if edge then
      lastEdgeFrame[b] = frameNo
      padUsed = true
    end
    edges[b] = edge
    prevDown[b] = d
  end
end

-- Touch is an equal path, not an afterthought: on a phone the pad does not
-- exist. Poll ALL ten pointer slots -- slot 0 is the mouse, 1-9 are
-- fingers, and a mouse-only read silently ignores every touch.
local prevPtr, click, clickHeld, dragFrom = {}, nil, nil, nil
local function readClicks()
  click, clickHeld = nil, nil
  local ptr = rawget(_G, "wc") and wc.pointer
  if not ptr then return end
  for slot = 0, 9 do
    local x, y, buttons, active = ptr(slot)
    local down = (active and buttons ~= 0) or false
    if down then clickHeld = { x = x, y = y } end
    if down and not prevPtr[slot] and not click then click = { x = x, y = y } end
    prevPtr[slot] = down
  end
end

local function inRect(p, r)
  return p and p.x >= r.x and p.x < r.x + r.w and p.y >= r.y and p.y < r.y + r.h
end

-- which cell is under a screen point (nil if outside the board)
local function cellAt(p)
  if not p then return nil end
  local gx = math.floor((p.x - BX) / CELL) + 1
  local gy = math.floor((p.y - BY) / CELL) + 1
  if B.inside(gx, gy) then return gx, gy end
  return nil
end

local HINT_BTN = { x = 0, y = 0, w = 0, h = 0 }   -- filled in at layout time

-- ── the move pipeline ─────────────────────────────────────────────────
-- A move runs as a small state machine, each stage handing to the next
-- when its animation finishes. Slow and legible on purpose: fast reads as
-- "what just happened?", which is exactly what we are avoiding.

local SWAP_TIME   = 0.20
local CLEAR_TIME  = 0.34
local FALL_TIME   = 0.26

local resolveBoard   -- forward declaration (mutually recursive with settle)

-- Clear the matched cells with a burst, then collapse and drop.
local function doClear(hit, runs)
  state = "clearing"
  cascade = cascade + 1

  local gain, n = 0, 0
  local sumX, sumY = 0, 0
  for _, run in ipairs(runs) do
    gain = gain + B.runScore(run.n, cascade)
  end

  for key in pairs(hit) do
    local sx, sy = key:match("^(%d+),(%d+)$")
    local x, y = tonumber(sx), tonumber(sy)
    n = n + 1
    sumX, sumY = sumX + cellCX(x), sumY + cellCY(y)
    local v = view[y][x]
    local kind = grid[y][x]
    -- the jewel flares bright, spins up and shrinks away
    v.glow = 1
    anim.tween(v, { scale = 0.05, alpha = 0, spin = 2.6 }, CLEAR_TIME)
    -- burst slightly after the shrink starts, so the gem is seen to break
    -- rather than simply vanishing into a puff
    local bx, by = cellCX(x), cellCY(y)
    local strength = 1 + 0.25 * (cascade - 1)
    anim.tween({}, { t = 1 }, CLEAR_TIME * 0.22, function()
      fx.burst(bx, by, kind, strength)
    end)
  end

  score = score + gain
  if score > best then best = score end
  lastGain, lastGainT = gain, 1.0

  -- one popup for the whole clear, at its centre of mass
  local cx, cy = sumX / n, sumY / n
  if cascade > 1 then
    fx.popup(cx, cy - 10, ("+%d"):format(gain), true)
    fx.popup(cx, cy + 46, ("CASCADE x%d"):format(cascade), false)
  else
    fx.popup(cx, cy, ("+%d"):format(gain), n >= 4)
  end

  -- Cascade steps climb the scale. This is the single most valuable piece
  -- of audio in the game: the rising run tells him the chain is STILL
  -- GOING without him having to track the board, and it is the reason a
  -- big cascade feels like an event rather than a longer wait.
  -- Capped, or a deep chain ends up sounding like a kettle.
  sounds.play("clear", math.min(1, 0.55 + 0.12 * cascade),
              math.min(2.0, 1.0 + 0.14 * (cascade - 1)))

  -- after the clear animation: collapse, then animate the fall
  anim.tween({}, { t = 1 }, CLEAR_TIME, function()
    local cleared, fell, spawned = B.collapse(grid, hit, B.KINDS)
    resetView()

    -- survivors: start at their OLD position and slide to the new one
    for _, f in ipairs(fell) do
      local v = view[f.toY][f.x]
      v.dy = (f.fromY - f.toY) * CELL
      anim.tween(v, { dy = 0 }, FALL_TIME)
    end
    -- new jewels: enter from above the board
    for _, s in ipairs(spawned) do
      local v = view[s.y][s.x]
      v.dy = (s.fromY - s.y) * CELL
      anim.tween(v, { dy = 0 }, FALL_TIME)
    end

    state = "falling"
    if #fell > 0 or #spawned > 0 then sounds.play("fall", 0.5) end
    anim.tween({}, { t = 1 }, FALL_TIME, function() resolveBoard() end)
  end)
end

-- Look at the board: if anything matches, clear it (and keep going, which
-- is the cascade). If nothing matches, the move is over.
resolveBoard = function()
  local hit, runs = B.findMatches(grid)
  if next(hit) then
    doClear(hit, runs)
    return
  end

  -- settled. Is the board still playable?
  cascade = 0
  if #B.legalMoves(grid) == 0 then
    -- No game over, ever. Reshuffle and say so gently.
    B.reshuffle(grid, B.KINDS)
    resetView()
    reshuffleFlash = 1.0
    setStatus("No moves left, so the board reshuffled", 3.0)
    sounds.play("shuffle", 0.8)
    -- a reshuffle can itself create matches; resolve those too
    if B.anyMatch(grid) then
      resolveBoard()
      return
    end
  end

  state = "idle"
  hintMove, hintTimer = nil, 0
end

-- Try the swap the player asked for.
local function trySwap(x1, y1, x2, y2)
  if state ~= "idle" then return end
  if not (B.inside(x1, y1) and B.inside(x2, y2)) then return end
  if math.abs(x1 - x2) + math.abs(y1 - y2) ~= 1 then return end

  local legal = B.isLegal(grid, x1, y1, x2, y2)
  local v1, v2 = view[y1][x1], view[y2][x2]
  local ddx, ddy = (x2 - x1) * CELL, (y2 - y1) * CELL

  state = "swapping"
  sel = nil

  if legal then
    B.swap(grid, x1, y1, x2, y2)
    -- the grid has already swapped, so animate each jewel FROM the other's
    -- cell back to zero -- the visual catches up with the truth
    v1.dx, v1.dy = ddx, ddy
    v2.dx, v2.dy = -ddx, -ddy
    anim.tween(v1, { dx = 0, dy = 0 }, SWAP_TIME)
    anim.tween(v2, { dx = 0, dy = 0 }, SWAP_TIME, function()
      moves = moves + 1
      resolveBoard()
    end)
    sounds.play("swap", 0.7)
  else
    -- ILLEGAL: nudge and spring back. It must cost nothing -- no penalty,
    -- no move counted, no sad noise. Exploring is free, and that freedom
    -- is what lets him poke at the board without worrying.
    anim.tween(v1, { dx = ddx * 0.34, dy = ddy * 0.34 }, SWAP_TIME * 0.6, function()
      anim.tween(v1, { dx = 0, dy = 0 }, SWAP_TIME * 0.7)
    end)
    anim.tween(v2, { dx = -ddx * 0.34, dy = -ddy * 0.34 }, SWAP_TIME * 0.6, function()
      anim.tween(v2, { dx = 0, dy = 0 }, SWAP_TIME * 0.7, function()
        state = "idle"
      end)
    end)
    sounds.play("bump", 0.35)
  end
end

local function showHint()
  local ms = B.legalMoves(grid)
  if #ms == 0 then return end
  hintMove = ms[love.math.random(#ms)]
  hintTimer = 4.0
  setStatus("Try these two", 2.0)
end

-- ── love callbacks ────────────────────────────────────────────────────

function love.load()
  -- Seed from the host entropy source if there is one, so two sessions do
  -- not deal the same opening board. `f and f(x)` is an EXPRESSION and not
  -- a valid Lua statement, which is what the first version of this line
  -- tried to be.
  if love.math.setRandomSeed then
    local seed = (rawget(_G, "wc") and wc.entropy and wc.entropy()) or 12345
    love.math.setRandomSeed(seed)
  end
  sounds.loadAll()
  -- Bake the six gem textures. MUST be after love.load has a live
  -- graphics context, and before anything draws.
  jewels.bake()
  fx.init()
  fx.initPops()
  grid = B.newBoard(B.KINDS)
  resetView()

  -- Expose live state to the headless test driver (tools/playdriver.lua).
  -- Only ever read, never written, and only when a driver is present -- the
  -- shipped cart has no JEWELS_DRIVER so this table is simply unused.
  -- Exposing it is what lets the driver play through the REAL input path
  -- (cursor, pick up, push) instead of reaching into trySwap behind the
  -- game's back, which would test nothing.
  _G.JEWELS_STATE = setmetatable({}, {
    __index = function(_, k)
      if k == "grid"  then return grid end
      if k == "cur"   then return cur end
      if k == "state" then return state end
      if k == "score" then return score end
      if k == "moves" then return moves end
      if k == "cascade" then return cascade end
      return nil
    end,
  })

  HINT_BTN.w, HINT_BTN.h = PANEL_W, 130
  HINT_BTN.x = PANEL_X
  HINT_BTN.y = 1080 - MARGIN - HINT_BTN.h
end

function love.update(dt)
  readEdges()
  readClicks()
  anim.update(dt)
  fx.update(dt)

  if statusTimer > 0 then
    statusTimer = statusTimer - dt
    if statusTimer <= 0 then statusText = nil end
  end
  if reshuffleFlash > 0 then reshuffleFlash = math.max(0, reshuffleFlash - dt * 1.4) end
  if lastGainT > 0 then lastGainT = math.max(0, lastGainT - dt * 0.8) end
  hintPulse = hintPulse + dt

  -- resting glow on the currently selected jewel
  for y = 1, B.H do
    for x = 1, B.W do
      local v = view[y][x]
      if v.glow > 0 and state ~= "clearing" then
        v.glow = math.max(0, v.glow - dt * 2)
      end
    end
  end

  local acted = false

  -- ── pad ──
  if state == "idle" then
    local dx, dy = 0, 0
    if edges.left  then dx = -1 end
    if edges.right then dx =  1 end
    if edges.up    then dy = -1 end
    if edges.down  then dy =  1 end

    if dx ~= 0 or dy ~= 0 then
      acted = true
      if sel then
        -- a jewel is picked up: a direction IS the swap. One press to
        -- pick, one direction to throw. No second confirm, because a
        -- two-stage commit is where a player gets lost.
        trySwap(sel.x, sel.y, sel.x + dx, sel.y + dy)
        cur.x = math.max(1, math.min(B.W, cur.x + dx))
        cur.y = math.max(1, math.min(B.H, cur.y + dy))
      else
        cur.x = math.max(1, math.min(B.W, cur.x + dx))
        cur.y = math.max(1, math.min(B.H, cur.y + dy))
        sounds.play("move", 0.25)
      end
    end

    if edges.a or edges.b then
      acted = true
      if sel and sel.x == cur.x and sel.y == cur.y then
        sel = nil                      -- press again on the same jewel = put it down
        sounds.play("move", 0.3)
      elseif sel and math.abs(sel.x - cur.x) + math.abs(sel.y - cur.y) == 1 then
        trySwap(sel.x, sel.y, cur.x, cur.y)   -- adjacent: swap the two
      else
        sel = { x = cur.x, y = cur.y }        -- pick this one up
        view[cur.y][cur.x].glow = 1
        sounds.play("pick", 0.5)
      end
    end

    -- hint on its own button, always one press away wherever the cursor is
    if edges.x or edges.y then
      acted = true
      showHint()
    end
  end

  -- ── touch ──
  if click then
    if inRect(click, HINT_BTN) then
      showHint()
      acted = true
    elseif state == "idle" then
      local gx, gy = cellAt(click)
      if gx then
        acted = true
        cur.x, cur.y = gx, gy
        if sel and sel.x == gx and sel.y == gy then
          sel = nil
        elseif sel and math.abs(sel.x - gx) + math.abs(sel.y - gy) == 1 then
          trySwap(sel.x, sel.y, gx, gy)
        else
          sel = { x = gx, y = gy }
          view[gy][gx].glow = 1
          sounds.play("pick", 0.5)
        end
      end
    end
  end

  -- Touch drag: press a jewel and flick toward its neighbour. This is the
  -- gesture people already have in their fingers from every other match-3,
  -- so it must work even though tap-tap also does.
  if state == "idle" and clickHeld then
    if not dragFrom then
      local gx, gy = cellAt(clickHeld)
      if gx then dragFrom = { x = gx, y = gy, px = clickHeld.x, py = clickHeld.y } end
    else
      local ddx, ddy = clickHeld.x - dragFrom.px, clickHeld.y - dragFrom.py
      if math.abs(ddx) > CELL * 0.45 or math.abs(ddy) > CELL * 0.45 then
        local sx, sy = 0, 0
        if math.abs(ddx) > math.abs(ddy) then sx = ddx > 0 and 1 or -1
        else sy = ddy > 0 and 1 or -1 end
        trySwap(dragFrom.x, dragFrom.y, dragFrom.x + sx, dragFrom.y + sy)
        sel, dragFrom = nil, nil
        acted = true
      end
    end
  elseif not clickHeld then
    dragFrom = nil
  end

  -- The idle hint. If he has been looking for a while, the game quietly
  -- offers a move. It is never a penalty and never costs anything.
  if state == "idle" then
    if acted then
      hintTimer = 0
      if hintMove then hintMove = nil end
    else
      hintTimer = hintTimer + dt
      if hintTimer > IDLE_HINT_AFTER and not hintMove then showHint() end
    end
  end
end

-- ── drawing ───────────────────────────────────────────────────────────

local function drawBoardBed()
  local g = love.graphics
  -- the bed: a dark inset panel with a soft inner vignette so the jewels
  -- sit IN something rather than floating on the background
  g.setColor(0.06, 0.09, 0.14)
  g.rectangle("fill", BX - 18, BY - 18, BOARD_W + 36, BOARD_H + 36)
  g.setColor(0.10, 0.14, 0.21)
  g.rectangle("fill", BX - 8, BY - 8, BOARD_W + 16, BOARD_H + 16)

  -- Checkered cells. Low contrast against each other -- enough to read the
  -- grid, not enough to compete with the jewels -- but lifted well clear
  -- of black so the dark-rimmed gems have something to sit ON. At 0.12 the
  -- board read as a hole in the screen.
  for y = 1, B.H do
    for x = 1, B.W do
      local shade = ((x + y) % 2 == 0) and 0.225 or 0.185
      g.setColor(shade, shade + 0.035, shade + 0.075)
      g.rectangle("fill", BX + (x - 1) * CELL, BY + (y - 1) * CELL, CELL, CELL)
    end
  end

  if reshuffleFlash > 0 then
    g.setColor(0.45, 0.75, 1.0, reshuffleFlash * 0.35)
    g.rectangle("fill", BX, BY, BOARD_W, BOARD_H)
  end
end

local function drawCursor()
  if not padUsed then return end        -- a touch player never sees a pad cursor
  local g = love.graphics
  local x = BX + (cur.x - 1) * CELL
  local y = BY + (cur.y - 1) * CELL
  local pulse = 0.5 + 0.5 * math.sin(hintPulse * 4)
  g.setColor(theme.gold[1], theme.gold[2], theme.gold[3], 0.55 + 0.45 * pulse)
  g.setLineWidth(6)
  local inset = 5
  g.rectangle("line", x + inset, y + inset, CELL - inset * 2, CELL - inset * 2)
  -- corner ticks make the cursor read even against a bright jewel
  local L = 26
  g.setLineWidth(8)
  for _, c in ipairs({ {0,0,1,1}, {1,0,-1,1}, {0,1,1,-1}, {1,1,-1,-1} }) do
    local px = x + inset + c[1] * (CELL - inset * 2)
    local py = y + inset + c[2] * (CELL - inset * 2)
    g.line(px, py, px + c[3] * L, py)
    g.line(px, py, px, py + c[4] * L)
  end
end

local function drawSelection()
  if not sel then return end
  local g = love.graphics
  local x = BX + (sel.x - 1) * CELL
  local y = BY + (sel.y - 1) * CELL
  local pulse = 0.5 + 0.5 * math.sin(hintPulse * 6)
  g.setColor(1, 1, 1, 0.20 + 0.22 * pulse)
  g.rectangle("fill", x + 4, y + 4, CELL - 8, CELL - 8)
  g.setColor(1, 1, 1, 0.85)
  g.setLineWidth(5)
  g.rectangle("line", x + 4, y + 4, CELL - 8, CELL - 8)
end

local function drawHint()
  if not hintMove or hintTimer <= 0 then return end
  local g = love.graphics
  local pulse = 0.5 + 0.5 * math.sin(hintPulse * 5)
  local cells = {
    { hintMove.x, hintMove.y },
    { hintMove.x + hintMove.dx, hintMove.y + hintMove.dy },
  }
  for _, c in ipairs(cells) do
    local x = BX + (c[1] - 1) * CELL
    local y = BY + (c[2] - 1) * CELL
    g.setColor(0.35, 0.85, 1.0, 0.25 + 0.30 * pulse)
    g.rectangle("fill", x + 6, y + 6, CELL - 12, CELL - 12)
    g.setColor(0.45, 0.90, 1.0, 0.75 + 0.25 * pulse)
    g.setLineWidth(6)
    g.rectangle("line", x + 6, y + 6, CELL - 12, CELL - 12)
  end
  -- an arrow between them, so it reads as "swap these", not "look here"
  local ax, ay = cellCX(hintMove.x), cellCY(hintMove.y)
  local bx2, by2 = cellCX(hintMove.x + hintMove.dx), cellCY(hintMove.y + hintMove.dy)
  g.setColor(0.55, 0.92, 1.0, 0.6 + 0.4 * pulse)
  g.setLineWidth(7)
  g.line(ax, ay, bx2, by2)
end

local function drawJewels()
  for y = 1, B.H do
    for x = 1, B.W do
      local k = grid[y][x]
      local v = view[y][x]
      if k and k > 0 and v.alpha > 0.004 then
        jewels.draw(k, cellCX(x) + v.dx, cellCY(y) + v.dy,
                    JEWEL_R * v.scale, v.alpha, v.spin, v.glow)
      end
    end
  end
end

local function drawPanel()
  local g = love.graphics
  local x, w = PANEL_X, PANEL_W

  g.setColor(0.06, 0.09, 0.14, 0.9)
  g.rectangle("fill", x, MARGIN, w, 1080 - MARGIN * 2)

  local y = MARGIN + 40

  g.setFont(ui.font(theme.fontSmall))
  g.setColor(theme.quiet)
  g.printf("SCORE", x, y, w, "center")
  y = y + 44

  -- the score pops when it changes: scale eases back to 1 as the gain fades
  local bump = 1 + 0.16 * lastGainT
  g.setFont(ui.font(theme.fontHuge))
  g.push()
  g.translate(x + w / 2, y + theme.fontHuge * 0.5)
  g.scale(bump, bump)
  g.setColor(lastGainT > 0.05 and theme.gold or theme.white)
  g.printf(tostring(score), -w / 2, -theme.fontHuge * 0.5, w, "center")
  g.pop()
  y = y + theme.fontHuge + 30

  if lastGain > 0 and lastGainT > 0 then
    g.setFont(ui.font(theme.fontMid))
    g.setColor(theme.gold[1], theme.gold[2], theme.gold[3], lastGainT)
    g.printf(("+%d"):format(lastGain), x, y, w, "center")
  end
  y = y + 60

  g.setFont(ui.font(theme.fontSmall))
  g.setColor(theme.quiet)
  g.printf("BEST", x, y, w, "center")
  y = y + 40
  g.setFont(ui.font(theme.fontBig))
  g.setColor(theme.white)
  g.printf(tostring(best), x, y, w, "center")
  y = y + theme.fontBig + 40

  g.setFont(ui.font(theme.fontSmall))
  g.setColor(theme.quiet)
  g.printf("MOVES  " .. moves, x, y, w, "center")
  y = y + 70

  -- how to play, permanently on screen. He should never have to remember
  -- the goal or the controls, and there is room for it.
  g.setFont(ui.font(theme.fontSmall - 2))
  g.setColor(1, 1, 1, 0.72)
  local help
  if padUsed then
    help = "Line up THREE of the same jewel.\n\n" ..
           "Move with the D-PAD.\n" ..
           "Press A to pick a jewel up,\n" ..
           "then push it toward its neighbour."
  else
    help = "Line up THREE of the same jewel.\n\n" ..
           "Tap a jewel, then tap the one\n" ..
           "next to it. Or just drag it."
  end
  g.printf(help, x + 24, y, w - 48, "center")

  -- status line sits above the button, where a change is noticed
  if statusText then
    g.setFont(ui.font(theme.fontSmall))
    g.setColor(0.55, 0.92, 1.0, math.min(1, statusTimer * 2))
    g.printf(statusText, x + 16, HINT_BTN.y - 90, w - 32, "center")
  end

  -- The hint button: free, unlimited, always available. In the commercial
  -- games a hint is a purchasable resource; strip the monetization out and
  -- it is simply help, so there is no reason to ration it.
  local focused = (not padUsed) or (hintMove ~= nil)
  ui.button("HINT", HINT_BTN.x, HINT_BTN.y, HINT_BTN.w, HINT_BTN.h, focused)
  if padUsed then
    g.setFont(ui.font(theme.fontSmall - 4))
    g.setColor(1, 1, 1, 0.6)
    g.printf("or press X", HINT_BTN.x, HINT_BTN.y - 40, HINT_BTN.w, "center")
  end
end

function love.draw()
  local g = love.graphics

  -- background: a deep vertical gradient, drawn as a few bands. Cheap, and
  -- it stops the panel and board from floating on flat black.
  for i = 0, 11 do
    local t = i / 11
    g.setColor(0.04 + 0.05 * t, 0.06 + 0.07 * t, 0.10 + 0.11 * t)
    g.rectangle("fill", 0, t * 1080, 1920, 1080 / 11 + 1)
  end

  drawBoardBed()
  drawHint()
  drawSelection()

  -- Jewels are clipped to the board so a falling jewel entering from above
  -- is hidden until it crosses the edge. Without this they visibly pop in
  -- out of nowhere above the bed.
  g.setScissor(BX, BY, BOARD_W, BOARD_H)
  drawJewels()
  g.setScissor()

  drawCursor()

  -- particles ride ON TOP of the board but are also clipped, so a burst at
  -- the edge does not spray over the HUD
  g.setScissor(BX - 18, BY - 18, BOARD_W + 36, BOARD_H + 36)
  fx.draw()
  g.setScissor()

  fx.drawPops(ui.font(theme.fontBig), ui.font(theme.fontHuge))

  drawPanel()
end
