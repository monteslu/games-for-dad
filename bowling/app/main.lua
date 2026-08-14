-- Bowling - ten frames, no clock, no way to lose badly.
--
-- BUILT ON THE DEFAULT RENDERER. Every solid thing here -- the lane, the
-- gutters, the ten pins, the ball -- is created through
-- love.physics3d.debug, which makes the collision shape AND the mesh that
-- draws it from the same numbers. There is no second description of the
-- geometry anywhere, so the picture cannot disagree with the simulation.
--
-- That is deliberate. Minigolf was built the other way -- art authored
-- separately from colliders -- and every rendering bug in it was a mesh
-- disagreeing with its body: a bumper offset twice and hanging in the sky,
-- a flat cap colliding as a 267x161 wall, a mirrored camera. Starting from
-- the physics view means those bugs cannot be written in the first place.
--
-- SCALE. Physics runs in cart pixels via b3.set_meter, as everywhere else
-- in this family. A real lane is 60 feet from foul line to headpin and 42
-- inches wide; at 34 px per foot that is 2040 x 119 -- too long for one
-- screen, so the lane is laid along +z and the camera watches it from the
-- side, square-on, framing the ball and the rack together.
--
-- THE FAMILY RULE: nothing moves unless he moves it. No shot clock, no
-- timer on the aim, and the ball waits at the foul line until he throws.

local theme  = require("lib.theme")
local ui     = require("lib.ui")
local sounds = require("lib.sounds")
local art    = require("art")
local dream  = require("3DreamEngine.init")
local dbg    = love.physics3d.debug

-- ── the alley, in cart pixels ─────────────────────────────────────────

local PPM      = 90                 -- pixels per metre
local GRAVITY  = -9.81 * PPM

local LANE_W   = 300                -- 42in at this scale, rounded for the eye
-- LONG, close to life. A real lane is 60ft from foul line to headpin and
-- 42in wide -- about 17:1. This ran at 4.6:1 for a while because a LEVEL
-- side camera flattens a long rack into a single row, and the length had to
-- pay for that. The 45-degree tilt fixes it at the source: looking down at
-- the deck opens the four rows out again, so the lane can be its real
-- proportions. 4200:300 is 14:1, most of the way there while keeping the
-- ball big enough to see.
local LANE_LEN = 4600               -- foul line to the pit
local LANE_Y   = 0                  -- the lane surface sits at y=0
local GUTTER_W = 90
local WALL_H   = 60

local BALL_R   = 52
local PIN_R    = 22
local PIN_H    = 130

-- Where the pins stand. Ten pins, four rows, 12in centres -- the real
-- triangle, pointing back at the bowler.
local PIN_SPACING = 96
local PIN_ROW_Z   = 4200            -- the headpin

-- Physics feel. A bowling ball is heavy and barely bounces; pins are light
-- and knock each other over, which is the entire game.
local BALL_FRICTION, BALL_REST, BALL_ROLL = 0.18, 0.08, 0.006
-- Pins topple and scatter; they do not cartwheel. The first pass had them
-- at 0.35 restitution and they flew the width of the lane off one hit,
-- which looks like a physics demo rather than bowling.
local PIN_FRICTION,  PIN_REST            = 0.55, 0.08

-- SIDE VIEW. The camera stands off the left rail, rides above the deck, and
-- looks square across the lane and down at it, so a throw travels
-- left-to-right across the screen. It backs off as the ball-to-rack span
-- grows so both stay in frame; this floor keeps it from crowding the pins
-- on the last few feet.
local SIDE_CAM_MIN_X = 900
-- How far the camera rides above the deck, as an ANGLE. 45 degrees is
-- halfway between a level side view (which flattens the rack into one row)
-- and a top-down plan (which loses the pins standing up).
local CAM_TILT       = math.rad(45)
-- The camera's FOV is VERTICAL. On a 16:9 frame the horizontal half-angle
-- is what actually has to cover the lane's length, so the fitting maths
-- works from this, not from the 56 passed to setFov.
local CAM_FOV        = 42
local CAM_HALF_H     = math.atan(math.tan(math.rad(CAM_FOV) * 0.5) * (1920 / 1080))
local CAM_FIT_SLACK  = 1.10        -- breathing room, see the fit in love.draw

-- Throwing. Pull back from the ball like every other game in the family.
local MAX_PULL  = 300
local MAX_SPEED = 1500
local MAX_SPIN  = 3.2               -- how much curve a full sideways drag adds

-- ── state ─────────────────────────────────────────────────────────────

local world
local ballBody, pins = nil, {}
local frameNo, ballNo = 1, 1        -- frame 1..10, ball 1 or 2
local rolls = {}                    -- every roll's pin count, in order
local state = "aim"                 -- aim | rolling | settling | between | done
local settleT = 0
local aimAngle, aimPull, aimSpin = 0, 0, 0
local dragFrom = nil
local msg, msgT = nil, 0
local standingAtFrameStart = 10
local t = 0

-- Audio state for the shot in flight. The roll is a long sound that has to
-- be cut when the ball arrives or drops in the channel, and the crash must
-- fire exactly once per roll rather than every frame the ball is near the
-- rack.
local rollingSound, hitRack, inGutter = false, false, false
local prevStanding = 10

local function setMsg(s, secs) msg, msgT = s, secs or 2.2 end

-- ── camera ────────────────────────────────────────────────────────────
--
-- 3Dream wants a WORLD matrix, not a view matrix. RIGHT is forward x up:
-- the other order gives a left-handed basis and mirrors the whole scene.
local function camWorld(eye, target)
  local up = dream.vec3(0, 1, 0)
  local f = (target - eye):normalize()
  if math.abs(f:dot(up)) > 0.999 then up = dream.vec3(0, 0, 1) end
  local r = f:cross(up):normalize()
  local u = r:cross(f):normalize()
  return dream.mat4({
    r.x, u.x, -f.x, eye.x,
    r.y, u.y, -f.y, eye.y,
    r.z, u.z, -f.z, eye.z,
    0,   0,    0,   1,
  })
end

-- Project a point in the world onto the screen, so the 2D aim line and HUD
-- land where the 3D actually is. Minigolf shipped without this and its aim
-- line sat up to 174px away from the ball it belonged to.
local projR, projU, projF, projEye, projTanX, projTanY
local function setProjection(eye, target, fov)
  local f = (target - eye):normalize()
  local up = dream.vec3(0, 1, 0)
  local r = f:cross(up):normalize()
  local u = r:cross(f):normalize()
  projR, projU, projF, projEye = r, u, f, eye
  projTanY = math.tan(math.rad(fov / 2))
  projTanX = projTanY * (1920 / 1080)
end

local U = 120                       -- px per world unit, shared with dbg

local function toScreen(px, py, pz)
  if not projR then return px, py end
  local dx = px / U - projEye.x
  local dy = py / U - projEye.y
  local dz = pz / U - projEye.z
  local x = dx * projR.x + dy * projR.y + dz * projR.z
  local y = dx * projU.x + dy * projU.y + dz * projU.z
  local z = dx * projF.x + dy * projF.y + dz * projF.z
  if z <= 0.001 then return -9999, -9999 end
  return (x / (z * projTanX)) * 960 + 960,
         (-y / (z * projTanY)) * 540 + 540
end

-- ── building the alley ────────────────────────────────────────────────

-- The ten-pin triangle, in lane coordinates. Row 1 is the headpin.
local function pinSpots()
  local spots = {}
  for row = 0, 3 do
    for i = 0, row do
      local x = (i - row / 2) * PIN_SPACING
      local z = PIN_ROW_Z + row * PIN_SPACING * 0.87   -- equilateral rows
      spots[#spots + 1] = { x = x, z = z }
    end
  end
  return spots
end

-- A PIN, as a stack of tapered hulls on one dynamic body.
--
-- It was a single capsule, and a capsule is the wrong shape for this in a
-- way you can feel: it stands on a hemisphere, so it balances on a curve,
-- self-rights after a glancing hit, and refuses to stay down. A real pin
-- has a FLAT base, which is what makes it tip and stay tipped.
--
-- Box3D cannot help here with a mesh or a compound -- both are static-only
-- ("Mesh collision only creates contacts on static bodies") and a pin is
-- dynamic. What it does have is hull builders: b3CreateCylinder takes a
-- yOffset, so several hulls attach to ONE dynamic body and fuse. That is
-- what these four sections are.
--
-- Proportions follow a real pin: 15in tall, 2.25in across the base, 4.7in
-- at the belly, waisted to ~1.8in at the neck, rounded head.
-- Sides per hull. 14 was chosen to be round enough to ROLL convincingly;
-- now that the pins are textured and the camera comes in close at the rack,
-- they also have to be round enough to LOOK round, and a 14-sided silhouette
-- against a dark backdrop reads as a cut gem. Meshes are shared by size
-- signature, so ten pins still cost six meshes at any segment count.
local PIN_SEG = 22
local function newPin(x, z)
  local b = b3.body_new(world, x, PIN_H / 2, z, 2)     -- 2 = dynamic

  -- Heights as fractions of PIN_H, measured from the pin's own centre
  -- (the body origin sits at PIN_H/2, so the base is at -PIN_H/2).
  local H = PIN_H
  local rBase, rBelly, rNeck, rHead = PIN_R * 0.92, PIN_R * 1.30, PIN_R * 0.56, PIN_R * 0.80

  -- Each section wears its OWN SLICE of the pin texture, given as the
  -- fraction of the pin's height it occupies -- centre y, plus or minus
  -- half its height, remapped from the pin's -0.5H..+0.5H onto 0..1. That
  -- is what carries the two red neck stripes across six separate meshes as
  -- one continuous livery; without it every section would repeat the whole
  -- texture and the pin would wear six pairs of stripes.
  local function vr(centre, height)
    return { (centre - height / 2) + 0.5, (centre + height / 2) + 0.5 }
  end

  -- base: a flat-bottomed cylinder, barely tapered. Wide enough to STAND
  -- on -- the first pass ran it at 0.62 and the pins came to a point like
  -- skittles, which both looks wrong and makes them tip too easily.
  local s1 = dbg.cylinder(b, H * 0.10, rBase, -H * 0.45, PIN_SEG, 0.9,
                          "pin", vr(-0.45, 0.10))
  -- the flare from base up into the belly
  local s2 = dbg.cone(b, H * 0.20, rBase, rBelly, -H * 0.30, PIN_SEG, 0.9,
                      "pin", vr(-0.30, 0.20))
  -- belly: the widest part, nearly straight
  local s3 = dbg.cone(b, H * 0.16, rBelly, rBelly * 0.96, -H * 0.12, PIN_SEG, 0.9,
                      "pin", vr(-0.12, 0.16))
  -- neck: the waist, tapering hard
  local s4 = dbg.cone(b, H * 0.28, rBelly * 0.96, rNeck, H * 0.10, PIN_SEG, 0.9,
                      "pin", vr(0.10, 0.28))
  -- head: flares back out, then a rounded cap rather than a point
  local s5 = dbg.cone(b, H * 0.16, rNeck, rHead, H * 0.32, PIN_SEG, 0.9,
                      "pin", vr(0.32, 0.16))
  local s6 = dbg.cone(b, H * 0.10, rHead, rHead * 0.62, H * 0.45, PIN_SEG, 0.9,
                      "pin", vr(0.45, 0.10))

  for _, s in ipairs({ s1, s2, s3, s4, s5, s6 }) do
    b3.shape_set_material(s, PIN_FRICTION, PIN_REST)
  end
  b3.body_set_linear_damping(b, 0.6)
  b3.body_set_angular_damping(b, 0.7)
  return { body = b, x = x, z = z, down = false }
end

-- ── surfaces ──────────────────────────────────────────────────────────
--
-- The default renderer draws every body, and now it can draw them WEARING
-- something. The geometry is unchanged -- the same dbg.box that makes the
-- collider makes the mesh -- so texturing cannot introduce the class of bug
-- that comes from art and colliders being described separately.
--
-- uvScale is texture repeats per PIXEL, which is what keeps a texture the
-- same physical size on a 4600px lane and on a 12px lip. The alternative,
-- fitting 0..1 to each face, smears one and tiles the other to mush.
local function defineSkins()
  local tex = art.makeTextures()

  -- THE LIGHT RIG. The renderer's defaults are tuned to make a COLLIDER
  -- readable -- ambient 0.42, so nothing is ever lost in shadow. That is
  -- exactly what makes a finished picture look flat: high ambient shrinks
  -- the gap between a face in the light and a face out of it, and that gap
  -- IS the modelling.
  --
  -- So: ambient down to 0.24, a strong warm key from high above and
  -- slightly behind the bowler (an alley's lights are over the lane), and a
  -- dim cool fill from the opposite side to keep the far gutter from going
  -- to pure black. Warm key against cool fill is what gives the pins a lit
  -- side and a shadow side instead of one average brightness.
  dbg.setLightRig({
    ambient       = 0.24,
    key           = { -0.30, 0.90, 0.32 },
    keyColor      = { 1.00, 0.94, 0.82 },
    keyIntensity  = 1.00,
    fill          = { 0.70, 0.30, -0.45 },
    fillColor     = { 0.48, 0.58, 0.86 },
    fillIntensity = 0.42,
  })

  -- THE LANE. The one surface whose UV is not a free choice.
  --
  -- Its texture is 39 BOARDS across, and on a top face u runs across the
  -- lane (X) while v runs down it (Z). So u must repeat EXACTLY ONCE over
  -- the full width -- 1/LANE_W -- or the tiling saws a board in half at the
  -- gutter, which is instantly visible as a seam of the wrong width. v is
  -- free, and repeats every ~1200px so the grain does not stretch over a
  -- 4600px runway.
  dbg.defineSkin("lane", { texture = tex.lane, uvScale = { 1 / LANE_W, 1 / 1200 } })
  dbg.defineSkin("deck", { texture = tex.deck, uvScale = 1 / 420 })
  dbg.defineSkin("gutter", { texture = tex.gutter, uvScale = 1 / 260 })
  dbg.defineSkin("wall", { texture = tex.wall, uvScale = 1 / 300 })

  -- The room. Tiled coarsely -- these are big surfaces seen at a distance,
  -- and a fine repeat on a 3000px wall turns to noise.
  dbg.defineSkin("floor",   { texture = tex.floor,   uvScale = 1 / 480 })
  dbg.defineSkin("ceiling", { texture = tex.ceiling, uvScale = 1 / 900 })
  dbg.defineSkin("masking", { texture = tex.masking, uvScale = 1 / 1100 })

  -- The ball is a sphere, so uvScale does not apply -- a sphere's UVs
  -- already wrap it exactly once, which is what the marbling and the
  -- finger holes are authored against. It gets extra segments instead,
  -- because it is the object the eye tracks for the whole roll.
  dbg.defineSkin("ball", { texture = tex.ball, segments = 32, roughness = 0.25 })

  -- THE PINS. No uvScale: the texture is authored as one pin from base to
  -- head, and each of the six hulls takes its own slice of it (see newPin),
  -- so the mapping is already exact and scaling it would only break the
  -- alignment of the neck stripes.
  dbg.defineSkin("pin", { texture = tex.pin, roughness = 0.35 })
end

-- THE ROOM.
--
-- Without this the alley is a lit plank floating in a void, and the void is
-- most of the screen. A bowling alley is a ROOM -- a dim one, with a bright
-- lane in it -- and the room is what tells the eye how big the lane is and
-- where the light is coming from.
--
-- These are STATIC BODIES placed where the ball can never reach: outside
-- the gutter walls, above the ceiling line, behind the pit. They are real
-- collision geometry, which keeps the renderer's one invariant intact --
-- the mesh is built from the shape, so decor cannot drift away from what it
-- claims to be -- while being unreachable, so they change no outcome.
--
-- AND THE ROOM MUST NOT ENCLOSE THE CAMERA.
--
-- This is the whole difficulty, and the first attempt got it wrong in the
-- most complete way available: a ceiling at y=1160 with the camera at
-- y=2795 put the eye ABOVE the roof looking down at its underside, and the
-- frame was a solid dark slab with the alley nowhere in it.
--
-- The camera is derived, not fixed: it stands off at `dist` and rides
-- `dist * tan(45deg)` above the deck, and `dist` grows with the span it has
-- to hold. At the setup framing -- the widest span, ball at the foul line
-- -- it reaches x = -2730, y = 2795. So the room is sized from THAT, with
-- margin, rather than from the lane.
local ROOM_X    = 3600            -- side walls, well outside the camera's -2730
local ROOM_Y    = 3400            -- ceiling, above the camera's 2795
local ROOM_FLOOR = -150
local ROOM_Z_PAD = 1200           -- how far the room runs past each end

local function buildRoom()
  local midZ = LANE_LEN / 2
  local halfZ = LANE_LEN / 2 + ROOM_Z_PAD
  local OUT  = LANE_W / 2 + GUTTER_W          -- outside the gutter wall

  -- THE APPROACH, behind the foul line. A bowler stands somewhere, and
  -- ending the boards at z=0 makes the lane look like it was cut off.
  --
  -- WIDER THAN THE LANE and running to the near wall. At lane width it read
  -- as a stub jutting into the void off the left edge of frame -- a piece
  -- of geometry rather than a place. An approach is the widest part of the
  -- floor in a real alley, not the narrowest.
  local apHalf = (halfZ - 40) * 0.5
  local ap = b3.body_new(world, 0, -20, -apHalf, 0)
  dbg.box(ap, OUT + 900, 20, apHalf, nil, "deck")

  -- THE FLOOR of the room, wide and low, running the whole length. It
  -- catches the dim fill light and gives the alley something to stand on.
  local fl = b3.body_new(world, 0, ROOM_FLOOR, midZ, 0)
  dbg.box(fl, ROOM_X, 16, halfZ, nil, "floor")

  -- SIDE WALLS. Only the FAR one is ever seen -- the camera stands off the
  -- -x rail looking across, so the -x wall would sit behind the eye and the
  -- +x wall is the backdrop the lane is seen against. Both are built
  -- anyway: the camera swings with the fit, and a room with one wall is a
  -- room that breaks the moment the framing changes.
  for _, side in ipairs({ -1, 1 }) do
    local w = b3.body_new(world, side * ROOM_X, ROOM_Y / 2, midZ, 0)
    dbg.box(w, 20, ROOM_Y / 2, halfZ, nil, "wall")
  end

  -- THE CEILING, dark, so the top of the frame is not empty void. Above the
  -- camera, or it becomes the picture.
  local ce = b3.body_new(world, 0, ROOM_Y, midZ, 0)
  dbg.box(ce, ROOM_X, 20, halfZ, nil, "ceiling")

  -- THE BACK WALL behind the pit, the surface the pins are seen against.
  -- It is the backdrop of every shot, so it gets the masking that a real
  -- alley has above the deck.
  local bw = b3.body_new(world, 0, ROOM_Y / 2, LANE_LEN + 620, 0)
  dbg.box(bw, ROOM_X, ROOM_Y / 2, 20, nil, "masking")

  -- The wall behind the BOWLER, closing the room at the near end.
  local nw = b3.body_new(world, 0, ROOM_Y / 2, -halfZ, 0)
  dbg.box(nw, ROOM_X, ROOM_Y / 2, 20, nil, "wall")
end

local function buildAlley()
  if world then b3.world_destroy(world) end
  dbg.reset()
  world = b3.world_new(0, GRAVITY, 0)

  -- THE LANE. A thin box. Untextured it drew as a ruled plane -- a
  -- flattened box is the case a box outline renders worst -- but SKINNED it
  -- stays a box, because the boards now say where the surface is and the
  -- solid edge is what the ball visibly rolls between.
  local laneBody = b3.body_new(world, 0, -20, LANE_LEN / 2, 0)
  dbg.box(laneBody, LANE_W / 2, 20, LANE_LEN / 2, nil, "lane")

  -- THE GUTTERS, one either side, dropped below the lane so a ball that
  -- leaves the boards falls in and cannot come back.
  for _, side in ipairs({ -1, 1 }) do
    local gx = side * (LANE_W / 2 + GUTTER_W / 2)
    local g = b3.body_new(world, gx, -70, LANE_LEN / 2, 0)
    dbg.box(g, GUTTER_W / 2, 20, LANE_LEN / 2, nil, "gutter")
    -- the outer wall, so the ball cannot leave the building
    local w = b3.body_new(world, side * (LANE_W / 2 + GUTTER_W), WALL_H / 2,
                          LANE_LEN / 2, 0)
    dbg.box(w, 12, WALL_H / 2, LANE_LEN / 2, nil, "wall")
    -- the lip between lane and gutter: what makes the gutter a real edge
    local lip = b3.body_new(world, side * (LANE_W / 2 + 6), -34, LANE_LEN / 2, 0)
    dbg.box(lip, 6, 34, LANE_LEN / 2, nil, "deck")
  end

  -- THE PIT, at the far end, so pins and ball stop somewhere.
  local back = b3.body_new(world, 0, WALL_H, LANE_LEN + 60, 0)
  dbg.box(back, LANE_W / 2 + GUTTER_W, WALL_H * 2, 30, nil, "wall")

  buildRoom()

  pins = {}
  for _, s in ipairs(pinSpots()) do
    pins[#pins + 1] = newPin(s.x, s.z)
  end

  ballBody = nil
end

local function placeBall()
  if ballBody then b3.body_destroy(ballBody) end
  ballBody = b3.body_new(world, 0, BALL_R, 120, 2)
  local s = dbg.sphere(ballBody, BALL_R, 2.2, "ball")
  b3.shape_set_material(s, BALL_FRICTION, BALL_REST, BALL_ROLL)
  b3.body_set_linear_damping(ballBody, 0.08)
  b3.body_set_angular_damping(ballBody, 0.12)
  b3.body_set_bullet(ballBody, true)
  aimAngle, aimPull, aimSpin = 0, 0, 0
  dragFrom = nil
  -- A new ball is a new shot: the crash may fire again, and the pin count
  -- baseline restarts from whatever is standing now (which is NOT ten on
  -- the second ball of a frame).
  hitRack, inGutter = false, false
  local standing = 0
  for _, p in ipairs(pins) do
    if not p.down then standing = standing + 1 end
  end
  prevStanding = standing
end

-- ── scoring ───────────────────────────────────────────────────────────
--
-- Real ten-pin scoring, including the tenth-frame extras: a strike or
-- spare there earns fill balls, and their pins count into that frame.
local function scoreGame(rs)
  local total, i = 0, 1
  local frames = {}
  for f = 1, 10 do
    local a = rs[i]
    if a == nil then break end
    if a == 10 then                                   -- strike
      local b, c = rs[i + 1], rs[i + 2]
      total = total + 10 + (b or 0) + (c or 0)
      frames[f] = (b and c) and total or nil
      i = i + 1
    else
      local b = rs[i + 1]
      if b == nil then break end
      if a + b == 10 then                             -- spare
        local c = rs[i + 2]
        total = total + 10 + (c or 0)
        frames[f] = c and total or nil
      else
        total = total + a + b
        frames[f] = total
      end
      i = i + 2
    end
  end
  return total, frames
end

-- ── input ─────────────────────────────────────────────────────────────

local edges, prevDown, lastEdge = {}, {}, {}
local frameCount, DEBOUNCE = 0, 6
local padUsed = false

local function readEdges()
  frameCount = frameCount + 1
  for k in pairs(edges) do edges[k] = nil end
  for _, b in ipairs({ "a", "b", "x", "y", "left", "right", "up", "down" }) do
    local d = love.pad.isDown(b)
    local e = d and not prevDown[b]
    if e and (frameCount - (lastEdge[b] or -100)) < DEBOUNCE then e = false end
    if e then lastEdge[b] = frameCount; padUsed = true end
    edges[b] = e
    prevDown[b] = d
  end
end

-- Touch is an equal path: poll ALL ten pointer slots, since a mouse-only
-- read silently ignores every finger on a phone.
local prevPtr, click, held = {}, nil, nil
local function readPointers()
  click, held = nil, nil
  local ptr = rawget(_G, "wc") and wc.pointer
  if not ptr then return end
  for slot = 0, 9 do
    local x, y, buttons, active = ptr(slot)
    local down = (active and buttons ~= 0) or false
    if down then held = { x = x, y = y } end
    if down and not prevPtr[slot] and not click then click = { x = x, y = y } end
    prevPtr[slot] = down
  end
end

local function throw()
  local sp = (aimPull / MAX_PULL) * MAX_SPEED
  if sp < 200 then return end
  -- Down the lane is +z. The aim angle tilts that, and the sideways part
  -- of the drag becomes SPIN -- a hook, which is the whole craft of the
  -- game and the reason a straight ball is not the only option.
  b3.body_set_velocity(ballBody, math.sin(aimAngle) * sp, 0,
                       math.cos(aimAngle) * sp)
  b3.body_set_angular_velocity(ballBody, 0, aimSpin * MAX_SPIN, 0)
  state = "rolling"
  settleT = 0
  -- The roll runs under the whole shot. Pitched slightly by how hard it was
  -- thrown, so a gentle ball sounds like a gentle ball.
  sounds.play("roll", 0.55, 0.88 + (sp / MAX_SPEED) * 0.22)
  rollingSound = true
  hitRack, inGutter = false, false
end

-- ── love callbacks ────────────────────────────────────────────────────

function love.load()
  dream.canvases:setMode("direct")
  dream:init()
  -- THE BACKDROP. Not a sky -- this is indoors. A dark warm haze that is
  -- dimmest at the top (the unlit ceiling of a big room) and lifts slightly
  -- toward the floor, where the alley's own lights spill. Warm rather than
  -- blue, because every other surface in the room is warm and a blue void
  -- behind them reads as outdoors at dusk.
  dream:setSky(function()
    local g = love.graphics
    g.setDepthMode()
    for i = 0, 47 do
      local k = i / 47
      -- eased so most of the frame stays dark and the lift is near the base
      local e = k * k
      g.setColor(0.045 + e * 0.10, 0.038 + e * 0.075, 0.062 + e * 0.085)
      g.rectangle("fill", 0, i * (1080 / 48), 1920, 1080 / 48 + 1)
    end
    g.setColor(1, 1, 1, 1)
  end)

  b3.set_meter(PPM)
  dbg.init(dream, U)
  dbg.setEnabled(true)          -- the default renderer IS the graphics here

  -- AFTER dbg.init: a skin builds a material, which needs the 3D lib the
  -- renderer is holding. Before buildAlley, because a shape looks its skin
  -- up by name at creation time and an unknown name silently falls back to
  -- the debug palette.
  defineSkins()

  sounds.loadAll()
  buildAlley()
  placeBall()

  _G.BOWL_STATE = setmetatable({}, { __index = function(_, k)
    if k == "frame" then return frameNo end
    if k == "ball" then return ballNo end
    if k == "state" then return state end
    if k == "score" then return (scoreGame(rolls)) end
    return nil
  end })
end

-- How many pins are down? A pin is down when it has tipped past about 45
-- degrees or has left its spot -- reading the BODY, not a flag we set.
local function countDown()
  local n = 0
  for _, p in ipairs(pins) do
    local px, py, pz = b3.body_position(p.body)
    local qx, qy, qz, qw = b3.body_rotation(p.body)
    -- the pin's own up vector, rotated by its quaternion
    local uy = 1 - 2 * (qx * qx + qz * qz)
    local moved = math.abs(px - p.x) > PIN_R or math.abs(pz - p.z) > PIN_R
    if uy < 0.72 or py < PIN_H * 0.3 or moved then
      p.down = true
    end
    if p.down then n = n + 1 end
  end
  return n
end

local function clearDeadwood()
  for _, p in ipairs(pins) do
    if p.down then
      b3.body_set_transform(p.body, p.x, -900, p.z, 0, 1, 0, 0)
      b3.body_set_velocity(p.body, 0, 0, 0)
      -- Parked under the deck is not the same as gone: the default renderer
      -- draws every body it tracks, so without this the swept pins hang
      -- visibly below the lane. The longer lane made that obvious.
      dbg.setBodyVisible(p.body, false)
    end
  end
end

local function resetPins()
  for _, p in ipairs(pins) do
    p.down = false
    b3.body_set_transform(p.body, p.x, PIN_H / 2, p.z, 0, 1, 0, 0)
    b3.body_set_velocity(p.body, 0, 0, 0)
    b3.body_set_angular_velocity(p.body, 0, 0, 0)
    dbg.setBodyVisible(p.body, true)   -- undo clearDeadwood
  end
end

local function endOfBall()
  local down = countDown()
  local knockedThisBall = down - (10 - standingAtFrameStart)
  rolls[#rolls + 1] = knockedThisBall

  -- whatever is left of the shot's audio stops here
  sounds.stop("roll")
  rollingSound = false

  local tenth = frameNo == 10
  if knockedThisBall == 10 and ballNo == 1 then
    setMsg("STRIKE", 2.4)
    sounds.play("strike", 0.85)
  elseif down == 10 then
    local strike = ballNo == 1
    setMsg(strike and "STRIKE" or "SPARE", 2.2)
    sounds.play(strike and "strike" or "spare", 0.8)
  end

  if tenth then
    -- the tenth frame runs on its own rules; fill balls reset the rack
    local a = rolls[#rolls - 1]
    if down == 10 then resetPins(); standingAtFrameStart = 10
    else clearDeadwood(); standingAtFrameStart = 10 - down end
    ballNo = ballNo + 1
    local strikeOrSpare = (rolls[#rolls] == 10) or (a and a + rolls[#rolls] == 10)
    if ballNo > (strikeOrSpare and 3 or 2) then state = "done" ; return end
  elseif ballNo == 1 and down < 10 then
    ballNo = 2
    standingAtFrameStart = 10 - down
    clearDeadwood()
  else
    frameNo = frameNo + 1
    ballNo = 1
    standingAtFrameStart = 10
    resetPins()
  end

  placeBall()
  state = "aim"
end

function love.update(dt)
  t = t + dt
  readEdges()
  readPointers()
  if msgT > 0 then msgT = msgT - dt; if msgT <= 0 then msg = nil end end

  if state == "aim" then
    if padUsed then
      if love.pad.isDown("left")  then aimAngle = aimAngle - dt * 0.5 end
      if love.pad.isDown("right") then aimAngle = aimAngle + dt * 0.5 end
      if love.pad.isDown("down")  then aimPull = math.min(MAX_PULL, aimPull + dt * 300) end
      if love.pad.isDown("up")    then aimPull = math.max(0, aimPull - dt * 300) end
      if edges.a or edges.b then throw() end
      -- Y toggles the physics view, which here is a plain-graphics toggle
      if edges.y then dbg.toggle() end
    end

    -- Touch: press, drag BACK to load, release to throw. Sideways drag is
    -- the hook. Measured from where the finger went down, never from the
    -- ball -- measuring from the ball makes the power random, since the
    -- distance to it counts as pull the instant you touch anywhere.
    if held then
      if not dragFrom then dragFrom = { x = held.x, y = held.y } end
      local dx, dy = held.x - dragFrom.x, held.y - dragFrom.y
      local d = math.sqrt(dx * dx + dy * dy)
      if d > 10 then
        aimPull  = math.min(MAX_PULL, math.max(0, dy))
        aimAngle = math.max(-0.28, math.min(0.28, dx / 900))
        aimSpin  = math.max(-1, math.min(1, dx / 320))
      else
        aimPull = 0
      end
    else
      if aimPull > 0 and not padUsed then throw() end
      dragFrom = nil
    end
  end

  if state == "rolling" or state == "settling" then
    b3.world_step(world, 1 / 60, 4)

    local vx, vy, vz = b3.body_velocity(ballBody)
    local speed = math.sqrt(vx * vx + vy * vy + vz * vz)
    local bx, by, bz = b3.body_position(ballBody)

    -- ── the sound of the shot ──────────────────────────────────────
    --
    -- THE GUTTER, first: the ball has left the boards. Read from the
    -- BALL'S OWN POSITION rather than from a collision callback, which is
    -- the same principle the rest of this game follows -- the simulation is
    -- the source of truth and the presentation reads it.
    if not inGutter and math.abs(bx) > LANE_W / 2 + 12 and by < 0 then
      inGutter = true
      sounds.stop("roll"); rollingSound = false
      sounds.play("gutter", 0.6)
    end

    -- THE CRASH, once, when the ball reaches the rack with pins still up.
    if not hitRack and not inGutter and bz > PIN_ROW_Z - PIN_SPACING then
      hitRack = true
      sounds.stop("roll"); rollingSound = false
      -- louder for a faster ball; a slow trickle into the rack should not
      -- sound like a strike
      local power = math.min(1, speed / (MAX_SPEED * 0.7))
      sounds.play("pinhit", 0.45 + power * 0.45, 0.94 + power * 0.12)
    end

    -- INDIVIDUAL PINS toppling after the crash. Counting the standing pins
    -- and clacking on each change gives the scatter its own sound without
    -- needing per-contact callbacks.
    local standing = 0
    for _, p in ipairs(pins) do
      local _, py, _ = b3.body_position(p.body)
      local qx, qy, qz, qw = b3.body_rotation(p.body)
      local uy = 1 - 2 * (qx * qx + qz * qz)
      if uy >= 0.72 and py > PIN_H * 0.3 then standing = standing + 1 end
    end
    if standing < prevStanding and hitRack then
      -- pitch varies per pin so a rack going down is not a metronome
      sounds.play("pinclack", 0.5, 0.86 + (standing % 5) * 0.07)
    end
    prevStanding = standing

    -- The roll fades out when the ball has stopped being a rolling ball.
    if rollingSound and speed < 120 then
      sounds.stop("roll"); rollingSound = false
    end

    -- everything has stopped, or the ball is past the pins and slow
    local moving = speed > 40
    if not moving then
      for _, p in ipairs(pins) do
        -- A pin knocked clean off the deck is out of play. It is also in
        -- FREE FALL, so its speed grows without bound -- and a settle test
        -- that watches every pin's velocity then never fires: measured
        -- 128 -> 227 -> 1024 -> 1471 over 900 frames while the ball sat
        -- still at 0, and the roll never ended. Ignore anything that has
        -- left the world.
        local _, py, _ = b3.body_position(p.body)
        if py > -400 then
          local pvx, pvy, pvz = b3.body_velocity(p.body)
          if math.sqrt(pvx * pvx + pvy * pvy + pvz * pvz) > 30 then
            moving = true; break
          end
        end
      end
    end

    if moving then
      settleT = 0
    else
      settleT = settleT + dt
      -- a beat of stillness, so a pin teetering back upright is not
      -- counted as down
      if settleT > 1.1 then endOfBall() end
    end

    if bz > LANE_LEN + 20 or by < -600 then
      settleT = settleT + dt * 2
    end
  end

  if state == "done" and (edges.a or edges.b or click) then
    rolls = {}
    frameNo, ballNo, standingAtFrameStart = 1, 1, 10
    resetPins()
    placeBall()
    state = "aim"
  end
end

-- ── drawing ───────────────────────────────────────────────────────────

local function drawAim()
  if state ~= "aim" or aimPull < 6 then return end
  local g = love.graphics
  local bx, by, bz = b3.body_position(ballBody)
  local power = aimPull / MAX_PULL

  local sx, sy = toScreen(bx, by, bz)
  -- the line runs FORWARD, down the lane, showing where the ball will go
  local ex, ey = toScreen(bx + math.sin(aimAngle) * 900, by,
                          bz + math.cos(aimAngle) * 900)
  g.setLineWidth(6)
  g.setColor(1, 0.92 - power * 0.5, 0.4, 0.85)
  g.line(sx, sy, ex, ey)

  -- the hook, drawn as a curve so the spin is visible before it is thrown
  if math.abs(aimSpin) > 0.05 then
    g.setColor(0.45, 0.85, 1.0, 0.8)
    local px, py = sx, sy
    for i = 1, 12 do
      local f = i / 12
      local dz = f * 1400
      local dx = math.sin(aimAngle) * dz + aimSpin * 190 * f * f
      local qx, qy = toScreen(bx + dx, by, bz + dz)
      g.line(px, py, qx, qy)
      px, py = qx, qy
    end
  end
end

local function drawHUD()
  local g = love.graphics
  local total, frames = scoreGame(rolls)

  g.setFont(ui.font(theme.fontMid))
  g.setColor(1, 1, 1)
  if state == "done" then
    g.printf("GAME OVER", 0, 14, 1920, "center")
  else
    g.printf(("FRAME %d of 10   BALL %d"):format(frameNo, ballNo), 0, 14, 1920, "center")
  end

  g.setFont(ui.font(theme.fontBig))
  g.print(("SCORE  %d"):format(total), 40, 986)

  -- the frame strip, so he can see the game at a glance
  local BOXW = 92
  local x0 = 1920 - 40 - BOXW * 10
  g.setFont(ui.font(theme.fontSmall))
  for f = 1, 10 do
    local x = x0 + (f - 1) * BOXW
    g.setColor(1, 1, 1, f == frameNo and 0.20 or 0.08)
    g.rectangle("fill", x, 972, BOXW - 6, 78)
    g.setColor(1, 1, 1, 0.75)
    g.printf(tostring(f), x, 978, BOXW - 6, "center")
    if frames[f] then
      g.setColor(1, 1, 1)
      g.printf(tostring(frames[f]), x, 1012, BOXW - 6, "center")
    end
  end

  if msg then
    g.setFont(ui.font(theme.fontHuge or theme.fontBig))
    g.setColor(1, 0.95, 0.6, math.min(1, msgT))
    g.printf(msg, 0, 300, 1920, "center")
  elseif state == "aim" then
    g.setFont(ui.font(theme.fontSmall))
    g.setColor(theme.quiet)
    g.printf("drag back to load, sideways to hook, let go to throw",
             0, 1044, 1920, "center")
  elseif state == "done" then
    g.setFont(ui.font(theme.fontMid))
    g.setColor(theme.quiet)
    g.printf("press A to play again", 0, 380, 1920, "center")
  end
end

function love.draw()
  love.graphics.clear(0.05, 0.06, 0.10, 1)

  -- THE CAMERA sits off to the side of the lane and looks across it, so the
  -- ball's travel reads as motion across the screen rather than as a dot
  -- growing smaller. It tracks the ball down the lane but hangs back near
  -- the rack once the ball is close, so the pin action stays framed.
  local bx, by, bz = 0, BALL_R, 120
  if ballBody then bx, by, bz = b3.body_position(ballBody) end
  -- Look PERPENDICULAR to the lane. Aiming the camera down-lane at all
  -- turns the alley into a diagonal wedge running off the corner of the
  -- screen; square-on keeps the lane a level band and the pins upright.
  --
  -- The camera centres on the MIDPOINT of ball and rack and stands back far
  -- enough to hold that whole span. Tracking the ball's own z instead puts
  -- the pins off the right edge for the entire roll, which is the one thing
  -- a side view exists to show.
  --
  -- Frame against the BACK of the rack, not the headpin. The triangle runs
  -- three more rows past PIN_ROW_Z, and fitting only to the headpin pushes
  -- the back six pins off the right edge.
  local backZ = PIN_ROW_Z + 3 * PIN_SPACING * 0.87
  local nearZ = math.min(bz, PIN_ROW_Z) - 200     -- margin behind the ball
  local midZ  = (nearZ + backZ) * 0.5
  -- CAM_FIT_SLACK is the framing margin. An exact fit puts the ball and the
  -- back of the rack ON the frame edges; tools/framing.mjs measures the gap
  -- and fails below 14px, which is how this number was chosen rather than
  -- guessed at.
  local spanZ = ((backZ - nearZ) + 260) * CAM_FIT_SLACK
  -- The fit needs the SLANT distance -- how far the camera actually is from
  -- the lane -- not its horizontal offset. Tilting moves the eye up and back
  -- along the slant, so fitting on the horizontal run alone pushes the whole
  -- alley further away and shrinks it (measured: right margin 71px -> 359px
  -- the moment the tilt went in). Dividing by cos(tilt) holds the apparent
  -- size fixed as the angle changes.
  local slant = spanZ * 0.5 / math.tan(CAM_HALF_H)
  local dist  = math.max(SIDE_CAM_MIN_X, slant * math.cos(CAM_TILT))
  -- TILTED DOWN toward the bowler. Level with the deck, the lane is a thin
  -- band seen edge-on and the pin triangle collapses into a single row --
  -- the depth of the rack, which is what tells a strike from a split, is
  -- exactly what a level camera throws away. Riding above it opens the deck
  -- out so the four rows read as four rows.
  --
  -- The height is derived from the distance, not set independently: rise
  -- over run IS the tilt angle, so a fixed height would mean the angle
  -- drifted every time the fit moved the camera in or out.
  local tgtY = PIN_H * 0.5
  local eye = dream.vec3(-dist / U,
                         (tgtY + dist * math.tan(CAM_TILT)) / U,
                         midZ / U)
  local tgt = dream.vec3(0, tgtY / U, midZ / U)

  local cam = dream:newCamera(camWorld(eye, tgt))
  cam:setFov(CAM_FOV)
  setProjection(eye, tgt, CAM_FOV)

  dream:prepare()
  dbg.draw()
  dream:present(cam)

  love.graphics.setDepthMode()
  drawAim()
  drawHUD()
end
