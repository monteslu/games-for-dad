-- art.lua - the surfaces of the alley, generated at load.
--
-- TEXTURES ONLY. NO BAKED LIGHTING.
--
-- Minigolf bakes a directional light rig into six variants of every texture,
-- one per face direction, because it authors its meshes by hand and has
-- nowhere else to put the light. This game does not: it is built on the
-- default renderer, which already bakes a two-light rig per VERTEX from the
-- normal each builder computes. That is strictly better here -- it shades a
-- sphere and a cone by their real curvature, which a per-face variant cannot
-- do, and there is exactly one description of the lighting instead of two
-- that can disagree.
--
-- So these are FLAT ALBEDO. The renderer multiplies its shading over them.
-- Baking a second light rig in here would double-darken every face and
-- fight the shading that already works.
--
-- Generated rather than shipped: the noise is seeded, so the lane looks the
-- same on every run and in every screenshot test, and no binary art has to
-- live in the repo.

local M = {}

-- A small deterministic value noise, same generator the rest of the family
-- uses. Seeded: a texture that changes between runs makes a screenshot test
-- meaningless.
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

local function image(w, h, fn)
  local d = love.image.newImageData(w, h)
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local r, g, b, a = fn(x, y, w, h)
      d:setPixel(x, y, r, g, b, a or 1)
    end
  end
  local img = love.graphics.newImage(d)
  if img.setWrap then img:setWrap("repeat", "repeat") end
  return img
end

function M.makeTextures()
  local T = {}

  -- ── THE LANE ────────────────────────────────────────────────────────
  --
  -- A lane is 39 MAPLE AND PINE BOARDS laid edge to edge, running the
  -- length of the alley, and the board seams are the single most
  -- recognisable thing about the surface: they are what makes a bowling
  -- lane read as a bowling lane rather than as a brown floor. They also do
  -- real work here, because they run down-lane -- they give the eye a
  -- perspective cue for a 4600px runway that is otherwise a flat band, and
  -- they show the ball's hook against a straight reference.
  --
  -- The texture is TALL and NARROW, and the UV scale below maps its width
  -- across the lane's width exactly once. That is what keeps the boards
  -- parallel to the lane instead of merely being stripes at some angle.
  --
  -- AUTHORED SIDEWAYS. buildBox maps a top face's u to the box's X half-
  -- extent and v to its Z -- so on a lane laid along +z, u runs ACROSS the
  -- boards and v runs down the alley. The boards therefore have to vary
  -- along Y in this image (which becomes u... no: v is y). Concretely: this
  -- texture's ROWS are the boards, and its columns run down-lane, which is
  -- what puts the seams parallel to the ball's path instead of across it.
  local BOARDS = 39
  T.lane = image(512, 256, function(x, y, w, h)
    local bw = h / BOARDS
    local bi = math.floor(y / bw)
    local inBoard = (y - bi * bw) / bw

    -- Each board is cut from its own piece of timber: its own base tone and
    -- its own grain seed. Uniform boards read as wallpaper.
    --
    -- The tone spread is WIDE on purpose. A real lane is finished and
    -- nearly uniform, and that is exactly what does not survive here: at
    -- this camera the whole alley is ~120px tall and a narrow spread
    -- averaged out to a flat orange plank. Alternating light maple against
    -- darker pine is also true to a real lane, where the pine is laid where
    -- the ball lands and the maple at the pin deck.
    local tone = noise2(bi, 0, 7)
    local base = 0.72 + tone * 0.34

    -- Grain runs ALONG the board -- down-lane, which is +x in this image.
    local grain = fbm(x / 26, y / 2.2, 13 + bi * 3, 3)
    local fine  = fbm(x / 9, y / 1.3, 29 + bi, 2)
    local l = base * (0.90 + grain * 0.15 + fine * 0.06)

    -- The seam between boards: a thin dark line, darkest at the very edge.
    -- Strong, because at this distance a subtle seam is no seam at all.
    local edge = math.min(inBoard, 1 - inBoard)
    if edge < 0.075 then
      l = l * (0.42 + edge / 0.075 * 0.54)
    end

    -- The lane is OILED, and oil is why a bowling ball hooks. A subtle
    -- sheen down the middle third, fading toward the gutters, which is
    -- roughly how a house pattern is laid. Across the boards is y here.
    local mid = 1 - math.min(1, math.abs(y / h - 0.5) * 2.6)
    l = l * (1 + mid * 0.06)

    return 0.72 * l, 0.50 * l, 0.26 * l
  end)

  -- ── THE APPROACH / PIT ─────────────────────────────────────────────
  -- Darker boards, for the flat area behind the pins where the ball ends
  -- up. Same construction, cooler and dimmer so it reads as "not the lane".
  T.deck = image(128, 256, function(x, y, w, h)
    local bw = w / 12
    local bi = math.floor(x / bw)
    local inBoard = (x - bi * bw) / bw
    local tone = noise2(bi, 3, 19)
    local grain = fbm(x / 2.4, y / 22, 31 + bi * 5, 3)
    local l = (0.52 + tone * 0.12) * (0.90 + grain * 0.18)
    local edge = math.min(inBoard, 1 - inBoard)
    if edge < 0.06 then l = l * (0.58 + edge / 0.06 * 0.38) end
    return 0.46 * l, 0.34 * l, 0.22 * l
  end)

  -- ── THE GUTTER ──────────────────────────────────────────────────────
  -- Painted metal, scuffed. Deliberately plain and cool: the gutter's job
  -- is to be visibly NOT the lane, so a ball that drops in reads instantly
  -- as a miss.
  T.gutter = image(128, 128, function(x, y)
    local grain = fbm(x / 1.8, y / 14, 43, 2)
    local scuff = fbm(x / 19, y / 7, 47, 3)
    local l = 0.78 + (grain - 0.5) * 0.14 + (scuff - 0.5) * 0.22
    return 0.20 * l, 0.23 * l, 0.29 * l
  end)

  -- ── THE WALLS ───────────────────────────────────────────────────────
  -- Dark panelling, so the bright lane is the thing the eye goes to. A
  -- bowling alley is a dim room with a lit lane in it.
  T.wall = image(128, 128, function(x, y, w)
    local grain = fbm(x / 3, y / 30, 53, 3)
    local l = 0.86 + (grain - 0.5) * 0.20
    -- vertical panel joints
    local p = (x % 42) / 42
    if p < 0.04 then l = l * 0.72 end
    return 0.16 * l, 0.13 * l, 0.15 * l
  end)

  -- ── THE ROOM ────────────────────────────────────────────────────────
  --
  -- Everything here is DARK on purpose. A bowling alley is a dim room with
  -- a brightly lit lane in it, and that contrast is the whole look: make
  -- the room as bright as the lane and the lane stops being the subject.

  -- The floor of the room: dark patterned carpet, the way every alley on
  -- earth is carpeted. Busy at full brightness, but it sits at a fraction
  -- of the lane's value, so it reads as texture rather than as pattern.
  -- The FIGURE IS SMALL and the CONTRAST IS LOW, both learned by looking:
  -- a 4-across diamond at this tiling drew a bold checkerboard the size of
  -- the lane itself, and the eye went to the carpet instead of to the game.
  -- A carpet should be legible as a texture and invisible as a pattern.
  T.floor = image(128, 128, function(x, y, w, h)
    local n = fbm(x / 5, y / 5, 91, 4)
    local u, v = x / w, y / h
    local d = (math.abs(((u * 12) % 1) - 0.5) + math.abs(((v * 12) % 1) - 0.5))
    local fleck = fbm(x / 1.5, y / 1.5, 97, 2)
    local l = 0.55 + n * 0.36 + fleck * 0.20
    if d < 0.44 then
      return 0.085 * l, 0.070 * l, 0.125 * l
    end
    return 0.070 * l, 0.058 * l, 0.105 * l
  end)

  -- The ceiling: dark acoustic tile, faintly gridded.
  T.ceiling = image(128, 128, function(x, y, w, h)
    local n = fbm(x / 3, y / 3, 101, 3)
    local l = 0.80 + (n - 0.5) * 0.22
    local gx = (x % 64) / 64
    local gy = (y % 64) / 64
    if gx < 0.03 or gy < 0.03 then l = l * 0.66 end
    return 0.11 * l, 0.11 * l, 0.14 * l
  end)

  -- THE MASKING UNIT: the panel above and behind the pin deck. In a real
  -- alley it is the one decorated surface in the room, and it is directly
  -- behind the pins in every shot -- so a little colour here is what stops
  -- the far end of the lane being a black hole.
  -- Dim and low-contrast. This panel is DIRECTLY BEHIND the pins, and the
  -- pins are the thing that has to be read -- how many are standing, and
  -- which. A bold figure here competes with them at exactly the moment the
  -- picture matters most, which is why the first pass (hard red/violet
  -- chevrons) had to go. Enough warmth to stop the far end being a black
  -- hole; not enough to be looked at.
  T.masking = image(256, 128, function(x, y, w, h)
    local u, v = x / w, y / h
    local n = fbm(x / 6, y / 6, 107, 3)
    local band = math.abs(((u * 3 + v * 0.6) % 1) - 0.5) * 2
    local l = 0.62 + n * 0.30
    if band < 0.34 then
      return 0.150 * l, 0.105 * l, 0.135 * l
    elseif band < 0.62 then
      return 0.125 * l, 0.100 * l, 0.145 * l
    end
    return 0.100 * l, 0.090 * l, 0.130 * l
  end)

  -- ── THE BALL ────────────────────────────────────────────────────────
  --
  -- A polished marbled ball, with THREE FINGER HOLES.
  --
  -- The holes are the point. A bowling ball at this size is otherwise a
  -- dark circle, and a dark circle does not appear to ROTATE -- the ball
  -- rolls 4600px down the lane and the entire sense of it rolling, and of
  -- the hook biting, comes from features tracking across its surface. The
  -- marbling alone is too low-contrast to carry that; the holes are
  -- unmistakable.
  --
  -- u is longitude and v is latitude, matching buildSphere's UVs.
  local BS = 256
  -- The three holes sit in a small triangle on ONE face, the way a real
  -- drilled ball has them, rather than scattered over the sphere.
  local HOLES = {
    { u = 0.50, v = 0.34, r = 0.052 },
    { u = 0.44, v = 0.46, r = 0.048 },
    { u = 0.56, v = 0.46, r = 0.048 },
  }
  T.ball = image(BS, BS, function(x, y, w, h)
    local u, v = x / (w - 1), y / (h - 1)

    -- Deep marbled resin: swirls of a lighter tone through a dark body.
    local sw = fbm(x / 20, y / 20, 61, 4)
    local vein = fbm(x / 7 + sw * 3, y / 7, 67, 3)
    local l = 0.72 + sw * 0.42 + vein * 0.22
    local r, g, b = 0.20 * l, 0.10 * l, 0.34 * l

    -- The holes. Distance is measured with the longitude wrapped and
    -- SCALED BY sin(latitude): near the poles the u axis compresses, and
    -- without that scaling a hole smears into a band around the pole.
    local vt = v * math.pi
    local sp = math.max(0.15, math.sin(vt))
    for _, hl in ipairs(HOLES) do
      local du = math.abs(u - hl.u)
      if du > 0.5 then du = 1 - du end
      du = du * sp
      local dv = v - hl.v
      local d = math.sqrt(du * du + dv * dv)
      if d < hl.r then
        -- dark inside, with a lighter rim so it reads as a drilled hole
        -- and not as a smudge
        local t = d / hl.r
        local k = 0.10 + t * t * 0.28
        r, g, b = r * k, g * k, b * k
      elseif d < hl.r * 1.16 then
        r, g, b = r * 1.35, g * 1.35, b * 1.35
      end
    end
    return r, g, b
  end)

  -- ── THE PIN ─────────────────────────────────────────────────────────
  --
  -- White lacquer with the two red neck stripes, which is the standard
  -- USBC pin livery and the thing that makes a white object read as a
  -- BOWLING PIN specifically.
  --
  -- The stripes have to land at the neck, and the pin is six stacked hulls
  -- rather than one mesh -- so v does not run 0..1 over the whole pin, it
  -- runs 0..1 over EACH SECTION. Placing the stripes by v alone would put
  -- a pair of stripes on all six pieces. Instead main.lua gives each
  -- section its own strip of this texture via the skin's uv offset, and
  -- this image is authored as the pin's full height from base (v=0) to
  -- head (v=1).
  T.pin = image(64, 256, function(x, y, w, h)
    local v = y / (h - 1)
    -- lacquer: near-white, very slightly warm, with faint wear
    local wear = fbm(x / 5, y / 9, 71, 3)
    local l = 0.965 + (wear - 0.5) * 0.055
    local r, g, b = 0.98 * l, 0.97 * l, 0.94 * l

    -- THE TWO RED STRIPES GO ON THE NECK, NOT THE WAIST.
    --
    -- The pin's sections, in v: base 0.00-0.10, flare 0.10-0.30, belly
    -- 0.30-0.46, NECK 0.46-0.74, head flare 0.74-0.90, cap 0.90-1.00. The
    -- neck is the narrow waisted taper between the belly and the head, and
    -- a real pin carries its stripes at the TOP of it -- right under where
    -- the head flares back out, which on a USBC pin is about 10 inches up
    -- a 15 inch pin.
    --
    -- The first pass put them at 0.700/0.775, which straddles the neck/head
    -- join and reads as a band around the widest part of the shoulder --
    -- visibly too low, and the wrong silhouette entirely.
    local function stripe(c, halfWidth)
      return math.abs(v - c) < halfWidth
    end
    if stripe(0.640, 0.024) or stripe(0.706, 0.024) then
      r, g, b = 0.82 * l, 0.13 * l, 0.16 * l
    end

    -- A faint dirt line at the very base, where a pin sits on the deck.
    if v < 0.045 then
      local k = 0.80 + (v / 0.045) * 0.20
      r, g, b = r * k, g * k, b * k
    end
    return r, g, b
  end)

  return T
end

return M
