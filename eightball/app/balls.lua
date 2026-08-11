-- balls.lua - the fifteen object balls plus the cue ball.
--
-- Ball faces are GENERATED, not downloaded. A pool ball is a solid colour, a
-- white band, and a numeral -- all of which draw crisper at any resolution
-- than a stock photo, and none of which carry a licence question. The number
-- disc is drawn with the same Atkinson Hyperlegible the rest of the family
-- uses, so the digits are legible from the couch at ball size.

local M = {}

-- The standard set. 1-7 solid, 8 black, 9-15 striped, same colour per rank.
M.COLORS = {
  [1]  = {0.96, 0.78, 0.13},   -- yellow
  [2]  = {0.13, 0.29, 0.76},   -- blue
  [3]  = {0.85, 0.16, 0.16},   -- red
  [4]  = {0.42, 0.16, 0.58},   -- purple
  [5]  = {0.94, 0.47, 0.10},   -- orange
  [6]  = {0.10, 0.48, 0.24},   -- green
  [7]  = {0.55, 0.16, 0.16},   -- maroon
  [8]  = {0.07, 0.07, 0.08},   -- black
}
for n = 9, 15 do M.COLORS[n] = M.COLORS[n - 8] end

function M.isStripe(n) return n >= 9 and n <= 15 end

-- One 256x256 ball face per number, drawn once at load into a canvas.
--
-- The texture is used as EMISSION (see main.lua): the textured mesh format's
-- albedo sampler is not wired up in this engine, so emission is what actually
-- reaches the screen. That also gives the flat, even, glare-free look a
-- top-down aiming game wants.
-- Faces are painted pixel by pixel into ImageData, NOT drawn into a Canvas.
--
-- A Canvas here is the wrong tool twice over: 3Dream's getImage only passes a
-- value through to the sampler when type() reports "userdata", which a Canvas
-- built in this engine does not, and Canvas:newImageData() is not implemented
-- so there is no way to convert one. ImageData -> newImage is the path that
-- actually reaches the GPU.
--
-- Digits are drawn from a tiny 3x5 bitmap font rather than a TTF, because
-- rasterising text needs a canvas. At 256px per face each pixel is ~14px
-- wide, which is crisper than a scaled glyph anyway.
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

function M.makeFaces()
  local faces = {}
  local S = 128
  for n = 0, 15 do
    local d = love.image.newImageData(S, S)
    local c = M.COLORS[n] or { 1, 1, 1 }
    local white = { 0.95, 0.94, 0.90 }

    local function base(x, y)
      if n == 0 then return white end
      if M.isStripe(n) then
        -- a coloured band across the middle of UV space wraps the sphere as
        -- a ring, which is exactly what a striped ball looks like
        local v = y / S
        if v > 0.30 and v < 0.70 then return c end
        return white
      end
      return c
    end

    for y = 0, S - 1 do
      for x = 0, S - 1 do
        local col = base(x, y)
        d:setPixel(x, y, col[1], col[2], col[3], 1)
      end
    end

    -- two number discs, on opposite sides of the ball
    if n > 0 then
      for _, cx in ipairs({ S * 0.25, S * 0.75 }) do
        local cy, rad = S * 0.5, S * 0.19
        for y = math.floor(cy - rad), math.ceil(cy + rad) do
          for x = math.floor(cx - rad), math.ceil(cx + rad) do
            if x >= 0 and x < S and y >= 0 and y < S then
              local dx, dy = x - cx, y - cy
              if dx * dx + dy * dy <= rad * rad then
                d:setPixel(x, y, 0.97, 0.96, 0.93, 1)
              end
            end
          end
        end
        -- the numeral, centred in the disc
        local s = tostring(n)
        local gw, gh = 3, 5
        local px = math.floor(rad / 3.4)          -- pixel size of one cell
        local totalW = (#s * (gw + 1) - 1) * px
        local ox = cx - totalW / 2
        local oy = cy - (gh * px) / 2
        for i = 1, #s do
          local glyph = DIGITS[s:sub(i, i)]
          if glyph then
            for gy = 1, gh do
              for gx = 1, gw do
                if glyph[gy]:sub(gx, gx) == "1" then
                  for yy = 0, px - 1 do
                    for xx = 0, px - 1 do
                      local tx = math.floor(ox + ((i - 1) * (gw + 1) + gx - 1) * px + xx)
                      local ty = math.floor(oy + (gy - 1) * px + yy)
                      if tx >= 0 and tx < S and ty >= 0 and ty < S then
                        d:setPixel(tx, ty, 0.08, 0.08, 0.08, 1)
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

-- Rack the fifteen balls in the triangle, apex on the foot spot.
--
-- Real 8-ball racking rules: the 8 sits in the CENTRE of the third row, and
-- the two back corners must be one solid and one stripe. The rest is random,
-- which is what keeps openings from feeling identical every game.
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

-- Triangle positions, apex pointing at the cue ball (toward -x).
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
