-- course.lua - a hole, as real 3D geometry AND real 3D collision.
--
-- One source of truth. Every entity in levels.lua produces BOTH a mesh and
-- a Box3D shape from the same numbers, so what you see is exactly what the
-- ball hits. The previous build kept a 2D Box2D world beside a 3D render
-- and derived the ball's spin from how far it had travelled; that is the
-- thing this file exists to stop doing.
--
-- THE MAPPING. Level data is in cart pixels: x right, y DOWN, on a
-- 1500x1000 course offset to (210, 40). The world is x right, y UP,
-- z toward the bottom of the screen:
--
--     world_x = (px - 960) / U
--     world_z = (py - 540) / U
--     world_y = height above the green
--
-- Physics runs in PIXELS, not world units: b3.set_meter maps them, and
-- keeping the simulation in the level data's own units means the 22 hole
-- layouts need no rescaling and the tuning numbers stay readable.

local dream = require("3DreamEngine.init")
local art = require("art")

local M = {}

local U = 120                       -- px per world unit
M.U = U

local BALL_R = 11.5                 -- ball radius, in cart pixels
M.BALL_R = BALL_R

-- Heights, in cart pixels so they sit in the same units as the layouts.
-- Rail height. Tall enough that the SIDE faces are a real part of the
-- picture from this camera: at 34 the rails read as flat tape on the
-- grass, because almost all of what you see is their top face.
local WALL_H  = 52                  -- timber rail height
-- How thick the green's slab is. Thick enough that its SIDE faces are a
-- visible band from this camera: with the surrounding apron gone, that
-- band is the only thing giving the course a physical edge, and at 10px
-- the green read as a sheet of paper lying in the sky.
local FLOOR_T = 46                  -- how thick the green's slab is
local CUP_R   = BALL_R * 2.2        -- the cup, sized off the BALL
M.CUP_R = CUP_R

local function wx(px) return (px - 960) / U end
local function wz(py) return (py - 540) / U end
M.wx, M.wz = wx, wz

-- ── materials ─────────────────────────────────────────────────────────

local mat = {}
local tex = {}

function M.initMaterials()
  tex = art.makeTextures()

  -- Textures go on the MESH, not only the material: 3DreamEngine assigns
  -- through the material, but this engine's 3D meshes carry their own
  -- texture and the material's sampler is never read. Both are set, and
  -- buildMesh() below does the mesh half.
  -- EMISSION IS AMBIENT, NOT THE WHOLE PICTURE.
  --
  -- The texture has to go through emission because this engine does not
  -- wire the albedo sampler for the lit mesh format. But at an emission
  -- factor of 1.0 every surface emits its texture at FULL strength, which
  -- means it is fullbright: the lights add almost nothing on top, every
  -- face lands at the same value regardless of which way it points, and
  -- the whole course reads flat and lifeless however good the lighting
  -- rig is.
  --
  -- So emission carries about a third -- Neverputt's own ambient is 0.7
  -- against a 1.0 diffuse, a similar ratio -- and the directional lights
  -- supply the rest. That is what makes a rail's top face brighter than
  -- its sides, which is what makes it look like a solid object.
  local function texMat(name, tx, rough, metal, emit)
    local m = dream:newMaterial(name)
    m:setColor(1, 1, 1, 1)
    m:setEmissionTexture(tx)
    -- emission = texel * factor + colour, so the COLOUR stays black or it
    -- is added to every texel and washes the texture out to white
    m:setEmission(0, 0, 0)
    -- FULL emission. With no runtime lighting on this path, emission is
    -- the ONLY thing that lights the scene -- dropping it to 0.02 to "let
    -- the lights do the work" turned the whole course black, because there
    -- are no lights. The per-face light levels are baked into the textures
    -- themselves (art.lua), so full strength here is correct.
    local e = emit or 1.0
    m:setEmissionFactor(e, e, e)
    m:setAlbedoTexture(tx)
    m:setRoughness(rough or 0.9)
    m:setMetallic(metal or 0)
    return m
  end

  mat.turf    = texMat("turf",  tex.turf,  0.95)
  mat.edge    = texMat("edge",  tex.edge,  0.7)
  mat.stone   = texMat("stone", tex.stone, 0.85)
  mat.sand    = texMat("sand",  tex.sand,  1.0)
  mat.water   = texMat("water", tex.water, 0.15, 0.2)
  mat.zone    = texMat("zone",  tex.zone,  0.6)
  mat.ball    = texMat("ball",  tex.ball,  0.25)
  mat.flag    = texMat("flag",  tex.flag,  0.9)

  -- The shadow is ALPHA-BLENDED onto the green, so it must not be culled
  -- (it is a single quad seen from one side) and must not be lit -- a
  -- shadow that brightens with the sun is not a shadow.
  mat.shadow = dream:newMaterial("shadow")
  mat.shadow:setColor(1, 1, 1, 1)
  mat.shadow:setEmissionTexture(tex.shadow)
  mat.shadow:setEmission(0, 0, 0)
  mat.shadow:setEmissionFactor(1, 1, 1)
  mat.shadow:setRoughness(1)
  mat.shadow:setCullMode("none")

  -- The cup is a dark hole. No texture: it is the absence of surface.
  mat.cup = dream:newMaterial("cup")
  mat.cup:setColor(0.02, 0.02, 0.03, 1)
  mat.cup:setEmission(0.02, 0.02, 0.03)
  mat.cup:setRoughness(1)
  mat.cup:setCullMode("none")

  return mat
end

-- ── mesh helpers ──────────────────────────────────────────────────────

-- Every mesh goes through here so the texture lands on the mesh as well as
-- the material. Missing this is invisible in every check except the
-- rendered picture: the shader compiles, the uniform sends, and the
-- surface draws flat white.
local function finish(m, texture)
  m:create()
  if texture and m.mesh and m.mesh.setTexture then
    m.mesh:setTexture(texture)
  end
  return m
end

-- A box in PIXEL space, converted to world units on the way in. uvScale
-- ties texture repeats to real size, so a long rail does not smear.
-- `texture` may be a single image or a table of per-face-direction images
-- from art.lit. With a table, each of the six faces gets the variant baked
-- for the direction it points -- which is the only way this engine shades
-- anything, since its 3D path has no runtime lighting.
--
-- A mesh carries ONE texture, so a multi-face box is built as six separate
-- meshes. That is six draw calls where one would do, and it is what buys
-- the shading: a rail whose top is bright and whose sides fall away in two
-- different hues reads as a solid object instead of a flat sticker.
-- BATCHED, LIT BOXES: one mesh per FACE DIRECTION for the whole hole, not
-- six meshes per box.
--
-- This engine has no runtime 3D lighting (render3d_gl.c: "no camera, no
-- matrix stack, no lighting"), so shading has to be baked into textures --
-- one variant per direction a face can point. The obvious implementation,
-- six meshes per box, costs six slots per rail: measured across the 22
-- holes that puts thirteen of them over the renderer's 64-mesh limit, with
-- hole 14 alone wanting 169. Overflowing does not error, it silently drops
-- geometry, which is how the sky went black.
--
-- So every box of a given material accumulates into six shared meshes, one
-- per direction. A hole costs six slots for all its rails together however
-- many rails it has, and the shading is identical.
local function newBatch(material)
  local b = { material = material, dirs = {} }
  for _, dir in ipairs({ "top", "bottom", "north", "south", "east", "west" }) do
    local m = dream:newMesh(material)
    b.dirs[dir] = {
      mesh = m,
      v = m:getOrCreateBuffer("vertices"),
      n = m:getOrCreateBuffer("normals"),
      t = m:getOrCreateBuffer("texCoords"),
      f = m:getOrCreateBuffer("faces"),
      count = 0,
    }
  end
  return b
end

local BOX_DIRS = {
  { "top",    { 0, 1, 0} }, { "bottom", { 0,-1, 0} },
  { "south",  { 0, 0, 1} }, { "north",  { 0, 0,-1} },
  { "east",   { 1, 0, 0} }, { "west",   {-1, 0, 0} },
}

local function batchBox(batch, cx, cy, cz, hx, hy, hz, uvScale)
  local s = uvScale or (1 / 128)
  local x, y, z = cx / U, cy / U, cz / U
  local ax, ay, az = hx / U, hy / U, hz / U
  local corners = {
    top    = { {-ax, ay,-az}, { ax, ay,-az}, { ax, ay, az}, {-ax, ay, az}, hx, hz },
    bottom = { {-ax,-ay, az}, { ax,-ay, az}, { ax,-ay,-az}, {-ax,-ay,-az}, hx, hz },
    south  = { {-ax,-ay, az}, { ax,-ay, az}, { ax, ay, az}, {-ax, ay, az}, hx, hy },
    north  = { { ax,-ay,-az}, {-ax,-ay,-az}, {-ax, ay,-az}, { ax, ay,-az}, hx, hy },
    east   = { { ax,-ay, az}, { ax,-ay,-az}, { ax, ay,-az}, { ax, ay, az}, hz, hy },
    west   = { {-ax,-ay,-az}, {-ax,-ay, az}, {-ax, ay, az}, {-ax, ay,-az}, hz, hy },
  }
  for _, d in ipairs(BOX_DIRS) do
    local dir, n = d[1], d[2]
    local c = corners[dir]
    local g = batch.dirs[dir]
    local base = g.count * 4
    local su, sv = c[5] * 2 * s, c[6] * 2 * s
    local uv = { { 0, 0 }, { su, 0 }, { su, sv }, { 0, sv } }
    for i = 1, 4 do
      g.v:append({ x + c[i][1], y + c[i][2], z + c[i][3] })
      g.n:append({ n[1], n[2], n[3] })
      g.t:append(uv[i])
    end
    g.f:append({ base + 1, base + 2, base + 3 })
    g.f:append({ base + 1, base + 3, base + 4 })
    g.count = g.count + 1
  end
end

-- Finish a batch: six meshes, each with its direction's baked-light texture.
-- Empty directions are skipped so an unused batch costs nothing.
-- A FLAT batch: every horizontal surface of one material in a single mesh.
-- Water, sand and the impulse pads are all flat and all face up, so they
-- need one mesh each for the whole hole rather than one per entity. Hole 18
-- has enough of them to want 94 meshes against a 64-slot renderer.
local function newFlat(material)
  local m = dream:newMesh(material)
  return {
    mesh = m,
    v = m:getOrCreateBuffer("vertices"),
    n = m:getOrCreateBuffer("normals"),
    t = m:getOrCreateBuffer("texCoords"),
    f = m:getOrCreateBuffer("faces"),
    count = 0,
  }
end

local function flatPoly(fb, pts, py, cx, cz, uvScale)
  local s = uvScale or (1 / 128)
  local n = #pts / 2
  local base = fb.count
  for i = 1, n do
    local px, pz = pts[i * 2 - 1], pts[i * 2]
    fb.v:append({ (cx + px) / U, py / U, (cz + pz) / U })
    fb.n:append({ 0, 1, 0 })
    fb.t:append({ px * s, pz * s })
  end
  for i = 2, n - 1 do
    fb.f:append({ base + 1, base + i, base + i + 1 })
  end
  fb.count = base + n
end

local function flatRect(fb, cx, cy, cz, hw, hh, uvScale)
  flatPoly(fb, { -hw, -hh, hw, -hh, hw, hh, -hw, hh }, cy, cx, cz, uvScale)
end

-- Bumpers batched into ONE mesh. Hole 15 has 47 circular bumpers, and a
-- sphere apiece is 47 slots on top of the ~27 the rest of the hole needs --
-- 74 against a 64-slot renderer, which is why that hole failed to build
-- while every hole before it was fine. It was never a leak: the live slot
-- count cycles and resets cleanly, one hole simply wanted more at once.
local function batchSphere(fb, cx, cy, cz, r, seg)
  seg = seg or 8
  local base = fb.count
  local rr = r / U
  for i = 0, seg do
    local phi = math.pi * i / seg
    for j = 0, seg do
      local th = 2 * math.pi * j / seg
      local x = math.sin(phi) * math.cos(th)
      local y = math.cos(phi)
      local z = math.sin(phi) * math.sin(th)
      fb.v:append({ cx / U + x * rr, cy / U + y * rr, cz / U + z * rr })
      fb.n:append({ x, y, z })
      fb.t:append({ j / seg, i / seg })
    end
  end
  for i = 0, seg - 1 do
    for j = 0, seg - 1 do
      local a = base + i * (seg + 1) + j + 1
      local b = a + seg + 1
      fb.f:append({ a, b, a + 1 })
      fb.f:append({ a + 1, b, b + 1 })
    end
  end
  fb.count = base + (seg + 1) * (seg + 1)
end

-- A solid polygon rail, as a real PRISM: the outline capped at WALL_H plus
-- a skirt down each edge to the green.
--
-- These were drawn as a flat cap only, while collision used a box hull
-- around the whole outline -- so a 267x161 triangle became a 267x161
-- invisible wall the ball bounced off with nothing on screen to explain it.
-- Drawing the sides makes the shape visible, and the collision below is
-- switched to a set of thin boxes along the outline so it matches what is
-- drawn rather than the bounding box.
local function batchPolyPrism(top, side, pts, y, cx, cz, uvScale)
  flatPoly(top, pts, y, cx, cz, uvScale)
  local n = #pts / 2
  local s = uvScale or (1 / 128)
  for i = 1, n do
    local j = (i % n) + 1
    local x1, z1 = pts[i * 2 - 1], pts[i * 2]
    local x2, z2 = pts[j * 2 - 1], pts[j * 2]
    local base = side.count
    local len = math.sqrt((x2 - x1) ^ 2 + (z2 - z1) ^ 2)
    side.v:append({ (cx + x1) / U, y / U, (cz + z1) / U })
    side.v:append({ (cx + x2) / U, y / U, (cz + z2) / U })
    side.v:append({ (cx + x2) / U, 0, (cz + z2) / U })
    side.v:append({ (cx + x1) / U, 0, (cz + z1) / U })
    -- outward normal of this edge, in the ground plane
    local nx, nz = (z2 - z1), -(x2 - x1)
    local nl = math.sqrt(nx * nx + nz * nz)
    if nl > 0 then nx, nz = nx / nl, nz / nl end
    for _ = 1, 4 do side.n:append({ nx, 0, nz }) end
    side.t:append({ 0, 0 })
    side.t:append({ len * s, 0 })
    side.t:append({ len * s, y * s })
    side.t:append({ 0, y * s })
    side.f:append({ base + 1, base + 2, base + 3 })
    side.f:append({ base + 1, base + 3, base + 4 })
    side.count = base + 4
  end
end

local function finishFlat(fb, texture, out)
  if fb.count > 0 then
    out[#out + 1] = { finish(fb.mesh, texture), 0, 0, 0 }
  elseif fb.mesh and fb.mesh.mesh and fb.mesh.mesh.release then
    fb.mesh.mesh:release()
    fb.mesh.mesh = nil
  end
end

local function finishBatch(batch, textures, out)
  for dir, g in pairs(batch.dirs) do
    if g.count > 0 then
      out[#out + 1] = { finish(g.mesh, textures[dir]), 0, 0, 0 }
    else
      -- RELEASE the directions that took no geometry. newBatch creates all
      -- six up front, and an empty one still holds a renderer slot: only
      -- the meshes that reach `out` are freed on the next rebuild, so the
      -- unused ones leak until the 64 slots run out and a mid-game hole
      -- fails to build. That is the same crash as before, arriving by a
      -- different route.
      if g.mesh and g.mesh.mesh and g.mesh.mesh.release then
        g.mesh.mesh:release()
        g.mesh.mesh = nil
      end
    end
  end
end

local function buildBox(material, texture, cx, cy, cz, hx, hy, hz, uvScale)
  local m = dream:newMesh(material)
  local mv = m:getOrCreateBuffer("vertices")
  local mn = m:getOrCreateBuffer("normals")
  local mt = m:getOrCreateBuffer("texCoords")
  local mf = m:getOrCreateBuffer("faces")
  local s = uvScale or (1 / 128)
  local x, y, z = cx / U, cy / U, cz / U
  local ax, ay, az = hx / U, hy / U, hz / U
  local faces = {
    { { 0, 1, 0}, {-ax, ay,-az}, { ax, ay,-az}, { ax, ay, az}, {-ax, ay, az}, hx, hz },
    { { 0,-1, 0}, {-ax,-ay, az}, { ax,-ay, az}, { ax,-ay,-az}, {-ax,-ay,-az}, hx, hz },
    { { 0, 0, 1}, {-ax,-ay, az}, { ax,-ay, az}, { ax, ay, az}, {-ax, ay, az}, hx, hy },
    { { 0, 0,-1}, { ax,-ay,-az}, {-ax,-ay,-az}, {-ax, ay,-az}, { ax, ay,-az}, hx, hy },
    { { 1, 0, 0}, { ax,-ay, az}, { ax,-ay,-az}, { ax, ay,-az}, { ax, ay, az}, hz, hy },
    { {-1, 0, 0}, {-ax,-ay,-az}, {-ax,-ay, az}, {-ax, ay, az}, {-ax, ay,-az}, hz, hy },
  }
  local base = 0
  for _, f in ipairs(faces) do
    local n = f[1]
    local su, sv = f[6] * 2 * s, f[7] * 2 * s
    local uv = { { 0, 0 }, { su, 0 }, { su, sv }, { 0, sv } }
    for i = 2, 5 do
      mv:append({ x + f[i][1], y + f[i][2], z + f[i][3] })
      mn:append({ n[1], n[2], n[3] })
      mt:append(uv[i - 1])
    end
    mf:append({ base + 1, base + 2, base + 3 })
    mf:append({ base + 1, base + 3, base + 4 })
    base = base + 4
  end
  return finish(m, texture)
end
M.buildBox = buildBox

-- A flat polygon, fanned from its first vertex. This winding is the one
-- that demonstrably renders here, so the cup and every hazard use it.
local function buildPoly(material, texture, pts, py, cx, cz, uvScale)
  local m = dream:newMesh(material)
  local mv = m:getOrCreateBuffer("vertices")
  local mn = m:getOrCreateBuffer("normals")
  local mt = m:getOrCreateBuffer("texCoords")
  local mf = m:getOrCreateBuffer("faces")
  local s = uvScale or (1 / 128)
  local n = #pts / 2
  for i = 1, n do
    local px, pz = pts[i * 2 - 1], pts[i * 2]
    mv:append({ (cx + px) / U, py / U, (cz + pz) / U })
    mn:append({ 0, 1, 0 })
    mt:append({ px * s, pz * s })
  end
  for i = 2, n - 1 do mf:append({ 1, i, i + 1 }) end
  return finish(m, texture)
end
M.buildPoly = buildPoly

local function buildDisc(material, texture, r, py, cx, cz, seg)
  local pts = {}
  for j = 0, (seg or 24) - 1 do
    local a = 2 * math.pi * j / (seg or 24)
    pts[#pts + 1] = math.cos(a) * r
    pts[#pts + 1] = math.sin(a) * r
  end
  return buildPoly(material, texture, pts, py, cx, cz, 1 / (r * 2))
end

local function buildSphere(material, texture, r, seg)
  local m = dream:newMesh(material)
  local mv = m:getOrCreateBuffer("vertices")
  local mn = m:getOrCreateBuffer("normals")
  local mt = m:getOrCreateBuffer("texCoords")
  local mf = m:getOrCreateBuffer("faces")
  local rr = r / U
  for i = 0, seg do
    local phi = math.pi * i / seg
    for j = 0, seg do
      local th = 2 * math.pi * j / seg
      local x = math.sin(phi) * math.cos(th)
      local y = math.cos(phi)
      local z = math.sin(phi) * math.sin(th)
      mv:append({ x * rr, y * rr, z * rr })
      mn:append({ x, y, z })
      mt:append({ j / seg, i / seg })
    end
  end
  for i = 0, seg - 1 do
    for j = 0, seg - 1 do
      local a = i * (seg + 1) + j + 1
      local b = a + seg + 1
      mf:append({ a, b, a + 1 })
      mf:append({ a + 1, b, b + 1 })
    end
  end
  return finish(m, texture)
end
M.buildSphere = buildSphere

-- ── building a hole ───────────────────────────────────────────────────

local meshes = {}          -- { mesh, x, y, z }
local spinners = {}        -- moving obstacles, rotated every frame
local rails = {}           -- rail footprints, for the 2D contact shadows
local ballMesh
local bodies = {}          -- every static body, freed on rebuild

-- Frees the previous hole. The renderer has 64 mesh slots and a hole uses
-- a dozen, so without this the sixth hole fails to build one and the cart
-- dies with a Lua error mid-game.
local function freeMeshes()
  for _, e in ipairs(meshes) do
    local mesh = e[1]
    if mesh and mesh.mesh and mesh.mesh.release then
      mesh.mesh:release()
      mesh.mesh = nil
    end
  end
  meshes = {}
end

-- A static body with one box shape, in pixel space.
-- Body type is a NUMBER in this API: 0 static, 1 kinematic, 2 dynamic.
local function staticBox(world, cx, cy, cz, hx, hy, hz, friction, restitution)
  local b = b3.body_new(world, cx, cy, cz, 0)
  local s = b3.shape_box(b, hx, hy, hz)
  b3.shape_set_material(s, friction or 0.7, restitution or 0.35)
  bodies[#bodies + 1] = b
  return b
end

-- Build one hole: geometry, collision, and where the ball and cup are.
function M.build(world, level)
  freeMeshes()
  bodies = {}
  spinners = {}
  rails = {}

  local X0, Y0 = 210, 40
  local W, H = 1500, 1000
  local cx, cy = X0 + W / 2, Y0 + H / 2

  -- THE GREEN. A slab with its top face at y=0, so every height in the
  -- level is measured from the putting surface.
  local turfBatch = newBatch(mat.turf)
  local stoneBatch = newBatch(mat.stone)
  local edgeBatch = newBatch(mat.edge)
  local waterFlat = newFlat(mat.water)
  local sandFlat  = newFlat(mat.sand)
  local zoneFlat  = newFlat(mat.zone)
  local edgeTopFlat = newFlat(mat.edge)
  local bumperFlat = newFlat(mat.edge)
  local edgeSideFlat = newFlat(mat.edge)
  batchBox(turfBatch, cx, -FLOOR_T / 2, cy, W / 2, FLOOR_T / 2, H / 2, 1 / 96)
  staticBox(world, cx, -FLOOR_T / 2, cy, W / 2, FLOOR_T / 2, H / 2, 0.85, 0.2)

  -- NO APRON. There used to be a stone slab under and around the green,
  -- "purely to frame it" -- a second, DARKER grey surrounding the lighter
  -- grey of the rails. Two near-identical greys (0.46 against 0.50) that
  -- differ only in brightness read as one material lit two different ways,
  -- which is incoherent side by side.
  --
  -- Neverputt has no apron: its greens simply end, and the sky shows
  -- behind them. Counted across its own hole files the outer material is
  -- turf-grey on the WALLS, not on a surround -- there is no surround.
  -- The sky gradient is the frame.

  local goal, start
  for _, e in ipairs(level.entities) do
    if e.id == "ball" then
      start = { x = e.x, y = e.y }

    elseif e.id == "goal" then
      goal = { x = e.x, y = e.y }

    elseif e.water then
      -- Water sits BELOW the surface and is a trigger, not a wall.
      if e.kind == "rect" then
        flatRect(waterFlat, e.x, -6, e.y, e.hw, e.hh, 1 / 160)
      elseif e.kind == "poly" then
        flatPoly(waterFlat, e.points, -6, e.x, e.y, 1 / 160)
      end

    elseif e.sand then
      if e.kind == "rect" then
        flatRect(sandFlat, e.x, -3, e.y, e.hw, e.hh, 1 / 112)
      elseif e.kind == "poly" then
        flatPoly(sandFlat, e.points, -3, e.x, e.y, 1 / 112)
      end

    elseif e.impulse then
      if e.kind == "rect" then
        flatRect(zoneFlat, e.x, 1.5, e.y, e.hw, e.hh, 1 / 64)
      elseif e.kind == "poly" then
        flatPoly(zoneFlat, e.points, 2, e.x, e.y, 1 / 64)
      end

    elseif e.dynamic and e.id ~= "ball" then
      -- THE WINDMILL. Hole 13's woodbar is the one moving obstacle in the
      -- whole course, and it was not implemented at all -- the hole played
      -- as an empty rectangle. It spins about its centre as a KINEMATIC
      -- body: driven by the game rather than by forces, so it sweeps the
      -- ball aside without the ball ever pushing it back.
      local m = dream:newMesh(mat.edge)
      local mv = m:getOrCreateBuffer("vertices")
      local mn = m:getOrCreateBuffer("normals")
      local mt = m:getOrCreateBuffer("texCoords")
      local mf = m:getOrCreateBuffer("faces")
      local hw, hh, hy = e.hw / U, e.hh / U, WALL_H / 2 / U
      local faces = {
        { { 0, 1, 0}, {-hw, hy,-hh}, { hw, hy,-hh}, { hw, hy, hh}, {-hw, hy, hh} },
        { { 0, 0, 1}, {-hw,-hy, hh}, { hw,-hy, hh}, { hw, hy, hh}, {-hw, hy, hh} },
        { { 0, 0,-1}, { hw,-hy,-hh}, {-hw,-hy,-hh}, {-hw, hy,-hh}, { hw, hy,-hh} },
        { { 1, 0, 0}, { hw,-hy, hh}, { hw,-hy,-hh}, { hw, hy,-hh}, { hw, hy, hh} },
        { {-1, 0, 0}, {-hw,-hy,-hh}, {-hw,-hy, hh}, {-hw, hy, hh}, {-hw, hy,-hh} },
      }
      local base = 0
      for _, f in ipairs(faces) do
        local n = f[1]
        for i = 2, 5 do
          mv:append({ f[i][1], f[i][2], f[i][3] })
          mn:append({ n[1], n[2], n[3] })
          mt:append({ (i == 2 or i == 5) and 0 or 1, (i <= 3) and 0 or 1 })
        end
        mf:append({ base + 1, base + 2, base + 3 })
        mf:append({ base + 1, base + 3, base + 4 })
        base = base + 4
      end
      finish(m, tex.lit.edge.south)

      local b = b3.body_new(world, e.x, WALL_H / 2, e.y, 1)   -- 1 = kinematic
      local sh = b3.shape_box(b, e.hw, WALL_H / 2, e.hh)
      b3.shape_set_material(sh, 0.4, 0.6)
      bodies[#bodies + 1] = b
      spinners[#spinners + 1] = {
        mesh = m, body = b, x = e.x, y = e.y,
        speed = e.spinSpeed or 1.15, angle = 0,
      }

    elseif not e.sensor then
      -- TIMBER RAILS: real boxes with real height, both drawn and solid.
      if e.kind == "rect" then
        -- 1/104 makes one checker square about 26px, so the pattern is
        -- the same physical size on every rail rather than repeating more
        -- times the longer the rail is.
        batchBox(edgeBatch, e.x, WALL_H / 2, e.y,
                 e.hw, WALL_H / 2, e.hh, 1 / 104)
        rails[#rails + 1] = { x = e.x, y = e.y, hw = e.hw, hh = e.hh }
        staticBox(world, e.x, WALL_H / 2, e.y, e.hw, WALL_H / 2, e.hh,
                  0.5, e.restitution or 0.55)
      elseif e.kind == "circle" then
        -- Position in ABSOLUTE pixel space / U, NOT through wx()/wz().
        -- Those recentre about the middle of the screen, which every other
        -- mesh here already accounts for by baking absolute coordinates
        -- into its vertices -- so a sphere placed through them is offset
        -- twice and ends up off the course, hanging in the sky.
        batchSphere(bumperFlat, e.x, WALL_H / 2, e.y, e.r, 8)
        local b = b3.body_new(world, e.x, WALL_H / 2, e.y, 0)
        local s = b3.shape_sphere(b, e.r)
        b3.shape_set_material(s, 0.5, e.restitution or 0.55)
        bodies[#bodies + 1] = b
      elseif e.kind == "poly" then
        -- A POLYGON RAIL IS A PRISM, drawn and collided as the same shape.
        --
        -- This used to draw a flat cap and collide with a BOX around the
        -- whole outline. Box3D has no convex-hull shape, and I wrote that
        -- the layouts' polygons were "all small wedges where a tight box is
        -- honest enough" -- they are not: hole 2 alone has 267x161 and
        -- 278x166 triangles, so the ball bounced off a large invisible
        -- rectangle with only a thin cap visible.
        --
        -- Now the sides are drawn, and collision is a thin box PER EDGE
        -- laid along the outline, so the solid shape is the drawn shape.
        batchPolyPrism(edgeTopFlat, edgeSideFlat, e.points, WALL_H,
                       e.x, e.y, 1 / 104)
        local n = #e.points / 2
        for i = 1, n do
          local j = (i % n) + 1
          local x1, z1 = e.points[i * 2 - 1], e.points[i * 2]
          local x2, z2 = e.points[j * 2 - 1], e.points[j * 2]
          local mx, mz = (x1 + x2) / 2, (z1 + z2) / 2
          local dx, dz = x2 - x1, z2 - z1
          local len = math.sqrt(dx * dx + dz * dz)
          if len > 1 then
            -- an axis-aligned box per edge is still an approximation, but
            -- it hugs the OUTLINE instead of the bounding box: the error is
            -- now a few pixels at a corner rather than a whole rectangle
            staticBox(world, e.x + mx, WALL_H / 2, e.y + mz,
                      math.max(3, math.abs(dx) / 2), WALL_H / 2,
                      math.max(3, math.abs(dz) / 2),
                      0.5, e.restitution or 0.55)
          end
        end
      end
    end
  end

  -- Flush the batched geometry: six meshes for the green, six for the
  -- apron, six for every rail in the hole put together.
  finishBatch(turfBatch, tex.lit.turf, meshes)
  finishBatch(stoneBatch, tex.lit.stone, meshes)
  finishBatch(edgeBatch, tex.lit.edge, meshes)
  finishFlat(waterFlat, tex.lit.water.top, meshes)
  finishFlat(sandFlat, tex.lit.sand.top, meshes)
  finishFlat(zoneFlat, tex.lit.zone.top, meshes)
  finishFlat(edgeTopFlat, tex.lit.edge.top, meshes)
  finishFlat(bumperFlat, tex.lit.edge.top, meshes)
  -- the prism sides take a SIDE-lit variant, not the top one, so a
  -- polygon rail shades like every other rail
  finishFlat(edgeSideFlat, tex.lit.edge.south, meshes)

  -- THE CUP, drawn last so it sits over the green rather than under it.
  if goal then
    -- The hole is a SHAFT: a dark disc at the bottom plus a ring of wall
    -- down to it. A disc alone floats -- it reads as a black sticker on
    -- the grass rather than as somewhere the ball goes -- and the wall is
    -- what gives it a rim and a shadowed inside.
    -- SHALLOW. The floor has to stay visible from a camera looking down at
    -- 20-odd degrees: at 26px deep the green's own surface occludes it and
    -- the cup renders as a bare ring with grass showing through the middle.
    local CUP_DEPTH = 7
    meshes[#meshes + 1] = { buildDisc(mat.cup, nil, CUP_R, -CUP_DEPTH,
                                      goal.x, goal.y, 28), 0, 0, 0 }
    local wall = dream:newMesh(mat.cup)
    local wv = wall:getOrCreateBuffer("vertices")
    local wn = wall:getOrCreateBuffer("normals")
    local wt = wall:getOrCreateBuffer("texCoords")
    local wf = wall:getOrCreateBuffer("faces")
    local SEG = 28
    for j = 0, SEG do
      local a = 2 * math.pi * j / SEG
      local px, pz = math.cos(a) * CUP_R, math.sin(a) * CUP_R
      wv:append({ (goal.x + px) / U, 0.6 / U, (goal.y + pz) / U })
      wn:append({ -math.cos(a), 0, -math.sin(a) })
      wt:append({ j / SEG, 0 })
      wv:append({ (goal.x + px) / U, -CUP_DEPTH / U, (goal.y + pz) / U })
      wn:append({ -math.cos(a), 0, -math.sin(a) })
      wt:append({ j / SEG, 1 })
    end
    for j = 0, SEG - 1 do
      local a = j * 2 + 1
      wf:append({ a, a + 1, a + 2 })
      wf:append({ a + 1, a + 3, a + 2 })
    end
    wall:create()
    meshes[#meshes + 1] = { wall, 0, 0, 0 }
    -- the pin, beside the hole rather than in it
    local off = CUP_R + 7
    meshes[#meshes + 1] = { buildBox(mat.flag, tex.flag, goal.x + off, 34, goal.y,
                                     2, 34, 2, 1 / 32), 0, 0, 0 }
    meshes[#meshes + 1] = { buildBox(mat.flag, tex.flag, goal.x + off + 15, 60, goal.y,
                                     15, 9, 1, 1 / 32), 0, 0, 0 }
  end

  if not ballMesh then
    ballMesh = buildSphere(mat.ball, tex.ball, BALL_R, 18)
  end

  return { start = start, goal = goal }
end

-- A flat textured quad lying on the green, used for contact shadows.
local function shadowQuad(material, texture, r)
  local m = dream:newMesh(material)
  local mv = m:getOrCreateBuffer("vertices")
  local mn = m:getOrCreateBuffer("normals")
  local mt = m:getOrCreateBuffer("texCoords")
  local mf = m:getOrCreateBuffer("faces")
  local rr = r / U
  local pts = { {-rr, -rr, 0, 0}, { rr, -rr, 1, 0}, { rr, rr, 1, 1}, {-rr, rr, 0, 1} }
  for _, p in ipairs(pts) do
    mv:append({ p[1], 0, p[2] })
    mn:append({ 0, 1, 0 })
    mt:append({ p[3], p[4] })
  end
  mf:append({ 1, 2, 3 })
  mf:append({ 1, 3, 4 })
  return finish(m, texture)
end

local ballShadow
function M.ballShadowMesh()
  if not ballShadow then
    ballShadow = shadowQuad(mat.shadow, tex.shadow, BALL_R * 2.6)
  end
  return ballShadow
end

-- The rail footprints, so the 2D pass can lay a contact shadow beside each
-- one. The shadows cannot be 3D geometry: this engine's 3D path does no
-- alpha blending, so a translucent quad paints a solid black rectangle.
function M.rails() return rails end

function M.ballMesh() return ballMesh end

-- Advance the moving obstacles. Kinematic bodies do not move themselves:
-- the game sets their transform, and the solver sweeps anything they touch.
function M.update(dt)
  for _, s in ipairs(spinners) do
    s.angle = s.angle + s.speed * dt
    b3.body_set_transform(s.body, s.x, WALL_H / 2, s.y, 0, 1, 0, s.angle)
  end
end

function M.draw()
  for _, m in ipairs(meshes) do
    dream:draw(m[1], m[2], m[3], m[4])
  end
  -- the spinners carry their own rotation, so they are drawn from a matrix
  for _, s in ipairs(spinners) do
    local c, sn = math.cos(s.angle), math.sin(s.angle)
    dream:draw(s.mesh, dream.mat4({
      c, 0, sn, s.x / U,
      0, 1, 0,  WALL_H / 2 / U,
      -sn, 0, c, s.y / U,
      0, 0, 0, 1,
    }))
  end
end

return M
