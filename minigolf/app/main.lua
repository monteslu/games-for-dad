-- Minigolf - 22 holes, no clock, no way to lose.
--
-- Inspired by frozenjs/minigolf (MIT, Iced Development LLC). The hole
-- LAYOUTS are converted from that game's own level data; the physics,
-- rendering and controls here are new.
--
-- THE SAME DESIGN RULE AS THE REST OF THE FAMILY: nothing moves unless he
-- moves it, and there is no way to fail. Specifically, two rules from the
-- original are deliberately NOT carried over:
--
--   * the original REFUSES the cup above maxGoalVelocity, so a firm putt
--     that goes in gets rejected. That punishes a good shot for being
--     confident. Here it drops and rattles in.
--   * there is no stroke limit and no losing score. Par is shown because
--     it is interesting, never because it is a threshold.
--
-- Water still costs a stroke and replays from where you hit -- that is the
-- game, not a punishment, and it is instantly understandable.

local theme  = require("lib.theme")
local ui     = require("lib.ui")
local sounds = require("lib.sounds")
local levels = require("levels")
local course = require("course")
local fx     = require("fx")

-- ── constants ─────────────────────────────────────────────────────────

local COURSE_X, COURSE_Y = 210, 40
local COURSE_W, COURSE_H = 1500, 1000

-- Physics. The original ran Box2D at its own scale with a ball of radius
-- 11.5px; ours uses the engine's 32 px/m default, so the ball is about
-- 0.36m -- roughly a real golf ball if a golf ball were 23px on a 1500px
-- course. Damping is the original's, which is what makes a putt roll out
-- and settle rather than bouncing forever.
local BALL_R          = 11.5
local LINEAR_DAMPING  = 0.5
local ANGULAR_DAMPING = 0.4
local RESTITUTION     = 0.45      -- lively off the rails, like real timber
local FRICTION        = 0.25

-- Aiming. Pull BACK from the ball; the pull length is the power, exactly
-- like Eight Ball's cue, so a player who knows one knows the other.
local MAX_PULL   = 300            -- px of pull at full power
local MAX_SPEED  = 1350           -- px/s at full power
local SETTLE_V   = 6              -- below this the ball is "stopped"
local SAND_DRAG  = 0.80           -- per-contact velocity multiplier
local ZONE_PUSH  = 260            -- impulse-zone acceleration, px/s^2

local PAR = { 2,3,2,3,3,4,3,3,4,3,3,4,4,4,3,4,3,4,3,4,4,5 }

-- ── state ─────────────────────────────────────────────────────────────

local world, ballBody, ballShape
local bodies            -- handle -> entity, for hazard lookups
local level, levelIdx = nil, 1
local strokes, total = 0, 0
local state = "aim"     -- aim | rolling | sunk | done
local aimAngle, aimPull = 0, 0
local t = 0
local msg, msgTimer = nil, 0
local sunkTimer = 0
local startX, startY = 0, 0
local lastVX, lastVY = nil, nil
local ballImg
local motorJoints = {}

local function setMsg(s, secs) msg, msgTimer = s, secs or 2.2 end

-- ── level building ────────────────────────────────────────────────────

local function buildLevel(n)
  if world then world:destroy() end
  level = levels[n]
  bodies, motorJoints = {}, {}

  -- Top-down: NO GRAVITY. Everything the ball does is the putt, damping
  -- and whatever the course pushes it with.
  world = love.physics.newWorld(0, 0)

  local byId = {}

  for _, e in ipairs(level.entities) do
    if e.id == "ball" then
      startX, startY = e.x, e.y
    elseif e.water or e.sand or e.impulse or e.sensor then
      -- hazards and zones are SENSORS: they report contact without
      -- blocking the ball, so a bunker slows you rather than stopping
      -- you dead at its edge
      local b = love.physics.newBody(world, e.x, e.y, "static")
      local shp
      if e.kind == "circle" then shp = love.physics.newCircleShape(e.r)
      elseif e.kind == "rect" then shp = love.physics.newRectangleShape(e.hw * 2, e.hh * 2)
      else shp = love.physics.newPolygonShape(e.points) end
      -- sensor-ness must be set AT CREATION: Box2D 3.x has no setter for
      -- it, and a fixture that silently stayed solid would make the ball
      -- bounce off water with nothing on screen explaining why
      love.physics.newFixture(b, shp, 0, { sensor = true })
      byId[e.id] = b
      bodies[b.handle] = e
    else
      local b = love.physics.newBody(world, e.x, e.y,
                                     e.dynamic and "dynamic" or "static")
      local shp
      if e.kind == "circle" then shp = love.physics.newCircleShape(e.r)
      elseif e.kind == "rect" then shp = love.physics.newRectangleShape(e.hw * 2, e.hh * 2)
      else shp = love.physics.newPolygonShape(e.points) end
      local f = love.physics.newFixture(b, shp, e.density or 1)
      f:setRestitution(e.restitution or RESTITUTION)
      f:setFriction(FRICTION)
      byId[e.id] = b
      bodies[b.handle] = e
    end
  end

  -- the ball
  ballBody = love.physics.newBody(world, startX, startY, "dynamic")
  ballShape = love.physics.newCircleShape(BALL_R)
  local bf = love.physics.newFixture(ballBody, ballShape, 1)
  bf:setRestitution(RESTITUTION)
  bf:setFriction(FRICTION)
  ballBody:setLinearDamping(LINEAR_DAMPING)
  ballBody:setAngularDamping(ANGULAR_DAMPING)
  ballBody:setBullet(true)     -- a hard putt must not tunnel through a rail
  byId.ball = ballBody

  -- moving obstacles (hole 13's motorised wood bar)
  if level.joints then
    for _, j in ipairs(level.joints) do
      local a, b = byId[j.a], byId[j.b]
      if a and b then
        local jt = love.physics.newRevoluteJoint(a, b, a:getX(), a:getY())
        if j.motor then
          jt:setMaxMotorForce(j.maxMotorTorque or 3500)
          jt:setMotorSpeed(j.motorSpeed or 4)
        end
        motorJoints[#motorJoints + 1] = jt
      end
    end
  end

  strokes = 0
  state = "aim"
  aimPull = 0
  fx.reset()
end

local function resetBall(why)
  ballBody:setPosition(startX, startY)
  ballBody:setLinearVelocity(0, 0)
  ballBody:setAngularVelocity(0)
  lastVX, lastVY = nil, nil
  state = "aim"
  aimPull = 0
  if why then setMsg(why, 1.8) end
end

-- ── input ─────────────────────────────────────────────────────────────

local prevDown, edges, lastEdge, frameNo = {}, {}, {}, 0
local DEBOUNCE = 9
local AUTO = rawget(_G, "GOLF_DRIVER")
local padUsed = false

local function readEdges()
  frameNo = frameNo + 1
  for k in pairs(edges) do edges[k] = nil end
  if AUTO then
    local b = AUTO(frameNo)
    if b then edges[b] = true end
    return
  end
  for _, b in ipairs({ "a", "b", "x", "y", "left", "right", "up", "down" }) do
    local d = love.pad.isDown(b)
    local e = d and not prevDown[b]
    if e and (frameNo - (lastEdge[b] or -100)) < DEBOUNCE then e = false end
    if e then lastEdge[b] = frameNo; padUsed = true end
    edges[b] = e
    prevDown[b] = d
  end
end

-- Touch is an equal path: poll ALL ten pointer slots, since a mouse-only
-- read silently ignores every finger.
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

local function strike()
  local sp = (aimPull / MAX_PULL) * MAX_SPEED
  if sp < 30 then return end                 -- a nudge is not a stroke
  ballBody:setLinearVelocity(math.cos(aimAngle) * sp, math.sin(aimAngle) * sp)
  strokes = strokes + 1
  state = "rolling"
  -- turf sprays BACKWARD from the strike, the way a real divot flies
  local bx0, by0 = ballBody:getPosition()
  fx.turf(bx0, by0, -math.cos(aimAngle), -math.sin(aimAngle), 0.9)
  aimPull = 0
  sounds.play("clack", 0.55, 0.95 + love.math.random() * 0.12)
end

-- ── love callbacks ────────────────────────────────────────────────────

function love.load()
  sounds.loadAll()
  fx.init()
  ballImg = love.graphics.newImage("assets/ball.png")
  buildLevel(levelIdx)
  _G.GOLF_STATE = setmetatable({}, { __index = function(_, k)
    if k == "state" then return state end
    if k == "strokes" then return strokes end
    if k == "level" then return levelIdx end
    if k == "ball" then return ballBody end
    if k == "total" then return total end
    return nil
  end })
end

function love.update(dt)
  t = t + dt
  readEdges()
  readPointers()
  if msgTimer > 0 then msgTimer = msgTimer - dt; if msgTimer <= 0 then msg = nil end end

  -- ── aiming ──
  if state == "aim" then
    local bx, by = ballBody:getPosition()

    if padUsed then
      if love.pad.isDown("left")  then aimAngle = aimAngle - dt * 2.2 end
      if love.pad.isDown("right") then aimAngle = aimAngle + dt * 2.2 end
      if love.pad.isDown("down")  then aimPull = math.min(MAX_PULL, aimPull + dt * 320) end
      if love.pad.isDown("up")    then aimPull = math.max(0, aimPull - dt * 320) end
      if edges.a or edges.b then strike() end
    end

    -- Touch/mouse: drag away from the ball. The drag vector IS the shot,
    -- reversed -- pull back like a real putter and let go.
    if held then
      local dx, dy = held.x - bx, held.y - by
      local d = math.sqrt(dx * dx + dy * dy)
      if d > 8 then
        aimAngle = math.atan(-dy, -dx)
        aimPull = math.min(MAX_PULL, d)
      end
    elseif aimPull > 0 and not padUsed then
      strike()                                  -- released: shoot
    end
  end

  -- ── physics ──
  if state == "rolling" or state == "aim" then
    world:update(1 / 60)
  end

  fx.update(dt)

  if state == "rolling" then
    local vx, vy = ballBody:getLinearVelocity()
    local speed = math.sqrt(vx * vx + vy * vy)
    local bx, by = ballBody:getPosition()

    -- the trail only makes sense while genuinely moving; a crawling ball
    -- with a comet tail looks wrong
    if speed > 60 then fx.trailPush(bx, by) end

    -- a rail hit: the ball reversed hard this frame. Kick up turf and
    -- click, scaled by how hard -- a nudge should not sound like a smash.
    if lastVX then
      local dvx, dvy = vx - lastVX, vy - lastVY
      local impact = math.sqrt(dvx * dvx + dvy * dvy)
      if impact > 180 then
        local g = math.min(1, impact / 900)
        sounds.play("clack", 0.25 + g * 0.6, 0.9 + love.math.random() * 0.25)
        fx.turf(bx, by, -vx, -vy, 0.4 + g)
      end
    end
    lastVX, lastVY = vx, vy

    -- hazards, by proximity. A contact callback would be tidier, but the
    -- engine polls contacts per step rather than delivering them, and a
    -- point test against 20-odd sensors is nothing next to the solver.
    for _, e in ipairs(level.entities) do
      local hit = false
      if e.water or e.sand or e.impulse then
        if e.kind == "circle" then
          local dx, dy = bx - e.x, by - e.y
          hit = (dx * dx + dy * dy) < (e.r + BALL_R) * (e.r + BALL_R)
        elseif e.kind == "rect" then
          hit = math.abs(bx - e.x) < e.hw + BALL_R and math.abs(by - e.y) < e.hh + BALL_R
        end
      end
      if hit then
        if e.water then
          fx.splash(bx, by)
          sounds.play("clack", 0.3, 0.7)
          strokes = strokes + 1              -- water costs a stroke
          resetBall("Water. Take a stroke.")
          break
        elseif e.sand then
          ballBody:setLinearVelocity(vx * SAND_DRAG, vy * SAND_DRAG)
        elseif e.impulse then
          local a = math.rad(e.impulseAngle or 0)
          local p = (e.impulse or 1) * ZONE_PUSH * (1 / 60)
          ballBody:setLinearVelocity(vx + math.cos(a) * p, vy + math.sin(a) * p)
        end
      end
    end

    -- the cup
    for _, e in ipairs(level.entities) do
      if e.id == "goal" then
        local dx, dy = bx - e.x, by - e.y
        -- generous: the drawn cup is bigger than the 6px sensor, and the
        -- player is aiming at what they can SEE
        if dx * dx + dy * dy < 26 * 26 then
          state = "sunk"
          sunkTimer = 2.4
          local d = strokes - (PAR[levelIdx] or 3)
          total = total + d
          ballBody:setLinearVelocity(0, 0)
          ballBody:setPosition(e.x, e.y)
          sounds.play("hole", 0.9)
          fx.celebrate(e.x, e.y, strokes == 1 or d <= -1)
          fx.popup(e.x, e.y - 70, d < 0 and (d .. " under") or
                   (d == 0 and "par") or ("+" .. d))
          if strokes > 7 then sounds.play("laugh", 0.7) end
        end
      end
    end

    if state == "rolling" and speed < SETTLE_V then
      ballBody:setLinearVelocity(0, 0)
      ballBody:setAngularVelocity(0)
      state = "aim"
    end
  end

  if state == "sunk" then
    sunkTimer = sunkTimer - dt
    if sunkTimer <= 0 then
      if levelIdx >= #levels then
        state = "done"
      else
        levelIdx = levelIdx + 1
        buildLevel(levelIdx)
      end
    end
  end

  if state == "done" and (edges.a or edges.b or click) then
    levelIdx, total = 1, 0
    buildLevel(levelIdx)
  end
end

-- ── drawing ───────────────────────────────────────────────────────────

local function drawAim()
  if state ~= "aim" or aimPull < 4 then return end
  local g = love.graphics
  local bx, by = ballBody:getPosition()
  local power = aimPull / MAX_PULL

  -- The pull line points BACK from the ball, the way a putter goes, and
  -- fades cream to red with power -- the same language as Eight Ball's
  -- cue, so the two games teach each other.
  local ex = bx - math.cos(aimAngle) * aimPull
  local ey = by - math.sin(aimAngle) * aimPull
  g.setLineWidth(7)
  g.setColor(1, 0.95 - power * 0.65, 0.75 - power * 0.7, 0.92)
  g.line(bx, by, ex, ey)
  g.circle("fill", ex, ey, 9)

  -- a dotted forecast the other way, so he can see where it will go
  g.setColor(1, 1, 1, 0.5)
  for i = 1, 9 do
    local d = i * 26
    g.circle("fill", bx + math.cos(aimAngle) * d, by + math.sin(aimAngle) * d,
             3.2 - i * 0.2)
  end
end

local function drawBall()
  local g = love.graphics
  local bx, by = ballBody:getPosition()
  -- contact shadow first: it is what puts the ball ON the grass rather
  -- than floating above it
  g.setColor(0, 0, 0, 0.32)
  g.ellipse("fill", bx + 4, by + 5, BALL_R * 1.05, BALL_R * 0.8)
  g.setColor(1, 1, 1, 1)
  local s = (BALL_R * 2) / ballImg:getWidth()
  g.draw(ballImg, bx, by, ballBody:getAngle(), s, s,
         ballImg:getWidth() / 2, ballImg:getHeight() / 2)
end

local function drawHUD()
  local g = love.graphics
  local par = PAR[levelIdx] or 3
  g.setFont(ui.font(theme.fontMid))
  g.setColor(1, 1, 1)
  g.printf(("HOLE %d of %d"):format(levelIdx, #levels), 0, 12, 1920, "center")
  g.setFont(ui.font(theme.fontBig))
  g.print(("STROKES  %d"):format(strokes), 40, 986)
  g.setFont(ui.font(theme.fontMid))
  g.setColor(theme.quiet)
  g.print(("PAR %d"):format(par), 40, 1036)
  local sign = total > 0 and "+" or ""
  g.printf(total == 0 and "EVEN" or (sign .. total), 0, 1036, 1880, "right")

  if msg then
    g.setFont(ui.font(theme.fontBig))
    g.setColor(0.55, 0.92, 1.0, math.min(1, msgTimer * 2))
    g.printf(msg, 0, 120, 1920, "center")
  end

  if state == "sunk" then
    local d = strokes - par
    local name = (strokes == 1 and "HOLE IN ONE!")
      or (d <= -3 and "ALBATROSS!") or (d == -2 and "EAGLE!")
      or (d == -1 and "BIRDIE") or (d == 0 and "PAR")
      or (d == 1 and "BOGEY") or (d == 2 and "DOUBLE BOGEY") or "NICE TRY"
    g.setFont(ui.font(theme.fontHuge))
    g.setColor(theme.gold)
    g.printf(name, 0, 440, 1920, "center")
  end

  if state == "done" then
    g.setColor(0, 0, 0, 0.72)
    g.rectangle("fill", 0, 0, 1920, 1080)
    g.setFont(ui.font(theme.fontHuge))
    g.setColor(theme.gold)
    g.printf("ROUND COMPLETE", 0, 400, 1920, "center")
    g.setFont(ui.font(theme.fontBig))
    g.setColor(1, 1, 1)
    local sign2 = total > 0 and "+" or ""
    g.printf(total == 0 and "EVEN PAR" or (sign2 .. total .. " for the round"),
             0, 520, 1920, "center")
    g.printf("Press a button to play again", 0, 620, 1920, "center")
  end

  -- controls, permanently on screen. He should never have to remember.
  g.setFont(ui.font(theme.fontSmall - 4))
  g.setColor(1, 1, 1, 0.6)
  if padUsed then
    g.printf("LEFT/RIGHT aim    DOWN pull back    A hit", 0, 1044, 1920, "center")
  else
    g.printf("drag back from the ball, let go to hit", 0, 1044, 1920, "center")
  end
end

function love.draw()
  course.draw(level, t)
  drawAim()
  fx.drawTrail(BALL_R)
  drawBall()
  fx.draw()
  fx.drawPops(ui.font(theme.fontBig))
  drawHUD()
end
