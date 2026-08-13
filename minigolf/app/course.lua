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
local FLOOR_T = 10                  -- how thick the green's slab is
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
  local function texMat(name, tx, rough, metal)
    local m = dream:newMaterial(name)
    m:setColor(1, 1, 1, 1)
    m:setEmissionTexture(tx)
    -- emission = texel * factor + colour, so the COLOUR stays black or it
    -- is added to every texel and washes the texture out to white
    m:setEmission(0, 0, 0)
    m:setEmissionFactor(1, 1, 1)
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

  local X0, Y0 = 210, 40
  local W, H = 1500, 1000
  local cx, cy = X0 + W / 2, Y0 + H / 2

  -- THE GREEN. A slab with its top face at y=0, so every height in the
  -- level is measured from the putting surface.
  meshes[#meshes + 1] = { buildBox(mat.turf, tex.turf, cx, -FLOOR_T / 2, cy,
                                   W / 2, FLOOR_T / 2, H / 2, 1 / 96), 0, 0, 0 }
  staticBox(world, cx, -FLOOR_T / 2, cy, W / 2, FLOOR_T / 2, H / 2, 0.85, 0.2)

  -- the stone apron the green sits on, purely to frame it
  meshes[#meshes + 1] = { buildBox(mat.stone, tex.stone, cx, -FLOOR_T - 22, cy,
                                   W / 2 + 150, 22, H / 2 + 120, 1 / 128), 0, 0, 0 }

  local goal, start
  for _, e in ipairs(level.entities) do
    if e.id == "ball" then
      start = { x = e.x, y = e.y }

    elseif e.id == "goal" then
      goal = { x = e.x, y = e.y }

    elseif e.water then
      -- Water sits BELOW the surface and is a trigger, not a wall.
      if e.kind == "rect" then
        meshes[#meshes + 1] = { buildBox(mat.water, tex.water, e.x, -6, e.y,
                                         e.hw, 2, e.hh, 1 / 160), 0, 0, 0 }
      elseif e.kind == "poly" then
        meshes[#meshes + 1] = { buildPoly(mat.water, tex.water, e.points, -6,
                                          e.x, e.y, 1 / 160), 0, 0, 0 }
      end

    elseif e.sand then
      if e.kind == "rect" then
        meshes[#meshes + 1] = { buildBox(mat.sand, tex.sand, e.x, -3, e.y,
                                         e.hw, 2, e.hh, 1 / 112), 0, 0, 0 }
      elseif e.kind == "poly" then
        meshes[#meshes + 1] = { buildPoly(mat.sand, tex.sand, e.points, -3,
                                          e.x, e.y, 1 / 112), 0, 0, 0 }
      end

    elseif e.impulse then
      if e.kind == "rect" then
        meshes[#meshes + 1] = { buildBox(mat.zone, tex.zone, e.x, 1.5, e.y,
                                         e.hw, 1, e.hh, 1 / 64), 0, 0, 0 }
      elseif e.kind == "poly" then
        meshes[#meshes + 1] = { buildPoly(mat.zone, tex.zone, e.points, 2,
                                          e.x, e.y, 1 / 64), 0, 0, 0 }
      end

    elseif not e.sensor then
      -- TIMBER RAILS: real boxes with real height, both drawn and solid.
      if e.kind == "rect" then
        -- 1/104 makes one checker square about 26px, so the pattern is
        -- the same physical size on every rail rather than repeating more
        -- times the longer the rail is.
        meshes[#meshes + 1] = { buildBox(mat.edge, tex.edge, e.x, WALL_H / 2, e.y,
                                         e.hw, WALL_H / 2, e.hh, 1 / 104), 0, 0, 0 }
        staticBox(world, e.x, WALL_H / 2, e.y, e.hw, WALL_H / 2, e.hh,
                  0.5, e.restitution or 0.55)
      elseif e.kind == "circle" then
        -- Position in ABSOLUTE pixel space / U, NOT through wx()/wz().
        -- Those recentre about the middle of the screen, which every other
        -- mesh here already accounts for by baking absolute coordinates
        -- into its vertices -- so a sphere placed through them is offset
        -- twice and ends up off the course, hanging in the sky.
        meshes[#meshes + 1] = { buildSphere(mat.edge, tex.edge, e.r, 12),
                                e.x / U, WALL_H / 2 / U, e.y / U }
        local b = b3.body_new(world, e.x, WALL_H / 2, e.y, 0)
        local s = b3.shape_sphere(b, e.r)
        b3.shape_set_material(s, 0.5, e.restitution or 0.55)
        bodies[#bodies + 1] = b
      elseif e.kind == "poly" then
        -- A polygon rail becomes a drawn cap plus a box hull for collision:
        -- Box3D has no convex-hull-from-points shape, and the layouts'
        -- polygons are all small wedges where a tight box is honest enough.
        meshes[#meshes + 1] = { buildPoly(mat.edge, tex.edge, e.points, WALL_H,
                                          e.x, e.y, 1 / 104), 0, 0, 0 }
        local minx, maxx, minz, maxz = math.huge, -math.huge, math.huge, -math.huge
        for i = 1, #e.points / 2 do
          local px, pz = e.points[i * 2 - 1], e.points[i * 2]
          minx = math.min(minx, px); maxx = math.max(maxx, px)
          minz = math.min(minz, pz); maxz = math.max(maxz, pz)
        end
        staticBox(world, e.x + (minx + maxx) / 2, WALL_H / 2, e.y + (minz + maxz) / 2,
                  math.max(2, (maxx - minx) / 2), WALL_H / 2,
                  math.max(2, (maxz - minz) / 2), 0.5, e.restitution or 0.55)
      end
    end
  end

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

function M.ballMesh() return ballMesh end

function M.draw()
  for _, m in ipairs(meshes) do
    dream:draw(m[1], m[2], m[3], m[4])
  end
end

return M
