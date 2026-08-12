-- Combo - merge marbles on a 4:3 field. Shoot from the right, no pockets.
--
-- Rendering is 3DreamEngine, physics is Box3D, and the whole control scheme
-- is the family's: d-pad moves, one button commits, and every action is also
-- a tap. See docs/DESIGN.md -- this is built for one 85-year-old on a couch
-- with a gamepad, and the rules bend where the rule book would punish him
-- for something he could not see coming.
--
-- Shot flow -- PULL THE CUE BACK, no timed press and no on-screen button:
--   LEFT/RIGHT  swing the aim
--   UP/DOWN     pull the cueBall back; how far back IS the power, and the stick
--               fades cream -> red as it grows
--   confirm     strike (or, on touch, just let go of the drag)
--   ROLL        physics runs until every ball sleeps, then the rules judge
--
-- This is the mechanic from monteslu's 2012 pool game
-- (github.com/monteslu/pool): impulse = min(distance * k, maxImpulse), with
-- the stick colour fading start -> end by that same percentage. It beats a
-- sweeping power bar for this player because nothing is TIMED: the shot is
-- wherever you left the cueBall, and docs/DESIGN.md says nothing times out.

local dream  = require("3DreamEngine.init")
local theme  = require("lib.theme")
local ui     = require("lib.ui")
local sounds = require("lib.sounds")
local merge  = require("merge")
local tbl    = require("field")
local ballart= require("balls")

local U = tbl.U

-- A unit circle, tabulated ONCE. The contact-shadow pass draws 3 rings for
-- each of 16 balls at 22 points apiece -- 1056 sin/cos calls a frame for a
-- shape that never changes.
-- Pocket discs: 28 segments, their own table (the shadow rings use 22).
local DISC_N = 28
local DISC_COS, DISC_SIN = {}, {}
for i = 1, DISC_N do
  local a = (i - 1) / DISC_N * math.pi * 2
  DISC_COS[i] = math.cos(a)
  DISC_SIN[i] = math.sin(a)
end
local discPts = {}
local function pocketDisc(sx, sy, r, cr, cg, cb)
  for i = 1, DISC_N do
    discPts[i * 2 - 1] = sx + DISC_COS[i] * r
    discPts[i * 2]     = sy + DISC_SIN[i] * r
  end
  love.graphics.setColor(cr, cg, cb)
  love.graphics.polygon("fill", discPts)
end

local RING_N = 22
local RING_COS, RING_SIN = {}, {}
for i = 1, RING_N do
  local a = (i - 1) / RING_N * math.pi * 2
  RING_COS[i] = math.cos(a)
  RING_SIN[i] = math.sin(a)
end

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
-- STRAIGHT OVERHEAD, through a NARROW lens.
--
-- Two separate reasons, and both were visible on screen:
--
-- 1. No tilt. This is a top-down arena, not a pool table you stand at, so
--    a tilt buys nothing and costs a trapezoid -- the far edge of the field
--    renders smaller than the near edge, and the marbles with it.
--
-- 2. Narrow FOV. A sphere off the view axis projects as an ELLIPSE, and
--    the stretch goes as 1/cos(angle from axis). At 60 degrees across a
--    1440px-wide field the far marbles were stretched ~9% -- which is
--    exactly the "why are the balls sometimes oval" that monteslu spotted.
--    At 30 degrees it is 2%, below noticing. The camera moves back to keep
--    the same framing, which is the whole trade: distance buys roundness.
--
-- (Eight Ball hit this same thing on its scoreboard chips and fixed it the
-- same way. Different symptom, identical cause.)
local CAM_H, CAM_TILT, CAM_FOV = 18, 0, 30

-- The field is NOT centred on screen: it fills the left 1440 px of 1920 and
-- the right 480 is the cue's column. So the camera looks at a point offset
-- from the field's centre, which slides the field left in frame without
-- skewing it (moving the EYE sideways instead would shear the field).
--
-- MEASURED every time, never derived. The sign has flipped on me twice
-- (it depends on the up-vector convention as well as the projection), and
-- the magnitude does not scale the way the algebra suggests -- a LOWER
-- camera showed MORE field here, not less. Both numbers came from reading
-- the felt's pixel extent out of a screenshot and iterating.
local CAM_SHIFT = 2.1

-- 3Dream's camera.transform is a WORLD matrix: present() reads the eye
-- position out of its translation column and the forward axis out of column
-- 3. Handing it a view matrix (what lookAt returns) puts the camera in the
-- wrong place looking the wrong way, with no error anywhere.
local function camWorld(eye, target)
  target = target or dream.vec3(0, 0, 0)
  local f = (target - eye):normalize()
  -- UP is +Z, not +Y, because this camera looks straight DOWN the y axis.
  --
  -- The usual up vector (0,1,0) is PARALLEL to the view direction here, so
  -- the cross products below collapse and the basis is garbage. The old
  -- code had a fallback for that -- flip up to (0,0,1) when nearly parallel
  -- -- but a fallback that only fires at the degenerate moment means the
  -- camera's whole orientation SNAPS the instant the tilt reaches zero, and
  -- the marbles render as squashed ellipses. Naming +Z as up unconditionally
  -- makes straight-down the normal case rather than the special one.
  local up = dream.vec3(0, 0, 1)
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
local balls = {}          -- { tier, body, shape, dead, x, z, combo, comboT }
local cueBall             -- the ball currently sitting on the launcher

-- MAX ALLOWED life cost. The difficulty dial, and the first thing to tune
-- in playtest: the cubic in merge.lua is measured against it, so this
-- single number decides how crowded the table gets before the bar bites.
--
-- Combo Pool uses 34-50 on a field ~16 ball-diameters wide. Ours is 13.8
-- across with much bigger balls, so there is physically less room and the
-- budget has to come down with it. 24 is about six junk balls.
local MAX_ALLOWED = 24

local state = {
  phase = "aim",          -- aim | roll | over
  balls = balls,
  message = "",
  messageMood = nil,
  score = 0,
  best = 0,
  life = 100,
  lifeShown = 100,        -- the bar chases the real value, so it slides
  won = false,
}
local aimAngle = 0
-- How far the cueBall is drawn back, in table pixels. This IS the power: the
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

-- Cue-ball speed at full power, in METRES PER SECOND. A real break is
-- 7-11 m/s; a soft positional roll is about 1.
--
-- This used to be an arbitrary impulse constant that worked out to 470 m/s.
-- At that speed the cueBall ball crosses 500 px in a single 1/60 s step -- more
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
-- holding. So the cueBall stick and the aim line stay hidden until a real press
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
-- One mat4 per caller slot, reused every frame.
--
-- This used to build a fresh 16-element table AND a mat4 object per ball per
-- frame. Sixteen balls plus the tray chips made it the single largest
-- remaining allocation source in the frame. The matrix is handed to
-- dream:draw, copied into the render task, and consumed by the draw before
-- the frame ends -- nothing retains it past present(), so a per-slot buffer
-- is safe. Each caller passes a distinct slot so two live transforms never
-- share storage.
local quatMatPool = {}
local chipMatPool = {}
-- Derive a rolling orientation from how far a ball has travelled.
--
-- Axis is perpendicular to the direction of motion (in the ground plane),
-- angle is distance/radius. Accumulated per ball so the roll is continuous
-- rather than recomputed from scratch each frame.
local function rollQuat(b)
  local x, z = b2.body_position(b.body)
  local dx, dz = x - (b.px or x), z - (b.pz or z)
  b.px, b.pz = x, z
  local d = math.sqrt(dx * dx + dz * dz)
  if d > 0.01 then
    -- perpendicular to travel, in the plane, NORMALISED. Dividing by d is
    -- what makes it a unit axis; without that the quaternion below scales
    -- the mesh instead of rotating it.
    b.axx, b.axz = dz / d, -dx / d
    b.spin = b.spin + d / tbl.BALL_R
  end
  local half = b.spin * 0.5
  local sn = math.sin(half)
  return b.axx * sn, 0, b.axz * sn, math.cos(half)
end

local function quatMat(slot, qx, qy, qz, qw, tx, ty, tz)
  local x2, y2, z2 = qx + qx, qy + qy, qz + qz
  local xx, xy, xz = qx * x2, qx * y2, qx * z2
  local yy, yz, zz = qy * y2, qy * z2, qz * z2
  local wx, wy, wz = qw * x2, qw * y2, qw * z2
  local m = quatMatPool[slot]
  if not m then
    m = dream.mat4({ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 })
    quatMatPool[slot] = m
  end
  m[1], m[2],  m[3],  m[4]  = 1 - (yy + zz), xy - wz,       xz + wy,       tx
  m[5], m[6],  m[7],  m[8]  = xy + wz,       1 - (xx + zz), yz - wx,       ty
  m[9], m[10], m[11], m[12] = xz - wy,       yz + wx,       1 - (xx + yy), tz
  m[13], m[14], m[15], m[16] = 0, 0, 0, 1
  return m
end

-- How far the cue may be drawn back, in FIELD pixels.
--
-- LONGER than Eight Ball's, because this layout has room Eight Ball did
-- not: the launcher sits at the right edge and the cue pulls back into the
-- 480 px HUD column, which is deliberately kept clear for exactly this.
--
-- This changes RESOLUTION, not POWER. The shot is fired with
-- `pull / PULL_MAX`, so a longer travel means the same 0..1 range spread
-- over more screen -- finer control at every power level, and full power
-- still means exactly what it meant before. A player who yanks the cue all
-- the way back gets the same shot they always did, just with more room to
-- have chosen something gentler on the way.
--
-- Measured from the RIGHT rail to the right edge of the screen, which is
-- the direction the cue actually travels here (shots go LEFT, so the stick
-- extends right). Derived from the live projection so it stays correct if
-- the camera framing moves.
local function pullMax()
  local rightX = worldToScreen(-tbl.W, 0)      -- world -x renders RIGHT
  local midX   = worldToScreen(0, 0)
  if not (rightX and midX) then return tbl.W end
  local pxPerFieldPx = math.abs(rightX - midX) / tbl.W
  if pxPerFieldPx < 0.0001 then return tbl.W end
  -- the gap from the right rail to the screen edge, in field pixels
  local W = love.graphics.getWidth()
  local gap = math.max(0, W - rightX)
  return math.max(200, gap / pxPerFieldPx)
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
local function addBall(tier, x, z, isCue)
  -- Box2D: x/y is the PLANE. The renderer calls it x/z because the camera
  -- looks down the 3D y axis, so "z" here is Box2D's y. Same number.
  local b = b2.body_new(world, x, z, 2)   -- 2 = DYNAMIC
  local sh = b2.shape_circle(b, tbl.BALL_R, {
    density     = 1.0,
    friction    = tbl.BALL_FRICTION,
    restitution = tbl.BALL_RESTITUTION,
  })
  -- Damping is the only thing that stops a marble: there is no cloth and no
  -- gravity, so without it a shot would ring around the box forever.
  b2.body_set_linear_damping(b, tbl.BALL_DAMPING)
  b2.body_set_bullet(b, isCue == true)

  local rec = { tier = tier, body = b, shape = sh, dead = false, x = x, z = z,
                combo = 1, comboT = 0,
                -- Spin is COSMETIC now. A 2D solver has no notion of a ball
                -- rolling, but a sphere that slides without turning reads as
                -- a sprite, so the renderer spins each marble about an axis
                -- derived from its own travel. Random start so a fresh table
                -- is not a row of identically-posed balls.
                spin = love.math.random() * math.pi * 2,
                -- The spin axis MUST be a unit vector. A quaternion built
                -- from a non-unit axis is not a rotation -- it carries a
                -- scale, and the ball renders as a squashed ellipse. These
                -- used to be raw random() * 2 - 1, so any ball that had not
                -- moved yet (and so never had its axis recomputed) drew as
                -- an oval. That is the "why are the balls sometimes oval"
                -- bug; the perspective FOV was only ever a small part of it.
                axx = 1, axz = 0 }
  balls[#balls + 1] = rec
  return rec
end

-- Where the launcher sits: hard against the RIGHT wall, vertically centred.
-- Shots travel LEFT across the field. (Screen +x is LEFT under this camera,
-- so the launcher lives at -x in world space. Stating it because getting it
-- backwards just mirrors the game rather than erroring.)
local function launchSpot()
  return -tbl.W + tbl.BALL_R * 1.6, 0
end

-- Put a fresh ball on the launcher. Every shot introduces a NEW ball, which
-- is what makes clutter accumulate: the player is always adding to the
-- table and can only ever remove by merging.
local function loadLauncher()
  local lx, lz = launchSpot()
  -- Low tiers only. Handing out a tier-4 would skip the work the game is
  -- made of; 1 and 2 keep every merge earned. (Combo Pool weights toward
  -- the bottom the same way.)
  local tier = (love.math.random() < 0.78) and 1 or 2
  cueBall = addBall(tier, lx, lz, true)
  return cueBall
end

local function newGame()
  for _, b in ipairs(balls) do b2.body_destroy(b.body) end
  for i = #balls, 1, -1 do balls[i] = nil end

  -- A few balls already on the field, so the first shot has something to
  -- work with rather than opening on an empty table.
  for i = 1, 4 do
    local x = (love.math.random() * 1.1 - 0.35) * tbl.W
    local z = (love.math.random() * 1.5 - 0.75) * tbl.H
    addBall(love.math.random() < 0.7 and 1 or 2, x, z)
  end

  loadLauncher()

  state.phase = "aim"
  state.message = ""
  state.messageMood = nil
  state.score = 0
  state.life = 100
  state.lifeShown = 100
  state.won = false
  aimAngle = 0        -- straight down the field, toward -x... which is LEFT
  pull = 0
end

function love.load()
  dream.canvases:setMode("direct")   -- no deferred g-buffer; see the spike notes
  dream:init()

  -- The metre scale must be set BEFORE the world exists: every length that
  -- follows (gravity, shape radii, thresholds) is converted through it.
  b2.set_meter(tbl.PPM)
  -- gravity in px/s^2: 9.81 m/s^2 at the table's own scale. Hardcoding 980
  -- was right only for the old (wrong) 64 px/m.
  -- ZERO GRAVITY. This is a top-down arena, not a table with a floor: the
  -- marbles are constrained to the plane by the simulation itself rather
  -- than by resting on something.
  world = b2.world_new(0, 0)
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

  for n = 1, ballart.TIERS do
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
  -- Drawn from RAIL_VISUAL, not RAIL: the physics wall is deliberately fat
  -- (so a hard shot cannot tunnel it) and would make an absurd border if we
  -- drew it. This is not a real pool table -- no pockets, nobody leaning on
  -- a cushion -- so the border is a thin trim line and the play field gets
  -- the space instead.
  local RH = 0.20                      -- rail height above the cloth
  local RW = tbl.RAIL_VISUAL / U       -- rail thickness, VISUAL only
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

  -- one sphere mesh per TIER so each carries its own face texture
  mesh_ball = {}
  for n = 1, ballart.TIERS do
    mesh_ball[n] = buildSphere(mat_balls[n], tbl.BALL_R / U, 14)
    -- Bind the face to the MESH, not only to the material.
    --
    -- 3Dream's material samplers are sent once per material switch and then
    -- many meshes are drawn, so all but the first sample whatever texture
    -- was bound last -- every ball comes out solid white. The mesh's own
    -- texture slot is bound per draw by the engine's Mesh path, which is
    -- exactly the per-object binding seven differently-coloured tiers
    -- need.
    local lm = mesh_ball[n]:getMesh()
    if lm and lm.setTexture then lm:setTexture(faces[n]) end
  end

  newGame()
end

-- ── shot bookkeeping ──────────────────────────────────────────────────
local function anyMoving()
  for _, b in ipairs(balls) do
    if not b.dead then
      local vx, vy = b2.body_velocity(b.body)
      if vx * vx + vy * vy > 4 then return true end
    end
  end
  return false
end

local function fire(angle, pow)
  if not cueBall then return end
  local v = SHOT_V_MIN + (SHOT_V_MAX - SHOT_V_MIN) * pow
  local imp = b2.body_mass(cueBall.body) * v * b2.get_meter()
  local ix = math.cos(angle) * imp
  local iz = math.sin(angle) * imp
  -- Strike ABOVE centre so the ball leaves rolling, not sliding. An impulse
  -- through the centre of mass makes no torque at all.
  b2.body_apply_impulse(cueBall.body, ix, iz)
  cueBall = nil          -- it is a field ball now; a new one loads on settle
  state.phase = "roll"
  rollFrames = 0
  sounds.play("chips", 0.5)
end

-- Find a ball by its physics shape, so contact events can be mapped back.
local function ballOfBody(h)
  for _, b in ipairs(balls) do
    if b.body == h and not b.dead then return b end
  end
  return nil
end

local popups = {}   -- floating score numbers: { x, z, text, t }

local function addPopup(x, z, text)
  popups[#popups + 1] = { x = x, z = z, text = text, t = 1.0 }
end

-- THE RULE. Two balls of the same tier that touch become one ball of the
-- next tier up.
--
-- Contact events are the trigger rather than a distance sweep: the solver
-- already knows exactly who touched whom this step, and asking it is both
-- cheaper and free of the "did they overlap enough?" tuning that a distance
-- test needs.
local function observe()
  -- Box2D reports contacts as pairs of BODY handles. Walls are not bodies
  -- here -- the boundary is a clamp, not a collider (see field.lua) -- so
  -- every contact is ball-on-ball and the only question is whether the two
  -- share a tier.
  for _, pair in ipairs(b2.contacts(world)) do
    local b1 = ballOfBody(pair[1])
    local b2b = ballOfBody(pair[2])
    if b1 and b2b and b1 ~= b2b and b1.tier == b2b.tier
       and not b1.dead and not b2b.dead then
      local tier = b1.tier
      local combo = math.max(b1.combo, b2b.combo)

      if tier >= ballart.TIERS then
        -- Top tier detonates: clears the board and wins.
        for _, b in ipairs(balls) do b.dead = true end
        state.score = state.score + merge.mergeScore(tier, combo) * 5
        state.won = true
        state.phase = "over"
        state.message = "BOARD CLEAR"
        state.messageMood = "win"
        sounds.play("win", 0.7)
        return
      end

      -- b2b dies, b1 is promoted IN PLACE so the merged marble keeps its
      -- momentum -- two beads fusing, rather than one vanishing and another
      -- appearing somewhere.
      b2b.dead = true
      b1.tier = tier + 1
      b1.combo = math.min(8, combo * 2)
      b1.comboT = 60

      local gained = merge.mergeScore(tier + 1, combo)
      state.score = state.score + gained
      addPopup(b1.x, b1.z, tostring(gained))
      sounds.play("chips", 0.6)
    end
  end
end

function startPlayerAim()
  pull = 0
  dragging = false
end

-- ── update ────────────────────────────────────────────────────────────
function love.update(dt)
  readEdges()
  readClicks()

  -- Popups drift up and fade wherever we are.
  for k = #popups, 1, -1 do
    local pp = popups[k]
    pp.t = pp.t - dt * 1.6
    pp.z = pp.z - dt * 40
    if pp.t <= 0 then table.remove(popups, k) end
  end

  -- Sweep merged-away balls out of the world. Deferred to here rather than
  -- done inside observe(): destroying a body while the solver is still
  -- walking its contact list is how you get a use-after-free.
  for k = #balls, 1, -1 do
    local b = balls[k]
    if b.dead then
      b2.body_destroy(b.body)
      table.remove(balls, k)
    end
  end

  -- Combo windows decay. A bank is only worth something for a short while,
  -- so a multiplier has to be SPENT on a merge rather than banked forever.
  for _, b in ipairs(balls) do
    if b.comboT > 0 then
      b.comboT = b.comboT - 1
      if b.comboT <= 0 then b.combo = 1 end
    end
  end

  if state.phase == "roll" then
    b2.world_step(world, 1 / 60, 8)
    -- THE BOUNDARY, applied after every step. This is what makes escaping
    -- impossible rather than merely unlikely: reflect and then HARD-CLAMP
    -- back inside, exactly as the original does. A bank also feeds the
    -- combo, since with no pockets the walls are the whole toolkit.
    for _, b in ipairs(balls) do
      if not b.dead and tbl.clampToField(b.body, tbl.BALL_R) then
        if b.combo < 8 then
          b.combo = b.combo * 2
          b.comboT = 60
        end
      end
    end
    observe()
    rollFrames = rollFrames + 1

    for _, b in ipairs(balls) do
      local x, z = b2.body_position(b.body)
      b.x, b.z = x, z
    end

    if (rollFrames > 30 and not anyMoving()) or rollFrames > 900 then
      -- The table has settled: score the situation and hand back control.
      state.life = merge.life(balls, MAX_ALLOWED)
      if state.life <= 0 and not state.won then
        state.phase = "over"
        state.message = "TABLE FULL"
        state.messageMood = "loss"
        sounds.play("lose", 0.6)
      elseif state.phase ~= "over" then
        loadLauncher()
        state.phase = "aim"
        state.message = ""
        startPlayerAim()
      end
    end
    return
  end

  -- keep the world ticking gently so bodies settle visually
  b2.world_step(world, 1 / 60, 4)
  for _, b in ipairs(balls) do
    if not b.dead then tbl.clampToField(b.body, tbl.BALL_R) end
  end
  for _, b in ipairs(balls) do
    local x, z = b2.body_position(b.body)
    b.x, b.z = x, z
  end
  state.life = merge.life(balls, MAX_ALLOWED)
  -- the bar CHASES the real value so it slides rather than jumping
  state.lifeShown = state.lifeShown + (state.life - state.lifeShown) * 0.12

  if state.phase == "over" then
    if confirmPressed() or click then
      state.best = math.max(state.best, state.score)
      newGame()
      dragging = false
      armDrag = false
    end
    return
  end

  -- ── the player's shot: aim, pull back, strike ───────────────────────
  if state.phase == "aim" then
    -- the cap depends on the projection, so it is refreshed live
    PULL_MAX = pullMax()
    local step = 0.014
    -- RIGHT sweeps the cueBall CLOCKWISE on screen, LEFT counter-clockwise.
    --
    -- Measured, not derived: holding RIGHT with the old signs walked the cueBall
    -- tip DOWN the left-hand side, which is counter-clockwise. The aim angle
    -- is consumed as (cos, sin) -> (x, z) and the projection flips the
    -- vertical, so the on-screen sense is the opposite of the maths sense.
    if heldLeft()  then aimAngle = aimAngle + step end
    if heldRight() then aimAngle = aimAngle - step end
    if edges.left  then aimAngle = aimAngle + step end
    if edges.right then aimAngle = aimAngle - step end

    -- UP/DOWN draw the cueBall back and push it in. Held, not tapped, so a
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
    -- a real cueBall -- and lifting off strikes, so touch needs no button.
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
      -- The shot travels OPPOSITE the drag, like a real cueBall. That is a
      -- vector negation, and a negation is only meaningful in a space where
      -- both axes mean the same kind of thing. Doing it on screen deltas
      -- meant hand-reasoning about which of screen-x and screen-y agrees
      -- with the table's axes through the projection -- and negating just
      -- ONE component does not reverse a vector, it MIRRORS it, so a
      -- straight-down drag came out as a shot to the left. That sign was
      -- flipped repeatedly by inference and got it wrong every time.
      --
      -- screenToWorld puts the finger on the cloth exactly (round-tripped
      -- to 0.0000 table px), so the pull vector is cueBall -> finger in table
      -- coordinates and the aim is simply its opposite. No conventions to
      -- get backwards, and it stays correct if the camera ever moves.
      local fx, fz = screenToWorld(clickHeld.x, clickHeld.y)
      if fx then
        local dx, dz = fx - cueBall.x, fz - cueBall.z
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

  local eye = dream.vec3(CAM_SHIFT, CAM_H, CAM_TILT)
  local cam = dream:newCamera(camWorld(eye, dream.vec3(CAM_SHIFT, 0, 0)))
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
  -- CONTACT SHADOWS. Drawn on the cloth BEFORE the pockets.
  --
  -- Order is load-bearing. A shadow is offset from its ball (away from the
  -- lamp), so a ball sitting BESIDE a pocket throws its shadow ACROSS the
  -- hole -- and a hole has no cloth to receive one. Painted after the
  -- pockets, that shadow smeared over the pocket's dark surround and read
  -- as a dirty patch on the ball's lower edge. The suppression test below
  -- cannot fix it: the BALL is legitimately on cloth, it is the SHADOW
  -- that is not. Drawing the pockets last lets the hole paint over any
  -- shadow that strays onto it, which is also what actually happens -- the
  -- hole is nearer the eye than the cloth the shadow lies on.
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
    -- ONE reusable point buffer and ONE closure for the whole pass. The
    -- ring() closure used to be allocated per ball and built a fresh
    -- 44-element table per call -- 48 throwaway tables a frame.
    local pts = {}
    local function ring(cx, cy, r, cr, cg, cb)
      for i = 1, RING_N do
        pts[i * 2 - 1] = cx + RING_COS[i] * r
        pts[i * 2]     = cy + RING_SIN[i] * r
      end
      g.setColor(cr, cg, cb)
      g.polygon("fill", pts)
    end
    for _, b in ipairs(balls) do
      if not b.dead then
        -- Read the body LIVE rather than using the cached b.x/b.z. Those
        -- are only refreshed by observe(), which runs during the roll and
        -- FREEZES at the instant a ball is flagged pocketed -- so a stale
        -- pair could paint a shadow on empty cloth for a ball that is no
        -- longer being drawn. Whatever is rendered must be what casts.
        local wx, wz = b2.body_position(b.body)
        local wy = 0
        local sx, sy = worldToScreen(wx, wz)
        -- No pockets here, so every ball on the field casts. Only a ball
        -- that has somehow left the surface is skipped.
        if sx and wy > -2 then
          -- Opaque rings over the felt colour rather than alpha: a
          -- translucent fill after the 3D pass is not dependable across
          -- backends, which is why the pockets are drawn this way too.
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
  for bi, b in ipairs(balls) do
    if not b.dead then
      local x, z = b2.body_position(b.body)
      local y = 0
      -- SPIN IS COSMETIC, and has to be, because the solver is 2D.
      --
      -- Box2D knows nothing about a marble rolling; it only pushes discs
      -- around a plane. But a textured sphere that slides without turning
      -- reads instantly as a sprite being dragged, which is the exact
      -- complaint that got the 3D physics into Eight Ball in the first
      -- place. So the roll is DERIVED: the ball turns about the axis
      -- perpendicular to its own travel, by the distance it moved over its
      -- circumference. That is what real rolling is, computed rather than
      -- simulated, and it is indistinguishable from across a room.
      local qx, qy, qz, qw = rollQuat(b)
      -- Slot keyed by LIST INDEX, not by tier: several balls share a tier
      -- and every transform is still live when present() walks the render
      -- tasks, so they cannot share one buffer.
      dream:draw(mesh_ball[b.tier],
                 quatMat(bi, qx, qy, qz, qw, x / U, y / U, z / U))
    end
  end
  dream:present(cam)
  projCam = cam.transformProj

  -- 3Dream leaves depth test and back-face culling on from its geometry
  -- pass; a 2D overlay is drawn at one depth with no consistent winding, so
  -- both would silently discard it.
  love.graphics.setDepthMode()
  love.graphics.setMeshCullMode("none")

  drawHUD()
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

-- The six pockets, projected onto the cloth.
--
-- Drawn after the 3D pass rather than as geometry because a pocket is a
-- HOLE: it has no lit surface of its own, and a black disc sitting exactly
-- on the cloth is both the correct look and the cheapest one. They matter
-- more than they sound -- without them a player has no idea where to aim,
-- which is the difference between a pool table and a green rectangle.

function drawHUD()
  local g = love.graphics
  local W, H = g.getWidth(), g.getHeight()

  -- The aim line ahead of the ball, and the CUE STICK behind it.
  --
  -- Only once a control is actually in use: a pad that is merely present
  -- proves nothing (Android reports one nobody is holding), so this waits
  -- for a real press or a finger on the glass. Before that the table is
  -- clean and the player is not staring at a cueBall they cannot move.
  if state.phase == "aim" and true and (padUsed or dragging) then
    local sx, sy = worldToScreen(cueBall.x, cueBall.z)
    -- where the shot is headed
    -- Stop the aim line at the first rail (or the first ball) it meets.
    -- Running it a fixed 700px shot it off the cloth and across the
    -- scoreboard, and a guide that leaves the table is telling the player
    -- about a shot that cannot happen.
    local dx, dz = math.cos(aimAngle), math.sin(aimAngle)
    local reach = 2200
    for _, ob in ipairs(balls) do
      if not ob.dead and ob ~= cueBall then
        -- distance along the ray to the closest approach
        local rx, rz = ob.x - cueBall.x, ob.z - cueBall.z
        local t = rx * dx + rz * dz
        if t > 0 then
          local px, pz = cueBall.x + dx * t, cueBall.z + dz * t
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
    if dx > 0.0001 then reach = math.min(reach, (tbl.W - tbl.BALL_R - cueBall.x) / dx)
    elseif dx < -0.0001 then reach = math.min(reach, (-tbl.W + tbl.BALL_R - cueBall.x) / dx) end
    if dz > 0.0001 then reach = math.min(reach, (tbl.H - tbl.BALL_R - cueBall.z) / dz)
    elseif dz < -0.0001 then reach = math.min(reach, (-tbl.H + tbl.BALL_R - cueBall.z) / dz) end
    reach = math.max(0, reach)
    local ex, ey = worldToScreen(cueBall.x + dx * reach, cueBall.z + dz * reach)
    if sx and ex then
      g.setColor(1, 1, 1, 0.32)
      g.setLineWidth(2)
      g.line(sx, sy, ex, ey)
    end

    -- the cueBall itself, drawn back opposite the aim. Its LENGTH is the power
    -- and its COLOUR is the same number again: cream at a touch, red at
    -- full. Two channels for one value, because a length alone is hard to
    -- judge across a room.
    if sx and pull > 0 then
      local pct = pull / PULL_MAX
      local bx, by = worldToScreen(cueBall.x - math.cos(aimAngle) * (pull + 40),
                                   cueBall.z - math.sin(aimAngle) * (pull + 40))
      local tx, ty = worldToScreen(cueBall.x - math.cos(aimAngle) * 34,
                                   cueBall.z - math.sin(aimAngle) * 34)
      if bx and tx then
        local r = STICK_NEAR[1] + (STICK_FAR[1] - STICK_NEAR[1]) * pct
        local gg = STICK_NEAR[2] + (STICK_FAR[2] - STICK_NEAR[2]) * pct
        local bb = STICK_NEAR[3] + (STICK_FAR[3] - STICK_NEAR[3]) * pct

        -- Drawn as a tapered POLYGON, not a wide line: line width is capped
        -- by the GL path, so setLineWidth(24) still came out hairline. A
        -- quad also lets the cueBall taper from butt to tip like a real one.
        local ux, uy = tx - bx, ty - by
        local ul = math.sqrt(ux * ux + uy * uy)
        if ul > 0.001 then
          ux, uy = ux / ul, uy / ul
          local px, py = -uy, ux            -- perpendicular
          local wButt, wTip = 11, 5

          -- The SHAFT stops short of the tip: the last stretch is the pale
          -- ferrule, capped with a thin band of blue chalk, like a real cueBall.
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
          -- a darker edge so the cueBall reads against pale felt and pale balls
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
  -- Polygons rather than circle("fill"): the engine evaluates a filled
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

  -- ── the right-hand column ─────────────────────────────────────────
  --
  -- The 4:3 field occupies the LEFT of the screen; everything else lives in
  -- the 480px column on the right. Life bar on top, HUD on the bottom, and
  -- the middle deliberately EMPTY because that is where the cue swings out
  -- to when the shot is pulled back to full power.
  local COL_X = W - 480
  local COL_W = 480

  -- LIFE BAR, top of the column.
  --
  -- This is the whole game state in one widget: it is not a timer, it is
  -- how crowded the table is. It falls as a cubic (see merge.lua), so it
  -- barely moves while there is room and then drops away quickly, and the
  -- player learns to read "I have to clear something" without being told.
  do
    local bx, by, bw, bh = COL_X + 30, 40, COL_W - 60, 46
    local warn = merge.warning(balls, MAX_ALLOWED)
    g.setColor(0.045, 0.045, 0.055)
    g.rectangle("fill", bx - 6, by - 6, bw + 12, bh + 12, 10, 10)
    -- the fill, coloured by how much trouble the player is in
    local frac = math.max(0, math.min(1, state.lifeShown / 100))
    if warn then
      g.setColor(theme.lossRed)
    elseif frac < 0.5 then
      g.setColor(0.95, 0.72, 0.15)
    else
      g.setColor(0.20, 0.78, 0.35)
    end
    g.rectangle("fill", bx, by, bw * frac, bh, 6, 6)
    g.setColor(0.35, 0.35, 0.40)
    g.setLineWidth(2)
    g.rectangle("line", bx, by, bw, bh, 6, 6)
    g.setLineWidth(1)
    if warn then
      g.setFont(ui.font(theme.fontMid))
      g.setColor(theme.lossRed)
      g.printf("TABLE FILLING", COL_X, by + bh + 12, COL_W, "center")
    end
  end

  -- SCORE + BEST, bottom of the column.
  do
    local py = H - 210
    g.setColor(0.045, 0.045, 0.055)
    g.rectangle("fill", COL_X + 24, py, COL_W - 48, 170, 14, 14)
    g.setFont(ui.font(theme.fontSmall))
    g.setColor(theme.quiet)
    g.print("SCORE", COL_X + 48, py + 18)
    g.setFont(ui.font(theme.fontBig))
    g.setColor(theme.white)
    g.print(tostring(state.score), COL_X + 48, py + 52)
    if state.best > 0 then
      g.setFont(ui.font(theme.fontSmall))
      g.setColor(theme.quiet)
      g.print("BEST " .. state.best, COL_X + 48, py + 128)
    end
  end

  -- Floating score popups, over the field where the merge happened.
  g.setFont(ui.font(theme.fontMid))
  for _, pp in ipairs(popups) do
    local sx, sy = worldToScreen(pp.x, pp.z)
    if sx then
      local a = math.max(0, math.min(1, pp.t))
      g.setColor(0, 0, 0, a)
      g.print(pp.text, sx + 2, sy + 2)
      g.setColor(1, 1, 1, a)
      g.print(pp.text, sx, sy)
    end
  end
  g.setColor(1, 1, 1)

  -- The message line, under the field rather than over it.
  if state.message and state.message ~= "" then
    local col = theme.white
    if state.messageMood == "win" then col = theme.win
    elseif state.messageMood == "loss" then col = theme.lossRed end
    local msgSize = (state.phase == "over") and theme.fontHuge or theme.fontBig
    local bannerY = H - 60 - theme.fontMid - msgSize
    ui.banner(state.message, bannerY, col, msgSize)
    if state.phase == "over" then
      g.setFont(ui.font(theme.fontMid))
      g.setColor(theme.quiet)
      g.printf("press to play again", 0, bannerY + msgSize + 14, W - 480, "center")
    end
  end
end
