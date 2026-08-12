-- field.lua - the play field. BOX2D, not Box3D.
--
-- This is a 2D game and pretending otherwise is what broke the first
-- version. Combo Pool's entire physics is six lines: reflect the velocity
-- at the boundary, then HARD-CLAMP the position back inside. A ball cannot
-- leave the arena because the code will not let it -- there is no floor to
-- fall off, no wall to climb, no gravity at all.
--
-- Built on Box3D with gravity, balls did all three: rolled over short
-- walls, rested on top of tall ones, and sat on the lip of a floor that
-- overhung its own cushions. Every one of those was a symptom of
-- simulating a dimension the game does not have.
--
-- So: Box2D with ZERO gravity for the simulation, and the 3D renderer
-- reads x/y out of it and draws spheres. The camera looks straight down,
-- so nothing is lost -- the third dimension was only ever presentation.

local M = {}

-- Field HALF-extents, in world units. 4:3, filling the left of the screen.
M.W, M.H = 540, 405

-- Big marbles: the field is 13.8 x 10.4 ball diameters across, chunkier
-- than Combo Pool (16) and far chunkier than a pool table (33). A merge
-- has to read at a glance from across a room.
M.BALL_R = 52

-- Drawn border. Thin: there are no pockets and nobody leans on a cushion,
-- so a chunky rail is screen space spent on furniture.
M.RAIL_VISUAL = 18

-- World units per 3D render unit. The renderer works in small numbers
-- (a ball is ~0.35 units across) while the game logic works in field
-- pixels, so everything handed to dream:draw is divided by this.
M.U = 92

-- Pixels per physics metre. Box2D is tuned for objects roughly 0.1-10 m,
-- so a 52 px ball wants to be ~0.1 m, not 52.
M.PPM = 520

-- Marble material.
--
-- Restitution stays high -- these are glass beads knocking about, not
-- billiard balls deadened by cloth, and a lively bank is where the combo
-- comes from. DAMPING is what ends a shot, and it is deliberately firm:
-- the player is waiting on the table to settle before the next launch, and
-- a marble that drifts for four seconds after the interesting part is over
-- is just dead air between turns. Firm enough to settle promptly, not so
-- firm that a shot cannot cross the field and still bank.
M.BALL_RESTITUTION = 0.60
M.BALL_FRICTION    = 0.02
M.BALL_DAMPING     = 2.4

function M.build(world)
  return { world = world }
end

-- THE BOUNDARY. Called after every step, for every ball.
--
-- This is NuSan's rule verbatim: if a ball is past an edge, flip that
-- component of its velocity and clamp the position back to the edge. The
-- clamp is what makes escape impossible -- reflection alone can still let
-- a fast ball end a step outside, and then it is gone forever.
--
-- Returns true if the ball hit a wall, which the caller turns into a combo
-- bump: with no pockets, banking is the whole toolkit.
function M.clampToField(body, r)
  local x, y = b2.body_position(body)
  local vx, vy = b2.body_velocity(body)
  local lim_x = M.W - r
  local lim_y = M.H - r
  local hit = false

  if x > lim_x then
    x, vx, hit = lim_x, -math.abs(vx), true
  elseif x < -lim_x then
    x, vx, hit = -lim_x, math.abs(vx), true
  end

  if y > lim_y then
    y, vy, hit = lim_y, -math.abs(vy), true
  elseif y < -lim_y then
    y, vy, hit = -lim_y, math.abs(vy), true
  end

  if hit then
    b2.body_set_position(body, x, y)
    b2.body_set_velocity(body, vx, vy)
  end
  return hit
end

return M
