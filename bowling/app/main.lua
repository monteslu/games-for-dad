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

-- THE LANE'S WIDTH IS SET BY THE RACK, not chosen.
--
-- A real lane is 42in wide with pins on 12in centres -- exactly 3.5 times
-- the spacing -- and that ratio is not decorative: it is what puts the
-- corner pins just inside the boards, clearing the gutter by about 0.6in.
--
-- At 300 this was WRONG IN A WAY YOU COULD SEE. The outermost pins sit at
-- 1.5 spacings (144px) and are 22px in radius, so their outer edge lands at
-- 166px against a half-width of 150 -- the corner pins overhung the lane by
-- 16px and stood partly over the gutter, which is not a tight rack, it is
-- an impossible one.
--
-- 344 is 3.58 spacings: true to life, plus a couple of px of margin because
-- at this scale a 2px clearance disappears into a rounding error.
local LANE_W   = 344
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

-- THE PIT, behind the pin deck. At 68px per foot (the lane is 60ft over
-- 4080px) a real ten-foot pit is 680px. The first version had a backboard
-- 179px past the back row -- 2.6 feet -- so pins bounced straight off it
-- and back onto the deck instead of flying away and staying gone.
local PIT_LEN   = 680
local PIT_DEPTH = 150               -- how far below the lane the well sits

local BALL_R   = 52
local PIN_R    = 22
local PIN_H    = 130

-- Where the pins stand. Ten pins, four rows, 12in centres -- the real
-- triangle, pointing back at the bowler.
local PIN_SPACING = 96
local PIN_ROW_Z   = 4200            -- the headpin

-- ── PIN ACTION ────────────────────────────────────────────────────────
--
-- The pins knocking EACH OTHER down is the entire game. A ball 8.5in across
-- can physically touch three or four pins in a ten-pin rack; the other six
-- or seven fall because the pins they were standing next to hit them. That
-- chain reaction is what separates a strike from a split, and it is the
-- thing a bowling game has to get right.
--
-- IT WAS NOT HAPPENING. Measured across a spread of aims, a dead-centre
-- hit took 9 pins but EVERY pocket and edge hit took exactly 1 -- a pin
-- would topple and its neighbours would ignore it. Three causes, all here:
--
--   1. DAMPING. Pins ran at 0.6 linear / 0.7 angular, which bleeds a struck
--      pin's velocity away almost as fast as it is given, so it fell over
--      in place instead of travelling into its neighbours. Real pins are
--      hardwood on hardwood: they slide and tumble a long way, and the only
--      honest damping is the friction that is already modelled.
--   2. RESTITUTION 0.08 -- nearly dead. A pin absorbed the impact instead
--      of passing it on. Maple on maple is springy; a pin struck hard
--      visibly bounces off its neighbour.
--   3. MASS RATIO 7.66:1. A real ball is 14lb against a 3.5lb pin, so 4:1.
--      At nearly twice that the ball ploughs straight through the rack
--      barely deflecting, which is both wrong and much less interesting --
--      the deflection is what carries the ball into the 5 pin behind.
local BALL_FRICTION, BALL_REST, BALL_ROLL = 0.18, 0.05, 0.004

-- Maple on maple. Friction moderate (pins skid across a waxed deck),
-- restitution high enough that a hit is passed along rather than swallowed.
local PIN_FRICTION,  PIN_REST            = 0.22, 0.55

-- Densities, chosen for a 4:1 ball-to-pin mass ratio -- real bowling's.
-- The pin's own volume comes out of its six stacked hulls, so this is set
-- against that rather than picked to look right.
local PIN_DENSITY  = 0.9
local BALL_DENSITY = 1.15

-- How much a pin resists being spun and shoved. Small but not zero: a real
-- pin does eventually stop, and zero damping leaves deadwood sliding around
-- the deck for the whole settle beat.
local PIN_LIN_DAMP, PIN_ANG_DAMP = 0.04, 0.06

-- SIDE VIEW. The camera stands off the left rail, rides above the deck, and
-- looks square across the lane and down at it, so a throw travels
-- left-to-right across the screen. It backs off as the ball-to-rack span
-- grows so both stay in frame; this floor keeps it from crowding the pins
-- on the last few feet.
local SIDE_CAM_MIN_X = 900
-- How far the camera rides above the deck, as an ANGLE. 45 degrees is
-- halfway between a level side view (which flattens the rack into one row)
-- and a top-down plan (which loses the pins standing up).
--
-- 52 rather than 45: a little more of the deck turned toward the viewer,
-- which opens the four rows of the rack out further and shows more of the
-- lane's surface -- the boards and the ball's line along them are most of
-- what there is to look at. Still well short of a plan view, so the pins
-- keep their height and a standing pin still reads as standing.
local CAM_TILT       = math.rad(52)
-- The camera's FOV is VERTICAL. On a 16:9 frame the horizontal half-angle
-- is what actually has to cover the lane's length, so the fitting maths
-- works from this, not from the 56 passed to setFov.
local CAM_FOV        = 42
local CAM_HALF_H     = math.atan(math.tan(math.rad(CAM_FOV) * 0.5) * (1920 / 1080))
local CAM_FIT_SLACK  = 1.10        -- breathing room, see the fit in love.draw

-- Throwing. Pull back from the ball like every other game in the family.
local MAX_PULL  = 300
local MAX_SPEED = 1500
-- ── THE HOOK ──────────────────────────────────────────────────────────
--
-- A real hook is not the ball spinning like a top. It is SIDE ROLL: the
-- ball leaves the hand rotating about a tilted axis, skids down the oiled
-- front of the lane barely gripping, and then -- as it reaches the dry
-- back end and the side rotation bites -- friction turns that rotation
-- into a sideways force and the ball arcs into the pocket. The curve
-- happens LATE, which is exactly why a hook is worth having: it comes in
-- at an angle no straight ball can.
--
-- THE OLD CODE SET ANGULAR VELOCITY ABOUT Y, which is a ball spinning
-- about the vertical -- a top. That produces no meaningful lateral force
-- at all, so the "hook" did nothing. Meanwhile drawAim drew a 21-board
-- curve, so the preview promised an arc the physics never delivered.
--
-- Modelled here as a lateral force proportional to side rotation, ramped
-- in over the length of the lane so the ball goes straight early and turns
-- late. Box3D gives us b3.body_apply_force, so this is real force on a
-- real body rather than the position of the ball being written directly.
local MAX_SPIN     = 3.2            -- rad/s of side rotation at a full sweep
-- Peak lateral force, as a multiple of the ball's own weight.
--
-- SOLVED, not guessed. Over the bite phase (1836px at 1500px/s, so 1.22s)
-- with the ramp giving a mean acceleration of HOOK_FORCE*g/2, the lateral
-- displacement is 0.5*a*t^2. A full hook should move the ball about ten
-- BOARDS -- a strong but ordinary league hook -- and a board is 344/39 =
-- 8.8px here, so ten boards is 88px. That puts HOOK_FORCE at 0.27.
--
-- The first value, 0.62, worked out to 23 boards: measured on screen, a
-- dead-centre aim with full spin hooked clean off the edge of the lane
-- into the gutter.
local HOOK_FORCE   = 0.27
-- Where down the lane the hook starts to bite, as a fraction of the run.
-- Real oil patterns run about 40ft of a 60ft lane.
local HOOK_START   = 0.55

-- ── THE SPIN DIAL ─────────────────────────────────────────────────────
--
-- Spin gets its OWN control, because a bowler's line and a bowler's hook
-- are genuinely independent: you pick which board to roll over, and
-- separately your grip and release decide how much the ball turns over.
-- Welding them to one axis, which is what this used to do, is not a
-- simplification -- it removes a real choice and makes aiming punish you.
--
-- A ROW OF STOPS, NOT A TIMING BAR. A moving marker that has to be
-- stopped at the right instant is a reaction test, and this family's rule
-- is that nothing moves unless he moves it. These stops sit still, keep
-- their setting between balls, and can be ignored entirely: the middle is
-- no spin, and a player who never touches them gets a straight ball
-- forever and a perfectly good game.
--
--   << <  |  > >>      hard left, left, straight, right, hard right
--
-- A SWEEPING MARKER, TAPPED. The marker travels left-to-right and back
-- along the meter and a single tap stops it: where it stops is the spin.
-- Centre is straight, the ends are a full hook either way.
--
-- This is the third click of the classic golf meter (Links, Hot Shots
-- Golf), and it is the right shape for this player. The dexterity it asks
-- for is RHYTHM -- watch a thing move, press when it is where you want it
-- -- which is a judgement an old hand keeps long after fine motor control
-- for small targets goes. There is nothing to drag, nothing small to hit,
-- and one input does the whole job.
--
-- It is also slow on purpose. A full sweep takes SPIN_SWEEP seconds, which
-- is unhurried enough to watch the marker approach the middle and press,
-- and the middle is WIDE (see SPIN_DEAD): a tap anywhere near the centre
-- is a straight ball, so someone who just taps without watching gets the
-- simple game and never knows the meter was doing anything.
local SPIN_SWEEP  = 2.6            -- seconds for one end-to-end pass
local SPIN_DEAD   = 0.16           -- fraction of the bar that reads as straight
local spinPos     = 0              -- -1..1, where the marker is right now
local spinDir     = 1              -- which way it is travelling
local spinSet     = false          -- has it been stopped for this ball?
local aimSpinVal  = 0              -- the spin the stop chose

-- Where the dial sits. Big and low, well clear of the throw drag.
--
-- SIZED TO 24 MILLIMETRES PER STOP, the touch-target floor that the Xbox
-- Accessibility Guidelines (107) and the Game Accessibility Guidelines
-- arrive at independently for tablets. On the 10-inch tablet this is
-- played on -- 1920px across roughly 217mm -- 24mm is 212px, so five stops
-- want about 1060px of the 1920.
--
-- The first pass used 128px stops: 14.5mm. Comfortably above what a phone
-- app would use, and comfortably below what an eighty-five-year-old hand
-- is entitled to. A floor is a floor, not a target.
local SPIN_UI_W = 1080
local SPIN_UI_X = (1920 - SPIN_UI_W) / 2
local SPIN_UI_Y = 906
local SPIN_UI_H = 96

-- ── AIM ───────────────────────────────────────────────────────────────
--
-- DERIVED FROM THE LANE, not chosen. The ball travels 4080px from the foul
-- line to the headpin, and the furthest its centre can usefully be off the
-- centreline when it gets there is half the lane minus its own radius --
-- past that it is in the gutter. That is an angle of 0.029 rad, 1.7
-- degrees. A bowling lane is a very long, very narrow thing and the useful
-- range of aim on one is genuinely tiny.
--
-- THE CLAMP WAS 0.28 RAD -- 9.5 times too permissive, 16 degrees, which
-- puts the ball 1180px sideways by the time it reaches the pins on a lane
-- whose half-width is 172. It is why every "aimed" shot was really a gutter
-- ball that clipped the corner pin on its way past, and why pin action
-- looked broken when the ball was simply never reaching the rack.
-- FULL SWEEP REACHES THE GUTTER, by design. The first correction clamped
-- at the last line the ball can hold on the boards -- half the lane minus
-- its radius, +-120px -- but the rack itself spans +-144, so the entire
-- aim range landed inside the pins and EVERY shot struck. A game where no
-- line can miss is not easier, it is not a game.
--
-- So the clamp is the gutter's own centre: at full sweep the ball leaves
-- the boards, exactly as a real bad line does. Everything between is a
-- real choice, and the pocket is a target you can miss on either side.
local AIM_TRAVEL  = PIN_ROW_Z - 120                 -- foul line to headpin
local MAX_AIM     = math.atan((LANE_W / 2 + GUTTER_W * 0.5) / AIM_TRAVEL)
-- How much finger travel spends the whole aim range. A deliberate, gentle
-- sweep -- this is a game for someone who should not have to be precise,
-- and the whole span is only 1.7 degrees.
local AIM_DRAG_PX = 260

-- ── state ─────────────────────────────────────────────────────────────

local world
local ballBody, pins = nil, {}
local frameNo, ballNo = 1, 1        -- frame 1..10, ball 1 or 2
local rolls = {}                    -- every roll's pin count, in order
local state = "aim"                 -- aim | rolling | settling | between | done
local settleT = 0
local aimAngle, aimPull, aimSpin = 0, 0, 0
-- The spin the ball was actually THROWN with, held for the whole roll.
-- Separate from aimSpin, which is the aiming UI's live value and gets
-- reset the moment the next ball is placed -- the hook needs to keep
-- pulling long after that.
local throwSpin = 0
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

-- FORWARD DECLARATION. endOfBall fires the celebration, and it is defined
-- well above the effects that draw it. A `local function` declared later
-- is a different upvalue entirely, so without this the strike handler
-- would call nil -- and only on a strike, which is the least convenient
-- moment to find out.
local burstSparks

local function setMsg(s, secs) msg, msgT = s, secs or 2.2 end

-- ── HEADLESS INTROSPECTION ────────────────────────────────────────────
--
-- The host can read two named debug fields, `score` and `aux`. That is the
-- whole channel, so the rest of the game's state is PACKED into aux --
-- enough for a test harness to drive ten frames and check the scoring
-- without the cart shipping any cheat keys or a debug HUD.
--
--   score : the running total, straight out of scoreGame
--   aux   : frame*100000 + ball*10000 + stateCode*1000 + rollCount*10
--           + lastRoll
--
-- aux carries the ROLL COUNT and the LAST ROLL'S PIN COUNT rather than the
-- pins currently standing. A harness cannot infer the rolls from standing
-- counts: the rack resets between frames, so sampling before and after a
-- ball straddles the reset and reports 0 for every second ball. The cart
-- already knows exactly what each ball knocked down -- it is what gets
-- pushed into `rolls` -- so it says so directly.
--
-- rollCount is 0..21 and lastRoll is 0..10, so both fit: aux stays under
-- the i32 the field is declared as.
--
-- Read with romdev's wasm({op:'read', name:'aux'}).
local STATE_CODE = { aim = 1, rolling = 2, settling = 3, between = 4, done = 5 }

-- scoreGame is defined further down; declared here so this can call it.
-- A `local function` declared later is a different upvalue entirely.
local scoreGame

local function publishState()
  if not love.debugValue then return end
  local total = scoreGame(rolls)
  love.debugValue(0, total)

  -- FIELD WIDTHS, chosen so nothing can carry into its neighbour:
  --   lastRoll  0..10   -> 11 values, low field
  --   rollCount 0..21   -> 22 values
  --   state     0..5    -> 8  (round up, room to spare)
  --   ball      1..4    -> 6  (see below)
  --   frame     1..10
  --
  -- BALL NEEDS SIX VALUES, NOT FOUR. The tenth frame increments ballNo
  -- once more as it finishes, so a game that ends on the third fill ball
  -- leaves ballNo at 4 -- and with only four values that carried into the
  -- frame field and reported FRAME 11. The game was right; the packing
  -- was too tight. Six leaves room and costs nothing.
  -- A strike is TEN, so lastRoll needs eleven values and cannot live in a
  -- single decimal digit -- packing it against 10 would make a strike read
  -- as zero with a phantom extra roll counted above it.
  local code = STATE_CODE[state] or 0
  local n = math.min(#rolls, 21)
  local last = math.min(rolls[#rolls] or 0, 10)
  -- The spin MARKER's position rides in the low field, 0..200 for -1..+1.
  -- A harness that wants a straight ball has to know where the marker is;
  -- guessing from a frame count would drift the moment SPIN_SWEEP changed.
  local mk = math.floor((math.max(-1, math.min(1, spinPos)) + 1) * 100 + 0.5)
  love.debugValue(1, (((frameNo * 6 + ballNo) * 8 + code) * 22 * 11
                     + n * 11 + last) * 201 + mk)
end

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
  local s1 = dbg.cylinder(b, H * 0.10, rBase, -H * 0.45, PIN_SEG, PIN_DENSITY,
                          "pin", vr(-0.45, 0.10))
  -- the flare from base up into the belly
  local s2 = dbg.cone(b, H * 0.20, rBase, rBelly, -H * 0.30, PIN_SEG, PIN_DENSITY,
                      "pin", vr(-0.30, 0.20))
  -- belly: the widest part, nearly straight
  local s3 = dbg.cone(b, H * 0.16, rBelly, rBelly * 0.96, -H * 0.12, PIN_SEG, PIN_DENSITY,
                      "pin", vr(-0.12, 0.16))
  -- neck: the waist, tapering hard
  local s4 = dbg.cone(b, H * 0.28, rBelly * 0.96, rNeck, H * 0.10, PIN_SEG, PIN_DENSITY,
                      "pin", vr(0.10, 0.28))
  -- head: flares back out, then a rounded cap rather than a point
  local s5 = dbg.cone(b, H * 0.16, rNeck, rHead, H * 0.32, PIN_SEG, PIN_DENSITY,
                      "pin", vr(0.32, 0.16))
  local s6 = dbg.cone(b, H * 0.10, rHead, rHead * 0.62, H * 0.45, PIN_SEG, PIN_DENSITY,
                      "pin", vr(0.45, 0.10))

  for _, s in ipairs({ s1, s2, s3, s4, s5, s6 }) do
    b3.shape_set_material(s, PIN_FRICTION, PIN_REST)
  end
  b3.body_set_linear_damping(b, PIN_LIN_DAMP)
  b3.body_set_angular_damping(b, PIN_ANG_DAMP)
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

  -- ── THE PIT ─────────────────────────────────────────────────────────
  --
  -- A REAL PIT IS A HOLE, not a wall a foot behind the pins.
  --
  -- It used to be a backboard 179px past the back row -- 2.6 feet at this
  -- scale, where a real pit is about ten. Pins hit it and bounced straight
  -- back onto the deck, which looks wrong and is wrong: a struck pin is
  -- supposed to fly off the back and DISAPPEAR.
  --
  -- So the boards now stop at the end of the pin deck and the floor falls
  -- away into a well. Pins that fly off the back drop into it and stay
  -- there; the ball follows them. The backboard is still present, but it
  -- is far enough away and low enough that nothing reaches it at speed.
  local deckEndZ = PIN_ROW_Z + 3 * PIN_SPACING * 0.87 + PIN_R * 2

  -- The pit floor, well below the lane, so anything that leaves the deck
  -- falls out of play instead of rolling back into it.
  local pitFloor = b3.body_new(world, 0, -PIT_DEPTH, deckEndZ + PIT_LEN / 2, 0)
  dbg.box(pitFloor, LANE_W / 2 + GUTTER_W, 20, PIT_LEN / 2, nil, "deck")

  -- The kickback walls either side of the pit, which is what a real one
  -- has -- pins rattle off them rather than escaping sideways.
  for _, side in ipairs({ -1, 1 }) do
    local k = b3.body_new(world, side * (LANE_W / 2 + GUTTER_W),
                          -PIT_DEPTH / 2, deckEndZ + PIT_LEN / 2, 0)
    dbg.box(k, 12, PIT_DEPTH / 2 + WALL_H, PIT_LEN / 2, nil, "wall")
  end

  -- The backboard, at the far end of the pit and padded (low restitution),
  -- so anything that does reach it drops rather than rebounds.
  local back = b3.body_new(world, 0, -PIT_DEPTH / 2, deckEndZ + PIT_LEN, 0)
  local bs = dbg.box(back, LANE_W / 2 + GUTTER_W, PIT_DEPTH / 2 + WALL_H, 24,
                     nil, "masking")
  b3.shape_set_material(bs, 0.9, 0.02)

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
  local s = dbg.sphere(ballBody, BALL_R, BALL_DENSITY, "ball")
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
  -- The meter starts sweeping again for the next ball. Spin is a choice
  -- made per throw, not a setting -- which is also what keeps the tenth
  -- frame's fill balls from inheriting whatever the last one used.
  spinSet, aimSpinVal = false, 0
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
-- ASSIGNS the forward-declared local above; not `local function`, which
-- would shadow it and leave publishState calling nil.
scoreGame = function(rs)
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
  -- Side rotation about the DIRECTION OF TRAVEL (z), not about the
  -- vertical. This is what a real release imparts, and it is what the
  -- lateral hook force in love.update is the consequence of. Setting it
  -- about y span the ball like a top and did nothing at all.
  b3.body_set_angular_velocity(ballBody, 0, 0, -aimSpin * MAX_SPIN)
  throwSpin = aimSpin
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
  -- THE BACKDROP. Not a sky -- this is indoors.
  --
  -- A DIM ROOM WITH LIGHTS OVER THE LANE. The first version was a flat
  -- near-black wash, which is honest about a bowling alley being dark and
  -- dull as a picture: two thirds of the frame was one colour.
  --
  -- Now the room has a source. A warm pool sits behind and above the lane
  -- where the house lights would be, falling off into a cooler dark at the
  -- corners -- so the eye is drawn along the lane toward the pins, and the
  -- empty space reads as depth rather than as nothing.
  dream:setSky(function()
    local g = love.graphics
    g.setDepthMode()
    local ROWS, COLS = 36, 24
    local rh, cw = 1080 / ROWS, 1920 / COLS
    for r = 0, ROWS - 1 do
      local v = (r + 0.5) / ROWS
      for c = 0, COLS - 1 do
        local u = (c + 0.5) / COLS
        -- distance from the warm pool, which sits high and slightly right
        -- (over the pin deck, which is where a real alley is brightest)
        local dx, dy = (u - 0.62) * 1.15, (v - 0.30) * 1.55
        local d = math.sqrt(dx * dx + dy * dy)
        local warm = math.max(0, 1 - d * 1.22) ^ 2
        -- a second, weaker pool low and left, over the approach
        local ax, ay = (u - 0.18) * 1.3, (v - 0.86) * 1.7
        local ad = math.sqrt(ax * ax + ay * ay)
        local warm2 = math.max(0, 1 - ad * 1.5) ^ 2 * 0.55
        local w = warm + warm2
        g.setColor(0.052 + w * 0.30, 0.043 + w * 0.20, 0.075 + w * 0.13)
        g.rectangle("fill", c * cw, r * rh, cw + 1, rh + 1)
      end
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

  publishState()
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
    burstSparks(true)
  elseif down == 10 then
    local strike = ballNo == 1
    setMsg(strike and "STRIKE" or "SPARE", 2.2)
    sounds.play(strike and "strike" or "spare", 0.8)
    burstSparks(strike)
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
    -- THE SPIN METER. The marker sweeps until it is stopped; once stopped
    -- it stays put and its position is the spin for this ball.
    if not spinSet then
      spinPos = spinPos + spinDir * (dt / SPIN_SWEEP) * 2
      if spinPos >= 1 then spinPos = 1; spinDir = -1
      elseif spinPos <= -1 then spinPos = -1; spinDir = 1 end
    end

    -- A WIDE DEAD ZONE in the middle. Anywhere near centre is a straight
    -- ball, so a player who taps without watching gets the simple game --
    -- the meter only rewards attention, it never punishes inattention.
    local s = spinPos
    if math.abs(s) < SPIN_DEAD then
      s = 0
    else
      s = (math.abs(s) - SPIN_DEAD) / (1 - SPIN_DEAD) * (s < 0 and -1 or 1)
    end
    aimSpin = spinSet and aimSpinVal or s

    -- ONE TAP STOPS THE MARKER. Anywhere on the meter's band, which is a
    -- 1080x176 target -- there is nothing to hit precisely, only a moment
    -- to choose. A gamepad press does the same thing, so the timing is
    -- reachable without a touchscreen.
    if not spinSet then
      local tapped = (click and click.y > SPIN_UI_Y - 60
                            and click.y < SPIN_UI_Y + SPIN_UI_H + 60)
      if tapped or edges.x then
        spinSet = true
        aimSpinVal = s
        sounds.play("clack", 0.4, 1.25)
        if tapped then click = nil end     -- consumed; not also a throw
      end
    end

    if padUsed then
      -- X and Y step the spin dial on a pad, so the whole game is
      -- reachable without a touchscreen.
      -- (X stops the spin meter; handled above with the touch tap so both
      -- paths do exactly the same thing.)
      -- The pad sweeps the same range as a drag, in about two seconds, and
      -- is CLAMPED to it. It ran at 0.5 rad/sec unclamped, which crosses
      -- the entire useful aim of a bowling lane in sixty milliseconds and
      -- then keeps going until the ball is thrown at the side wall.
      local rate = MAX_AIM / 1.0
      if love.pad.isDown("left")  then aimAngle = math.max(-MAX_AIM, aimAngle - dt * rate) end
      if love.pad.isDown("right") then aimAngle = math.min( MAX_AIM, aimAngle + dt * rate) end
      if love.pad.isDown("down")  then aimPull = math.min(MAX_PULL, aimPull + dt * 300) end
      if love.pad.isDown("up")    then aimPull = math.max(0, aimPull - dt * 300) end
      if edges.a or edges.b then throw() end
      -- (Y used to toggle the physics view. The default renderer IS the
      -- graphics in this game, so that toggle only ever blanked the
      -- screen; the button is better spent on the spin dial.)
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
        -- SIDEWAYS IS AIM ONLY. It used to be aim AND spin at once, off
        -- the same dx, which meant he could not aim right without also
        -- hooking right -- two of the three things a bowler controls
        -- welded to one axis. Worse, spin saturated further out than aim
        -- did, so a full hook was only reachable from a line already in
        -- the gutter, and the measured result was that every shot got
        -- worse the further he aimed (9, 7, 6, 1 pins).
        --
        -- Spin now has its own control, set before the throw. See
        -- SPIN_STEP and the spin dial.
        local f = math.max(-1, math.min(1, dx / AIM_DRAG_PX))
        aimAngle = f * MAX_AIM
      else
        aimPull = 0
      end
    else
      if aimPull > 0 and not padUsed then throw() end
      dragFrom = nil
    end
  end

  if state == "rolling" or state == "settling" then
    -- SUBSTEPS 4 -> 8. Ten pins in a tight rack is a dense contact island:
    -- a pin is touching the deck and two or three neighbours at once, and
    -- the whole rack has to resolve as one system. Four substeps leaves
    -- that under-solved, which shows up as impacts that get swallowed at
    -- the moment several pins are in contact -- exactly when the chain
    -- reaction should be happening. Eight is cheap here: this is ten
    -- dynamic bodies, not a thousand.
    -- THE HOOK BITES. Applied before the step, every step, while the ball
    -- is still on the boards and still moving down the lane. The ramp is
    -- what makes the curve read as a hook rather than as a banana: the
    -- ball tracks straight through the oil and turns over the back end.
    if throwSpin ~= 0 and ballBody then
      local hx, hy, hz = b3.body_position(ballBody)
      local f = (hz - 120) / (PIN_ROW_Z - 120)
      if f > HOOK_START and f < 1.15 and hy > -40 then
        -- 0 at the start of the bite, 1 by the time it reaches the pins
        local bite = math.min(1, (f - HOOK_START) / (1 - HOOK_START))
        local mass = b3.body_mass(ballBody)
        -- NEGATED: a ">>" (right) setting has to send the ball right. The
        -- first pass hooked a right-spin ball to the LEFT, straight off
        -- the edge of the lane, because the sign was never checked against
        -- the screen.
        local force = -throwSpin * HOOK_FORCE * mass * math.abs(GRAVITY) * bite
        b3.body_apply_force(ballBody, force, 0, 0)
      end
    end

    b3.world_step(world, 1 / 60, 8)

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

  -- LAST, so the host always reads settled state rather than something
  -- mid-transition.
  publishState()
end

-- ── drawing ───────────────────────────────────────────────────────────

-- ── effects ───────────────────────────────────────────────────────────
--
-- These are 2D, drawn over the finished 3D pass and projected through the
-- same toScreen the aim line uses, so they land exactly where the geometry
-- is. That is a deliberate choice over more 3D bodies: a contact shadow is
-- not a solid, and adding collision geometry for something that is
-- conceptually a smudge of darkness would be the minigolf mistake in a new
-- costume.

-- THE CONTACT SHADOW. The single biggest thing separating a ball that sits
-- ON the lane from one that hovers above it -- the eye reads contact from
-- the shadow, not from the gap.
--
-- Drawn as a flattened ellipse at the ball's own x/z but at the lane's
-- surface, so it stays put under the ball however the camera moves. It
-- tightens and darkens as the ball nears the boards, which is what sells
-- the ball actually resting on them.
local function drawContactShadow()
  if not ballBody then return end
  local bx, by, bz = b3.body_position(ballBody)
  -- Nothing to catch a shadow once the ball has left the boards.
  if math.abs(bx) > LANE_W / 2 + 4 or by < -40 then return end

  local sx, sy = toScreen(bx, LANE_Y + 2, bz)
  if sx < -900 then return end
  -- how far above the lane the ball is riding, 0 at rest
  local lift = math.max(0, (by - BALL_R) / (BALL_R * 3))
  local tight = 1 - math.min(0.6, lift)

  -- Radius in SCREEN pixels, from the ball's own projected size, so it
  -- scales with the camera instead of being a fixed blob.
  local ex, _ = toScreen(bx + BALL_R, LANE_Y + 2, bz)
  local rad = math.max(4, math.abs(ex - sx))

  local g = love.graphics
  -- A few stacked ellipses instead of one: a soft edge without needing a
  -- texture or a blend mode the 2D path may not have.
  for i = 3, 1, -1 do
    local k = i / 3
    g.setColor(0, 0, 0, 0.30 * tight * (1.15 - k * 0.55))
    -- squashed hard in y: the lane is seen at 45 degrees, so a circle on
    -- it projects to a shallow ellipse
    g.ellipse("fill", sx, sy, rad * k * 1.05 * tight, rad * k * 0.40 * tight)
  end
  g.setColor(1, 1, 1, 1)
end

-- THE BALL'S SPECULAR. A polished ball catches the house lights, and that
-- highlight is what says "polished" rather than "matte plastic". Drawn
-- offset toward the key light, and it does NOT rotate with the ball --
-- a highlight is a reflection of a fixed light, so it stays put while the
-- marbling turns underneath it, which is exactly what reads as gloss.
local function drawBallSheen()
  if not ballBody then return end
  local bx, by, bz = b3.body_position(ballBody)
  local sx, sy = toScreen(bx, by, bz)
  if sx < -900 then return end
  local ex, _ = toScreen(bx + BALL_R, by, bz)
  local rad = math.abs(ex - sx)
  if rad < 3 then return end

  local g = love.graphics
  -- up and to the left, where the key light is
  local hx, hy = sx - rad * 0.34, sy - rad * 0.40
  g.setColor(1, 0.98, 0.94, 0.30)
  g.circle("fill", hx, hy, rad * 0.26)
  g.setColor(1, 1, 1, 0.42)
  g.circle("fill", hx, hy, rad * 0.13)
  g.setColor(1, 1, 1, 1)
end

-- THE CELEBRATION. A strike is the whole point of the game and it used to
-- pass with a word on screen. A slow warm shower of sparks over the deck
-- gives it a moment.
--
-- SLOW AND WARM ON PURPOSE. This game is for someone who should never feel
-- hurried or startled: no flash, no shake, no strobe. The sparks drift up
-- and fade, and they never obscure the pins.
local sparks = {}

-- ASSIGNS the forward-declared local above. Not `local function` (that
-- would shadow it with a new local) and not a bare `function` (that would
-- make a global and leave the declared local nil).
burstSparks = function(big)
  local n = big and 34 or 16
  local px, py = toScreen(0, PIN_H * 0.6, PIN_ROW_Z + PIN_SPACING)
  if px < -900 then return end
  for i = 1, n do
    local a = (i / n) * math.pi * 2
    local sp = (big and 120 or 80) * (0.45 + ((i * 37) % 100) / 100 * 0.8)
    sparks[#sparks + 1] = {
      x = px + math.cos(a) * 12,
      y = py + math.sin(a) * 12,
      vx = math.cos(a) * sp,
      vy = math.sin(a) * sp - (big and 90 or 60),
      life = (big and 1.5 or 1.1) * (0.7 + ((i * 53) % 100) / 100 * 0.6),
      age = 0,
      r = (big and 5 or 4) + ((i * 29) % 30) / 10,
    }
  end
end

local function updateSparks(dt)
  for i = #sparks, 1, -1 do
    local s = sparks[i]
    s.age = s.age + dt
    if s.age >= s.life then
      table.remove(sparks, i)
    else
      s.x = s.x + s.vx * dt
      s.y = s.y + s.vy * dt
      s.vy = s.vy + 150 * dt        -- gentle gravity, so they arc over
      s.vx = s.vx * (1 - dt * 0.9)  -- and slow down
    end
  end
end

local function drawSparkle()
  if #sparks == 0 then return end
  local g = love.graphics
  for _, s in ipairs(sparks) do
    local k = 1 - s.age / s.life
    -- warm gold, fading to a deeper amber as it dies
    g.setColor(1, 0.80 + k * 0.18, 0.35 + k * 0.30, k * 0.85)
    g.circle("fill", s.x, s.y, s.r * (0.35 + k * 0.75))
  end
  g.setColor(1, 1, 1, 1)
end

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

-- THE SCOREBOARD LIVES AT THE TOP, and it is big.
--
-- The alley is a wide, shallow band across the middle of the frame, which
-- leaves a great deal of empty room above and below it -- and the score
-- was down in the corner at 56px, competing with the bottom edge and the
-- hint line. Up here it has the space to be read from across a room, which
-- is the whole design brief for this family of games.
local SCORE_SIZE = 132
local STRIP_Y    = 40

-- A HOOKING ARROW: the path a hooked ball takes, as a curve with a head.
--
-- Drawn rather than typed. `dir` is -1 for a left hook and +1 for a right
-- one, and the curve is a quadratic that runs straight for the first
-- third and bends hard over the last -- the same late break the physics
-- actually applies, so the picture is a description of the shot rather
-- than a decoration.
-- The curve runs ACROSS the bar, not up it: this is a plan view of the
-- lane, so the ball travels left-to-right (or right-to-left) and bends
-- toward the end it is pointing at. Drawn thick, because a hairline
-- squiggle at the end of a 1080px bar is not a signpost.
local function drawHookArrow(cx, cy, len, dir, colour)
  local g = love.graphics
  local N = 18
  local px, py
  for i = 0, N do
    local t = i / N
    -- along the bar, and bending late -- t^2.6 keeps the first half
    -- visibly straight, the same late break the physics applies
    local x = cx + dir * t * len
    local y = cy - (t ^ 2.6) * len * 0.46
    if px then
      g.setLineWidth(5 + t * 6)                     -- thickens into the head
      g.setColor(colour[1], colour[2], colour[3], 0.42 + t * 0.55)
      g.line(px, py, x, y)
    end
    px, py = x, y
  end
  -- The head, pointing along the curve's actual tangent at the end.
  local hx, hy = px, py
  local t = 1 - 1 / N
  local bx = cx + dir * t * len
  local by = cy - (t ^ 2.6) * len * 0.46
  local a = math.atan(hy - by, hx - bx)
  local s = 26
  g.setColor(colour[1], colour[2], colour[3], 1)
  g.polygon("fill",
    hx + math.cos(a) * s * 0.6, hy + math.sin(a) * s * 0.6,
    hx + math.cos(a + 2.5) * s, hy + math.sin(a + 2.5) * s,
    hx + math.cos(a - 2.5) * s, hy + math.sin(a - 2.5) * s)
end

local function drawHUD()
  local g = love.graphics
  local total, frames = scoreGame(rolls)

  -- THE SCORE, top left, as large as the vertical room allows.
  --
  -- Label FIRST and above, then the number under it. With the label below,
  -- a one-digit score at 132px was a lone glyph floating over a word it
  -- did not obviously belong to.
  -- Solid ground under the score too, for the same reason as the strip.
  g.setColor(0.05, 0.04, 0.07, 0.82)
  g.rectangle("fill", 30, STRIP_Y - 20, 560, SCORE_SIZE + 100)

  g.setFont(ui.font(theme.fontSmall))
  g.setColor(theme.quiet)
  g.print("SCORE", 56, STRIP_Y - 4)

  -- The number in the lane's own maple, which ties the HUD to the thing
  -- it is reporting on and is warmer than plain white on this ground.
  g.setFont(ui.font(SCORE_SIZE))
  g.setColor(theme.lane)
  g.print(tostring(total), 52, STRIP_Y + 22)

  -- FRAME / BALL, under the score rather than centred across the top.
  -- Centred put it straight under the frame strip, which starts at x=828 --
  -- the two drew on top of each other and both became unreadable.
  g.setFont(ui.font(theme.fontMid))
  g.setColor(1, 1, 1)
  if state == "done" then
    g.print("GAME OVER", 56, STRIP_Y + SCORE_SIZE + 28)
  else
    g.print(("FRAME %d of 10    BALL %d"):format(frameNo, ballNo),
            56, STRIP_Y + SCORE_SIZE + 28)
  end

  -- THE FRAME STRIP, top right, so the whole game reads at a glance.
  --
  -- COLOURED BY WHAT HAPPENED. A strike is hot orange, a spare is cool
  -- blue, an ordinary frame is neutral -- so the shape of his game is
  -- legible from across the room without reading a single number. That is
  -- the whole point of a scoreboard, and a strip of identical grey boxes
  -- was not doing it.
  local BOXW, BOXH = 104, 96
  local x0 = 1920 - 52 - BOXW * 10

  -- AN OPAQUE PLATE UNDER THE STRIP. The room behind it is a patterned
  -- carpet now, and a translucent box over confetti is a box you cannot
  -- read. Everything in the HUD that carries a number gets solid ground.
  g.setColor(0.05, 0.04, 0.07, 0.86)
  g.rectangle("fill", x0 - 14, STRIP_Y - 14, BOXW * 10 + 22, BOXH + 28)

  -- What each frame was, walked from the rolls the same way scoring does.
  local kind = {}
  do
    local i = 1
    for f = 1, 10 do
      local a = rolls[i]
      if a == nil then break end
      if a == 10 then kind[f] = "strike"; i = i + 1
      else
        local b = rolls[i + 1]
        if b == nil then break end
        kind[f] = (a + b == 10) and "spare" or "open"
        i = i + 2
      end
    end
  end

  for f = 1, 10 do
    local x = x0 + (f - 1) * BOXW
    local k = kind[f]
    local c = (k == "strike" and theme.strike)
           or (k == "spare"  and theme.spare)
           or (k == "open"   and theme.openFrame)
           or nil

    -- the box: tinted by result, brightest on the frame being played
    if c then
      g.setColor(c[1], c[2], c[3], 0.30)
    else
      g.setColor(1, 1, 1, f == frameNo and 0.20 or 0.07)
    end
    g.rectangle("fill", x, STRIP_Y, BOXW - 6, BOXH)

    -- THE CURRENT FRAME wears a gold ring, which is this family's "you are
    -- here" marker everywhere else.
    if f == frameNo and state ~= "done" then
      g.setColor(theme.gold)
      g.setLineWidth(4)
      g.rectangle("line", x, STRIP_Y, BOXW - 6, BOXH)
    end

    g.setFont(ui.font(theme.fontSmall - 4))
    g.setColor(1, 1, 1, 0.68)
    g.printf(tostring(f), x, STRIP_Y + 6, BOXW - 6, "center")

    -- X for a strike, / for a spare -- the marks a real scoresheet uses,
    -- and they read faster than the number does.
    if k == "strike" or k == "spare" then
      g.setFont(ui.font(theme.fontSmall))
      g.setColor(c[1], c[2], c[3], 0.95)
      g.printf(k == "strike" and "X" or "/", x, STRIP_Y + 28, BOXW - 6, "center")
    end

    if frames[f] then
      g.setFont(ui.font(theme.fontMid))
      g.setColor(1, 1, 1)
      g.printf(tostring(frames[f]), x, STRIP_Y + 56, BOXW - 6, "center")
    end
  end

  -- THE SPIN DIAL. Only while aiming -- it is a choice about the next
  -- throw, and leaving it on screen during the roll implies it can still
  -- be changed.
  if state == "aim" then
    local X, Y, W, H = SPIN_UI_X, SPIN_UI_Y, SPIN_UI_W, SPIN_UI_H
    -- and solid ground under the meter, so the coloured track is read
    -- against black rather than against carpet
    g.setColor(0.05, 0.04, 0.07, 0.88)
    g.rectangle("fill", X - 26, Y - 58, W + 52, H + 92)
    g.setFont(ui.font(theme.fontSmall - 2))
    g.setColor(theme.quiet)
    g.printf(spinSet and "SPIN SET" or "TAP TO SET SPIN",
             X, Y - 46, W, "center")

    -- THE TRACK, tinted from hook-left through neutral to hook-right, so
    -- the bar itself says which end does what before the arrows are read.
    local SEG = 40
    for i = 0, SEG - 1 do
      local t = i / (SEG - 1) * 2 - 1              -- -1..1 across the bar
      local c = t < 0 and theme.hookLeft or theme.hookRight
      local k = math.abs(t)
      g.setColor(c[1] * k + theme.meterTrack[1] * (1 - k),
                 c[2] * k + theme.meterTrack[2] * (1 - k),
                 c[3] * k + theme.meterTrack[3] * (1 - k),
                 0.30 + k * 0.30)
      g.rectangle("fill", X + i * (W / SEG), Y, W / SEG + 1, H)
    end

    -- THE DEAD ZONE, drawn. A visible band in the middle that says "this
    -- much is straight" -- so the wide tolerance is a promise the player
    -- can see rather than a kindness hidden in the code.
    local dw = W * SPIN_DEAD
    g.setColor(0.82, 0.84, 0.90, 0.22)
    g.rectangle("fill", X + W / 2 - dw, Y, dw * 2, H)
    g.setColor(1, 1, 1, 0.30)
    g.setLineWidth(2)
    g.rectangle("line", X + W / 2 - dw, Y, dw * 2, H)

    -- HOOK DIRECTION, DRAWN AS THE PATH THE BALL WILL TAKE.
    --
    -- "<<" and ">>" are a programmer's shorthand for "more of this way".
    -- A curving arrow is the actual thing: it shows the ball going down
    -- the lane and bending, which is what the setting does, and it needs
    -- no reading at all. Mirrored either side of centre so the two hooks
    -- are visibly opposites.
    -- INSIDE the bar and pointing outward, one per hook direction. They
    -- start just outside the dead zone and run toward their own end, so
    -- the bar reads as "straight here, and more hook the further you go".
    local dz = W * SPIN_DEAD
    drawHookArrow(X + W / 2 - dz - 30, Y + H / 2 + 16, 176, -1, theme.hookLeft)
    drawHookArrow(X + W / 2 + dz + 30, Y + H / 2 + 16, 176,  1, theme.hookRight)

    g.setFont(ui.font(theme.fontSmall - 4))
    g.setColor(1, 1, 1, 0.42)
    g.printf("STRAIGHT", X + W / 2 - 120, Y + H / 2 - 18, 240, "center")

    -- THE MARKER. Fat, so it is easy to track: this is the thing his eye
    -- follows and his hand answers.
    local mx = X + (spinPos * 0.5 + 0.5) * W
    -- a soft glow under it, so a moving white bar on a coloured track
    -- still reads as the thing to watch
    g.setColor(1, 1, 1, 0.18)
    g.rectangle("fill", mx - 19, Y - 16, 38, H + 32)
    g.setColor(spinSet and theme.gold or { 1, 1, 1 })
    g.rectangle("fill", mx - 9, Y - 12, 18, H + 24)
    if spinSet then
      g.setColor(theme.gold)
      g.setLineWidth(4)
      g.rectangle("line", X, Y, W, H)
    end
  end

  if msg then
    -- BELOW the alley, not above it. The scoreboard owns the top of the
    -- frame now, and STRIKE at y=300 would land on the frame strip; the
    -- room under the lane is empty and the banner reads fine there.
    g.setFont(ui.font(theme.fontHuge or theme.fontBig))
    g.setColor(1, 0.95, 0.6, math.min(1, msgT))
    g.printf(msg, 0, 830, 1920, "center")
  elseif state == "aim" then
    g.setFont(ui.font(theme.fontSmall))
    g.setColor(theme.quiet)
    g.printf(spinSet and "drag back to load, sideways to aim, let go to throw"
                      or "tap to set the spin, then drag back and let go to throw",
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
  -- THE ALLEY SITS LOW IN THE FRAME.
  --
  -- Aiming the camera exactly at the lane centres it, and centred is not
  -- what this composition wants: the scoreboard now owns the top of the
  -- screen, and a centred alley crowds it while leaving dead room below.
  --
  -- Done by AIMING ABOVE the lane rather than by moving the eye. The eye's
  -- height is what defines the tilt angle (rise over run), so nudging it
  -- would change how far the deck is turned toward the viewer -- coupling
  -- two things that should stay independent. Lifting only the look-at
  -- point slides the subject down the frame and leaves the angle alone.
  -- 300, not 620. At 620 the lane was shoved down onto the hint line with
  -- the whole upper two thirds of the frame empty carpet -- overcorrecting
  -- a centred composition into a bottom-heavy one. This drops it clear of
  -- the scoreboard and no further.
  local LOOK_LIFT = 300
  local eye = dream.vec3(-dist / U,
                         (tgtY + dist * math.tan(CAM_TILT)) / U,
                         midZ / U)
  local tgt = dream.vec3(0, (tgtY + LOOK_LIFT) / U, midZ / U)

  local cam = dream:newCamera(camWorld(eye, tgt))
  cam:setFov(CAM_FOV)
  setProjection(eye, tgt, CAM_FOV)

  dream:prepare()
  dbg.draw()
  dream:present(cam)

  love.graphics.setDepthMode()
  -- Shadow first, under everything; then the sheen on the ball; then the
  -- aim line, which must sit on top of both.
  drawContactShadow()
  drawBallSheen()
  drawAim()
  -- Sparks are advanced HERE rather than in love.update purely because the
  -- effects live below it in this file and a local declared later is not
  -- in scope above. They are decoration with no bearing on the simulation,
  -- so stepping them on the draw clock costs nothing.
  updateSparks(love.timer and love.timer.getDelta and love.timer.getDelta() or 1 / 60)
  drawSparkle()
  drawHUD()
end
