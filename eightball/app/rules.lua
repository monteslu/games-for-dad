-- rules.lua - 8-ball, WPA rules as far as they serve the player.
--
-- Deliberate departures from the tournament rule book, each for the same
-- reason (docs/DESIGN.md: one 85-year-old, a d-pad, and a TV across the
-- room):
--
--   CALLED POCKETS ARE NOT REQUIRED. WPA calls every shot, naming ball AND
--   pocket. That is a second selection step before every single shot, and
--   getting it wrong hands the table over for a reason the player did not
--   see coming. Consumer pool games drop it almost universally; so does
--   this. Any legal pocketing counts.
--
--   NO "BEHIND THE HEAD STRING" RESTRICTION after a break scratch. It is a
--   real rule and a real trap: the player places the cue ball, is told
--   "not there", and has learned nothing about pool. Ball in hand is ball
--   in hand here.
--
--   THE BREAK CANNOT LOSE. Pocketing the 8 on the break is a re-rack, never
--   a loss.
--
--   SLOP COUNTS AND ALMOST NOTHING IS A FOUL. The only foul is a scratch,
--   because that is the only one a player can see and understand: the white
--   went in the hole. Hitting the wrong group first, failing to reach a
--   rail, missing everything -- the rule book hands the table over for all
--   of them, and each is a punishment for something invisible. Losing your
--   turn is enough. Pot a ball you never aimed at and it is yours.
--
-- What IS still real: groups are assigned on the first ball pocketed, the
-- table is open until then, you must clear your group before the 8, and
-- putting the 8 down early (or scratching on it) loses the game.

local M = {}

M.SOLIDS, M.STRIPES = "solids", "stripes"

function M.groupOf(n)
  if n == 8 then return "eight" end
  if n >= 1 and n <= 7 then return M.SOLIDS end
  if n >= 9 and n <= 15 then return M.STRIPES end
  return nil                      -- 0 = cue ball
end

-- Which balls of a group are still on the table?
function M.remaining(balls, group)
  local n = 0
  for _, b in ipairs(balls) do
    if not b.pocketed and M.groupOf(b.num) == group then n = n + 1 end
  end
  return n
end

-- A player may shoot at the 8 only once their whole group is gone.
function M.onEight(balls, group)
  return group ~= nil and M.remaining(balls, group) == 0
end

-- The legal target group for a player right now. nil = open table.
function M.targetGroup(state, seat)
  local g = state.groups[seat]
  if not g then return nil end
  if M.onEight(state.balls, g) then return "eight" end
  return g
end

-- Is `num` a legal FIRST contact for this player?
function M.legalFirstContact(state, seat, num)
  if num == 0 or num == nil then return false end
  local target = M.targetGroup(state, seat)
  if target == nil then
    -- open table: anything but the 8
    return num ~= 8
  end
  if target == "eight" then return num == 8 end
  return M.groupOf(num) == target
end

--[[
Judge a completed shot. `shot` describes what physically happened:

  shot.firstHit     number  first object ball the cue ball touched (nil = none)
  shot.pocketed     list    ball numbers that fell, in order
  shot.cueScratched bool    cue ball fell in a pocket
  shot.railAfter    bool    any ball hit a cushion after first contact
  shot.isBreak      bool    this was the opening break
  shot.offTable     list    balls that left the table entirely

Returns a table:
  foul       bool     the shot was illegal
  reason     string   why, for the on-screen message
  lose       bool     this player has lost the game outright
  win        bool     this player has won
  continue   bool     the shooter keeps the table
  assigned   string   a group just became this player's (or nil)
  rerack     bool     the rack must be redone (8 on the break)
]]
function M.judge(state, seat, shot)
  local r = {
    foul = false, reason = nil, lose = false, win = false,
    continue = false, assigned = nil, rerack = false,
  }

  local group = state.groups[seat]
  local shootingEight = M.onEight(state.balls, group)

  local pocketedEight = false
  local pocketedOwn, pocketedOther = 0, 0
  for _, n in ipairs(shot.pocketed) do
    if n == 8 then
      pocketedEight = true
    elseif group and M.groupOf(n) == group then
      pocketedOwn = pocketedOwn + 1
    elseif group then
      pocketedOther = pocketedOther + 1
    end
  end

  -- ── the 8 ball settles everything else ───────────────────────────
  if pocketedEight then
    if shot.isBreak then
      -- house rule: the break can never lose. Re-rack and go again.
      r.rerack = true
      r.reason = "8 ON THE BREAK - RE-RACK"
      return r
    end
    if not shootingEight then
      r.lose = true
      r.reason = "THE 8 WENT DOWN TOO EARLY"
      return r
    end
    if shot.cueScratched then
      r.lose = true
      r.reason = "SCRATCH ON THE 8"
      return r
    end
    -- Sinking the 8 when it was your last ball WINS, however it got there.
    -- The rule book wants the 8 struck first and the pocket called; both
    -- would turn a won game into a loss for a reason the player cannot see.
    r.win = true
    r.reason = "8 BALL - GAME"
    return r
  end

  for _, n in ipairs(shot.offTable or {}) do
    if n == 8 then
      r.lose = true
      r.reason = "THE 8 LEFT THE TABLE"
      return r
    end
  end

  -- ── fouls: ONE of them ───────────────────────────────────────────
  --
  -- Only a SCRATCH costs anything. The rule book also fouls you for hitting
  -- the wrong group first, for failing to drive a ball to a rail, and for
  -- not striking anything at all -- and every one of those hands the table
  -- over for a reason this player did not see coming, which docs/DESIGN.md
  -- rules out. Losing your turn is punishment enough for a bad shot.
  --
  -- SLOP COUNTS. Pot a ball you never meant to and it is yours. Aiming at
  -- one ball and sinking another is the most satisfying thing that happens
  -- to a casual player, and calling it a foul is how you make someone stop
  -- playing.
  if shot.cueScratched then
    r.foul = true
    r.reason = "SCRATCH"
  end

  -- ── group assignment: the first legally pocketed ball claims it ───
  if not r.foul and group == nil and #shot.pocketed > 0 then
    for _, n in ipairs(shot.pocketed) do
      local g = M.groupOf(n)
      if g == M.SOLIDS or g == M.STRIPES then
        r.assigned = g
        pocketedOwn = 0
        for _, m in ipairs(shot.pocketed) do
          if M.groupOf(m) == g then pocketedOwn = pocketedOwn + 1 end
        end
        break
      end
    end
  end

  -- ── does the shooter keep the table? ─────────────────────────────
  if r.foul then
    r.continue = false
  elseif shot.isBreak then
    -- the breaker continues if anything at all went down
    r.continue = #shot.pocketed > 0
  elseif r.assigned then
    r.continue = true
  elseif group and pocketedOwn > 0 then
    r.continue = true
  else
    r.continue = false
  end

  return r
end

return M
