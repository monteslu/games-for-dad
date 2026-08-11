-- Eight Ball - 3D top-down 8-ball against a CPU opponent.
--
-- Rendering is 3DreamEngine, physics is Box3D, and the whole control scheme
-- is the family's: d-pad moves, one button commits, and every action is also
-- a tap. See docs/DESIGN.md -- this is built for one 85-year-old on a couch
-- with a gamepad, and the rules bend where the rule book would punish him
-- for something he could not see coming.
--
-- Shot flow -- PULL THE CUE BACK, no timed press and no on-screen button:
--   LEFT/RIGHT  swing the aim
--   UP/DOWN     pull the cue back; how far back IS the power, and the stick
--               fades cream -> red as it grows
--   confirm     strike (or, on touch, just let go of the drag)
--   ROLL        physics runs until every ball sleeps, then the rules judge
--
-- This is the mechanic from monteslu's 2012 pool game
-- (github.com/monteslu/pool): impulse = min(distance * k, maxImpulse), with
-- the stick colour fading start -> end by that same percentage. It beats a
-- sweeping power bar for this player because nothing is TIMED: the shot is
-- wherever you left the cue, and docs/DESIGN.md says nothing times out.

local dream  = require("3DreamEngine.init")
local theme  = require("lib.theme")
local ui     = require("lib.ui")
local sounds = require("lib.sounds")
local rules  = require("rules")
local tbl    = require("table3d")
local ballart= require("balls")
local bot    = require("bot")

local U = tbl.U

-- ── camera ────────────────────────────────────────────────────────────
-- Very slightly off vertical -- just enough to give the balls some shape
-- against the cloth, not enough to skew the table.
--
-- The tilt is deliberately NOT doing the work of showing ball numbers. A
-- ball's resting orientation is random, so the fraction of balls whose
-- number faces the camera is ~43% at ANY tilt (measured over 20k random
-- orientations at 0, 11, 20, 30 and 40 degrees -- all within noise of each
-- other). Leaning the camera back buys nothing and costs a trapezoid.
--
-- That matches real pool: you identify a ball by COLOUR and by
-- solid-vs-stripe, both always visible, and read the number when it
-- happens to face you. The scoreboard tray is where numbers are
-- guaranteed, because those balls are posed rather than rolled.
local CAM_H, CAM_TILT, CAM_FOV = 12.6, 0.9, 60

-- 3Dream's camera.transform is a WORLD matrix: present() reads the eye
-- position out of its translation column and the forward axis out of column
-- 3. Handing it a view matrix (what lookAt returns) puts the camera in the
-- wrong place looking the wrong way, with no error anywhere.
local function camWorld(eye)
  local up = dream.vec3(0, 1, 0)
  local f = (dream.vec3(0, 0, 0) - eye):normalize()
  if math.abs(f:dot(up)) > 0.999 then up = dream.vec3(0, 0, 1) end
  local r = up:cross(f):normalize()
  local u = f:cross(r):normalize()
  return dream.mat4({
    r.x, u.x, -f.x, eye.x,
    r.y, u.y, -f.y, eye.y,
    r.z, u.z, -f.z, eye.z,
    0,   0,    0,   1,
  })
end

-- ── state ─────────────────────────────────────────────────────────────
local world, table3d
local mesh_ball, mesh_cloth, mesh_rails
local felt_tex, wood_tex
local mat_cloth, mat_rail, mat_balls = nil, nil, {}
local faces
local balls = {}          -- { num, body, shape, pocketed, x, z }
local cue                 -- balls[1] is always the cue ball

local PLAYER, CPU = 1, 2
local state = {
  phase = "aim",          -- aim | roll | over | placing
  turn = PLAYER,
  groups = {},            -- seat -> "solids"|"stripes"
  balls = balls,
  isBreak = true,
  message = "BREAK",
  messageMood = nil,
  ballInHand = false,
  winner = nil,
}
local aimAngle = 0
-- How far the cue is drawn back, in table pixels. This IS the power: the
-- shot is whatever the player left on screen, so nothing is timed and a
-- distracted player loses nothing.
local pull = 0
local dragging = false
local armDrag = true   -- has the screen been released since this phase began?
-- Max pull reaches from the TOP RAIL to the TOP OF THE SCREEN -- the empty
-- band above the table, which is the room the gesture actually has. Derived
-- from the live projection rather than hardcoded, so it stays correct if the
-- camera framing ever changes. pullMax() falls back to the table half-height
-- on the first frame, before a projection exists.
local PULL_MIN = 0
local PULL_MAX = 380       -- refreshed every frame by pullMax()
-- The stick fades cream -> red across that range (monteslu's 2012 colours).
local STICK_NEAR = { 254 / 255, 232 / 255, 214 / 255 }
local STICK_FAR  = { 1, 0, 0 }
local shot = nil          -- what happened during the current roll
local rollFrames = 0
local cpuThink = 0
local placeX, placeZ = 0, 0
local chipQueue = {}

-- Cue-ball speed at full power, in METRES PER SECOND. A real break is
-- 7-11 m/s; a soft positional roll is about 1.
--
-- This used to be an arbitrary impulse constant that worked out to 470 m/s.
-- At that speed the cue ball crosses 500 px in a single 1/60 s step -- more
-- than ten ball-widths -- so it passed clean THROUGH the rack, contacting
-- one ball on the way. The break looked instant and nothing scattered.
-- Speed is the honest unit here, and the impulse is derived from the ball's
-- actual mass so it stays right if the ball size ever changes.
local SHOT_V_MIN, SHOT_V_MAX = 0.7, 11.0

-- ── input: the family readEdges pattern ───────────────────────────────
-- 9-frame debounce and edge detection done by hand from the raw down state.
-- A human cannot press twice in 150ms; a resting thumb or a flaky host
-- mapping can, and a double-fire here costs a shot.
-- Has a gamepad actually been USED? A pad that is merely plugged in is not
-- evidence of a pad player: an Android phone reports a virtual pad nobody is
-- holding. So the cue stick and the aim line stay hidden until a real press
-- arrives, and a touch player never sees a control they cannot reach.
local padUsed = false
local padWokeOnFrame = -1
local prevDown, edges, lastEdgeFrame, frameNo = {}, {}, {}, 0
local DEBOUNCE = 9
local AUTO = rawget(_G, "EIGHTBALL_DRIVER")
local function readEdges()
  frameNo = frameNo + 1
  for k in pairs(edges) do edges[k] = nil end
  if AUTO then
    local b = AUTO(frameNo)
    if b then edges[b] = true end
    return
  end
  for _, b in ipairs({ "a", "b", "left", "right", "up", "down" }) do
    local d = love.pad.isDown(b)
    local edge = d and not prevDown[b]
    if edge and (frameNo - (lastEdgeFrame[b] or -100)) < DEBOUNCE then edge = false end
    if edge then
      lastEdgeFrame[b] = frameNo
      if not padUsed then
        padUsed = true
        padWokeOnFrame = frameNo
        -- the first press only wakes the pad UI up; it must not also fire a
        -- shot the player never aimed
        startPlayerAim()
      end
    end
    edges[b] = edge
    prevDown[b] = d
  end
end
local function confirmPressed() return edges.a or edges.b end
local function heldLeft()  return not AUTO and love.pad.isDown("left") end
local function heldRight() return not AUTO and love.pad.isDown("right") end

-- Touch is an equal path, not an afterthought: on a phone the pad does not
-- exist. Poll ALL ten pointer slots -- slot 0 is the mouse, 1-9 are fingers,
-- and a mouse-only read silently ignores every touch.
local prevPtr, click, clickHeld = {}, nil, nil
local function readClicks()
  click = nil
  clickHeld = nil
  local ptr = rawget(_G, "wc") and wc.pointer
  if not ptr then return end
  for slot = 0, 9 do
    local x, y, buttons, active = ptr(slot)
    local down = (active and buttons ~= 0) or false
    if down then clickHeld = { x = x, y = y } end
    if down and not prevPtr[slot] and not click then click = { x = x, y = y } end
    prevPtr[slot] = down
  end
end
local function inRect(p, r)
  return p and p.x >= r.x and p.x < r.x + r.w and p.y >= r.y and p.y < r.y + r.h
end

local PLACE_BTN = { x = 1560, y = 900, w = 300, h = 120 }

-- ── world <-> screen ──────────────────────────────────────────────────
-- The aiming line and the ball-in-hand cursor are drawn in 2D over the 3D
-- table, so the HUD needs the same projection the camera uses. Rather than
-- reimplement it, project through the ACTUAL camera matrix.
local projCam
local function worldToScreen(wx, wz)
  if not projCam then return nil end
  local m = projCam
  local x, y, z = wx / U, tbl.BALL_R / U, wz / U
  local cx = m[1] * x + m[2] * y + m[3] * z + m[4]
  local cy = m[5] * x + m[6] * y + m[7] * z + m[8]
  local cw = m[13] * x + m[14] * y + m[15] * z + m[16]
  if cw <= 0.0001 then return nil end
  local W, H = love.graphics.getWidth(), love.graphics.getHeight()
  return (cx / cw * 0.5 + 0.5) * W, (1 - (cy / cw * 0.5 + 0.5)) * H
end

-- The inverse: a screen point back to a spot on the cloth.
--
-- Ball-in-hand has to be placeable with a mouse or a finger, not only by
-- walking a cursor with the d-pad. Every ball sits at one fixed height, so
-- the projection restricted to that plane is a 2D map from (wx,wz) to the
-- screen -- but a PERSPECTIVE one, so it is not linear in world space and
-- cannot simply be solved as a 2x2 system. It IS linear in homogeneous
-- terms: sx*cw and cx are both affine in (wx,wz), so moving cw to the left
-- side gives two genuinely linear equations. Solve those.
local function screenToWorld(sx, sy)
  if not projCam then return nil end
  local m = projCam
  local W, H = love.graphics.getWidth(), love.graphics.getHeight()
  -- target normalised device coords
  local ndx = (sx / W - 0.5) * 2
  local ndy = (1 - sy / H - 0.5) * 2
  local y = tbl.BALL_R / U
  -- cx - ndx*cw = 0 and cy - ndy*cw = 0, each affine in (x,z)
  local a1 = m[1] - ndx * m[13]
  local b1 = m[3] - ndx * m[15]
  local c1 = (m[2] - ndx * m[14]) * y + (m[4] - ndx * m[16])
  local a2 = m[5] - ndy * m[13]
  local b2 = m[7] - ndy * m[15]
  local c2 = (m[6] - ndy * m[14]) * y + (m[8] - ndy * m[16])
  local det = a1 * b2 - a2 * b1
  if math.abs(det) < 1e-9 then return nil end
  local x = (-c1 * b2 + c2 * b1) / det
  local z = (-a1 * c2 + a2 * c1) / det
  return x * U, z * U
end

-- A model matrix from a quaternion plus a translation.
--
-- Box3D reports orientation as a quaternion because in 3D there is no single
-- angle to report. 3Dream wants a mat4. This is the standard conversion,
-- ROW-major to match LOVE's convention (the engine transposes on upload).
local function quatMat(qx, qy, qz, qw, tx, ty, tz)
  local x2, y2, z2 = qx + qx, qy + qy, qz + qz
  local xx, xy, xz = qx * x2, qx * y2, qx * z2
  local yy, yz, zz = qy * y2, qy * z2, qz * z2
  local wx, wy, wz = qw * x2, qw * y2, qw * z2
  return dream.mat4({
    1 - (yy + zz), xy - wz,       xz + wy,       tx,
    xy + wz,       1 - (xx + zz), yz - wx,       ty,
    xz - wy,       yz + wx,       1 - (xx + yy), tz,
    0,             0,             0,             1,
  })
end

-- How far the cue may be drawn back, in TABLE pixels.
--
-- The limit is the SMALLEST margin around the table, not the largest. A pull
-- has to be equally achievable in every direction: if the cap came from the
-- generous gap above the table, a player aiming sideways would run out of
-- screen before reaching full power and the same gesture would mean
-- different things depending on which way they were shooting.
--
-- Derived from the live projection so it stays correct if the camera
-- framing changes, with a fallback for the first frame before one exists.
local function pullMax()
  -- A CONSTANT distance: the gap from the top of the green to the top of
  -- the screen. It does not depend on where the cue ball is, so the same
  -- gesture means the same power everywhere on the table -- and because it
  -- is the SMALLEST margin around the cloth, a full pull is reachable in
  -- every direction rather than running out of screen sideways.
  --
  -- The old version added a half-table term, which made the cap grow when
  -- the ball sat in the middle. That is exactly the inconsistency this is
  -- supposed to remove.
  local _, topY = worldToScreen(0, -tbl.H)
  local _, midY = worldToScreen(0, 0)
  if not (topY and midY) then return tbl.H end
  local pxPerTablePy = math.abs(midY - topY) / tbl.H
  if pxPerTablePy < 0.0001 then return tbl.H end
  -- topY is the screen y of the top rail; the gap above it is topY itself.
  return math.max(120, topY / pxPerTablePy)
end

-- ── geometry builders ─────────────────────────────────────────────────
-- Built through 3Dream's own buffers (getOrCreateBuffer + append), the path
-- its .obj loader uses. Assigning plain Lua tables to mesh.vertices looks
-- like it works and then dies inside the library, because everything
-- downstream calls :getSize() on them.
local function buildBox(material, hx, hy, hz)
  local m = dream:newMesh(material)
  local mv = m:getOrCreateBuffer("vertices")
  local mn = m:getOrCreateBuffer("normals")
  local mt = m:getOrCreateBuffer("texCoords")
  local mf = m:getOrCreateBuffer("faces")
  local faceDefs = {
    { {-hx,-hy, hz}, { hx,-hy, hz}, { hx, hy, hz}, {-hx, hy, hz}, { 0, 0, 1} },
    { { hx,-hy,-hz}, {-hx,-hy,-hz}, {-hx, hy,-hz}, { hx, hy,-hz}, { 0, 0,-1} },
    { {-hx, hy, hz}, { hx, hy, hz}, { hx, hy,-hz}, {-hx, hy,-hz}, { 0, 1, 0} },
    { {-hx,-hy,-hz}, { hx,-hy,-hz}, { hx,-hy, hz}, {-hx,-hy, hz}, { 0,-1, 0} },
    { { hx,-hy, hz}, { hx,-hy,-hz}, { hx, hy,-hz}, { hx, hy, hz}, { 1, 0, 0} },
    { {-hx,-hy,-hz}, {-hx,-hy, hz}, {-hx, hy, hz}, {-hx, hy,-hz}, {-1, 0, 0} },
  }
  local uv = { {0,0}, {1,0}, {1,1}, {0,1} }
  for _, f in ipairs(faceDefs) do
    local base = mv:getSize()
    for i = 1, 4 do mv:append(f[i]); mn:append(f[5]); mt:append(uv[i]) end
    mf:append({ base + 1, base + 2, base + 3 })
    mf:append({ base + 1, base + 3, base + 4 })
  end
  m:create()
  return m
end

local function buildSphere(material, r, seg)
  local m = dream:newMesh(material)
  local mv = m:getOrCreateBuffer("vertices")
  local mn = m:getOrCreateBuffer("normals")
  local mt = m:getOrCreateBuffer("texCoords")
  local mf = m:getOrCreateBuffer("faces")
  for i = 0, seg do
    local phi = math.pi * i / seg
    for j = 0, seg do
      local th = 2 * math.pi * j / seg
      local x = math.sin(phi) * math.cos(th)
      local y = math.cos(phi)
      local z = math.sin(phi) * math.sin(th)
      mv:append({ x * r, y * r, z * r })
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
  m:create()
  return m
end

-- ── setup ─────────────────────────────────────────────────────────────
local function addBall(num, x, z)
  local b = b3.body_new(world, x, tbl.BALL_R + 10, z)
  local s = b3.shape_sphere(b, tbl.BALL_R, tbl.MAT.ballDensity)
  local M = tbl.MAT.ball
  b3.shape_set_material(s, M.friction, M.restitution, M.rolling)
  -- Damping is what STOPS a ball, and it has to be split the right way or
  -- the balls slide like hockey pucks instead of rolling like billiards.
  --
  -- Linear damping bleeds travel; ANGULAR damping bleeds spin. Setting
  -- angular high (it was 0.9) meant every ball was braked out of rotating
  -- the instant the cloth's friction tried to spin it up, so the physics
  -- was genuinely 3D and the balls genuinely never rolled. Spin now decays
  -- only through rolling resistance, which is the real mechanism.
  b3.body_set_linear_damping(b, 0.28)
  b3.body_set_angular_damping(b, 0.06)
  -- Bullet (continuous collision) ONLY on the cue ball.
  --
  -- It is there so a hard break cannot tunnel through a cushion, and the cue
  -- ball is the only one that ever travels fast enough to need it. Turning
  -- it on for all sixteen made the solver treat the touching rack as one
  -- welded mass -- a measured 1 of 15 object balls moved on a full-power
  -- break. Racked balls are in resting contact; they want the ordinary
  -- discrete solver, which propagates an impulse down the chain.
  b3.body_set_bullet(b, num == 0)
  b3.shape_enable_hit_events(s, true)
  b3.body_set_sleep_threshold(b, 0.02 * tbl.PPM)   -- ~2 cm/s
  -- A random resting orientation.
  --
  -- A fresh body has identity rotation, which points its pole straight at
  -- an overhead camera -- so every ball in a new rack sat there showing its
  -- number face-on like a display case. Real racked balls show whatever
  -- face they happen to be sitting on. The scoreboard chips are the ONLY
  -- place a number should face the player, and those are drawn separately
  -- with no rotation at all.
  if num ~= 0 then
    local ax = love.math.random() * 2 - 1
    local ay = love.math.random() * 2 - 1
    local az = love.math.random() * 2 - 1
    local al = math.sqrt(ax * ax + ay * ay + az * az)
    if al < 0.01 then ax, ay, az, al = 0, 1, 0, 1 end
    b3.body_set_transform(b, x, tbl.BALL_R + 10, z,
                          ax / al, ay / al, az / al,
                          love.math.random() * math.pi * 2)
  end

  local rec = { num = num, body = b, shape = s, pocketed = false, x = x, z = z }
  balls[#balls + 1] = rec
  return rec
end

local function rack()
  for _, b in ipairs(balls) do b3.body_destroy(b.body) end
  for i = #balls, 1, -1 do balls[i] = nil end

  -- The camera looks down -Y with +X to the LEFT on screen, so the cue ball
  -- sits at +x to appear on the right and the rack grows toward -x. Getting
  -- this backwards is not an error, just a mirrored table, which is why it
  -- is worth stating rather than discovering again.
  -- Real table geometry: the cue ball sits on the head spot at a quarter of
  -- the table's length, the rack's apex on the foot spot at three quarters.
  cue = addBall(0, -tbl.W * 0.50, 0)
  local order = ballart.rackOrder(function(n) return love.math.random(n) end)
  local pos = ballart.rackPositions(tbl.W * 0.50, 0, tbl.BALL_R, 1)
  for i = 1, 15 do addBall(order[i], pos[i].x, pos[i].z) end

  state.groups = {}
  state.isBreak = true
  state.turn = PLAYER
  state.phase = "aim"
  state.message = "YOUR BREAK"
  state.messageMood = nil
  state.ballInHand = false
  state.winner = nil
  -- point at the rack, not at +x: the cue ball sits at +x and the rack is
  -- toward -x, so a zero angle aims off the end of the table.
  aimAngle = 0
  pull = 0
  if padUsed then startPlayerAim() end
end

function love.load()
  dream.canvases:setMode("direct")   -- no deferred g-buffer; see the spike notes
  dream:init()

  -- The metre scale must be set BEFORE the world exists: every length that
  -- follows (gravity, shape radii, thresholds) is converted through it.
  b3.set_meter(tbl.PPM)
  -- gravity in px/s^2: 9.81 m/s^2 at the table's own scale. Hardcoding 980
  -- was right only for the old (wrong) 64 px/m.
  world = b3.world_new(0, -9.81 * tbl.PPM, 0)
  b3.world_set_hit_threshold(world, 0.6 * tbl.PPM)  -- ~0.6 m/s
  table3d = tbl.build(world)

  sounds.loadAll()
  faces = ballart.makeFaces()

  -- The room. Without this the table floats in 3Dream's default grey, which
  -- is the single thing that made the old build read as a debug view rather
  -- than as a game.
  dream:setSky({ 0.055, 0.05, 0.065 })

  felt_tex = ballart.makeFelt(theme.felt)
  wood_tex = ballart.makeWood()

  -- Emission carries the colour: the textured mesh format's albedo sampler
  -- is not wired up in this engine, so an albedo-only material renders
  -- black no matter how many lights are in the scene. The shading that
  -- makes these surfaces read as surfaces is baked into the textures.
  mat_cloth = dream:newMaterial("cloth")
  mat_cloth:setColor(1, 1, 1, 1)
  mat_cloth:setEmissionTexture(felt_tex)
  mat_cloth:setEmission(0, 0, 0)
  mat_cloth:setEmissionFactor(1, 1, 1)
  mat_cloth:setRoughness(0.95)
  mat_cloth:setMetallic(0)

  mat_rail = dream:newMaterial("rail")
  mat_rail:setColor(1, 1, 1, 1)
  mat_rail:setEmissionTexture(wood_tex)
  mat_rail:setEmission(0, 0, 0)
  mat_rail:setEmissionFactor(1, 1, 1)
  mat_rail:setRoughness(0.6)
  mat_rail:setMetallic(0)

  for n = 0, 15 do
    local m = dream:newMaterial("ball" .. n)
    m:setColor(1, 1, 1, 1)
    m:setEmissionTexture(faces[n])
    -- the shader computes emission = texel * emissionFactor + emissionColor,
    -- so emissionColor must stay BLACK: any constant added here is added to
    -- every texel and washes the ball's number and colour out to white.
    m:setEmission(0, 0, 0)
    m:setEmissionFactor(1, 1, 1)
    m:setRoughness(0.12)
    m:setMetallic(0)
    mat_balls[n] = m
  end

  mesh_cloth = buildBox(mat_cloth, tbl.W / U, 0.08, tbl.H / U)
  do
    local lm = mesh_cloth:getMesh()
    if lm and lm.setTexture then lm:setTexture(felt_tex) end
  end

  -- The RAILS, as real geometry rather than a painted border. Four boxes
  -- standing proud of the cloth, so the table has an edge that catches the
  -- light and the playing surface is visibly inset. A pool table without
  -- rails reads as a green rectangle.
  mesh_rails = {}
  local RH = 0.34                      -- rail height above the cloth
  local RW = tbl.RAIL / U              -- rail thickness
  local function rail(hx, hy, hz, x, y, z)
    local m = buildBox(mat_rail, hx, hy, hz)
    local lm = m:getMesh()
    if lm and lm.setTexture then lm:setTexture(wood_tex) end
    mesh_rails[#mesh_rails + 1] = { mesh = m, x = x, y = y, z = z }
  end
  local halfW, halfH = tbl.W / U, tbl.H / U
  -- The rails form a closed frame, with a small quarter-round at each
  -- outer corner.
  --
  -- The rails run the FULL length and the corner piece is inscribed in the
  -- square they already leave, so the arc can never bulge past the rail
  -- face. The previous version centred the arc on the rail end with a
  -- radius LARGER than the rail thickness, so every corner stuck out past
  -- its own rails and read as four detached lumps.
  rail(halfW + RW * 2, RH, RW, 0, RH * 0.5, -(halfH + RW))
  rail(halfW + RW * 2, RH, RW, 0, RH * 0.5,  (halfH + RW))
  rail(RW, RH, halfH, -(halfW + RW), RH * 0.5, 0)
  rail(RW, RH, halfH,  (halfW + RW), RH * 0.5, 0)

  -- A quarter-round that rounds the OUTER corner only: it fills the square
  -- the two rails leave, minus the bite the arc takes out of it.
  local function corner(sx, sz)
    local m = dream:newMesh(mat_rail)
    local mv = m:getOrCreateBuffer("vertices")
    local mn = m:getOrCreateBuffer("normals")
    local mt = m:getOrCreateBuffer("texCoords")
    local mf = m:getOrCreateBuffer("faces")
    -- the outer corner of the frame, and the arc centre inset from it
    local ox = sx * (halfW + RW * 2)
    local oz = sz * (halfH + RW * 2)
    local cx = ox - sx * RW
    local cz = oz - sz * RW
    local SEG = 8
    local yTop = RH
    -- a triangle fan from the arc centre out to the arc
    local base = mv:getSize()
    mv:append({ cx, yTop, cz }); mn:append({ 0, 1, 0 }); mt:append({ 0.5, 0.5 })
    for i = 0, SEG do
      local a = (i / SEG) * (math.pi / 2)
      local px = cx + sx * RW * math.cos(a)
      local pz = cz + sz * RW * math.sin(a)
      mv:append({ px, yTop, pz })
      mn:append({ 0, 1, 0 })
      mt:append({ i / SEG, 1 })
      if i > 0 then
        mf:append({ base + 1, base + i + 1, base + i + 2 })
      end
    end
    m:create()
    local lm = m:getMesh()
    if lm and lm.setTexture then lm:setTexture(wood_tex) end
    mesh_rails[#mesh_rails + 1] = { mesh = m, x = 0, y = 0, z = 0 }
  end
  corner( 1,  1); corner(-1,  1); corner(-1, -1); corner( 1, -1)

  mesh_ball  = buildSphere(mat_balls[0], tbl.BALL_R / U, 14)
  -- one sphere mesh per number so each carries its own face texture
  mesh_ball = {}
  for n = 0, 15 do
    mesh_ball[n] = buildSphere(mat_balls[n], tbl.BALL_R / U, 14)
    -- Bind the face to the MESH, not only to the material.
    --
    -- 3Dream's material samplers are sent once per material switch and then
    -- many meshes are drawn, so all but the first sample whatever texture
    -- was bound last -- every ball comes out solid white. The mesh's own
    -- texture slot is bound per draw by the engine's Mesh path, which is
    -- exactly the per-object binding sixteen differently-numbered balls
    -- need.
    local lm = mesh_ball[n]:getMesh()
    if lm and lm.setTexture then lm:setTexture(faces[n]) end
  end

  rack()
end

-- ── shot bookkeeping ──────────────────────────────────────────────────
local function anyMoving()
  for _, b in ipairs(balls) do
    if not b.pocketed and b3.body_is_awake(b.body) then return true end
  end
  return false
end

local function fire(angle, pow)
  -- impulse = mass * desired velocity, in the binding's px units
  local v = SHOT_V_MIN + (SHOT_V_MAX - SHOT_V_MIN) * pow
  local imp = b3.body_mass(cue.body) * v * b3.get_meter()
  b3.body_set_awake(cue.body, true)
  local ix = math.cos(angle) * imp
  local iz = math.sin(angle) * imp
  -- Strike slightly ABOVE centre, as a real cue does.
  --
  -- An impulse through the centre of mass produces no torque at all, so the
  -- cue ball would leave the tip sliding rather than rolling and only pick
  -- up spin from cloth friction. Hitting above centre imparts forward roll
  -- immediately, which is both what happens on a real table and what makes
  -- the ball visibly turn as it travels.
  local cx, cy, cz = b3.body_position(cue.body)
  b3.body_apply_impulse_at(cue.body, ix, 0, iz, cx, cy + tbl.BALL_R * 0.45, cz)
  shot = { firstHit = nil, pocketed = {}, cueScratched = false,
           railAfter = false, isBreak = state.isBreak, offTable = {} }
  state.phase = "roll"
  rollFrames = 0
  sounds.play("chips", 0.5)
end

-- Pull the shot's story out of the physics: what was hit first, what fell,
-- whether anything reached a cushion. The rules module judges it; this only
-- reports.
local function observe()
  local ev = b3.contact_events(world)
  for _, h in ipairs(ev.hits or {}) do
    local a, b = h.a, h.b
    local ca = table3d.cushionShapes[a] or table3d.cushionShapes[b]
    local involvesCue = (a == cue.shape or b == cue.shape)

    if ca then
      if shot.firstHit then shot.railAfter = true end
      if (h.speed or 0) > 120 then sounds.play("place", 0.35) end
    elseif involvesCue and not shot.firstHit then
      local other = (a == cue.shape) and b or a
      for _, bb in ipairs(balls) do
        if bb.shape == other then shot.firstHit = bb.num end
      end
      local v = math.min(1, (h.speed or 0) / 900)
      sounds.play("deal", 0.35 + v * 0.5)
    elseif (h.speed or 0) > 150 then
      sounds.play("deal", 0.3)
    end
  end

  for _, b in ipairs(balls) do
    if not b.pocketed then
      local x, y, z = b3.body_position(b.body)
      b.x, b.z = x, z
      -- Pocketed the moment the ball reaches a pocket MOUTH, not once it
      -- has fallen below the cloth. Waiting for the drop let a ball roll
      -- straight through the side-pocket gap and out onto the floor, which
      -- reads as the table leaking rather than as a pot.
      if y < -60 or tbl.overPocket(x, z) then
        b.pocketed = true
        b3.body_set_velocity(b.body, 0, 0, 0)
        b3.body_set_transform(b.body, 0, -9000, 0, 0, 1, 0, 0)
        if b.num == 0 then shot.cueScratched = true
        else shot.pocketed[#shot.pocketed + 1] = b.num end
        sounds.play("win", 0.55)
      elseif math.abs(x) > tbl.W + 200 or math.abs(z) > tbl.H + 200 then
        b.pocketed = true
        shot.offTable[#shot.offTable + 1] = b.num
        b3.body_set_transform(b.body, 0, -9000, 0, 0, 1, 0, 0)
      end
    end
  end
end

local function placeCueAt(x, z)
  cue.pocketed = false
  cue.x, cue.z = x, z
  b3.body_set_transform(cue.body, x, tbl.BALL_R + 10, z, 0, 1, 0, 0)
  b3.body_set_velocity(cue.body, 0, 0, 0)
  b3.body_set_angular_velocity(cue.body, 0, 0, 0)
  b3.body_set_awake(cue.body, true)
end

local function endTurn(verdict)
  if verdict.rerack then
    state.message = verdict.reason
    rack()
    return
  end
  if verdict.win then
    state.winner = state.turn
    state.phase = "over"
    state.message = (state.turn == PLAYER) and "YOU WIN!" or "CPU WINS"
    state.messageMood = (state.turn == PLAYER) and "win" or "loss"
    return
  end
  if verdict.lose then
    state.winner = (state.turn == PLAYER) and CPU or PLAYER
    state.phase = "over"
    state.message = (state.turn == PLAYER) and verdict.reason or "CPU FOULED - YOU WIN!"
    state.messageMood = (state.turn == PLAYER) and "loss" or "win"
    return
  end

  if verdict.assigned then
    state.groups[state.turn] = verdict.assigned
    state.groups[3 - state.turn] =
      (verdict.assigned == rules.SOLIDS) and rules.STRIPES or rules.SOLIDS
  end

  state.isBreak = false

  if verdict.foul then
    state.message = verdict.reason
    state.messageMood = "loss"
    state.turn = 3 - state.turn
    state.ballInHand = true
  elseif verdict.continue then
    state.message = "NICE SHOT"
    state.messageMood = "win"
    state.ballInHand = false
  else
    state.message = ""
    state.messageMood = nil
    state.turn = 3 - state.turn
    state.ballInHand = false
  end

  -- the cue must come back if it fell
  if cue.pocketed then
    state.ballInHand = true
  end

  if state.ballInHand and state.turn == PLAYER then
    state.phase = "placing"
    placeX, placeZ = tbl.W * 0.5, 0
    state.message = "BALL IN HAND"
  else
    state.phase = "aim"
    cpuThink = 0
    if state.turn == PLAYER then startPlayerAim() end
  end
end

-- Set up a fresh player shot.
--
-- The cue starts HALF drawn back so a shot is one press away rather than
-- fifteen, and the aim starts pointed at a sensible ball with a small
-- random error -- never dead-on. The aim line is a hint about DIRECTION,
-- not a solved shot: the player still owns the power and the last few
-- degrees.
--
-- Pad only. On touch the drag defines both angle and power from wherever
-- the finger lands, so a pre-set pull would just fight the gesture.
function startPlayerAim()
  pull = 0
  dragging = false
  if AUTO then return end
  local tgt = rules.targetGroup(state, PLAYER)
  local best, bestD
  for _, b in ipairs(balls) do
    if not b.pocketed and b.num ~= 0 then
      local grp = rules.groupOf(b.num)
      local legal = (tgt == nil and b.num ~= 8)
                 or (tgt == "eight" and b.num == 8)
                 or (tgt ~= nil and tgt ~= "eight" and grp == tgt)
      if legal then
        local dx, dz = b.x - cue.x, b.z - cue.z
        local d = dx * dx + dz * dz
        if not bestD or d < bestD then bestD, best = d, b end
      end
    end
  end
  if best then
    aimAngle = math.atan(best.z - cue.z, best.x - cue.x)
                 + (love.math.random() * 2 - 1) * 0.06   -- never dead-on
  end
  pull = PULL_MAX * 0.5                                   -- half power to start
end

-- ── update ────────────────────────────────────────────────────────────
function love.update(dt)
  readEdges()
  readClicks()

  if state.phase == "roll" then
    -- Two half-steps per frame, 8 substeps each. A break sends the cue ball
    -- across a third of a ball-width per substep; coarser than this and a
    -- fast ball can pass between two racked balls without registering a
    -- contact, which is exactly how a break ends up moving one ball.
    b3.world_step(world, 1 / 120, 8)
    b3.world_step(world, 1 / 120, 8)
    observe()
    rollFrames = rollFrames + 1
    -- settle: everything asleep, or a hard cap so a stuck ball cannot hang
    -- the game forever
    if (rollFrames > 30 and not anyMoving()) or rollFrames > 1200 then
      if cue.pocketed then placeCueAt(-tbl.W * 0.5, 0); cue.pocketed = true end
      local verdict = rules.judge(state, state.turn, shot)
      if cue.pocketed then placeCueAt(-tbl.W * 0.5, 0) end
      endTurn(verdict)
    end
    return
  end

  -- keep the world ticking gently so bodies settle visually
  b3.world_step(world, 1 / 60, 4)

  if state.phase == "over" then
    -- same leftover-touch guard as PLACE: the tap that dismisses the result
    -- must not also be read as the start of a shot on the new rack
    if confirmPressed() or click then
      rack()
      dragging = false
      armDrag = false
    end
    return
  end

  if state.phase == "placing" then
    local sp = 7
    if heldLeft()  then placeX = placeX - sp end
    if heldRight() then placeX = placeX + sp end
    if not AUTO and love.pad.isDown("up")   then placeZ = placeZ - sp end
    if not AUTO and love.pad.isDown("down") then placeZ = placeZ + sp end
    -- Touch/mouse: drag the ball around the cloth. The cursor follows the
    -- finger for as long as it is down, so it can be nudged into place
    -- rather than committed on the first tap -- and crucially it does NOT
    -- place on release, because the release still has to be available for
    -- the PLACE button. Confirm is a separate, deliberate act.
    if clickHeld and not inRect(clickHeld, PLACE_BTN) then
      local wx, wz = screenToWorld(clickHeld.x, clickHeld.y)
      if wx then placeX, placeZ = wx, wz end
    end
    placeX = math.max(-tbl.W + tbl.BALL_R, math.min(tbl.W - tbl.BALL_R, placeX))
    placeZ = math.max(-tbl.H + tbl.BALL_R, math.min(tbl.H - tbl.BALL_R, placeZ))
    if confirmPressed() or inRect(click, PLACE_BTN) then
      placeCueAt(placeX, placeZ)
      state.ballInHand = false
      state.phase = "aim"
      state.message = ""
      -- The finger that tapped PLACE is still DOWN. Without this the aim
      -- phase sees it as a drag already in progress and lifting off fires a
      -- shot the player never aimed -- placing the ball launched it.
      -- Require the touch to be released and started again.
      dragging = false
      armDrag = false
    end
    return
  end

  -- CPU takes its turn
  if state.turn == CPU then
    cpuThink = cpuThink + 1
    if state.ballInHand then
      local spot = bot.placeCue({ balls = balls, cue = cue },
                                rules.targetGroup(state, CPU))
      placeCueAt(spot.x, spot.z)
      state.ballInHand = false
    end
    -- a beat before it shoots, so the player sees the table
    if cpuThink > 50 then
      local snap = { balls = balls, cue = { x = cue.x, z = cue.z } }
      local tgt = rules.targetGroup(state, CPU)
      local s = bot.chooseShot(snap, tgt, function() return love.math.random() end)
          or bot.safetyShot(snap, tgt, function() return love.math.random() end)
      if s then
        aimAngle = s.angle
        fire(s.angle, s.power)
      else
        fire(love.math.random() * math.pi * 2, 0.4)
      end
    end
    return
  end

  -- ── the player's shot: aim, pull back, strike ───────────────────────
  if state.phase == "aim" then
    -- the cap depends on the projection, so it is refreshed live
    PULL_MAX = pullMax()
    local step = 0.014
    -- RIGHT sweeps the cue CLOCKWISE on screen, LEFT counter-clockwise.
    --
    -- Measured, not derived: holding RIGHT with the old signs walked the cue
    -- tip DOWN the left-hand side, which is counter-clockwise. The aim angle
    -- is consumed as (cos, sin) -> (x, z) and the projection flips the
    -- vertical, so the on-screen sense is the opposite of the maths sense.
    if heldLeft()  then aimAngle = aimAngle + step end
    if heldRight() then aimAngle = aimAngle - step end
    if edges.left  then aimAngle = aimAngle + step end
    if edges.right then aimAngle = aimAngle - step end

    -- UP/DOWN draw the cue back and push it in. Held, not tapped, so a
    -- shaky thumb cannot overshoot in one press.
    local pullStep = 7
    if not AUTO then
      if love.pad.isDown("down") then pull = pull + pullStep end
      if love.pad.isDown("up")   then pull = pull - pullStep end
    end
    if edges.down then pull = pull + pullStep end
    if edges.up   then pull = pull - pullStep end

    -- TOUCH: the pull is always measured FROM THE CUE BALL to the finger,
    -- wherever on screen the finger happens to be. So the stick lands under
    -- your thumb and stretches back as you drag away, exactly like dragging
    -- a real cue -- and lifting off strikes, so touch needs no button.
    --
    -- Screen distance is converted to table distance through the projection
    -- so the pull means the same thing it does on the pad: one shared power
    -- scale, not two that drift apart.
    -- A drag only counts once the screen has been released since entering
    -- this phase; otherwise a finger left over from the PLACE tap (or from
    -- dismissing a result) reads as an aim already under way.
    if not clickHeld then armDrag = true end

    if clickHeld and armDrag then
      -- Measure the drag in WORLD space, not screen space.
      --
      -- The shot travels OPPOSITE the drag, like a real cue. That is a
      -- vector negation, and a negation is only meaningful in a space where
      -- both axes mean the same kind of thing. Doing it on screen deltas
      -- meant hand-reasoning about which of screen-x and screen-y agrees
      -- with the table's axes through the projection -- and negating just
      -- ONE component does not reverse a vector, it MIRRORS it, so a
      -- straight-down drag came out as a shot to the left. That sign was
      -- flipped repeatedly by inference and got it wrong every time.
      --
      -- screenToWorld puts the finger on the cloth exactly (round-tripped
      -- to 0.0000 table px), so the pull vector is cue -> finger in table
      -- coordinates and the aim is simply its opposite. No conventions to
      -- get backwards, and it stays correct if the camera ever moves.
      local fx, fz = screenToWorld(clickHeld.x, clickHeld.y)
      if fx then
        local dx, dz = fx - cue.x, fz - cue.z
        local d = math.sqrt(dx * dx + dz * dz)
        if d > 20 then
          aimAngle = math.atan(-dz, -dx)
          pull = math.min(PULL_MAX, d)
          dragging = true
        end
      end
    elseif dragging then
      -- finger lifted: strike with whatever was pulled back
      dragging = false
      if pull > 12 then fire(aimAngle, pull / PULL_MAX) else pull = 0 end
    end

    pull = math.max(PULL_MIN, math.min(PULL_MAX, pull))

    -- confirm strikes, on the pad. Skipped on the very first press, which
    -- only wakes the pad UI (see padUsed).
    if confirmPressed() and padWokeOnFrame ~= frameNo then
      if pull > 12 then
        fire(aimAngle, pull / PULL_MAX)
      else
        state.message = "PULL BACK WITH DOWN FIRST"
        state.messageMood = nil
      end
    end
  end
end

-- ── draw ──────────────────────────────────────────────────────────────
function love.draw()
  love.graphics.clear(0.04, 0.06, 0.05, 1)

  local eye = dream.vec3(0, CAM_H, CAM_TILT)
  local cam = dream:newCamera(camWorld(eye))
  cam:setFov(CAM_FOV)

  dream:prepare()
  -- prepare() clears the light list every frame, so lights are added HERE,
  -- not once in love.load: a light registered at load time is wiped before
  -- the first draw and every surface renders unlit.
  dream:addNewLight("point", dream.vec3(0, 8, 0), dream.vec3(1, 0.97, 0.92), 70)

  -- PASS 1: the table itself.
  dream:draw(mesh_cloth, 0, 0, 0)
  for _, r in ipairs(mesh_rails) do dream:draw(r.mesh, r.x, r.y, r.z) end
  dream:present(cam)
  projCam = cam.transformProj

  -- The pockets go on the cloth BEFORE the balls, so a ball crossing a
  -- pocket mouth passes OVER it. Drawn after the balls they painted on top,
  -- which read as the ball sinking under the hole while still in play.
  love.graphics.setDepthMode()
  love.graphics.setMeshCullMode("none")
  drawPockets()

  -- CONTACT SHADOWS, between the cloth and the balls.
  --
  -- This is the single thing that stops a rendered ball reading as a flat
  -- disc floating over the felt, and it is the one piece of a sphere's
  -- light-and-shadow structure that no amount of texture work can supply:
  -- shading lives ON the ball, but the shadow is evidence about the ball's
  -- RELATIONSHIP to the surface. Without it there is nothing anchoring a
  -- ball to the cloth. (See docs/DESIGN.md; the reference is the standard
  -- art-school sphere study and every billiard renderer worth copying.)
  --
  -- Two parts, both from that same structure:
  --   * a soft CAST shadow, offset away from the lamp. Straight down, a
  --     sphere's cast shadow is very nearly a circle, so concentric rings
  --     of darkened felt are enough and cost nothing.
  --   * an OCCLUSION core right at the contact point, tighter and darker,
  --     where nothing can reach at all.
  -- Deliberately NOT drawn under a ball hanging over a pocket -- there is
  -- no cloth there to receive it.
  do
    local g = love.graphics
    local r0 = worldToScreen(0, 0)
    local r1 = worldToScreen(tbl.BALL_R, 0)
    local br = (r0 and r1) and math.abs(r1 - r0) or 14
    -- lamp is above and slightly toward -x/+z (matches balls.lua shade())
    local offx, offy = br * 0.30, br * 0.34
    for _, b in ipairs(balls) do
      if not b.pocketed then
        -- Read the body LIVE rather than using the cached b.x/b.z. Those
        -- are only refreshed by observe(), which runs during the roll and
        -- FREEZES at the instant a ball is flagged pocketed -- so a stale
        -- pair could paint a shadow on empty cloth for a ball that is no
        -- longer being drawn. Whatever is rendered must be what casts.
        local wx, wy, wz = b3.body_position(b.body)
        local sx, sy = worldToScreen(wx, wz)
        -- No cloth over a pocket to receive a shadow, and none once the
        -- ball has started to drop below the surface.
        local nearPocket = tbl.overPocket(wx, wz) or wy < -2
        for _, p in ipairs(tbl.pockets()) do
          local dx, dz = wx - p.x, wz - p.z
          if dx * dx + dz * dz < (tbl.POCKET_R * 1.35) ^ 2 then nearPocket = true end
        end
        if sx and not nearPocket then
          -- Opaque rings over the felt colour rather than alpha: a
          -- translucent fill after the 3D pass is not dependable across
          -- backends, which is why the pockets are drawn this way too.
          local function ring(cx, cy, r, cr, cg, cb)
            local pts, N = {}, 22
            for i = 0, N - 1 do
              local a = i / N * math.pi * 2
              pts[#pts + 1] = cx + math.cos(a) * r
              pts[#pts + 1] = cy + math.sin(a) * r
            end
            g.setColor(cr, cg, cb)
            g.polygon("fill", pts)
          end
          ring(sx + offx, sy + offy, br * 1.16, 0.052, 0.235, 0.098)
          ring(sx + offx * 0.8, sy + offy * 0.8, br * 0.98, 0.040, 0.196, 0.082)
          ring(sx + offx * 0.5, sy + offy * 0.5, br * 0.80, 0.030, 0.156, 0.066)
        end
      end
    end
    g.setColor(1, 1, 1)
  end

  -- PASS 2: the balls, on top of everything.
  dream:prepare()
  dream:addNewLight("point", dream.vec3(0, 8, 0), dream.vec3(1, 0.97, 0.92), 70)
  for _, b in ipairs(balls) do
    if not b.pocketed then
      local x, y, z = b3.body_position(b.body)
      -- Draw with the body's ORIENTATION, not just its position.
      --
      -- dream:draw(mesh, x, y, z) builds a translation-only matrix, which
      -- throws away the rotation Box3D computed -- so the balls slid across
      -- the cloth like sprites and the whole thing read as 2D physics on a
      -- 3D table. The numbers painted on a ball are the tell: if they never
      -- turn, it is not rolling.
      local qx, qy, qz, qw = b3.body_rotation(b.body)
      dream:draw(mesh_ball[b.num], quatMat(qx, qy, qz, qw, x / U, y / U, z / U))
    end
  end
  dream:present(cam)
  projCam = cam.transformProj

  -- 3Dream leaves depth test and back-face culling on from its geometry
  -- pass; a 2D overlay is drawn at one depth with no consistent winding, so
  -- both would silently discard it.
  love.graphics.setDepthMode()
  love.graphics.setMeshCullMode("none")

  chipQueue = {}
  drawHUD()
  drawChips()
end

-- The scoreboard's potted balls, as real GL spheres.
--
-- Rendered through their own orthographic-ish camera placed so that one
-- dream unit maps to a known number of screen pixels: that lets a chip be
-- positioned in HUD pixel coordinates while still being a lit, textured
-- sphere rather than a flat disc.
--
-- No rotation is applied, so the number faces the player. The balls on the
-- cloth keep their physical orientation -- a ball there should show the face
-- it rolled to -- but a ball in the tray exists to be READ.
function drawChips()
  if #chipQueue == 0 then return end
  local W, H = love.graphics.getWidth(), love.graphics.getHeight()

  -- A camera looking down -Z at the HUD plane. Placing the eye at
  -- (0,0,dist) with this fov makes the visible half-height exactly `half`
  -- dream units, so screen pixels convert by a single scale factor.
  -- A NARROW field of view with the camera pushed far back, which is
  -- effectively an orthographic projection.
  --
  -- At a wide fov a chip near the screen edge sits ~39 degrees off the view
  -- axis, and a sphere that far off-axis is foreshortened into an OVAL. The
  -- table camera does not suffer this because the balls are near its centre;
  -- the scoreboard spans the full width. Narrowing to 8 degrees puts every
  -- chip within ~5 degrees of the axis, so they stay round.
  local half = 6.0
  local fov = 8
  local dist = half / math.tan(math.rad(fov / 2))
  local pxPerUnit = (H / 2) / half

  local eye = dream.vec3(0, 0, dist)
  local cam = dream:newCamera(dream.mat4({
    1, 0, 0, eye.x,
    0, 1, 0, eye.y,
    0, 0, 1, eye.z,
    0, 0, 0, 1,
  }))
  cam:setFov(fov)

  dream:prepare()
  -- a light in front so the chips are lit from the viewer's side
  dream:addNewLight("point", dream.vec3(0, 2.5, dist * 0.8),
                    dream.vec3(1, 0.98, 0.94), 55)

  for _, c in ipairs(chipQueue) do
    -- HUD pixels -> dream units on the z=0 plane
    local ux = (c.x - W / 2) / pxPerUnit
    local uy = -(c.y - H / 2) / pxPerUnit
    local scale = (c.rad / pxPerUnit) / (tbl.BALL_R / U)
    -- NO rotation: the identity pose already points u=0.25 -- the first
    -- number circle, which sits on the EQUATOR -- straight down -Z at this
    -- camera.
    --
    -- This used to carry a quarter turn about X, from when the number lived
    -- at the ball's pole. Moving the number to the equator (see balls.lua)
    -- made that rotation exactly wrong, and the tray went back to showing
    -- bare colour.
    dream:draw(mesh_ball[c.num], dream.mat4({
      scale, 0,     0,     ux,
      0,     scale, 0,     uy,
      0,     0,     scale, 0,
      0,     0,     0,     1,
    }))
  end
  dream:present(cam)

  love.graphics.setDepthMode()
  love.graphics.setMeshCullMode("none")
end

-- The six pockets, projected onto the cloth.
--
-- Drawn after the 3D pass rather than as geometry because a pocket is a
-- HOLE: it has no lit surface of its own, and a black disc sitting exactly
-- on the cloth is both the correct look and the cheapest one. They matter
-- more than they sound -- without them a player has no idea where to aim,
-- which is the difference between a pool table and a green rectangle.
function drawPockets()
  local g = love.graphics
  local r0 = worldToScreen(0, 0)
  local r1 = worldToScreen(tbl.POCKET_R, 0)
  local rad = (r0 and r1) and math.abs(r1 - r0) or 26
  for _, p in ipairs(tbl.pockets()) do
    local sx, sy = worldToScreen(p.x, p.z)
    if sx then
      -- The hole, drawn OPAQUE in concentric rings rather than as a
      -- translucent halo. Alpha after the 3D pass is not reliable across
      -- backends -- on Android the translucent version came out as a faint
      -- outline with no hole at all -- and a pocket a player cannot see is
      -- a pocket they cannot aim at.
      -- A POLYGON, not circle("fill").
      --
      -- The engine evaluates a filled circle per fragment from
      -- gl_FragCoord, which is viewport-relative -- and after 3Dream's pass
      -- the viewport is not the screen's, so the coverage test fails and
      -- the fill silently vanishes while ordinary line geometry still
      -- draws. A triangle fan is plain geometry and immune to that.
      local function disc(r, cr, cg, cb)
        local pts, N = {}, 28
        for i = 0, N - 1 do
          local a = i / N * math.pi * 2
          pts[#pts + 1] = sx + math.cos(a) * r
          pts[#pts + 1] = sy + math.sin(a) * r
        end
        g.setColor(cr, cg, cb)
        g.polygon("fill", pts)
      end
      disc(rad * 1.20, 0.055, 0.10, 0.06)
      disc(rad, 0.02, 0.02, 0.025)
      -- a brass lip catching the overhead lamp
      g.setColor(0.42, 0.34, 0.16, 0.85)
      g.setLineWidth(math.max(2, rad * 0.14))
      g.circle("line", sx, sy, rad * 1.02)
      g.setLineWidth(1)
    end
  end
end

function drawHUD()
  local g = love.graphics
  local W, H = g.getWidth(), g.getHeight()

  -- The aim line ahead of the ball, and the CUE STICK behind it.
  --
  -- Only once a control is actually in use: a pad that is merely present
  -- proves nothing (Android reports one nobody is holding), so this waits
  -- for a real press or a finger on the glass. Before that the table is
  -- clean and the player is not staring at a cue they cannot move.
  if state.phase == "aim" and state.turn == PLAYER and (padUsed or dragging) then
    local sx, sy = worldToScreen(cue.x, cue.z)
    -- where the shot is headed
    -- Stop the aim line at the first rail (or the first ball) it meets.
    -- Running it a fixed 700px shot it off the cloth and across the
    -- scoreboard, and a guide that leaves the table is telling the player
    -- about a shot that cannot happen.
    local dx, dz = math.cos(aimAngle), math.sin(aimAngle)
    local reach = 2200
    for _, ob in ipairs(balls) do
      if not ob.pocketed and ob ~= cue then
        -- distance along the ray to the closest approach
        local rx, rz = ob.x - cue.x, ob.z - cue.z
        local t = rx * dx + rz * dz
        if t > 0 then
          local px, pz = cue.x + dx * t, cue.z + dz * t
          local miss = math.sqrt((ob.x - px) ^ 2 + (ob.z - pz) ^ 2)
          if miss < tbl.BALL_R * 2 then
            -- back off to where the surfaces actually touch
            local back = math.sqrt(math.max(0, (tbl.BALL_R * 2) ^ 2 - miss * miss))
            reach = math.min(reach, math.max(0, t - back))
          end
        end
      end
    end
    -- and clamp to the cushions
    if dx > 0.0001 then reach = math.min(reach, (tbl.W - tbl.BALL_R - cue.x) / dx)
    elseif dx < -0.0001 then reach = math.min(reach, (-tbl.W + tbl.BALL_R - cue.x) / dx) end
    if dz > 0.0001 then reach = math.min(reach, (tbl.H - tbl.BALL_R - cue.z) / dz)
    elseif dz < -0.0001 then reach = math.min(reach, (-tbl.H + tbl.BALL_R - cue.z) / dz) end
    reach = math.max(0, reach)
    local ex, ey = worldToScreen(cue.x + dx * reach, cue.z + dz * reach)
    if sx and ex then
      g.setColor(1, 1, 1, 0.32)
      g.setLineWidth(2)
      g.line(sx, sy, ex, ey)
    end

    -- the cue itself, drawn back opposite the aim. Its LENGTH is the power
    -- and its COLOUR is the same number again: cream at a touch, red at
    -- full. Two channels for one value, because a length alone is hard to
    -- judge across a room.
    if sx and pull > 0 then
      local pct = pull / PULL_MAX
      local bx, by = worldToScreen(cue.x - math.cos(aimAngle) * (pull + 40),
                                   cue.z - math.sin(aimAngle) * (pull + 40))
      local tx, ty = worldToScreen(cue.x - math.cos(aimAngle) * 34,
                                   cue.z - math.sin(aimAngle) * 34)
      if bx and tx then
        local r = STICK_NEAR[1] + (STICK_FAR[1] - STICK_NEAR[1]) * pct
        local gg = STICK_NEAR[2] + (STICK_FAR[2] - STICK_NEAR[2]) * pct
        local bb = STICK_NEAR[3] + (STICK_FAR[3] - STICK_NEAR[3]) * pct

        -- Drawn as a tapered POLYGON, not a wide line: line width is capped
        -- by the GL path, so setLineWidth(24) still came out hairline. A
        -- quad also lets the cue taper from butt to tip like a real one.
        local ux, uy = tx - bx, ty - by
        local ul = math.sqrt(ux * ux + uy * uy)
        if ul > 0.001 then
          ux, uy = ux / ul, uy / ul
          local px, py = -uy, ux            -- perpendicular
          local wButt, wTip = 11, 5

          -- The SHAFT stops short of the tip: the last stretch is the pale
          -- ferrule, capped with a thin band of blue chalk, like a real cue.
          local ferL = math.min(ul * 0.16, 26)      -- ferrule length, px
          local chkL = math.min(ul * 0.05, 8)       -- chalk band, px
          local fx1, fy1 = tx - ux * (ferL + chkL), ty - uy * (ferL + chkL)
          local wFer = wTip + (wButt - wTip) * (ferL + chkL) / math.max(ul, 1)
          local cx1, cy1 = tx - ux * chkL, ty - uy * chkL
          local wChk = wTip + (wButt - wTip) * chkL / math.max(ul, 1)

          -- the stained shaft, butt to ferrule
          g.setColor(r, gg, bb)
          g.polygon("fill",
            bx + px * wButt, by + py * wButt,
            bx - px * wButt, by - py * wButt,
            fx1 - px * wFer, fy1 - py * wFer,
            fx1 + px * wFer, fy1 + py * wFer)
          -- the pale ferrule
          g.setColor(0.94, 0.92, 0.86)
          g.polygon("fill",
            fx1 + px * wFer, fy1 + py * wFer,
            fx1 - px * wFer, fy1 - py * wFer,
            cx1 - px * wChk, cy1 - py * wChk,
            cx1 + px * wChk, cy1 + py * wChk)
          -- and the blue chalk at the very tip
          g.setColor(0.20, 0.38, 0.62)
          g.polygon("fill",
            cx1 + px * wChk, cy1 + py * wChk,
            cx1 - px * wChk, cy1 - py * wChk,
            tx - px * wTip,  ty - py * wTip,
            tx + px * wTip,  ty + py * wTip)
          -- a darker edge so the cue reads against pale felt and pale balls
          g.setColor(r * 0.45, gg * 0.45, bb * 0.45)
          g.setLineWidth(2)
          g.polygon("line",
            bx + px * wButt, by + py * wButt,
            bx - px * wButt, by - py * wButt,
            tx - px * wTip,  ty - py * wTip,
            tx + px * wTip,  ty + py * wTip)
          g.setLineWidth(1)
        end
      end
    end
    g.setLineWidth(1)
  end

  -- ── the scoreboard ──────────────────────────────────────────────────
  --
  -- Two panels, one per player, each showing that player's GROUP and the
  -- balls they have actually sunk. Real pool balls, drawn with the same
  -- shading as the table's, because a flat dot beside a shaded ball reads
  -- as a different object. The active player's panel is lit gold; the
  -- other recedes. That is the whole "whose turn is it" signal, in the
  -- place a player is already looking.
  -- Polygons rather than circle("fill") -- see drawPockets for why a filled
  -- circle silently disappears after the 3D pass.
  local function disc(x, y, r, cr, cg, cb)
    local pts, N = {}, 22
    for i = 0, N - 1 do
      local a = i / N * math.pi * 2
      pts[#pts + 1] = x + math.cos(a) * r
      pts[#pts + 1] = y + math.sin(a) * r
    end
    g.setColor(cr, cg, cb)
    g.polygon("fill", pts)
  end

  -- Scoreboard chips are REAL GL SPHERES, not 2D discs: the same mesh and
  -- the same texture as the balls on the cloth, so a potted ball looks like
  -- the ball it was. They are queued here during HUD layout and drawn in
  -- their own 3D pass afterwards (drawChips), because a 3D draw cannot be
  -- interleaved with the 2D HUD.
  --
  -- Unlike the table balls they are drawn with NO rotation, so the number
  -- faces the player. On the cloth a ball shows whatever face it rolled to,
  -- which is correct; in the tray you want to read it.
  local function ballChip(num, x, y, rad)
    if not ballart.COLORS[num] then return end
    chipQueue[#chipQueue + 1] = { num = num, x = x, y = y, rad = rad }
  end

  -- The panels live in the band ABOVE the table, side by side, where there
  -- is real width to use. Down the left margin they collided with the rail.
  local function panel(seat, px, label)
    local active = (state.turn == seat and state.phase ~= "over")
    -- Three clean rows, no overlaps. Was 128 tall with the chips sitting on
    -- top of the group label -- the chip row spanned py+58..py+90 while
    -- "SOLIDS" ran py+56..py+86.
    local py, pw, ph = 20, 470, 150
    -- the panel itself
    -- opaque, for the same reason the pockets are: alpha after the 3D pass
    -- is not dependable across backends, and a panel that reads as solid on
    -- the desktop should not wash out on the phone
    g.setColor(0.045, 0.045, 0.055)
    g.rectangle("fill", px, py, pw, ph, 14, 14)
    if active then
      g.setColor(theme.gold[1], theme.gold[2], theme.gold[3], 0.95)
      g.setLineWidth(4)
      g.rectangle("line", px, py, pw, ph, 14, 14)
      g.setLineWidth(1)
    end

    -- ROW 1: who, and how many they have left
    g.setFont(ui.font(theme.fontMid))
    g.setColor(active and theme.gold or theme.quiet)
    g.print(label, px + 18, py + 8)

    local grp = state.groups[seat]
    g.setFont(ui.font(theme.fontSmall))
    g.setColor(theme.quiet)
    -- ROW 2: which group
    if grp then
      g.print(string.upper(grp), px + 18, py + 54)
    elseif state.phase ~= "over" then
      g.print("OPEN TABLE", px + 18, py + 54)
    end

    -- the balls this player has sunk, in a row across the panel
    local n = 0
    for _, b in ipairs(balls) do
      if b.pocketed and b.num ~= 0 and b.num ~= 8
         and grp and rules.groupOf(b.num) == grp then
        -- ROW 3: the balls sunk, clear of both text rows
        ballChip(b.num, px + 34 + n * 44, py + 116, 18)
        n = n + 1
      end
    end
    -- how many are left, which is the number a player actually wants
    if grp then
      local left = rules.remaining(balls, grp)
      g.setFont(ui.font(theme.fontSmall))
      g.setColor(left == 0 and theme.win or theme.quiet)
      g.printf(left == 0 and "ON THE 8" or (left .. " LEFT"),
               px, py + 14, pw - 18, "right")
    end
  end
  panel(PLAYER, 40, "YOU")
  panel(CPU, W - 510, "CPU")

  -- The message line, in the dark band BELOW the table rather than across
  -- the cloth: a banner over the playing surface hides the very balls the
  -- player is reading. Wins loud, losses quiet (docs/DESIGN.md).
  if state.message and state.message ~= "" then
    local col = theme.white
    if state.messageMood == "win" then col = theme.win
    elseif state.messageMood == "loss" then col = theme.lossRed end
    ui.banner(state.message, H - 128, col,
              state.phase == "over" and theme.fontHuge or theme.fontBig)
  end

  -- No power meter and no shoot button: the cue stick already shows the
  -- power as both a length and a colour, and confirm (or letting go of a
  -- drag) strikes. One less thing on screen, one less thing to learn.

  -- ball in hand cursor
  if state.phase == "placing" then
    local sx, sy = worldToScreen(placeX, placeZ)
    if sx then
      g.setColor(theme.gold)
      g.setLineWidth(4)
      g.circle("line", sx, sy, 26)
      g.line(sx - 40, sy, sx + 40, sy)
      g.line(sx, sy - 40, sx, sy + 40)
      g.setLineWidth(1)
    end
  end

  -- Ball-in-hand is the ONE case that still needs a button: there is no
  -- drag to release, so a tap has to mean "put it here".
  if state.turn == PLAYER and state.phase == "placing" then
    ui.button("PLACE", PLACE_BTN.x, PLACE_BTN.y, PLACE_BTN.w, PLACE_BTN.h, true)
  end

  if state.phase == "over" then
    g.setFont(ui.font(theme.fontMid))
    g.setColor(theme.quiet)
    g.printf("press to rack again", 0, H - 110, W, "center")
  end
end
