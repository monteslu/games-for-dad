-- fx.lua - the things that make a putt feel like an event.
--
-- All pooled and fixed-size. A celebration bursts 60 particles and the
-- ball leaves a trail every frame it rolls; allocating those fresh is the
-- steady drip that turns into a GC hitch exactly when the ball is moving
-- and you would notice.

local M = {}

-- Everything here is authored in CART PIXELS, the same space as the
-- physics and the level data -- but it is drawn OVER a perspective render
-- of the course, so a raw cart coordinate lands up to 174px from the thing
-- it is attached to. main.lua installs the projection; until it does,
-- points pass through unchanged so this module still works standalone.
local function P(x, y, h)
  local f = rawget(_G, "MINIGOLF_TO_SCREEN")
  if not f then return x, y end
  return f(x, y, h or 0)
end

-- ── ball trail ────────────────────────────────────────────────────────
-- A fading ribbon behind a rolling ball. This is the single cheapest
-- thing that makes motion read as FAST rather than as a sprite changing
-- position: without it a hard putt and a soft one look the same at any
-- given frame.
local TRAIL_N = 26
local trail, trailHead, trailLive = {}, 0, 0

-- ── particles ─────────────────────────────────────────────────────────
local PMAX = 420
local pool, live = {}, 0

-- ── floating score text ───────────────────────────────────────────────
local POPMAX = 8
local pops, popN = {}, 0

function M.init()
  for i = 1, TRAIL_N do trail[i] = { x = 0, y = 0, age = 0 } end
  trailHead, trailLive = 0, 0
  for i = 1, PMAX do
    pool[i] = { x = 0, y = 0, vx = 0, vy = 0, r = 0, life = 0, max = 1,
                cr = 1, cg = 1, cb = 1, spin = 0, dspin = 0, kind = 0 }
  end
  live = 0
  for i = 1, POPMAX do pops[i] = { x = 0, y = 0, life = 0, text = "" } end
  popN = 0
end

function M.reset()
  trailHead, trailLive, live, popN = 0, 0, 0, 0
end

-- Record where the ball is. Called every frame it moves; the ribbon
-- length is what encodes speed, since a fast ball leaves gaps.
function M.trailPush(x, y)
  trailHead = trailHead % TRAIL_N + 1
  local p = trail[trailHead]
  p.x, p.y, p.age = x, y, 1
  if trailLive < TRAIL_N then trailLive = trailLive + 1 end
end

local function take()
  if live >= PMAX then return nil end
  live = live + 1
  return pool[live]
end

-- Grass kicked up where the ball lands or scuffs.
function M.turf(x, y, dirx, diry, strength)
  strength = strength or 1
  -- A caller with no direction gets an even spray rather than an error.
  -- atan(nil) is a crash three frames after a putt, which is a rotten way
  -- to find out an argument was optional.
  dirx = dirx or 0
  diry = diry or 0
  if dirx == 0 and diry == 0 then dirx = 1 end
  for _ = 1, math.floor(9 * strength) do
    local p = take(); if not p then break end
    local a = math.atan(diry, dirx) + (love.math.random() - 0.5) * 2.2
    local sp = (60 + love.math.random() * 220) * strength
    p.x, p.y = x, y
    p.vx, p.vy = math.cos(a) * sp, math.sin(a) * sp
    p.r = 2 + love.math.random() * 4
    p.max = 0.28 + love.math.random() * 0.30; p.life = p.max
    -- grass green, varied so it does not read as one colour
    p.cr = 0.18 + love.math.random() * 0.16
    p.cg = 0.45 + love.math.random() * 0.28
    p.cb = 0.16 + love.math.random() * 0.12
    p.kind, p.spin, p.dspin = 0, 0, 0
  end
end

-- A splash when the ball finds water.
function M.splash(x, y)
  for _ = 1, 46 do
    local p = take(); if not p then break end
    local a = -math.pi / 2 + (love.math.random() - 0.5) * 2.6
    local sp = 90 + love.math.random() * 320
    p.x, p.y = x, y
    p.vx, p.vy = math.cos(a) * sp, math.sin(a) * sp
    p.r = 3 + love.math.random() * 7
    p.max = 0.45 + love.math.random() * 0.45; p.life = p.max
    local w = love.math.random() * 0.5
    p.cr = 0.30 + w * 0.6; p.cg = 0.62 + w * 0.35; p.cb = 0.92
    p.kind, p.spin, p.dspin = 0, 0, 0
  end
  -- the ring on the surface
  local p = take()
  if p then
    p.x, p.y, p.vx, p.vy = x, y, 0, 0
    p.r = 10; p.max = 0.6; p.life = p.max
    p.cr, p.cg, p.cb = 0.5, 0.8, 1.0
    p.kind = -1
  end
end

-- Sinking the putt: gold confetti out of the cup.
function M.celebrate(x, y, big)
  local n = big and 90 or 54
  for _ = 1, n do
    local p = take(); if not p then break end
    local a = love.math.random() * math.pi * 2
    local sp = 120 + love.math.random() * (big and 520 or 340)
    p.x, p.y = x, y
    p.vx, p.vy = math.cos(a) * sp, math.sin(a) * sp - 120
    p.r = 4 + love.math.random() * 7
    p.max = 0.7 + love.math.random() * 0.7; p.life = p.max
    -- gold and white, the colour the family uses for "you did well"
    if love.math.random() < 0.7 then
      p.cr, p.cg, p.cb = 1.0, 0.82 + love.math.random() * 0.15, 0.28
    else
      p.cr, p.cg, p.cb = 1, 1, 1
    end
    p.kind = 1                       -- a tumbling flake, not a dot
    p.spin = love.math.random() * math.pi
    p.dspin = (love.math.random() - 0.5) * 18
  end
  -- two shockwave rings
  for i = 1, 2 do
    local p = take()
    if p then
      p.x, p.y, p.vx, p.vy = x, y, 0, 0
      p.r = 14 + i * 10; p.max = 0.5 + i * 0.12; p.life = p.max
      p.cr, p.cg, p.cb = 1, 0.85, 0.35
      p.kind = -1
    end
  end
end

function M.popup(x, y, text)
  if popN >= POPMAX then return end
  popN = popN + 1
  local p = pops[popN]
  p.x, p.y, p.life, p.text = x, y, 1.4, text
end

function M.update(dt)
  for i = 1, trailLive do
    local p = trail[i]
    if p.age > 0 then p.age = math.max(0, p.age - dt * 2.6) end
  end

  local i = 1
  while i <= live do
    local p = pool[i]
    p.life = p.life - dt
    if p.life <= 0 then
      pool[i], pool[live] = pool[live], pool[i]
      live = live - 1
    else
      p.x = p.x + p.vx * dt
      p.y = p.y + p.vy * dt
      if p.kind >= 0 then
        p.vy = p.vy + 620 * dt          -- debris falls; rings do not
        p.vx = p.vx * (1 - 1.9 * dt)
      end
      p.spin = p.spin + p.dspin * dt
      i = i + 1
    end
  end

  local j = 1
  while j <= popN do
    local p = pops[j]
    p.life = p.life - dt
    if p.life <= 0 then
      pops[j], pops[popN] = pops[popN], pops[j]
      popN = popN - 1
    else
      p.y = p.y - 42 * dt
      j = j + 1
    end
  end
end

function M.drawTrail(r)
  if trailLive < 2 then return end
  local g = love.graphics
  g.setBlendMode("add")
  for i = 1, trailLive do
    local p = trail[i]
    if p.age > 0 then
      local a = p.age * p.age * 0.42
      g.setColor(1, 1, 0.92, a)
      local sx, sy = P(p.x, p.y, r)
      g.circle("fill", sx, sy, r * (0.30 + p.age * 0.62))
    end
  end
  g.setBlendMode("alpha")
end

function M.draw()
  local g = love.graphics
  g.setBlendMode("add")
  for i = 1, live do
    local p = pool[i]
    local t = p.life / p.max
    local a = t * t
    if p.kind == -1 then
      local rr = p.r + (1 - t) * 130
      g.setLineWidth(math.max(1.5, 8 * t))
      g.setColor(p.cr, p.cg, p.cb, a * 0.75)
      local sx, sy = P(p.x, p.y)
      g.circle("line", sx, sy, rr)
    elseif p.kind == 1 then
      -- confetti: a rotating sliver, so it tumbles rather than floats
      local sx, sy = P(p.x, p.y)
      g.push(); g.translate(sx, sy); g.rotate(p.spin)
      g.setColor(p.cr, p.cg, p.cb, a)
      g.rectangle("fill", -p.r, -p.r * 0.34, p.r * 2, p.r * 0.68)
      g.pop()
    else
      local sx, sy = P(p.x, p.y)
      g.setColor(p.cr, p.cg, p.cb, a * 0.55)
      g.circle("fill", sx, sy, p.r * 1.8)
      g.setColor(p.cr, p.cg, p.cb, a)
      g.circle("fill", sx, sy, p.r * 0.8)
    end
  end
  g.setBlendMode("alpha")
end

function M.drawPops(font)
  local g = love.graphics
  g.setFont(font)
  for i = 1, popN do
    local p = pops[i]
    local a = math.min(1, p.life * 1.6)
    local sx, sy = P(p.x, p.y)
    g.setColor(0, 0, 0, a * 0.5)
    g.printf(p.text, sx - 200 + 3, sy + 3, 400, "center")
    g.setColor(1, 0.9, 0.45, a)
    g.printf(p.text, sx - 200, sy, 400, "center")
  end
end

return M
