-- balls.lua - the fifteen object balls plus the cue ball, and the table's
-- surface textures.
--
-- Everything here is GENERATED. A pool ball is a solid colour, a white band
-- and a numeral; felt is a weave; a rail is grain. All of them draw crisper
-- at any resolution than a stock photo and none carry a licence question.
--
-- The balls also carry BAKED SPHERICAL SHADING with a specular highlight.
-- That is what makes them read as balls rather than as flat discs: these
-- spheres are small on screen under one overhead lamp, and a highlight
-- painted in the right place sells the roundness better than a real light
-- that has to survive the whole material pipeline. It is a function of the
-- UV, so it costs nothing at runtime.

local M = {}

-- The standard set. 1-7 solid, 8 black, 9-15 striped, same colour per rank.
M.COLORS = {
  [1]  = {0.98, 0.80, 0.09},   -- yellow
  [2]  = {0.09, 0.24, 0.78},   -- blue
  [3]  = {0.88, 0.11, 0.11},   -- red
  [4]  = {0.38, 0.11, 0.56},   -- purple
  [5]  = {0.96, 0.45, 0.06},   -- orange
  [6]  = {0.05, 0.45, 0.20},   -- green
  [7]  = {0.50, 0.11, 0.13},   -- maroon
  [8]  = {0.06, 0.06, 0.07},   -- black
}
for n = 9, 15 do M.COLORS[n] = M.COLORS[n - 8] end

function M.isStripe(n) return n >= 9 and n <= 15 end

-- A 3x5 bitmap font, stored the right way round. Rasterising a TTF needs a
-- canvas, and at ball size a crisp block numeral out-reads a scaled glyph.

local DIGITS = {
  ["0"] = { "111", "101", "101", "101", "111" },
  ["1"] = { "010", "110", "010", "010", "111" },
  ["2"] = { "111", "001", "111", "100", "111" },
  ["3"] = { "111", "001", "111", "001", "111" },
  ["4"] = { "101", "101", "111", "001", "001" },
  ["5"] = { "111", "100", "111", "001", "111" },
  ["6"] = { "111", "100", "111", "101", "111" },
  ["7"] = { "111", "001", "010", "010", "010" },
  ["8"] = { "111", "101", "111", "101", "111" },
  ["9"] = { "111", "101", "111", "001", "111" },
}

-- Baked shading for a point on the sphere, from its UV.
--
-- The lamp is above and slightly toward the viewer, so the top of a ball is
-- lit, the bottom falls away, and a tight specular sits above centre. The
-- ambient floor is deliberately high: this is a game for someone who has to
-- tell a 3 from a 6 across a room, and a physically honest shadow side
-- would make half of every ball unreadable.
-- Pool balls are polished phenolic resin: a hard, near-dielectric surface
-- with a high-gloss clearcoat. Three separate terms, because a real one has
-- three and dropping any of them is what makes a rendered ball look like
-- plastic:
--
--   DIFFUSE     the body colour, Lambertian, with a high ambient floor.
--               Physically the shadow side would go much darker, but this
--               is a game for someone reading a 3 from a 6 across a room.
--   SPECULAR    a TIGHT highlight. Gloss lives in the exponent: a broad
--               lobe reads as chalk, a tight one as varnish. The reference
--               implementations land around ^30 after a smoothstep gate,
--               which is much tighter than the single broad ^46 lobe this
--               used to have with no gate at all.
--   FRESNEL/RIM at grazing angles a dielectric reflects far more light, so
--               the edge of a sphere picks up a bright rim. This is what
--               separates a ball from the cloth behind it and reads as
--               roundness rather than a painted circle.
local function shade(u, v)
  local phi = v * math.pi
  local th  = u * math.pi * 2
  local nx = math.sin(phi) * math.cos(th)
  local ny = math.cos(phi)
  local nz = math.sin(phi) * math.sin(th)

  local lx, ly, lz = -0.35, 0.90, 0.26
  local ndl = nx * lx + ny * ly + nz * lz
  if ndl < 0 then ndl = 0 end
  local diff = 0.56 + 0.44 * ndl

  -- BOUNCE LIGHT off the cloth, which is the detail that separates a ball
  -- resting ON a surface from a ball floating above one. Light reflects up
  -- from the felt and relights the underside, so the darkest band on a real
  -- ball is NOT the bottom edge -- it sits slightly above it, with a
  -- faintly brighter core shadow below. Modelled as a second, weak,
  -- upward-pointing light tinted with the cloth's own green, since bounced
  -- light carries the colour of what it bounced off.
  local ndb = -ny                     -- how much this point faces the cloth
  if ndb < 0 then ndb = 0 end
  diff = diff + ndb * ndb * 0.13

  -- tight gloss: gate the lobe, then sharpen it
  local s = (ndl - 0.5) / 0.5
  if s < 0 then s = 0 elseif s > 1 then s = 1 end
  s = s * s * (3 - 2 * s)                 -- smoothstep(0.5, 1.0, ndl)
  local spec = s ^ 30 * 0.95

  -- Fresnel rim. The camera looks straight down (+y), so the view-facing
  -- term is simply ny: 1 at the pole under the camera, 0 at the silhouette.
  -- Schlick's approximation with the edge weighted by how lit that edge is,
  -- so the rim does not glow on the shadow side.
  local face = ny
  if face < 0 then face = -face end
  local fres = (1 - face) ^ 5
  -- Kept deliberately gentle. A strong Fresnel term on a light-coloured
  -- ball stops reading as a glossy edge and starts reading as a halo, and
  -- the white/yellow balls are where that shows up first.
  local rim = fres * (0.06 + 0.20 * ndl)

  return diff, spec + rim
end

function M.makeFaces()
  local faces = {}
  local S = 192
  for n = 0, 15 do
    local d = love.image.newImageData(S, S)
    local c = M.COLORS[n] or { 1, 1, 1 }
    local white = { 0.96, 0.95, 0.91 }

    -- The sphere is unwrapped with u around the equator and v pole to pole,
    -- so a horizontal band in UV space wraps the ball as a ring, which is
    -- exactly what a stripe is.
    local function base(x, y)
      if n == 0 then return white end
      if M.isStripe(n) then
        local v = y / S
        if v > 0.295 and v < 0.705 then return c end
        return white
      end
      return c
    end

    for y = 0, S - 1 do
      for x = 0, S - 1 do
        local col = base(x, y)
        local diff, spec = shade((x + 0.5) / S, (y + 0.5) / S)
        d:setPixel(x, y,
          math.min(1, col[1] * diff + spec),
          math.min(1, col[2] * diff + spec),
          math.min(1, col[3] * diff + spec), 1)
      end
    end

    -- The number disc goes AT THE POLE, not on the equator.
    --
    -- The camera looks straight down, so what it sees of every ball is the
    -- +Y pole -- and in this unwrap the pole is v=0, the top edge of the
    -- texture, where the whole u range collapses to a single point. A disc
    -- painted at the equator (v=0.5) sits on the ball's SIDE and reads as a
    -- smear at the rim, which is exactly what it did.
    --
    -- So the disc is drawn in POLAR terms: every texel within an angular
    -- radius of the pole. Because u wraps all the way around there, this is
    -- a horizontal BAND across the top of the texture, and it lands on the
    -- ball as a clean circle facing the camera. A second band at the bottom
    -- puts a number on the other pole, so a rolled ball still shows one.
    -- ── the number circles ────────────────────────────────────────────
    --
    -- At the EQUATOR, in a plain UV rect. This is how real pool-ball models
    -- are built and the reason is a hard property of the projection, not a
    -- preference: an equirectangular unwrap has singularities at the poles
    -- where the entire u range collapses to a point, so a glyph placed
    -- there is drawn once per revolution and pinches into a smear. Detail
    -- belongs at the equator, where distortion is minimal.
    --
    -- (This file previously painted the numbers AT the pole, to face a
    -- straight-down camera. That is unfixable by any amount of sign
    -- flipping -- the glyph repeats because u wraps. The camera tilts
    -- instead; see CAM_TILT in main.lua.)
    --
    -- TWO circles, half a turn apart, exactly like a real ball.
    --
    -- A ring of six was tried and looked like a die: three visible at once
    -- on the same ball, and the 8 staring back with two circles side by
    -- side. A real pool ball has two, and the answer to "can the player see
    -- one" is the camera angle, not more numbers.
    if n > 0 then
      local rad = S * 0.125                 -- circle radius, in texels
      local radU = rad / 2                  -- u carries 2x the arc of v
      for _, cu in ipairs({ 0.25, 0.75 }) do
        local cx, cy = cu * S, S * 0.5
        for y = math.floor(cy - rad), math.ceil(cy + rad) do
          for x = math.floor(cx - radU), math.ceil(cx + radU) do
            if x >= 0 and x < S and y >= 0 and y < S then
              local dx, dy = (x - cx) / radU, (y - cy) / rad
              if dx * dx + dy * dy <= 1 then
                local diff, spec = shade((x + 0.5) / S, (y + 0.5) / S)
                d:setPixel(x, y,
                  math.min(1, 0.97 * diff + spec),
                  math.min(1, 0.96 * diff + spec),
                  math.min(1, 0.93 * diff + spec), 1)
              end
            end
          end
        end

        -- the numeral, squashed in u to match the circle
        local str = tostring(n)
        local gw, gh = 3, 5
        local py = math.max(3, math.floor(rad * 1.15 / gh))
        local px = math.max(2, math.floor(py * 0.5))
        local totalW = (#str * (gw + 1) - 1) * px
        local ox = cx - totalW / 2
        local oy = cy - (gh * py) / 2
        for i = 1, #str do
          local glyph = DIGITS[str:sub(i, i)]
          if glyph then
            for gy = 1, gh do
              for gx = 1, gw do
                if glyph[gy]:sub(gx, gx) == "1" then
                  for yy = 0, py - 1 do
                    for xx = 0, px - 1 do
                      local tx = math.floor(ox + ((i - 1) * (gw + 1) + gx - 1) * px + xx)
                      local ty = math.floor(oy + (gy - 1) * py + yy)
                      if tx >= 0 and tx < S and ty >= 0 and ty < S then
                        local dd = shade((tx + 0.5) / S, (ty + 0.5) / S)
                        d:setPixel(tx, ty, 0.09 * dd, 0.09 * dd, 0.10 * dd, 1)
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end

    faces[n] = love.graphics.newImage(d)
  end
  return faces
end

-- ── surface textures ──────────────────────────────────────────────────

-- Woven cloth. Real felt has a weave and takes the light unevenly, and a
-- perfectly flat green is the single biggest reason a rendered table reads
-- as a diagram rather than as a table.
function M.makeFelt(baseColor)
  local S = 256
  local d = love.image.newImageData(S, S)
  for y = 0, S - 1 do
    for x = 0, S - 1 do
      local weave = math.sin(x * 0.7) * 0.5 + math.sin(y * 0.7) * 0.5
      local n = (love.math.noise(x * 0.14, y * 0.14) - 0.5) * 2
      local k = 1 + weave * 0.020 + n * 0.055
      d:setPixel(x, y,
        math.max(0, math.min(1, baseColor[1] * k)),
        math.max(0, math.min(1, baseColor[2] * k)),
        math.max(0, math.min(1, baseColor[3] * k)), 1)
    end
  end
  return love.graphics.newImage(d)
end

-- Stained hardwood for the rails.
function M.makeWood()
  local S = 256
  local d = love.image.newImageData(S, S)
  for y = 0, S - 1 do
    for x = 0, S - 1 do
      local g = love.math.noise(x * 0.045, y * 0.5)
      local rings = math.sin((x * 0.09 + g * 2.2) * 3.0) * 0.5 + 0.5
      local k = 0.70 + rings * 0.36 + (g - 0.5) * 0.20
      d:setPixel(x, y,
        math.max(0, math.min(1, 0.40 * k)),
        math.max(0, math.min(1, 0.205 * k)),
        math.max(0, math.min(1, 0.095 * k)), 1)
    end
  end
  return love.graphics.newImage(d)
end

-- Rack the fifteen balls in the triangle, apex on the foot spot.
--
-- Real 8-ball racking: the 8 sits in the CENTRE of the third row, and the
-- two back corners must be one solid and one stripe. The rest is random,
-- which keeps openings from feeling identical every game.
function M.rackOrder(rng)
  local solids, stripes = {}, {}
  for n = 1, 7 do solids[#solids + 1] = n end
  for n = 9, 15 do stripes[#stripes + 1] = n end
  local function shuffle(t)
    for i = #t, 2, -1 do
      local j = rng(i)
      t[i], t[j] = t[j], t[i]
    end
  end
  shuffle(solids); shuffle(stripes)

  local slots = {}
  slots[5] = 8                       -- centre of the third row
  slots[11] = table.remove(solids)   -- back-left corner: a solid
  slots[15] = table.remove(stripes)  -- back-right corner: a stripe

  local rest = {}
  for _, n in ipairs(solids) do rest[#rest + 1] = n end
  for _, n in ipairs(stripes) do rest[#rest + 1] = n end
  shuffle(rest)
  local k = 1
  for i = 1, 15 do
    if not slots[i] then slots[i] = rest[k]; k = k + 1 end
  end
  return slots
end

-- dir = +1 for a rack growing toward +x, -1 toward -x (the apex always
-- points at the cue ball).
function M.rackPositions(footX, footZ, r, dir)
  dir = dir or 1
  local pos, i = {}, 0
  local dx = r * 1.74            -- row spacing for touching spheres
  local dz = r * 2.02
  for row = 0, 4 do
    for k = 0, row do
      i = i + 1
      pos[i] = {
        x = footX + row * dx * dir,
        z = footZ + (k - row / 2) * dz,
      }
    end
  end
  return pos
end

return M
