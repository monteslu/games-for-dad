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

function M.makeTextures()
  local T = {}
  local S = 128

  -- TURF. Mown grass: fine noise for the blades, plus wide bands for the
  -- mower stripes that make a green look like a green.
  T.turf = image(S, function(x, y, size)
    local n = fbm(x / 6, y / 6, 11, 4)
    local fine = fbm(x / 2.2, y / 2.2, 23, 2)
    -- stripes run diagonally so they never line up with the rails
    local band = math.sin((x + y) * math.pi / 32) * 0.5 + 0.5
    local l = 0.72 + n * 0.30 + fine * 0.16 + band * 0.10
    return 0.16 * l, 0.52 * l, 0.20 * l
  end)

  -- EDGE. The checkered band on the rails, straight from Neverputt's
  -- vocabulary: alternating turf-green and pale stone. Bold, because a
  -- rail is only a few dozen pixels tall on screen and subtle banding
  -- would vanish.
  -- FOUR squares across, not eight. A rail is only a few dozen pixels tall
  -- on screen; at eight the checker collapses into a grey dither that
  -- reads as a flat sheet lying on the grass rather than as a solid kerb
  -- with a top and two sides. Neverputt's own edge texture is similarly
  -- coarse, and coarse is what survives.
  T.edge = image(S, function(x, y, size)
    local c = (math.floor(x / (size / 4)) + math.floor(y / (size / 4))) % 2
    local n = fbm(x / 5, y / 5, 37, 3)
    if c == 0 then
      local l = 0.74 + n * 0.26
      return 0.17 * l, 0.46 * l, 0.20 * l
    else
      local l = 0.80 + n * 0.24
      return 0.86 * l, 0.85 * l, 0.79 * l
    end
  end)

  -- STONE. The apron under the green.
  T.stone = image(S, function(x, y)
    local n = fbm(x / 7, y / 7, 53, 4)
    local l = 0.62 + n * 0.42
    return 0.46 * l, 0.46 * l, 0.48 * l
  end)

  -- SAND. Bright, warm, and finer-grained than the turf.
  T.sand = image(S, function(x, y)
    local n = fbm(x / 4, y / 4, 71, 4)
    local l = 0.78 + n * 0.34
    return 0.86 * l, 0.76 * l, 0.52 * l
  end)

  -- WATER. Broad slow ripples rather than noise, so it reads as a surface
  -- and not as static.
  T.water = image(S, function(x, y)
    local w = math.sin(x * math.pi / 21 + math.cos(y * math.pi / 33) * 1.7)
    local n = fbm(x / 9, y / 9, 89, 3)
    local l = 0.74 + w * 0.13 + n * 0.24
    return 0.10 * l, 0.34 * l, 0.66 * l
  end)

  -- IMPULSE PAD. Chevrons, so the direction of the push is legible.
  -- Chevrons on GREEN, not a solid yellow field. A full-strength pad the
  -- size of a bunker dominates the hole and reads as terrain rather than
  -- as a marking painted on the turf; the arrows carry the meaning, so the
  -- ground between them stays grass.
  T.zone = image(S, function(x, y, size)
    local v = ((x + math.abs(y - size / 2)) % 34) / 34
    local n = fbm(x / 6, y / 6, 11, 4)
    if v < 0.34 then
      local l = 0.92 + n * 0.16
      return 0.95 * l, 0.76 * l, 0.22 * l
    end
    local l = 0.72 + n * 0.30
    return 0.16 * l, 0.52 * l, 0.20 * l
  end)

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

  return T
end

return M
