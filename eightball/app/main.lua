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
-- Straight down, not tilted. A tilt makes the far rail shorter than the near
-- one, and on a 2:1 table that reads as a skewed trapezoid rather than as
-- depth -- which is actively misleading when the player is judging an angle.
-- The balls still read as spheres because they are lit and shaded.
local CAM_H, CAM_TILT, CAM_FOV = 11.6, 0.001, 60

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
local mesh_ball, mesh_cloth, mesh_rail
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
-- Max pull is the table's half-height: a full-power drag reaches from the
-- cue ball to the top or bottom rail, so the gesture never runs out of
-- screen no matter how big the table is drawn.
local PULL_MIN, PULL_MAX = 0, tbl.H
-- The stick fades cream -> red across that range (monteslu's 2012 colours).
local STICK_NEAR = { 254 / 255, 232 / 255, 214 / 255 }
local STICK_FAR  = { 1, 0, 0 }
local shot = nil          -- what happened during the current roll
local rollFrames = 0
local cpuThink = 0
local placeX, placeZ = 0, 0

local SHOT_IMPULSE = 5.6  -- tuned so full power breaks a rack convincingly

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
  local s = b3.shape_sphere(b, tbl.BALL_R, 1.7)
  local M = tbl.MAT.ball
  b3.shape_set_material(s, M.friction, M.restitution, M.rolling)
  b3.body_set_linear_damping(b, 0.52)
  b3.body_set_angular_damping(b, 0.9)
  b3.body_set_bullet(b, true)            -- a hard shot can cross a cushion
  b3.shape_enable_hit_events(s, true)
  b3.body_set_sleep_threshold(b, 7)
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
  cue = addBall(0, tbl.W * 0.52, 0)
  local order = ballart.rackOrder(function(n) return love.math.random(n) end)
  local pos = ballart.rackPositions(-tbl.W * 0.34, 0, tbl.BALL_R, -1)
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
  aimAngle = math.pi
  pull = 0
  if padUsed then startPlayerAim() end
end

function love.load()
  dream.canvases:setMode("direct")   -- no deferred g-buffer; see the spike notes
  dream:init()

  world = b3.world_new(0, -980, 0)
  b3.world_set_hit_threshold(world, 55)
  table3d = tbl.build(world)

  sounds.loadAll()
  faces = ballart.makeFaces()

  -- Emission carries the colour: the textured mesh format's albedo sampler
  -- is not wired up in this engine, so an albedo-only material renders
  -- black no matter how many lights are in the scene. Emission also gives
  -- the flat, even, glare-free look a top-down aiming game wants.
  mat_cloth = dream:newMaterial("cloth")
  mat_cloth:setColor(theme.felt[1], theme.felt[2], theme.felt[3], 1)
  mat_cloth:setEmission(theme.felt[1], theme.felt[2], theme.felt[3])
  mat_cloth:setRoughness(0.95)
  mat_cloth:setMetallic(0)

  mat_rail = dream:newMaterial("rail")
  mat_rail:setColor(0.32, 0.17, 0.08, 1)
  mat_rail:setEmission(0.26, 0.14, 0.07)
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
  mesh_rail  = buildBox(mat_rail, 1, 1, 1)
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
  local imp = SHOT_IMPULSE * (0.22 + pow * 0.78)
  b3.body_set_awake(cue.body, true)
  b3.body_apply_impulse(cue.body,
    math.cos(angle) * imp * 1000, 0, math.sin(angle) * imp * 1000)
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
    b3.world_step(world, 1 / 60, 6)
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
    if confirmPressed() or click then rack() end
    return
  end

  if state.phase == "placing" then
    local sp = 7
    if heldLeft()  then placeX = placeX - sp end
    if heldRight() then placeX = placeX + sp end
    if not AUTO and love.pad.isDown("up")   then placeZ = placeZ - sp end
    if not AUTO and love.pad.isDown("down") then placeZ = placeZ + sp end
    if click then
      -- tap anywhere on the cloth to drop the ball there
      for wx = -tbl.W, tbl.W, 10 do
        for wz = -tbl.H, tbl.H, 10 do end
      end
    end
    placeX = math.max(-tbl.W + tbl.BALL_R, math.min(tbl.W - tbl.BALL_R, placeX))
    placeZ = math.max(-tbl.H + tbl.BALL_R, math.min(tbl.H - tbl.BALL_R, placeZ))
    if confirmPressed() or inRect(click, PLACE_BTN) then
      placeCueAt(placeX, placeZ)
      state.ballInHand = false
      state.phase = "aim"
      state.message = ""
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
    local step = 0.014
    if heldLeft()  then aimAngle = aimAngle - step end
    if heldRight() then aimAngle = aimAngle + step end
    if edges.left  then aimAngle = aimAngle - step end
    if edges.right then aimAngle = aimAngle + step end

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
    if clickHeld then
      local sx, sy = worldToScreen(cue.x, cue.z)
      local rx = worldToScreen(cue.x + 100, cue.z)   -- 100px of table...
      if sx and rx then
        local pxPerTablePx = math.abs(rx - sx) / 100  -- ...is this many screen px
        local dx, dy = clickHeld.x - sx, clickHeld.y - sy
        local d = math.sqrt(dx * dx + dy * dy)
        if d > 20 then
          -- the cue sits BEHIND the ball, so the shot goes opposite the drag
          aimAngle = math.atan(-dy, -dx)
          pull = math.min(PULL_MAX, d / math.max(pxPerTablePx, 0.0001))
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

  dream:draw(mesh_cloth, 0, 0, 0)
  for _, b in ipairs(balls) do
    if not b.pocketed then
      local x, y, z = b3.body_position(b.body)
      dream:draw(mesh_ball[b.num], x / U, y / U, z / U)
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
    local ex, ey = worldToScreen(cue.x + math.cos(aimAngle) * 700,
                                 cue.z + math.sin(aimAngle) * 700)
    if sx and ex then
      g.setColor(1, 1, 1, 0.32)
      g.setLineWidth(3)
      g.line(sx, sy, ex, ey)
      g.circle("line", ex, ey, 15)
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
        g.setColor(r, gg, bb)
        g.setLineWidth(13)
        g.line(bx, by, tx, ty)
        g.setLineWidth(1)
      end
    end
    g.setLineWidth(1)
  end

  -- pocketed balls, per side
  local function groupRow(seat, y, label)
    g.setFont(ui.font(theme.fontSmall))
    g.setColor(theme.quiet)
    g.print(label, 60, y - 34)
    local grp = state.groups[seat]
    local n = 0
    for _, b in ipairs(balls) do
      if b.pocketed and b.num ~= 0 and b.num ~= 8
         and grp and rules.groupOf(b.num) == grp then
        local c = ballart.COLORS[b.num]
        g.setColor(c[1], c[2], c[3])
        g.circle("fill", 70 + n * 46, y, 17)
        if ballart.isStripe(b.num) then
          g.setColor(0.95, 0.95, 0.9)
          g.rectangle("fill", 70 + n * 46 - 17, y - 5, 34, 10)
        end
        n = n + 1
      end
    end
    if grp then
      g.setFont(ui.font(theme.fontSmall))
      g.setColor(theme.quiet)
      g.print(string.upper(grp), 60, y + 26)
    end
  end
  groupRow(PLAYER, 120, "YOU")
  groupRow(CPU, 260, "CPU")

  -- whose turn
  g.setFont(ui.font(theme.fontBig))
  if state.turn == PLAYER then
    g.setColor(theme.gold)
    g.print("YOUR SHOT", W - 460, 60)
  else
    g.setColor(theme.quiet)
    g.print("CPU SHOOTING", W - 520, 60)
  end

  -- the message line: wins loud, losses quiet (docs/DESIGN.md)
  if state.message and state.message ~= "" then
    local col = theme.white
    if state.messageMood == "win" then col = theme.win
    elseif state.messageMood == "loss" then col = theme.lossRed end
    ui.banner(state.message, H - 210, col,
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
