-- fx.lua - soft particle bursts, score popups and the board shimmer.
--
-- love.graphics.newParticleSystem is one of the API gaps (see
-- wasmcart-lua/API_STATUS.md), so this is a small hand-rolled emitter.
-- That is fine here: a bespoke one can do the thing the game actually
-- wants, which is a SOFT burst -- no hard-edged sprites, everything
-- additive, everything fading before it lands.
--
-- POOLED. Every particle is preallocated and reused, because a cascade
-- clearing 30 jewels at 40 particles each is 1200 tables, and allocating
-- those per burst is how a cart ends up with a GC hitch mid-animation.

local jewels = require("jewels")

local M = {}

local MAX = 1400
local pool, live = {}, 0

function M.init()
  for i = 1, MAX do
    pool[i] = { x = 0, y = 0, vx = 0, vy = 0, r = 0, life = 0, max = 1,
                cr = 1, cg = 1, cb = 1, spin = 0, dspin = 0, kind = 0 }
  end
  live = 0
end

local function take()
  if live >= MAX then return nil end        -- drop, never grow
  live = live + 1
  return pool[live]
end

-- A soft burst where a jewel was cleared.
--
-- Three species, on purpose:
--   * a few SHARDS in the jewel's own shape, spinning outward -- reads as
--     the gem breaking
--   * a cloud of soft round MOTES, additive, that fade to nothing
--   * one expanding RING, which is what actually sells the "pop"
function M.burst(cx, cy, kind, strength)
  strength = strength or 1
  local col = jewels.color(kind)

  -- Sizes and lifetimes are tuned against a 120px cell. The first pass
  -- used values that would have been right for a phone -- 4-13px motes
  -- over 0.35s -- and on a 1080p board they were an invisible wisp. On a
  -- screen this size a soft burst has to be BIG and it has to LINGER.
  local shards = math.floor(7 * strength)
  for i = 1, shards do
    local p = take(); if not p then break end
    local a = love.math.random() * math.pi * 2
    local sp = (110 + love.math.random() * 230) * strength
    p.x, p.y = cx, cy
    p.vx, p.vy = math.cos(a) * sp, math.sin(a) * sp - 70
    p.r = 20 + love.math.random() * 20
    p.max = 0.60 + love.math.random() * 0.35
    p.life = p.max
    p.cr, p.cg, p.cb = col[1], col[2], col[3]
    p.spin = love.math.random() * math.pi * 2
    p.dspin = (love.math.random() - 0.5) * 14
    p.kind = kind                       -- draw as the gem's silhouette
  end

  local motes = math.floor(13 * strength)
  for i = 1, motes do
    local p = take(); if not p then break end
    local a = love.math.random() * math.pi * 2
    local sp = (40 + love.math.random() * 190) * strength
    p.x, p.y = cx, cy
    p.vx, p.vy = math.cos(a) * sp, math.sin(a) * sp - 40
    p.r = 11 + love.math.random() * 20
    p.max = 0.50 + love.math.random() * 0.55
    p.life = p.max
    -- motes wash toward white, so the burst has a hot centre
    local w = 0.12 + love.math.random() * 0.22
    p.cr = col[1] + (1 - col[1]) * w
    p.cg = col[2] + (1 - col[2]) * w
    p.cb = col[3] + (1 - col[3]) * w
    p.spin, p.dspin, p.kind = 0, 0, 0
  end

  -- Two rings, the second slightly delayed and wider, which reads as a
  -- shockwave rather than a single hoop.
  for ring = 1, 2 do
    local p = take()
    if p then
      p.x, p.y = cx, cy
      p.vx, p.vy = 0, 0
      p.r = 16 + ring * 10
      p.max = 0.42 + ring * 0.10; p.life = p.max
      p.cr, p.cg, p.cb = col[1], col[2], col[3]
      p.kind = -1                          -- the ring
      p.spin, p.dspin = 0, 0
    end
  end
end

-- ── score popups ──────────────────────────────────────────────────────
-- Small numbers that rise and fade where the match happened. This is the
-- feedback that tells the player WHICH match was the good one, which a
-- score counter in the corner cannot do.

local pops, popN = {}, 0
local POPMAX = 40
function M.initPops()
  for i = 1, POPMAX do pops[i] = { x = 0, y = 0, life = 0, text = "", big = false } end
  popN = 0
end

function M.popup(x, y, text, big)
  if popN >= POPMAX then return end
  popN = popN + 1
  local p = pops[popN]
  p.x, p.y, p.life, p.text, p.big = x, y, 1.15, text, big or false
end

-- ── update / draw ─────────────────────────────────────────────────────

function M.update(dt)
  local i = 1
  while i <= live do
    local p = pool[i]
    p.life = p.life - dt
    if p.life <= 0 then
      -- swap-remove: keeps the live prefix dense with no allocation
      pool[i], pool[live] = pool[live], pool[i]
      live = live - 1
    else
      p.x = p.x + p.vx * dt
      p.y = p.y + p.vy * dt
      if p.kind >= 0 then
        p.vy = p.vy + 420 * dt          -- gravity: debris falls, ring does not
        p.vx = p.vx * (1 - 2.2 * dt)    -- air drag, so nothing flies off screen
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
      p.y = p.y - 46 * dt
      j = j + 1
    end
  end
end

function M.draw()
  local g = love.graphics
  -- ADDITIVE for the whole particle pass: overlapping motes get brighter
  -- instead of muddier, which is the entire difference between "soft glow"
  -- and "grey smear".
  g.setBlendMode("add")
  for i = 1, live do
    local p = pool[i]
    local t = p.life / p.max
    local a = t * t                     -- quadratic fade: fast out, long tail
    if p.kind == -1 then
      -- expanding ring
      -- expand across most of a cell: a ring that only grows 78px on a
      -- 120px board barely leaves the gem it came from
      local rr = p.r + (1 - t) * 145
      g.setLineWidth(math.max(2, 9 * t))
      g.setColor(p.cr, p.cg, p.cb, a * 0.55)
      g.circle("line", p.x, p.y, rr)
    elseif p.kind > 0 then
      -- a shard: the jewel's own silhouette, shrinking
      jewels.draw(p.kind, p.x, p.y, p.r * (0.45 + 0.55 * t), a * 0.95, p.spin, 0.5)
    else
      -- a soft mote: three stacked ellipses approximate a gaussian blob
      -- far more cheaply than a real blur, and additive hides the seams
      -- Additive stacking saturates FAST: three layers at 0.38/0.50/0.72
      -- turned a burst into a solid white column that hid the board and
      -- swallowed the score popup. Keep each layer faint and let the
      -- OVERLAP do the brightening, which is the whole point of additive.
      -- No pure-white core at all -- the colour is the identity, and a
      -- white centre erases which jewel just cleared.
      g.setColor(p.cr, p.cg, p.cb, a * 0.13)
      g.circle("fill", p.x, p.y, p.r * 2.0)
      g.setColor(p.cr, p.cg, p.cb, a * 0.17)
      g.circle("fill", p.x, p.y, p.r * 1.15)
      g.setColor(p.cr * 0.6 + 0.4, p.cg * 0.6 + 0.4, p.cb * 0.6 + 0.4, a * 0.22)
      g.circle("fill", p.x, p.y, p.r * 0.5)
    end
  end
  g.setBlendMode("alpha")
end

function M.drawPops(font, bigFont)
  local g = love.graphics
  for i = 1, popN do
    local p = pops[i]
    local t = p.life / 1.15
    local a = math.min(1, t * 2.2)      -- hold, then fade
    local f = p.big and bigFont or font
    g.setFont(f)
    -- shadow first so the number reads over a bright burst
    g.setColor(0, 0, 0, a * 0.55)
    g.printf(p.text, p.x - 150 + 3, p.y + 3, 300, "center")
    if p.big then g.setColor(1, 0.92, 0.55, a) else g.setColor(1, 1, 1, a) end
    g.printf(p.text, p.x - 150, p.y, 300, "center")
  end
end

function M.count() return live end
function M.busy() return live > 0 or popN > 0 end

return M
