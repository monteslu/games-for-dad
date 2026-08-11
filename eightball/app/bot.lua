-- bot.lua - the CPU opponent. A beatable club player.
--
-- It picks a real shot the way a person does (find a ball of my group with a
-- clear line to a pocket, hit the ghost-ball point) and then MISSES like a
-- person: a small random error on the aim angle, scaled by how hard the shot
-- is. That is the whole difficulty model.
--
-- Why not a perfect aimer with a random miss chance bolted on: a bot that is
-- either perfect or wildly wrong reads as cheating in both directions. Error
-- proportional to difficulty means it sinks the easy ones, sometimes misses
-- the long thin cut, and leaves the table in a plausible state either way.

local tbl = require("table3d")

local M = {}

-- Aim error in radians, before difficulty scaling. Tuned by playing it:
-- big enough that it misses a few a rack, small enough that it punishes a
-- player who leaves an easy table.
M.SKILL = 0.045

local function dist(ax, az, bx, bz)
  local dx, dz = bx - ax, bz - az
  return math.sqrt(dx * dx + dz * dz)
end

-- Is the straight line from (ax,az) to (bx,bz) clear of every other ball?
local function pathClear(balls, ax, az, bx, bz, ignoreA, ignoreB, r)
  local dx, dz = bx - ax, bz - az
  local len = math.sqrt(dx * dx + dz * dz)
  if len < 1e-6 then return true end
  local ux, uz = dx / len, dz / len
  for _, b in ipairs(balls) do
    if not b.pocketed and b ~= ignoreA and b ~= ignoreB then
      -- project the ball's centre onto the line
      local px, pz = b.x - ax, b.z - az
      local t = px * ux + pz * uz
      if t > 0 and t < len then
        local cx, cz = ax + ux * t, az + uz * t
        if dist(cx, cz, b.x, b.z) < r * 2.02 then return false end
      end
    end
  end
  return true
end

--[[
Choose a shot.

  state.balls    list of { num, x, z, pocketed }
  state.cue      { x, z }
  target         "solids" | "stripes" | "eight" | nil (open table)

Returns { angle = radians, power = 0..1, target = ballNum } or nil when no
legal shot has a clear line, in which case the caller should just nudge
toward the nearest legal ball rather than pass (there is no "pass" in pool).
]]
function M.chooseShot(state, target, rng)
  local r = tbl.BALL_R
  local cue = state.cue
  local best = nil

  for _, b in ipairs(state.balls) do
    if not b.pocketed and b.num ~= 0 then
      local grp = (b.num == 8) and "eight"
                  or (b.num <= 7 and "solids" or "stripes")
      local legal = (target == nil and b.num ~= 8) or (grp == target)
      if legal then
        for _, p in ipairs(tbl.pockets()) do
          -- the ghost ball: where the cue must be at contact to send this
          -- ball at the pocket
          local pdx, pdz = p.x - b.x, p.z - b.z
          local plen = math.sqrt(pdx * pdx + pdz * pdz)
          if plen > 1e-6 then
            local gx = b.x - (pdx / plen) * r * 2
            local gz = b.z - (pdz / plen) * r * 2

            local cueToGhost = dist(cue.x, cue.z, gx, gz)
            if cueToGhost > r then
              -- cut angle: straight-on is easy, thin is hard
              local ax, az = (gx - cue.x) / cueToGhost, (gz - cue.z) / cueToGhost
              local cutDot = ax * (pdx / plen) + az * (pdz / plen)
              if cutDot > 0.15                                  -- not a backwards cut
                 and pathClear(state.balls, cue.x, cue.z, gx, gz, b, nil, r)
                 and pathClear(state.balls, b.x, b.z, p.x, p.z, b, nil, r) then
                -- lower score is better
                local score = (cueToGhost + plen) / 400 + (1 - cutDot) * 3
                if not best or score < best.score then
                  best = {
                    score = score, ball = b, pocket = p,
                    angle = math.atan(az, ax),
                    cut = cutDot,
                    length = cueToGhost + plen,
                  }
                end
              end
            end
          end
        end
      end
    end
  end

  if not best then return nil end

  -- Miss like a person: error grows with how thin the cut is and how far the
  -- whole shot travels.
  local hardness = (1 - best.cut) * 1.6 + best.length / 1600
  local err = (rng() * 2 - 1) * M.SKILL * (0.5 + hardness)

  -- Power: enough to reach, more for a long shot, never a wild smash.
  local power = math.min(0.92, 0.34 + best.length / 1700)

  return {
    angle = best.angle + err,
    power = power,
    target = best.ball.num,
  }
end

-- Nothing makeable: roll gently at the nearest legal ball so the shot is
-- still legal (first contact on your own group) and the table stays alive.
function M.safetyShot(state, target, rng)
  local cue = state.cue
  local bestB, bestD
  for _, b in ipairs(state.balls) do
    if not b.pocketed and b.num ~= 0 then
      local grp = (b.num == 8) and "eight"
                  or (b.num <= 7 and "solids" or "stripes")
      if (target == nil and b.num ~= 8) or grp == target then
        local d = dist(cue.x, cue.z, b.x, b.z)
        if not bestD or d < bestD then bestD, bestB = d, b end
      end
    end
  end
  if not bestB then return nil end
  local a = math.atan(bestB.z - cue.z, bestB.x - cue.x)
  return {
    angle = a + (rng() * 2 - 1) * 0.03,
    power = 0.42,
    target = bestB.num,
  }
end

-- Ball in hand: put the cue somewhere with a clear look at a legal ball,
-- rather than dropping it on the spot and immediately snookering itself.
function M.placeCue(state, target)
  local r = tbl.BALL_R
  local candidates = {}
  for _, b in ipairs(state.balls) do
    if not b.pocketed and b.num ~= 0 then
      local grp = (b.num == 8) and "eight"
                  or (b.num <= 7 and "solids" or "stripes")
      if (target == nil and b.num ~= 8) or grp == target then
        candidates[#candidates + 1] = b
      end
    end
  end
  if #candidates == 0 then return { x = -tbl.W * 0.5, z = 0 } end

  -- try a few spots along the head string and keep the one with the best
  -- clear line to any candidate
  local best, bestScore
  for _, sx in ipairs({ -tbl.W * 0.55, -tbl.W * 0.2, 0, tbl.W * 0.2 }) do
    for _, sz in ipairs({ -tbl.H * 0.5, 0, tbl.H * 0.5 }) do
      if tbl.onTable(sx, sz) then
        local score = 0
        for _, b in ipairs(candidates) do
          if pathClear(state.balls, sx, sz, b.x, b.z, b, nil, r) then
            score = score + 1 / (1 + dist(sx, sz, b.x, b.z) / 300)
          end
        end
        if not bestScore or score > bestScore then
          bestScore, best = score, { x = sx, z = sz }
        end
      end
    end
  end
  return best or { x = -tbl.W * 0.5, z = 0 }
end

return M
