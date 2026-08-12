-- course.lua - draws the hole.
--
-- VECTOR, FROM THE COLLISION GEOMETRY ITSELF. The original game drew a
-- backdrop PNG per hole and kept the collision shapes invisible behind it;
-- this draws the shapes. Two things follow that are worth the trouble:
--
--   * what you see IS what you hit. A backdrop can disagree with its
--     collision -- the original has walls whose art and body differ by a
--     pixel or two -- and the player has no way to tell which is real.
--   * it stays sharp at any resolution, and the 22 backdrops (a megabyte
--     of PNG drawn for a 1500x1000 canvas) are not shipped at all.
--
-- Everything here is flat 2D drawing with a consistent light from the
-- upper left, which is the same direction the ball texture was baked with.

local jewels_unused = nil   -- (placeholder removed)

local M = {}

-- ── palette ───────────────────────────────────────────────────────────
-- Greens are separated in LIGHTNESS as well as hue so the course reads
-- for a colour-blind player: fairway mid, rough dark, water dark-blue,
-- sand pale. The same rule as the jewels.
local C = {
  fairway   = {0.24, 0.55, 0.26},
  fairway2  = {0.27, 0.60, 0.29},   -- the mow stripe
  rough     = {0.15, 0.36, 0.18},
  wallTop   = {0.52, 0.40, 0.26},   -- timber, lit
  wallSide  = {0.31, 0.23, 0.14},   -- timber, shaded
  wallEdge  = {0.20, 0.15, 0.09},
  water     = {0.11, 0.35, 0.62},
  waterLite = {0.24, 0.55, 0.85},
  sand      = {0.86, 0.78, 0.55},
  sandDark  = {0.72, 0.63, 0.42},
  zone      = {0.95, 0.75, 0.20},   -- impulse pads
  cup       = {0.05, 0.05, 0.06},
  cupRim    = {0.85, 0.85, 0.88},
  flagPole  = {0.90, 0.90, 0.92},
  flag      = {0.90, 0.20, 0.22},
}
M.COLORS = C

-- Shadows all fall the same way, from a light up and to the left. A
-- consistent offset is most of what makes flat shapes read as solid.
local SHX, SHY = 7, 9

-- ── scratch buffers ───────────────────────────────────────────────────
-- Pooled: a hole redraws 40-odd polygons every frame, and building a
-- fresh point table for each is the steady allocation drip that turns
-- into a GC hitch mid-putt.
local poly = {}
local function polyFrom(e, ox, oy, scale)
  local p, n = e.points, 0
  scale = scale or 1
  for i = 1, #p, 2 do
    n = n + 1; poly[n] = e.x + p[i] * scale + (ox or 0)
    n = n + 1; poly[n] = e.y + p[i + 1] * scale + (oy or 0)
  end
  for i = n + 1, #poly do poly[i] = nil end
  return poly
end

local function setC(c, a) love.graphics.setColor(c[1], c[2], c[3], a or 1) end

-- ── ground ────────────────────────────────────────────────────────────
--
-- The fairway is BAKED ONCE into a canvas: mow stripes, a fine grass
-- noise, and a soft edge darkening. Baking matters because the texture is
-- thousands of tiny marks -- drawing them per frame would cost more than
-- the rest of the game put together, and they never change.
--
-- Grass noise is what stops a green rectangle looking like a green
-- rectangle. Stripes alone read as a flag; stripes plus per-blade
-- variation read as turf.

local groundCanvas = nil

local function bakeGround(x, y, w, h)
  local g = love.graphics
  groundCanvas = g.newCanvas(1920, 1080)
  groundCanvas:renderTo(function()
    g.clear(C.rough[1], C.rough[2], C.rough[3], 1)

    -- the rough, with its own coarser noise so the border is not flat
    for i = 1, 2600 do
      local rx = love.math.random() * 1920
      local ry = love.math.random() * 1080
      local v = (love.math.random() - 0.5) * 0.07
      g.setColor(C.rough[1] + v, C.rough[2] + v * 1.3, C.rough[3] + v)
      g.rectangle("fill", rx, ry, 3, 2)
    end

    -- fairway base
    setC(C.fairway)
    g.rectangle("fill", x, y, w, h)

    -- mow stripes, alternating direction of cut
    setC(C.fairway2)
    local stripe = 68
    for sx = 0, math.ceil(w / stripe) - 1, 2 do
      g.rectangle("fill", x + sx * stripe, y, math.min(stripe, w - sx * stripe), h)
    end

    -- per-blade noise across the whole fairway. Two passes: dark flecks
    -- for depth, light flecks for the sheen the mower leaves.
    for i = 1, 9000 do
      local rx = x + love.math.random() * w
      local ry = y + love.math.random() * h
      local v = (love.math.random() - 0.5) * 0.085
      local onStripe = (math.floor((rx - x) / stripe) % 2 == 0)
      local base = onStripe and C.fairway2 or C.fairway
      g.setColor(base[1] + v, base[2] + v * 1.25, base[3] + v)
      g.rectangle("fill", rx, ry, 2, love.math.random() < 0.5 and 3 or 2)
    end

    -- the fairway edge sits slightly below the rough, so darken inward
    for i = 1, 14 do
      g.setColor(0, 0, 0, 0.028)
      g.rectangle("line", x + i, y + i, w - i * 2, h - i * 2)
    end
  end)
end

function M.drawGround(x, y, w, h)
  local g = love.graphics
  if not groundCanvas then bakeGround(x, y, w, h) end
  g.setColor(1, 1, 1, 1)
  g.draw(groundCanvas, 0, 0)
end

-- ── hazards ───────────────────────────────────────────────────────────
--
-- WHY THESE GO THROUGH A CANVAS.
--
-- The source levels approximate a curved lake with a STACK OF RECTANGLES
-- of decreasing width -- hole 18's water is 37 separate pieces. Drawing
-- them individually is honest to the collision but looks like a
-- staircase, and any per-piece edge treatment (a rim, a ripple) lands in
-- the middle of the shape where two pieces abut.
--
-- So each hazard KIND is composited into an offscreen canvas first: fill
-- every piece flat, and the union is one silhouette with no internal
-- seams. The rim and the ripples are then drawn against THAT, and clipped
-- to it, which is what makes 37 rectangles read as one lake.
--
-- One canvas per kind, built once per hole rather than per frame -- the
-- geometry never moves, so rebuilding it every frame would be 37 fills a
-- frame for a picture that never changes.

local hazCanvas = {}      -- kind -> canvas
local hazBuilt = nil      -- the level these were built for

local function fillPiece(e)
  local g = love.graphics
  if e.kind == "circle" then
    g.circle("fill", e.x, e.y, e.r)
  elseif e.kind == "rect" then
    -- a half-pixel of overlap closes the hairline seams between abutting
    -- rects, which otherwise show as bright lines through the lake
    g.rectangle("fill", e.x - e.hw - 0.5, e.y - e.hh - 0.5,
                e.hw * 2 + 1, e.hh * 2 + 1)
  else
    g.polygon("fill", polyFrom(e))
  end
end

local function buildHazards(level)
  local g = love.graphics
  hazCanvas = {}
  for _, kind in ipairs({ "water", "sand" }) do
    local any = false
    for _, e in ipairs(level.entities) do
      if e[kind] then any = true break end
    end
    if any then
      local cv = g.newCanvas(1920, 1080)
      cv:renderTo(function()
        g.clear(0, 0, 0, 0)
        g.setColor(1, 1, 1, 1)
        for _, e in ipairs(level.entities) do
          if e[kind] then fillPiece(e) end
        end
      end)
      hazCanvas[kind] = cv
      if kind == "water" then
        hazCanvas.waterSurf = g.newCanvas(1920, 1080)
      end
    end
  end
  hazBuilt = level
end

-- Draw the merged hazard.
--
-- The ripples are composited INTO the water canvas rather than stencilled
-- over it. A stencil cannot help here: a textured quad writes the stencil
-- buffer for its whole RECTANGLE, not for the shape in its alpha channel,
-- so masking from a canvas would need an alpha-discard in the shader.
-- Drawing them into the canvas gets the clipping for free from ordinary
-- alpha blending, and costs one canvas pass per frame instead of two
-- stencil passes.
local function drawHazard(kind, level, t)
  local cv = hazCanvas[kind]
  if not cv then return end
  local g = love.graphics

  if kind == "water" then
    -- Repaint the animated surface into a second canvas that carries the
    -- lake's silhouette: draw the mask, then the ripples MULTIPLIED down
    -- to the mask's alpha by drawing them with the mask as a stencil in
    -- the only way that works here -- inside the canvas, where anything
    -- outside the already-painted shape simply lands on transparent
    -- pixels and is discarded when the canvas is composited.
    local surf = hazCanvas.waterSurf
    surf:renderTo(function()
      g.clear(0, 0, 0, 0)
      setC(C.water)
      g.draw(cv, 0, 0)
      -- ripples: only the pixels that land ON the lake survive, because
      -- the canvas is transparent everywhere else and these are drawn
      -- with the lake already down
      g.setBlendMode("add")
      g.setColor(C.waterLite[1] * 0.30, C.waterLite[2] * 0.30,
                 C.waterLite[3] * 0.30, 1)
      g.setLineWidth(3)
      for i = 0, 13 do
        local yy = 40 + i * 78 + math.sin(t * 0.7 + i) * 6
        local xo = math.sin(t * 0.45 + i * 0.9) * 90
        g.line(160 + xo, yy, 1760 + xo, yy)
      end
      g.setBlendMode("alpha")
    end)
    g.setColor(1, 1, 1, 1)
    g.draw(surf, 0, 0)
  else
    -- sand: a darker offset copy under a pale fill reads as a lip
    g.setColor(C.sandDark[1], C.sandDark[2], C.sandDark[3], 1)
    g.draw(cv, 0, 4)
    setC(C.sand); g.draw(cv, 0, 0)
  end
end

-- An impulse zone: a conveyor or slope that pushes the ball. Drawn as
-- chevrons POINTING THE WAY IT PUSHES, because a coloured pad that moves
-- your ball without explaining itself is the most annoying thing a mini
-- golf hole can contain.
function M.drawZone(e, t)
  local g = love.graphics
  g.setColor(C.zone[1], C.zone[2], C.zone[3], 0.22)
  if e.kind == "circle" then
    g.circle("fill", e.x, e.y, e.r)
  elseif e.kind == "rect" then
    g.rectangle("fill", e.x - e.hw, e.y - e.hh, e.hw * 2, e.hh * 2)
  else
    g.polygon("fill", polyFrom(e))
  end

  local ang = math.rad(e.impulseAngle or 0)
  local dx, dy = math.cos(ang), math.sin(ang)
  local span = (e.kind == "circle") and e.r or math.max(e.hw or 30, e.hh or 30)
  g.setColor(C.zone[1], C.zone[2], C.zone[3], 0.75)
  g.setLineWidth(4)
  for i = 0, 2 do
    -- chevrons crawl along the push direction, so the motion itself
    -- shows which way the pad throws you
    local slide = ((t * 60 + i * 24) % 72) - 36
    local cx = e.x + dx * slide
    local cy = e.y + dy * slide
    local px, py = -dy, dx
    local sz = math.min(span * 0.5, 16)
    g.line(cx - px * sz - dx * sz, cy - py * sz - dy * sz, cx, cy)
    g.line(cx + px * sz - dx * sz, cy + py * sz - dy * sz, cx, cy)
  end
end

-- ── walls ─────────────────────────────────────────────────────────────
--
-- Timber rails: a cast shadow, a shaded body, a lit top face, wood grain
-- along the length, and a bright top edge. Six flat shapes that together
-- read as a plank with height and a light on it.
--
-- The grain runs along the LONG axis, which is what makes a rail look
-- like sawn timber rather than a brown box -- grain across the short side
-- would read as a stack of coins.

local WOOD_SEED = 12345
local function grainLines(e)
  local g = love.graphics
  if e.kind ~= "rect" then return end
  local horiz = e.hw > e.hh
  g.setLineWidth(1)
  local n = math.min(14, math.floor((horiz and e.hh or e.hw) / 5))
  for i = 1, n do
    -- deterministic offsets so the grain does not crawl between frames
    local seed = (e.x * 7 + e.y * 13 + i * 31) % 97 / 97
    local a = 0.06 + seed * 0.10
    g.setColor(0.16, 0.11, 0.06, a)
    if horiz then
      local yy = e.y - e.hh + (i / (n + 1)) * e.hh * 2
      local inset = e.hw * (0.02 + seed * 0.12)
      g.line(e.x - e.hw + inset, yy, e.x + e.hw - inset, yy)
    else
      local xx = e.x - e.hw + (i / (n + 1)) * e.hw * 2
      local inset = e.hh * (0.02 + seed * 0.12)
      g.line(xx, e.y - e.hh + inset, xx, e.y + e.hh - inset)
    end
  end
end

function M.drawWall(e)
  local g = love.graphics
  -- cast shadow, soft: two offset copies at low alpha beat one hard edge
  g.setColor(0, 0, 0, 0.20)
  if e.kind == "rect" then
    g.rectangle("fill", e.x - e.hw + SHX * 1.5, e.y - e.hh + SHY * 1.5, e.hw * 2, e.hh * 2)
  elseif e.kind == "circle" then
    g.circle("fill", e.x + SHX * 1.5, e.y + SHY * 1.5, e.r)
  else
    g.polygon("fill", polyFrom(e, SHX * 1.5, SHY * 1.5))
  end
  g.setColor(0, 0, 0, 0.26)
  if e.kind == "rect" then
    g.rectangle("fill", e.x - e.hw + SHX, e.y - e.hh + SHY, e.hw * 2, e.hh * 2)
  elseif e.kind == "circle" then
    g.circle("fill", e.x + SHX, e.y + SHY, e.r)
  else
    g.polygon("fill", polyFrom(e, SHX, SHY))
  end

  setC(C.wallSide)
  if e.kind == "rect" then
    g.rectangle("fill", e.x - e.hw, e.y - e.hh, e.hw * 2, e.hh * 2)
    setC(C.wallTop)
    g.rectangle("fill", e.x - e.hw, e.y - e.hh, e.hw * 2, e.hh * 2 - 7)
    grainLines(e)
    -- a lit top edge: the single brightest line, where the light hits
    g.setColor(0.68, 0.55, 0.36, 0.85); g.setLineWidth(3)
    g.line(e.x - e.hw, e.y - e.hh + 1.5, e.x + e.hw, e.y - e.hh + 1.5)
    setC(C.wallEdge); g.setLineWidth(2)
    g.rectangle("line", e.x - e.hw, e.y - e.hh, e.hw * 2, e.hh * 2)
  elseif e.kind == "circle" then
    g.circle("fill", e.x, e.y, e.r)
    setC(C.wallTop); g.circle("fill", e.x, e.y - 3, e.r * 0.92)
    g.setColor(0.68, 0.55, 0.36, 0.7); g.setLineWidth(3)
    g.arc("line", "open", e.x, e.y - 3, e.r * 0.92, math.pi * 1.12, math.pi * 1.88)
    setC(C.wallEdge); g.setLineWidth(2); g.circle("line", e.x, e.y, e.r)
  else
    g.polygon("fill", polyFrom(e))
    setC(C.wallTop); g.polygon("fill", polyFrom(e, 0, -5))
    setC(C.wallEdge); g.setLineWidth(2); g.polygon("line", polyFrom(e))
  end
end

-- ── the cup ───────────────────────────────────────────────────────────
--
-- Drawn LARGER than its 6px sensor on purpose: the sensor is honest
-- physics, but 6px on a TV across a room is invisible, and the player
-- aims at what they can see. main.lua's own hit test is matched to the
-- drawn size, so what looks like the hole IS the hole.

function M.drawCup(e, t)
  local g = love.graphics
  local R = math.max(e.r * 2.8, 18)

  -- a ground shadow puts the cup IN the turf
  g.setColor(0, 0, 0, 0.22)
  g.ellipse("fill", e.x + 2, e.y + 6, R * 1.30, R * 1.02)

  -- the liner, in three bands so the hole has visible depth: dark bottom,
  -- a lit far wall, and a bright rim on the near side only. That
  -- asymmetry is the entire depth cue.
  setC(C.cup)
  g.ellipse("fill", e.x, e.y, R, R * 0.84)
  g.setColor(0.13, 0.13, 0.15, 1)
  g.ellipse("fill", e.x, e.y - R * 0.14, R * 0.88, R * 0.62)
  g.setColor(0.03, 0.03, 0.04, 1)
  g.ellipse("fill", e.x, e.y + R * 0.10, R * 0.72, R * 0.48)

  setC(C.cupRim, 0.6); g.setLineWidth(3)
  g.arc("line", "open", e.x, e.y, R, math.pi * 1.05, math.pi * 1.95)
  g.setColor(1, 1, 1, 0.18); g.setLineWidth(2)
  g.arc("line", "open", e.x, e.y, R, math.pi * 0.1, math.pi * 0.9)

  -- ── flag ──
  -- Leaning, with the pole casting a shadow and the cloth rippling in
  -- two waves rather than one, so it looks caught by wind instead of
  -- wobbling on a hinge.
  local sway = math.sin(t * 1.15) * 4
  local top = e.y - 112
  g.setColor(0, 0, 0, 0.20); g.setLineWidth(5)
  g.line(e.x + 8, e.y + 3, e.x + sway + 14, top + 8)

  setC(C.flagPole); g.setLineWidth(5)
  g.line(e.x, e.y, e.x + sway, top)
  g.setColor(1, 1, 1, 0.9); g.setLineWidth(2)
  g.line(e.x - 1.5, e.y, e.x + sway - 1.5, top)
  -- the finial
  g.setColor(0.95, 0.9, 0.5); g.circle("fill", e.x + sway, top - 4, 5)

  -- cloth as a strip of quads, each following the wave
  local segs = 7
  local L, H = 62, 34
  for i = 0, segs - 1 do
    local u0, u1 = i / segs, (i + 1) / segs
    local w0 = math.sin(t * 3.1 + u0 * 5.2) * (5 + u0 * 11)
    local w1 = math.sin(t * 3.1 + u1 * 5.2) * (5 + u1 * 11)
    -- darker where the cloth turns away: fakes the fold
    local shade = 0.78 + 0.22 * math.cos(t * 3.1 + u0 * 5.2)
    g.setColor(C.flag[1] * shade, C.flag[2] * shade, C.flag[3] * shade)
    g.polygon("fill",
      e.x + sway + u0 * L, top + w0,
      e.x + sway + u1 * L, top + w1,
      e.x + sway + u1 * L, top + w1 + H * (1 - u1 * 0.45),
      e.x + sway + u0 * L, top + w0 + H * (1 - u0 * 0.45))
  end
end

-- Draw one hole. Order matters: hazards under walls, cup above the
-- ground but below the ball, which main.lua draws last.
function M.draw(level, t)
  local g = love.graphics
  -- BEFORE the ground: building a canvas binds a render target, and doing
  -- that halfway through the frame would drop whatever had been drawn so
  -- far into the wrong buffer.
  if hazBuilt ~= level then buildHazards(level) end
  M.drawGround(210, 40, 1500, 1000)
  drawHazard("water", level, t)
  drawHazard("sand", level, t)

  for _, e in ipairs(level.entities) do
    if e.id ~= "ball" and e.id ~= "goal" and not e.water and not e.sand then
      if e.impulse then M.drawZone(e, t)
      elseif not e.sensor then M.drawWall(e)
      end
    end
  end

  for _, e in ipairs(level.entities) do
    if e.id == "goal" then M.drawCup(e, t) end
  end
end

return M
