-- Minigolf - 22 holes, no clock, no way to lose.
--
-- Inspired by frozenjs/minigolf (MIT, Iced Development LLC). The hole
-- LAYOUTS are converted from that game's own level data; the physics,
-- rendering and controls here are new.
--
-- FULL 3D, with 3D PHYSICS. Box3D simulates a real sphere rolling on a
-- real surface, so the ball's orientation comes from the solver as an
-- actual quaternion rather than being derived from how far it moved. An
-- earlier build ran a 2D world and computed the spin from travel distance;
-- it looked like a sliding disc because that is what it was.
--
-- THE SAME DESIGN RULE AS THE REST OF THE FAMILY: nothing moves unless he
-- moves it, and there is no way to fail. Two rules from the original are
-- deliberately NOT carried over:
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
local dream  = require("3DreamEngine.init")
local course = require("course")
local fx     = require("fx")

-- ── constants ─────────────────────────────────────────────────────────

local U      = course.U
local BALL_R = course.BALL_R

-- PHYSICS IN PIXELS. b3.set_meter maps pixels to metres, so the level
-- data's own units drive the simulation directly and every tuning number
-- below is readable against the 1500x1000 course.
local PPM     = 90                -- pixels per metre
local GRAVITY = -9.81 * PPM

-- A golf ball on a green: bouncy off timber, high rolling resistance so a
-- putt runs out and settles rather than rolling forever.
local RESTITUTION = 0.45
local FRICTION    = 0.28
local ROLLING     = 0.055
local LIN_DAMP    = 0.35
local ANG_DAMP    = 0.55

-- Aiming. Pull BACK from the ball; the pull length is the power, exactly
-- like Eight Ball's cue, so a player who knows one knows the other.
local MAX_PULL   = 300            -- px of pull at full power
local MAX_SPEED  = 1500           -- px/s at full power
local SETTLE_V   = 14             -- below this the ball is "stopped"
local SAND_DRAG  = 0.80
local ZONE_PUSH  = 320

local PAR = { 2,3,2,3,3,4,3,3,4,3,3,4,4,4,3,4,3,4,3,4,4,5 }

-- ── state ─────────────────────────────────────────────────────────────

local world, ballBody, ballShape
local level, levelIdx = nil, 1
local holeInfo
local strokes, total = 0, 0
local state = "aim"     -- aim | rolling | sunk | done
local aimAngle, aimPull = 0, 0
local t = 0
local msg, msgTimer = nil, 0
local sunkTimer = 0
local startX, startY = 0, 0
local lastVX, lastVZ = nil, nil
local dragFrom = nil    -- where the current drag STARTED, in cart pixels

-- 3Dream wants a WORLD matrix for the camera, not a view matrix.
--
-- The AIM POINT is a parameter, not always the origin: with a fixed origin
-- target, pushing the eye back to get a lean also rotates the course under
-- the camera. RIGHT is forward x up, NOT up x forward -- the other order
-- gives a left-handed basis and mirrors the whole scene, which renders the
-- ball at the cup's end of the course and the hole at the tee.
local function camWorld(eye, target)
  target = target or dream.vec3(0, 0, 0)
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

local function setMsg(s, secs) msg, msgTimer = s, secs or 2.2 end

-- ── projecting the green onto the screen ──────────────────────────────
--
-- THE 2D OVERLAYS HAVE TO GO THROUGH THE CAMERA TOO.
--
-- The aim line, the trail and the particles are all authored in CART
-- PIXELS, which is the space the level data and the physics use. The
-- course, though, is drawn by a tilted perspective camera -- so a point at
-- cart (372,378) actually lands at screen (546,429). Drawing the overlays
-- at their raw cart coordinates puts them up to 174px away from the ball
-- they are supposed to be attached to; they agree only at the exact centre
-- of the screen, which is why it looks almost right.
--
-- These functions project a point ON THE GREEN (y=0) to screen pixels
-- using the same eye, target and fov the 3D pass just used.
local projR, projU, projF, projEye = nil, nil, nil, nil
local projTanX, projTanY = 1, 1

function setProjection(eye, target, fov)
  local f = (target - eye):normalize()
  local up = dream.vec3(0, 1, 0)
  local r = f:cross(up):normalize()
  local u = r:cross(f):normalize()
  projR, projU, projF, projEye = r, u, f, eye
  local t = math.tan(math.rad(fov / 2))
  projTanY = t
  projTanX = t * (1920 / 1080)
end

-- cart pixels (x, y) on the green -> screen pixels
local function toScreen(px, py, height)
  if not projR then return px, py end
  local dx = px / U - projEye.x
  local dy = (height or 0) / U - projEye.y
  local dz = py / U - projEye.z
  local x = dx * projR.x + dy * projR.y + dz * projR.z
  local y = dx * projU.x + dy * projU.y + dz * projU.z
  local z = dx * projF.x + dy * projF.y + dz * projF.z
  if z <= 0.001 then return -9999, -9999 end
  return (x / (z * projTanX)) * 960 + 960,
         (-y / (z * projTanY)) * 540 + 540
end
_G.MINIGOLF_TO_SCREEN = toScreen

-- ── level building ────────────────────────────────────────────────────

local function buildLevel(n)
  if world then b3.world_destroy(world) end
  level = levels[n]

  world = b3.world_new(0, GRAVITY, 0)
  holeInfo = course.build(world, level)

  startX = holeInfo.start and holeInfo.start.x or 400
  startY = holeInfo.start and holeInfo.start.y or 540

  -- The ball starts ON the green: its centre one radius above y=0, which
  -- is the putting surface. Dropped from higher it bounces on the tee.
  ballBody = b3.body_new(world, startX, BALL_R, startY, 2)   -- 2 = dynamic
  ballShape = b3.shape_sphere(ballBody, BALL_R)
  b3.shape_set_material(ballShape, FRICTION, RESTITUTION, ROLLING)
  b3.body_set_linear_damping(ballBody, LIN_DAMP)
  b3.body_set_angular_damping(ballBody, ANG_DAMP)
  -- A putt is fast and the rails are thin; without continuous collision a
  -- hard shot tunnels straight through a rail between steps.
  b3.body_set_bullet(ballBody, true)

  strokes = 0
  aimPull = 0
  state = "aim"
  lastVX, lastVZ = nil, nil
  fx.reset()
end

local function resetBall(why)
  b3.body_set_transform(ballBody, startX, BALL_R, startY, 0, 1, 0, 0)
  b3.body_set_velocity(ballBody, 0, 0, 0)
  b3.body_set_angular_velocity(ballBody, 0, 0, 0)
  state = "aim"
  aimPull = 0
  if why then setMsg(why) end
end

-- The ball's position, in CART PIXELS, which is what the HUD, the aim line
-- and the hazard tests all speak.
local function ballPos()
  local x, y, z = b3.body_position(ballBody)
  return x, z, y
end

-- ── input ─────────────────────────────────────────────────────────────

local edges, prevDown, lastEdge = {}, {}, {}
local frameNo, DEBOUNCE = 0, 6
local padUsed = false
local AUTO = rawget(_G, "MINIGOLF_AUTOPLAY")

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
  if sp < 40 then return end                 -- a nudge is not a stroke
  -- The putt is horizontal: velocity in x and z, nothing in y. A putter
  -- does not loft the ball, and any vertical component here turns a firm
  -- shot into a chip that skips over the rails.
  b3.body_set_velocity(ballBody, math.cos(aimAngle) * sp, 0,
                       math.sin(aimAngle) * sp)
  strokes = strokes + 1
  state = "rolling"
  local bx, by = ballPos()
  fx.turf(bx, by, -math.cos(aimAngle), -math.sin(aimAngle), 0.9)
  aimPull = 0
  sounds.play("clack", 0.55, 0.95 + love.math.random() * 0.12)
end

-- ── love callbacks ────────────────────────────────────────────────────

function love.load()
  -- DIRECT MODE, set before init so the canvas set is built for it. The
  -- deferred ("normal") path renders the geometry correctly and then
  -- composites to black in this engine, which is why Eight Ball runs
  -- direct too.
  dream.canvases:setMode("direct")
  dream:init()
  -- THE SKY IS A FUNCTION, not a colour.
  --
  -- Passed a colour, 3DreamEngine clears to it inside its own push/pop with
  -- its canvas bound -- and on this engine's direct path that clear never
  -- reaches the screen, so the sky came out black however it was set. A
  -- clear in love.draw does not survive either: dream:present() wipes the
  -- frame (clearing to bright red proves it -- the corner still comes back
  -- black).
  --
  -- A function sky is called at the right point in the render pass, with
  -- the screen bound, so drawing here actually lands. A vertical gradient
  -- reads as a horizon and gives the course something to sit against.
  dream:setSky(function()
    local g = love.graphics
    g.setDepthMode()
    local BANDS = 32
    for i = 0, BANDS - 1 do
      local t = i / (BANDS - 1)
      -- deeper blue overhead, paler toward the horizon, which is what
      -- makes a flat fill read as sky rather than as a backdrop
      g.setColor(0.30 + t * 0.34, 0.52 + t * 0.30, 0.82 + t * 0.12)
      g.rectangle("fill", 0, i * (1080 / BANDS), 1920, 1080 / BANDS + 1)
    end
    g.setColor(1, 1, 1, 1)
  end)

  -- The metre scale must be set BEFORE the world exists: every length that
  -- follows is converted through it.
  b3.set_meter(PPM)

  course.initMaterials()
  sounds.loadAll()
  fx.init()
  buildLevel(levelIdx)

  _G.GOLF_STATE = setmetatable({}, { __index = function(_, k)
    if k == "state" then return state end
    if k == "strokes" then return strokes end
    if k == "level" then return levelIdx end
    if k == "total" then return total end
    return nil
  end })
end

function love.update(dt)
  t = t + dt
  readEdges()
  readPointers()
  if msgTimer > 0 then msgTimer = msgTimer - dt; if msgTimer <= 0 then msg = nil end end

  -- TEST HOOK. The host can write the `aux` debug field to jump straight to
  -- a hole; the harness uses it to render all 22 without sinking 22 putts.
  -- It is not reachable from any control, so it cannot fire during play.
  if love.debugRead then
    local want = love.debugRead(1)
    if want and want > 0 and want <= #levels and want ~= levelIdx then
      levelIdx = want
      buildLevel(levelIdx)
    end
  end

  -- ── aiming ──
  if state == "aim" then
    local bx, by = ballPos()

    if padUsed then
      if love.pad.isDown("left")  then aimAngle = aimAngle - dt * 2.2 end
      if love.pad.isDown("right") then aimAngle = aimAngle + dt * 2.2 end
      if love.pad.isDown("down")  then aimPull = math.min(MAX_PULL, aimPull + dt * 320) end
      if love.pad.isDown("up")    then aimPull = math.max(0, aimPull - dt * 320) end
      if edges.a or edges.b then strike() end
    end

    -- Touch/mouse: the drag is measured from WHERE THE FINGER WENT DOWN,
    -- not from the ball.
    --
    -- Measuring from the ball made the pull effectively random: the moment
    -- you touched anywhere, the distance from that point to the ball was
    -- already counted as pull, so touching far from the ball fired a
    -- full-power shot before you had dragged at all. A putt has to be a
    -- gesture with a beginning -- press, drag back, release -- and the
    -- length of the DRAG is the power.
    if held then
      if not dragFrom then dragFrom = { x = held.x, y = held.y } end
      local dx, dy = held.x - dragFrom.x, held.y - dragFrom.y
      local d = math.sqrt(dx * dx + dy * dy)
      if d > 8 then
        aimAngle = math.atan(-dy, -dx)
        aimPull = math.min(MAX_PULL, d)
      else
        aimPull = 0
      end
    else
      if aimPull > 0 and not padUsed then strike() end
      dragFrom = nil
    end
  end

  -- ── physics ──
  if state == "rolling" or state == "aim" then
    b3.world_step(world, 1 / 60, 4)
  end

  course.update(dt)
  fx.update(dt)

  -- Publish the ball's position for the test harness. Finding it by
  -- pixel-hunting is genuinely hard now that the rails are a pale checker
  -- and the ball is tinted: a colour search merges the two, and every
  -- refinement of the heuristic was another way to be confidently wrong
  -- about where the ball was. The cart knows, so it says.
  do
    local bx, by = ballPos()
    love.debugValue(0, math.floor(bx) * 2048 + math.floor(by))
  end

  if state == "rolling" then
    local vx, _, vz = b3.body_velocity(ballBody)
    local speed = math.sqrt(vx * vx + vz * vz)
    local bx, by = ballPos()

    if speed > 60 then fx.trailPush(bx, by) end

    -- a rail hit: the ball reversed hard this frame
    if lastVX then
      local dvx, dvz = vx - lastVX, vz - lastVZ
      local impact = math.sqrt(dvx * dvx + dvz * dvz)
      if impact > 180 then
        local g = math.min(1, impact / 900)
        sounds.play("clack", 0.25 + g * 0.6, 0.9 + love.math.random() * 0.25)
        fx.turf(bx, by, -vx, -vz, 0.4 + g)
      end
    end
    lastVX, lastVZ = vx, vz

    -- hazards, by proximity
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
          b3.body_set_velocity(ballBody, vx * SAND_DRAG, 0, vz * SAND_DRAG)
        elseif e.impulse then
          local a = math.rad(e.impulseAngle or 0)
          local p = (e.impulse or 1) * ZONE_PUSH * (1 / 60)
          b3.body_set_velocity(ballBody, vx + math.cos(a) * p, 0,
                               vz + math.sin(a) * p)
        end
      end
    end

    -- the cup
    if holeInfo.goal then
      local dx, dy = bx - holeInfo.goal.x, by - holeInfo.goal.y
      if dx * dx + dy * dy < course.CUP_R * course.CUP_R then
        state = "sunk"
        sunkTimer = 2.4
        local d = strokes - (PAR[levelIdx] or 3)
        total = total + d
        b3.body_set_velocity(ballBody, 0, 0, 0)
        b3.body_set_angular_velocity(ballBody, 0, 0, 0)
        b3.body_set_transform(ballBody, holeInfo.goal.x, -BALL_R * 0.4,
                              holeInfo.goal.y, 0, 1, 0, 0)
        sounds.play("hole", 0.9)
        fx.celebrate(holeInfo.goal.x, holeInfo.goal.y, strokes == 1 or d <= -1)
        fx.popup(holeInfo.goal.x, holeInfo.goal.y - 70,
                 d < 0 and (d .. " under") or (d == 0 and "par") or ("+" .. d))
        if strokes > 7 then sounds.play("laugh", 0.7) end
      end
    end

    if state == "rolling" and speed < SETTLE_V then
      b3.body_set_velocity(ballBody, 0, 0, 0)
      b3.body_set_angular_velocity(ballBody, 0, 0, 0)
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
  local bx, by = ballPos()
  local power = aimPull / MAX_PULL

  -- Every point goes through toScreen. The aim line is authored in cart
  -- pixels like the physics, but it is drawn OVER a perspective render, so
  -- raw cart coordinates put it up to 174px away from the ball it belongs
  -- to -- correct only at the exact centre of the screen.
  local sx, sy = toScreen(bx, by, BALL_R)
  local ex, ey = toScreen(bx - math.cos(aimAngle) * aimPull,
                          by - math.sin(aimAngle) * aimPull, BALL_R)
  g.setLineWidth(7)
  g.setColor(1, 0.95 - power * 0.65, 0.75 - power * 0.7, 0.92)
  g.line(sx, sy, ex, ey)
  g.circle("fill", ex, ey, 9)

  g.setColor(1, 1, 1, 0.5)
  for i = 1, 9 do
    local d = i * 26
    local dx, dy = toScreen(bx + math.cos(aimAngle) * d,
                            by + math.sin(aimAngle) * d, BALL_R)
    g.circle("fill", dx, dy, 3.2 - i * 0.2)
  end
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
    g.setColor(1, 1, 1, math.min(1, msgTimer))
    g.printf(msg, 0, 470, 1920, "center")
  elseif state == "aim" and strokes == 0 then
    g.setFont(ui.font(theme.fontSmall))
    g.setColor(theme.quiet)
    g.printf("drag back from the ball, let go to hit", 0, 1044, 1920, "center")
  end

  if state == "done" then
    g.setFont(ui.font(theme.fontBig))
    g.setColor(1, 1, 1)
    g.printf("ROUND COMPLETE", 0, 430, 1920, "center")
    g.setFont(ui.font(theme.fontMid))
    g.printf((total == 0 and "EVEN" or ((total > 0 and "+" or "") .. total)) ..
             " for 22 holes", 0, 510, 1920, "center")
    g.printf("press A to play again", 0, 570, 1920, "center")
  end
end

-- The ball's world matrix, straight from the solver's quaternion. This is
-- the whole point of simulating in 3D: the roll is not derived from travel
-- distance, it IS the body's orientation.
local function ballMatrix()
  local x, y, z = b3.body_position(ballBody)
  local qx, qy, qz, qw = b3.body_rotation(ballBody)
  local xx, yy, zz = qx * qx, qy * qy, qz * qz
  local xy, xz, yz = qx * qy, qx * qz, qy * qz
  local wx, wy, wz = qw * qx, qw * qy, qw * qz
  return dream.mat4({
    1 - 2 * (yy + zz), 2 * (xy - wz),     2 * (xz + wy),     x / U,
    2 * (xy + wz),     1 - 2 * (xx + zz), 2 * (yz - wx),     y / U,
    2 * (xz - wy),     2 * (yz + wx),     1 - 2 * (xx + yy), z / U,
    0,                 0,                 0,                 1,
  })
end

function love.draw()
  love.graphics.clear(0.46, 0.66, 0.88, 1)

  -- CAMERA. The course is 1500x1000px; at fov 52 an eye 1490px up frames
  -- its width with room for the rough. The eye sits in front of the green
  -- and aims at its middle, which leans the view just enough for the rails
  -- to show their side faces without skewing the course into a trapezoid.
  local cx, cy = 960, 540
  local eye = dream.vec3(cx / U, 1490 / U, (cy + 360) / U)
  local tgt = dream.vec3(cx / U, 0, cy / U)
  local cam = dream:newCamera(camWorld(eye, tgt))
  cam:setFov(52)
  setProjection(eye, tgt, 52)

  dream:prepare()
  -- LIGHTS GO HERE, NOT IN love.load: prepare() clears the light list every
  -- frame, so anything registered at load time is wiped before the first
  -- draw and the whole scene renders unlit.
  --
  -- NO LIGHTS ARE REGISTERED, deliberately.
  --
  -- This engine's 3D path has no runtime lighting -- render3d_gl.c says so
  -- outright ("no camera, no matrix stack, no lighting") and it is
  -- provable: forcing 3DreamEngine's fragment shader to output solid
  -- magenta changes nothing on screen, because its shader never binds
  -- here. Lights, emission factors and albedo textures are all inert.
  --
  -- So the light lives in the TEXTURES instead (art.lua bakes Neverputt's
  -- two-sun rig into one variant per face direction), and registering
  -- lights here would be decoration that costs a shadow pass. Worse, a
  -- "sun" light made dream:present() clear the frame to black and took the
  -- sky with it.
  course.draw()
  dream:draw(course.ballMesh(), ballMatrix())
  dream:present(cam)


  -- ── 2D overlays ─────────────────────────────────────────────────────
  love.graphics.setDepthMode()
  drawAim()
  fx.drawTrail(BALL_R)
  fx.draw()
  fx.drawPops(ui.font(theme.fontBig))
  drawHUD()
end
