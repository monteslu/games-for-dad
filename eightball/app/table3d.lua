-- table3d.lua - the pool table: physics bodies, 3D meshes, pockets.
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

-- A 2:1 table, the real proportion of a pool table (9ft x 4.5ft).
M.W, M.H = 760, 380           -- HALF extents of the playing surface, px
M.BALL_R = 23
M.POCKET_R = 44               -- generous: this is a game for a 85-year-old,
                              -- and a pocket that rejects a good shot is a
                              -- bug as far as the player is concerned
M.RAIL = 26                   -- cushion thickness

-- Pocket centres: four corners and two side pockets, as on a real table.
function M.pockets()
  return {
    { x = -M.W, z = -M.H }, { x = 0, z = -M.H - 4 }, { x = M.W, z = -M.H },
    { x = -M.W, z =  M.H }, { x = 0, z =  M.H + 4 }, { x = M.W, z =  M.H },
  }
end

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
  local fs = b3.shape_box(floor, M.W + M.RAIL * 2, 10, M.H + M.RAIL * 2)
  b3.shape_set_material(fs, M.MAT.cloth.friction, M.MAT.cloth.restitution,
                        M.MAT.cloth.rolling)
  t.floor, t.floorShape = floor, fs

  -- Cushions. Split at the side pockets so a ball can actually fall in
  -- rather than rolling along an unbroken wall past the opening.
  --
  -- The gap is only as wide as the pocket itself: any wider and a ball
  -- rolls straight through it and off the table, which looks like the
  -- table leaking rather than like a pot.
  local seg = (M.W - M.POCKET_R) / 2
  local function cushion(x, z, hx, hz)
    local b = b3.body_new(world, x, 22, z, 0)
    local s = b3.shape_box(b, hx, 22, hz)
    b3.shape_set_material(s, M.MAT.cushion.friction, M.MAT.cushion.restitution,
                          M.MAT.cushion.rolling)
    b3.shape_enable_hit_events(s, true)
    t.cushionShapes[s] = true
    return b
  end
  local off = M.POCKET_R + seg
  cushion(-off, -M.H - M.RAIL, seg, M.RAIL)   -- top, left of the side pocket
  cushion( off, -M.H - M.RAIL, seg, M.RAIL)   -- top, right
  cushion(-off,  M.H + M.RAIL, seg, M.RAIL)   -- bottom, left
  cushion( off,  M.H + M.RAIL, seg, M.RAIL)   -- bottom, right
  cushion(-M.W - M.RAIL, 0, M.RAIL, M.H - M.POCKET_R)   -- left end
  cushion( M.W + M.RAIL, 0, M.RAIL, M.H - M.POCKET_R)   -- right end

  return t
end

-- Is this ball over a pocket mouth?
function M.overPocket(x, z)
  for _, p in ipairs(M.pockets()) do
    local dx, dz = x - p.x, z - p.z
    if dx * dx + dz * dz < M.POCKET_R * M.POCKET_R then return true end
  end
  return false
end

-- Is a point on the playing surface (used to place a ball in hand)?
function M.onTable(x, z)
  return x > -M.W + M.BALL_R and x < M.W - M.BALL_R
     and z > -M.H + M.BALL_R and z < M.H - M.BALL_R
end

return M
