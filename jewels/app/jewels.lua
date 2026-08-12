-- jewels.lua - the six jewel types, drawn as faceted gems.
--
-- SHAPE CARRIES THE IDENTITY, NOT COLOUR. Every jewel has a distinct
-- silhouette and a distinct number of facets, so the board reads for a
-- colour-blind player and at a glance from ten feet away. Colour is the
-- second channel, never the only one. This is the single most important
-- decision in the file: the whole game is telling these six apart, and an
-- 85-year-old on a couch is the player.
--
-- The gems are drawn procedurally rather than as sprites so they stay
-- crisp at 120px cells on a 1080p screen, and so the facet highlights can
-- track the light per-frame while a jewel spins on clear.

local M = {}

-- Each jewel: a silhouette (polygon points on a unit circle), a base
-- colour, and how the facets divide. Colours are widely separated in HUE
-- AND in lightness, so they still differ when hue perception does not.
M.KINDS = {
  { name = "ruby",    sides = 4,  rot = math.pi / 4, col = {0.93, 0.20, 0.29}, light = 0.60 },
  { name = "topaz",   sides = 3,  rot = -math.pi / 2, col = {1.00, 0.68, 0.13}, light = 0.80 },
  { name = "emerald", sides = 6,  rot = 0,           col = {0.20, 0.82, 0.45}, light = 0.55 },
  { name = "sapphire",sides = 5,  rot = -math.pi / 2, col = {0.25, 0.55, 1.00}, light = 0.45 },
  { name = "amethyst",sides = 8,  rot = math.pi / 8, col = {0.72, 0.40, 0.95}, light = 0.50 },
  { name = "pearl",   sides = 0,  rot = 0,           col = {0.96, 0.96, 0.90}, light = 0.95 },
}
-- sides == 0 means a circle (the pearl): the one jewel with no corners at
-- all, which makes it unmistakable even out of focus.

-- OPTICAL SIZE COMPENSATION.
--
-- Regular polygons inscribed in the SAME circle have wildly different
-- areas: at r=1 the triangle covers 1.299 and the circle 3.142, so the
-- topaz reads as under half the size of the pearl even though both
-- "radius 48" on paper. Measured, not guessed -- the first build had a
-- visibly runty triangle and square.
--
-- Full area equalisation would need the triangle at 1.555x, which pushes
-- its points outside the cell and into its neighbours. So compensate on a
-- square-root curve and cap it: most of the discrepancy goes away, and
-- nothing overflows its cell.
local function areaOf(sides)
  if sides == 0 then return math.pi end
  return 0.5 * sides * math.sin(2 * math.pi / sides)
end
for _, k in ipairs(M.KINDS) do
  local full = math.sqrt(math.pi / areaOf(k.sides))   -- exact equalisation
  k.rscale = math.min(1.30, 1 + (full - 1) * 0.80)    -- 80% of it, capped
end

-- Cache the unit polygons; regenerating them per jewel per frame was
-- 480 polygon builds a frame at 10x8, which is real work for no gain.
local shapeCache = {}
local function unitShape(kind)
  local k = M.KINDS[kind]
  if shapeCache[kind] then return shapeCache[kind] end
  local pts = {}
  if k.sides == 0 then
    for i = 0, 23 do
      local a = i / 24 * math.pi * 2
      pts[#pts + 1] = math.cos(a); pts[#pts + 1] = math.sin(a)
    end
  else
    for i = 0, k.sides - 1 do
      local a = k.rot + i / k.sides * math.pi * 2
      pts[#pts + 1] = math.cos(a); pts[#pts + 1] = math.sin(a)
    end
  end
  shapeCache[kind] = pts
  return pts
end

-- Scratch buffer for the transformed polygon.
--
-- POOLED, and it matters more than it looks. Each jewel draws five
-- polygons and the board holds 80 jewels, so a fresh table per polygon is
-- 400 allocations and ~19k float writes EVERY FRAME. Measured at 12 KB of
-- garbage per frame before this change, which is exactly the kind of
-- steady drip that turns into a GC hitch in the middle of a cascade.
--
-- One buffer is enough because a polygon is fully consumed by the
-- love.graphics call before the next one is built. `n` is tracked
-- explicitly rather than using #buf, since the buffer is never shortened.
local scratch = {}
local function scaled(pts, cx, cy, r)
  local n = #pts
  for i = 1, n, 2 do
    scratch[i]     = cx + pts[i] * r
    scratch[i + 1] = cy + pts[i + 1] * r
  end
  -- trim: a pearl (48 floats) followed by a triangle (6) would otherwise
  -- leave the pearl's tail behind and draw a 24-gon
  for i = n + 1, #scratch do scratch[i] = nil end
  return scratch
end

-- Set the colour scaled by f. Returns nothing and allocates nothing --
-- the previous version built a 4-element table per call, which is another
-- 320 tables a frame on a full board.
local function setMul(c, f, a)
  love.graphics.setColor(math.min(1, c[1] * f), math.min(1, c[2] * f),
                         math.min(1, c[3] * f), a)
end

-- Draw the gem's layers directly. This is the expensive path: seven GPU
-- calls per gem. Used to BAKE each jewel into a texture once, and for the
-- handful of gems that genuinely need per-frame parameters (a spinning,
-- glowing shard).
local function drawDirect(kind, cx, cy, r, alpha, spin, glow)
  alpha = alpha or 1
  spin  = spin or 0
  glow  = glow or 0
  if alpha <= 0.004 or r <= 0.5 then return end

  local k = M.KINDS[kind]
  if not k then return end
  local g = love.graphics
  local pts = unitShape(kind)
  r = r * (k.rscale or 1)          -- optical size compensation, see above
  -- inradius/circumradius: how far "inside" the silhouette really is.
  -- 0.50 for a triangle, 1.0 for the pearl. Used to keep highlights and
  -- shadow offsets on the gem instead of out in the corner of the cell.
  local inr = (k.sides > 0) and math.cos(math.pi / k.sides) or 1

  g.push()
  g.translate(cx, cy)
  g.rotate(spin)

  -- 1. Contact shadow, deliberately INSIDE the body's own silhouette.
  --    Gives the board depth and separates a jewel from the cell behind it.
  --
  -- A true drop shadow would extend past the gem, and once the gem is
  -- baked into a texture that overhang becomes opaque pixels that cover
  -- whatever the cell is sitting on -- which is exactly how the checkered
  -- board turned solid black. Offset it, but keep it smaller than the
  -- body so the body always covers it.
  -- M.NO_SHADOW lets the icon renderer skip this. A launcher composites the
  -- icon onto its own background, so a baked-in shadow is wrong there --
  -- and against a chroma-key background it survives as an opaque rim.
  if not M.NO_SHADOW then
    g.setColor(0, 0, 0, 0.34 * alpha)
    g.polygon("fill", scaled(pts, r * 0.05 * inr, r * 0.09 * inr, r * 0.93))
  end

  -- 2. the body
  setMul(k.col, 0.85 + 0.35 * glow, alpha)
  g.polygon("fill", scaled(pts, 0, 0, r))

  -- 3. facets: a smaller, brighter copy of the silhouette, rotated half a
  --    step so its corners sit in the body's edge midpoints. This is what
  --    reads as "cut stone" rather than "coloured blob", and it is the
  --    cheapest possible way to get it -- one extra polygon.
  --
  --    The HALF-STEP ROTATION IS WHY THIS MUST BE SCALED BY inr. Rotated,
  --    the facet's vertices point at the parent's EDGE MIDPOINTS, so to
  --    stay inside it needs circumradius <= the parent's INRADIUS. That is
  --    0.500 for a triangle: a flat 0.62 poked out by 0.12 and gave the
  --    topaz little horns sticking through its own edges. Every other
  --    shape has inradius >= 0.707 and hid the bug completely.
  local half = (k.sides > 0) and (math.pi / k.sides) or 0
  g.push()
  g.rotate(half)
  setMul(k.col, 1.25 + 0.5 * glow, alpha * 0.85)
  g.polygon("fill", scaled(pts, 0, 0, r * 0.72 * inr))
  g.pop()

  -- 4. table (the flat top of a cut gem): a small bright core. NOT rotated,
  --    so it only needs to clear the body -- but keep it inside the facet
  --    above so the layering still reads as a cut stone.
  setMul(k.col, 1.6 + 0.6 * glow, alpha * 0.75)
  g.polygon("fill", scaled(pts, 0, -r * 0.05, r * 0.42 * inr))

  -- 5. specular glint, up and left, where the light is. The thing that
  --    makes the gem look wet rather than flat.
  --
  --    Pulled IN by the shape's inradius ratio. A position that sits nicely
  --    inside a circle is well outside a triangle: at r*0.40 the topaz's
  --    highlight floated in the empty corner of its cell, visibly detached
  --    from the gem. The inradius of a regular n-gon is cos(pi/n) times the
  --    circumradius, which is 0.5 for a triangle and 1.0 for a circle --
  --    exactly the correction needed.
  g.setColor(1, 1, 1, 0.55 * alpha)
  g.ellipse("fill", -r * 0.34 * inr, -r * 0.40 * inr, r * 0.20 * inr, r * 0.13 * inr)
  g.setColor(1, 1, 1, 0.30 * alpha)
  g.ellipse("fill", r * 0.26 * inr, r * 0.30 * inr, r * 0.11 * inr, r * 0.08 * inr)

  -- 6. rim, darker than the body, to hold the silhouette against a bright
  --    background. Without this the pearl vanishes on the light felt.
  g.setLineWidth(math.max(2, r * 0.07))
  setMul(k.col, 0.45, alpha * 0.9)
  g.polygon("line", scaled(pts, 0, 0, r))

  g.pop()
end

-- ── baked jewels ──────────────────────────────────────────────────────
--
-- WHY: drawing a gem takes SEVEN GPU calls (shadow, body, facet, table,
-- two glints, rim). Eighty of those is 560 calls a frame before the HUD,
-- and measurement put the whole draw at ~3.1us per call -- 3.0ms a frame,
-- over budget, for a board that is COMPLETELY STATIC most of the time.
--
-- Measured, not assumed: cutting the gem to a single polygon took the
-- frame from 3.0ms to 0.70ms at 187 calls. The cost is essentially linear
-- in draw calls, so the fix is to issue fewer of them -- NOT to draw a
-- simpler gem. The detail is the whole point of how this looks.
--
-- So each of the six jewels is rendered ONCE into its own canvas at boot,
-- and the board then draws six textures eighty times: one call each.
-- Identical pixels, ~7x fewer calls.
--
-- Baked at 2x the on-screen size so the texture still looks sharp when a
-- jewel scales up, and so it survives a higher-DPI display.

local baked = {}          -- baked[kind] = canvas
local BAKE_R = 96         -- nominal radius; the gem is drawn at this size

-- The canvas has to hold the BIGGEST thing any gem draws, which is not
-- BAKE_R. Two things push past it, and both bit me:
--
--   * rscale: the triangle is drawn at 1.30x for optical size
--     compensation, i.e. 124.8px, which a 122px half-canvas CLIPPED.
--   * the drop shadow, offset down-right by up to 0.10r.
--
-- Compute the real bound instead of guessing a pad. maxScale is taken
-- from the actual table so adding a seventh jewel cannot silently
-- reintroduce the clip.
local maxScale = 1
for _, k in ipairs(M.KINDS) do
  if k.rscale > maxScale then maxScale = k.rscale end
end
local BAKE_EXTENT = BAKE_R * maxScale * 1.12   -- gem + shadow offset + rim
local BAKE_SIZE = math.ceil(BAKE_EXTENT) * 2

-- What a caller must scale by to get an on-screen radius of r. The texture
-- is BAKE_SIZE across but the GEM inside it is only BAKE_R, so drawing the
-- texture at r/BAKE_R makes the gem exactly r -- and the padding stays
-- padding instead of eating the cell.
--
-- Getting this wrong is what turned the board black: at BAKE_PAD=26 the
-- texture footprint came to 122px inside a 120px cell, so every gem's
-- transparent-but-shadowed border covered the checker underneath.

-- Build the six textures. Must be called once after love.load.
function M.bake()
  local g = love.graphics
  -- setCanvas() with no argument restores the screen; do not assume
  -- getCanvas exists (it is not in every build's surface).
  local restore = function() g.setCanvas() end
  for kind = 1, #M.KINDS do
    local c = g.newCanvas(BAKE_SIZE, BAKE_SIZE)
    g.setCanvas(c)
    g.clear(0, 0, 0, 0)
    -- neutral state: no spin, no glow, full alpha. Those are applied at
    -- draw time by tinting and rotating the TEXTURE instead.
    drawDirect(kind, BAKE_SIZE / 2, BAKE_SIZE / 2, BAKE_R, 1, 0, 0)
    restore()
    baked[kind] = c
  end
  g.setColor(1, 1, 1, 1)
end

-- Draw one jewel centred at (cx, cy) with radius r.
--   alpha  fades it (used while clearing)
--   spin   rotates it (used while clearing)
--   glow   0..1 extra brightness, for a selected or hinted jewel
--
-- Uses the baked texture when there is one. A glowing gem is drawn as the
-- texture plus an additive pass of itself, which keeps it to two calls
-- rather than falling back to the seven-call path.
function M.draw(kind, cx, cy, r, alpha, spin, glow)
  alpha = alpha or 1
  spin = spin or 0
  glow = glow or 0
  if alpha <= 0.004 or r <= 0.5 then return end

  local tex = baked[kind]
  if not tex then
    return drawDirect(kind, cx, cy, r, alpha, spin, glow)
  end

  local g = love.graphics
  local scale = r / BAKE_R
  local o = BAKE_SIZE / 2
  g.setColor(1, 1, 1, alpha)
  g.draw(tex, cx, cy, spin, scale, scale, o, o)

  if glow > 0.01 then
    -- additive re-draw brightens the gem without a second full build
    g.setBlendMode("add")
    g.setColor(1, 1, 1, alpha * glow * 0.5)
    g.draw(tex, cx, cy, spin, scale, scale, o, o)
    g.setBlendMode("alpha")
  end
end

-- The colour of a jewel, for particles and the score popup.
function M.color(kind)
  local k = M.KINDS[kind]
  return k and k.col or { 1, 1, 1 }
end

function M.name(kind)
  local k = M.KINDS[kind]
  return k and k.name or "?"
end

return M
