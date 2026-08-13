-- art.lua - every surface in the game, generated at load.
--
-- Neverputt's courses read the way they do because the surfaces are
-- TEXTURED, not flat-filled: noisy green turf, a green/grey checkered band
-- around the rails, grey stone underneath. A flat vector fill of the same
-- colours looks like a diagram of a golf course rather than a golf course.
--
-- These are generated rather than copied. Neverputt's own art is GPL and
-- this game is not a Neverball derivative -- and generating them means the
-- noise is seeded, the checker aligns to the geometry, and nothing has to
-- ship in the repo.

local M = {}

-- A small deterministic value noise. Seeded, so the turf is identical on
-- every run and on every platform: the alternative is a course that looks
-- subtly different in a screenshot test than it did when it was tuned.
local function noise2(x, y, seed)
  local n = x * 374761393 + y * 668265263 + seed * 1274126177
  n = (n % 2147483647)
  n = (n * (n * n * 15731 + 789221) + 1376312589) % 2147483647
  return (n % 65536) / 65536
end

local function smoothNoise(x, y, seed)
  local ix, iy = math.floor(x), math.floor(y)
  local fx, fy = x - ix, y - iy
  fx = fx * fx * (3 - 2 * fx)
  fy = fy * fy * (3 - 2 * fy)
  local a = noise2(ix, iy, seed)
  local b = noise2(ix + 1, iy, seed)
  local c = noise2(ix, iy + 1, seed)
  local d = noise2(ix + 1, iy + 1, seed)
  return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
end

-- Fractal noise: a few octaves is the difference between "noise" and
-- something that reads as a MATERIAL.
local function fbm(x, y, seed, octaves)
  local v, amp, freq, norm = 0, 1, 1, 0
  for _ = 1, (octaves or 4) do
    v = v + smoothNoise(x * freq, y * freq, seed) * amp
    norm = norm + amp
    amp = amp * 0.5
    freq = freq * 2
  end
  return v / norm
end

local function image(size, fn)
  local d = love.image.newImageData(size, size)
  for y = 0, size - 1 do
    for x = 0, size - 1 do
      local r, g, b, a = fn(x, y, size)
      d:setPixel(x, y, r, g, b, a or 1)
    end
  end
  local img = love.graphics.newImage(d)
  if img.setWrap then img:setWrap("repeat", "repeat") end
  return img
end

-- ── BAKED LIGHTING ────────────────────────────────────────────────────
--
-- THIS ENGINE HAS NO RUNTIME 3D LIGHTING. render3d_gl.c says so in its
-- header -- "no camera, no matrix stack, no lighting" -- and it is not an
-- oversight: it exposes the GPU seam LOVE exposes and leaves the rest to
-- the cart. 3DreamEngine's lit shader never binds on this path, which is
-- provable: forcing its fragment output to solid magenta changes nothing
-- on screen. Lights, emission factors and albedo textures are all inert.
--
-- So the light has to be IN THE TEXTURE, which is exactly what Eight Ball
-- does ("the shading that makes these surfaces read as surfaces is baked
-- into the textures"). Every surface here therefore comes in several
-- versions, one per face direction, each pre-shaded for how much light a
-- face pointing that way would receive.
--
-- The rig is Neverputt's, from its own data/lights.txt and geom.c:
--   * two DIRECTIONAL lights at opposite high corners, (-8,+32,-8) and
--     (+8,+32,+8), so shading depends only on facing and not on where a
--     surface sits on a 1500px course
--   * colour-opposed, 1.0/0.8/0.8 warm against 0.8/1.0/0.8 cool-green, so
--     a rail's two sides differ in HUE as well as brightness -- which is
--     most of what makes geometry read as solid
--   * global ambient 0.2, so nothing goes fully black
local SUN_A = { -8, 32, -8 }
local SUN_B = { 8, 32, 8 }
local COL_A = { 1.00, 0.80, 0.80 }
local COL_B = { 0.80, 1.00, 0.80 }
local AMBIENT = 0.42

-- NORMALISED so the brightest face lands just under 1.0.
--
-- The rig's raw numbers put a top face at 1.60 and a side at 0.57, but the
-- texture clamps at 1.0 -- so the top was crushed flat and the DIFFERENCE
-- between a face pointing at the sky and one standing vertical was thrown
-- away. The green's edge band came out brighter than the green's top,
-- which is backwards and is exactly what makes a slab look like paper.
local SHADE_SCALE = 0.60

local function normalize(v)
  local l = math.sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3])
  return { v[1] / l, v[2] / l, v[3] / l }
end

-- How much light a face pointing `n` receives, per channel.
local function shadeFor(n)
  local a, b = normalize(SUN_A), normalize(SUN_B)
  local da = math.max(0, n[1] * a[1] + n[2] * a[2] + n[3] * a[3])
  local db = math.max(0, n[1] * b[1] + n[2] * b[2] + n[3] * b[3])
  local r = (AMBIENT + da * COL_A[1] * 0.72 + db * COL_B[1] * 0.72) * SHADE_SCALE
  local g = (AMBIENT + da * COL_A[2] * 0.72 + db * COL_B[2] * 0.72) * SHADE_SCALE
  local bl = (AMBIENT + da * COL_A[3] * 0.72 + db * COL_B[3] * 0.72) * SHADE_SCALE
  return r, g, bl
end

-- The six face directions a box has, plus the name each is stored under.
M.FACES = {
  top    = { 0, 1, 0 },
  bottom = { 0, -1, 0 },
  north  = { 0, 0, -1 },
  south  = { 0, 0, 1 },
  east   = { 1, 0, 0 },
  west   = { -1, 0, 0 },
}

function M.makeTextures()
  local T = {}
  local S = 128

  -- TURF. Mown grass: fine noise for the blades, plus wide bands for the
  -- mower stripes that make a green look like a green.
  local turfFn = function(x, y, size)
    local n = fbm(x / 6, y / 6, 11, 4)
    local fine = fbm(x / 2.2, y / 2.2, 23, 2)
    -- stripes run diagonally so they never line up with the rails
    local band = math.sin((x + y) * math.pi / 32) * 0.5 + 0.5
    local l = 0.72 + n * 0.30 + fine * 0.16 + band * 0.10
    return 0.16 * l, 0.52 * l, 0.20 * l
  end
  T.turf = image(S, turfFn)

  -- THE WALLS ARE CONCRETE.
  --
  -- I had these as a green/grey CHECKER, which was wrong: Neverputt's
  -- checkered "edge-green" is decorative course trim used a handful of
  -- times, while the material actually on its walls is turf-grey -- used
  -- 43 times in a single hole against edge-green's 8. Measured, turf-grey
  -- is flat grey concrete: mean luminance 126, standard deviation 3.7,
  -- a fine speckle with no pattern whatsoever.
  --
  -- So: fine high-frequency grain, a barely-there mottle to break up large
  -- faces, and no repeating figure at all. A pattern on a wall reads as
  -- decoration; concrete reads as a wall.
  local edgeFn = function(x, y)
    local grain = fbm(x / 1.6, y / 1.6, 37, 2)
    local mottle = fbm(x / 22, y / 22, 41, 3)
    local l = 0.94 + (grain - 0.5) * 0.10 + (mottle - 0.5) * 0.13
    -- very slightly cool, the way cast concrete photographs
    return 0.50 * l, 0.505 * l, 0.515 * l
  end
  T.edge = image(S, edgeFn)

  -- STONE. The apron under the green.
  local stoneFn = function(x, y)
    local n = fbm(x / 7, y / 7, 53, 4)
    local l = 0.62 + n * 0.42
    return 0.46 * l, 0.46 * l, 0.48 * l
  end
  T.stone = image(S, stoneFn)

  -- SAND. Bright, warm, and finer-grained than the turf.
  local sandFn = function(x, y)
    local n = fbm(x / 4, y / 4, 71, 4)
    local l = 0.78 + n * 0.34
    return 0.86 * l, 0.76 * l, 0.52 * l
  end
  T.sand = image(S, sandFn)

  -- WATER. Broad slow ripples rather than noise, so it reads as a surface
  -- and not as static.
  local waterFn = function(x, y)
    local w = math.sin(x * math.pi / 21 + math.cos(y * math.pi / 33) * 1.7)
    local n = fbm(x / 9, y / 9, 89, 3)
    local l = 0.74 + w * 0.13 + n * 0.24
    return 0.10 * l, 0.34 * l, 0.66 * l
  end
  T.water = image(S, waterFn)

  -- IMPULSE PAD. Chevrons, so the direction of the push is legible.
  -- Chevrons on GREEN, not a solid yellow field. A full-strength pad the
  -- size of a bunker dominates the hole and reads as terrain rather than
  -- as a marking painted on the turf; the arrows carry the meaning, so the
  -- ground between them stays grass.
  local zoneFn = function(x, y, size)
    local v = ((x + math.abs(y - size / 2)) % 34) / 34
    local n = fbm(x / 6, y / 6, 11, 4)
    if v < 0.34 then
      local l = 0.92 + n * 0.16
      return 0.95 * l, 0.76 * l, 0.22 * l
    end
    local l = 0.72 + n * 0.30
    return 0.16 * l, 0.52 * l, 0.20 * l
  end
  T.zone = image(S, zoneFn)

  -- FLAG. Flat red; it is small and only needs to read as a pin.
  T.flag = image(16, function() return 0.86, 0.20, 0.22 end)

  -- THE BALL.
  --
  -- Dimples ALONE do not work: the ball is under twenty pixels across and
  -- a 392-dimple lattice lands under a pixel per dimple, so it averages to
  -- flat white and the roll is invisible. Neverputt's stock ball is a 4x2
  -- black/white CHECKER for exactly this reason -- big blocks are the only
  -- thing that survives at this size.
  --
  -- So: dimples for texture up close, quadrant tinting for legibility at
  -- distance. u is longitude and v is latitude, matching buildSphere.
  local BS = 256
  local DIMPLES, GOLDEN = 220, math.pi * (3 - math.sqrt(5))
  local dim = {}
  for i = 0, DIMPLES - 1 do
    local yy = 1 - (i / (DIMPLES - 1)) * 2
    local rr = math.sqrt(math.max(0, 1 - yy * yy))
    local th = GOLDEN * i
    dim[#dim + 1] = { math.cos(th) * rr, yy, math.sin(th) * rr }
  end
  local SPACING = math.acos(1 - 2 / DIMPLES)
  local RAD = SPACING * 0.62

  T.ball = image(BS, function(x, y, size)
    local phi = (y / (size - 1)) * math.pi
    local th = (x / (size - 1)) * math.pi * 2
    local sp = math.sin(phi)
    local nx, ny, nz = sp * math.cos(th), math.cos(phi), sp * math.sin(th)

    local best = math.huge
    for i = 1, #dim do
      local p = dim[i]
      local dot = nx * p[1] + ny * p[2] + nz * p[3]
      if dot > 1 then dot = 1 elseif dot < -1 then dot = -1 end
      local ang = math.acos(dot)
      if ang < best then best = ang end
    end

    local shade = 1
    if best < RAD then
      local t = best / RAD
      shade = 1 - math.sqrt(math.max(0, 1 - t * t)) * 0.30
    end

    local l = 0.93 * shade
    local r, g, b = l, l, l * 1.01
    -- the quadrant tint that carries the rotation at a dozen pixels
    local uu = math.floor((x / size) * 4) % 2
    local vv = math.floor((y / size) * 2) % 2
    if uu == vv then
      -- STRONG. At 0.80 the tint measured only 5 levels of variance across
      -- the ball on screen -- technically textured, visually a white dot,
      -- which is the exact failure this pattern exists to prevent.
      -- Neverputt's stock ball goes all the way to 50/50 black and white.
      r, g, b = r * 0.52, g * 0.60, b * 0.80
    end
    return r, g, b
  end)

  -- ── the lit variants ────────────────────────────────────────────────
  --
  -- Each surface that appears on more than one face direction gets a
  -- version per direction, pre-multiplied by that direction's light. The
  -- ball is excluded: it is a sphere, so no single face normal describes
  -- it, and its own texture already carries dimples and quadrants.
  local function litVariants(name, fn, size)
    local out = {}
    for dir, n in pairs(M.FACES) do
      local lr, lg, lb = shadeFor(n)
      out[dir] = image(size or S, function(x, y, sz)
        local r, g, b = fn(x, y, sz)
        return math.min(1, r * lr), math.min(1, g * lg), math.min(1, b * lb)
      end)
    end
    return out
  end

  T.lit = {
    turf  = litVariants("turf", turfFn),
    edge  = litVariants("edge", edgeFn),
    stone = litVariants("stone", stoneFn),
    sand  = litVariants("sand", sandFn),
    water = litVariants("water", waterFn),
    zone  = litVariants("zone", zoneFn),
  }

  return T
end

return M
