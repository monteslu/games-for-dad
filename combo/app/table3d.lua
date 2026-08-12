-- table3d.lua - the play field: physics bodies, 3D meshes, walls.
--
-- Units: physics and layout are in PIXELS (the family's convention, and what
-- the 2D HUD is authored in). 3Dream is fed pixels/U. One conversion, named
-- once -- a second copy that disagrees puts the balls and the cloth in
-- different worlds, which renders as balls floating beside the table rather
-- than as an error.

local M = {}

M.U = 100                     -- pixels per dream unit

-- PIXELS PER METRE for the physics solver.
--
-- This is the single most important number in the file and it was wrong by
-- 10x. At Box3D's default 64 px/m these 19px balls were 30 CENTIMETRE
-- spheres on a 24-metre table -- beach balls in a car park. Box3D is tuned
-- for objects roughly 0.1-10 m, and everything downstream (impulse, mass,
-- gravity, restitution, sleep thresholds) inherits that error, which is why
-- no amount of tuning the shot impulse ever made the break feel right.
--
-- 598 px/m makes the playing surface a real 9-foot table (2.54 m x 1.27 m)
-- and a ball a real 3.2 cm.
M.PPM = 598

-- A 4:3 FIELD, not a 2:1 pool table. The play area fills the left of the
-- screen and the right-hand column is the cue's working space (the launcher
-- is on the right and shots travel LEFT), with the life bar above it and the
-- HUD below. See docs/COMBO.md for the layout drawing.
--
-- 1440x1080 of a 1920x1080 screen is exactly 4:3, leaving a 480px column.
M.W, M.H = 540, 405           -- HALF extents: 1080x810 px of play surface

-- BIGGER BALLS than Eight Ball (23) on purpose. At r=52 the field is 13.8 x
-- 10.4 ball diameters -- chunkier than Combo Pool's 16 and far chunkier than
-- Eight Ball's 33. A merge has to be readable at a glance from across a
-- room, and a seven-tier colour ramp needs a ball big enough to carry the
-- colour.
M.BALL_R = 52

-- NO POCKETS. Nothing to sink, so the walls are the only geometry and the
-- bank shot is the whole toolkit.
-- Cushion HALF-thickness. Must be comfortably larger than a ball's radius:
-- a wall thinner than the ball it is stopping can be tunnelled in a single
-- solver step by a hard shot, and the ball simply leaves the field. At
-- BALL_R=52 the old 30 was doing exactly that.
M.RAIL = 70

-- Built ONCE. These are constants, but this used to allocate a fresh outer
-- table plus six inner ones on every call -- and the contact-shadow pass
-- calls it once per ball, so a frame threw away ~112 tables just to read
-- six fixed positions. Cheap per call, not cheap sixteen times a frame at
-- 60Hz, and all of it garbage for the collector to walk.


-- Measured billiard constants (Dr Dave / Mathavan et al):
--   ball-ball restitution   0.92 - 0.98
--   ball-cloth rolling res. 0.005 - 0.015
--   ball-cushion restitution ~0.82, sliding friction ~0.14
-- These are what make a struck ball behave like a ball instead of a crate.
M.MAT = {
  cloth   = { friction = 0.22, restitution = 0.0,  rolling = 0.0 },
  cushion = { friction = 0.14, restitution = 0.82, rolling = 0.0 },
  -- friction here is the BALL-CLOTH sliding coefficient (measured 0.15-0.4,
  -- typical 0.2), NOT the ball-ball value. This is the number that converts
  -- a struck ball's sliding into ROLLING; at 0.06 the balls skated across
  -- the cloth without ever spinning up, which is what made 3D physics look
  -- like 2D physics.
  ball    = { friction = 0.22, restitution = 0.94, rolling = 0.010 },
  -- density chosen so a ball weighs the regulation 170 g at M.PPM
  ballDensity = 1268,
}

function M.build(world)
  local t = { cushionShapes = {}, world = world }

  -- The cloth. A thin static box; balls roll on its top face.
  local floor = b3.body_new(world, 0, 0, 0, 0)
  -- The floor stops AT the walls' inner faces, not past them. Eight Ball's
  -- floor overhangs the rails because a ball has to keep rolling under a
  -- pocket; here an overhang is just a ledge OUTSIDE the play area for balls
  -- to come to rest on, which is exactly what they did.
  local fs = b3.shape_box(floor, M.W, 10, M.H)
  b3.shape_set_material(fs, M.MAT.cloth.friction, M.MAT.cloth.restitution,
                        M.MAT.cloth.rolling)
  t.floor, t.floorShape = floor, fs

  -- Cushions: four solid walls.
  -- rather than rolling along an unbroken wall past the opening.
  --
  -- The gap is only as wide as the pocket itself: any wider and a ball
  -- rolls straight through it and off the table, which looks like the
  -- table leaking rather than like a pot.
  -- Wall geometry, and BOTH numbers were wrong on the first two attempts:
  --
  --  * too SHORT (22, inherited from a game with r=23 balls) and an r=52
  --    ball rolls straight over the top and leaves the field;
  --  * too TALL and centred high, and the wall's top face becomes a SHELF
  --    the balls climb onto and rest on, which looks identical to escaping.
  --
  -- The fix is a wall that is tall enough to block and whose top is BELOW
  -- the ball's resting centre, so there is nothing to come to rest on: the
  -- box is centred at y=0 like the felt, with a half-height slightly under
  -- the ball radius. A ball can never get on top of it because its own
  -- centre would have to rise above the contact point to do so.
  local WALL_H = M.BALL_R * 0.9
  local function cushion(x, z, hx, hz)
    local b = b3.body_new(world, x, 0, z, 0)
    local s = b3.shape_box(b, hx, WALL_H, hz)
    b3.shape_set_material(s, M.MAT.cushion.friction, M.MAT.cushion.restitution,
                          M.MAT.cushion.rolling)
    b3.shape_enable_hit_events(s, true)
    t.cushionShapes[s] = true
    return b
  end
  -- FOUR SOLID WALLS. Eight Ball splits each rail around a pocket mouth;
  -- there are no pockets here, so every wall is one unbroken cushion and a
  -- ball can be banked off any point of it.
  cushion(0, -M.H - M.RAIL, M.W + M.RAIL, M.RAIL)   -- top
  cushion(0,  M.H + M.RAIL, M.W + M.RAIL, M.RAIL)   -- bottom
  cushion(-M.W - M.RAIL, 0, M.RAIL, M.H + M.RAIL)   -- left
  cushion( M.W + M.RAIL, 0, M.RAIL, M.H + M.RAIL)   -- right

  return t
end

-- Is a point on the playing surface (used to place a ball in hand)?
function M.onTable(x, z)
  return x > -M.W + M.BALL_R and x < M.W - M.BALL_R
     and z > -M.H + M.BALL_R and z < M.H - M.BALL_R
end

return M
