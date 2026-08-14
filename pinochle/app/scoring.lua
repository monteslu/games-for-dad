-- pinochle/scoring.lua - the one scoring table, applied per team per hand.
--
-- Kept pure so the tests can assert every delta, the same contract
-- spades/scoring.lua has.
local M = {}

M.MIN_BID   = 250      -- and 250 is also the trick points in a hand, so a
                       -- minimum bid means "our meld had better carry us"
M.BID_STEP  = 10
M.GAME_TO   = 1500

-- t = { meld = n, tricks = n, bid = n or nil }
--   bid is set only on the DECLARING team.
--
-- MAKING IT: meld and tricks both score, normally.
--
-- GOING SET: the declaring side scores NOTHING for the hand -- they lose
-- their meld as well as their trick points -- and the full bid is
-- SUBTRACTED from their running total. Not the shortfall, not double: the
-- bid. Scores go negative and that is correct.
--
-- The defenders always score their meld and their tricks, made or set.
function M.scoreTeam(t)
  local r = { meld = t.meld or 0, tricks = t.tricks or 0,
              bid = t.bid, made = nil, delta = 0 }
  if t.bid then
    local got = r.meld + r.tricks
    if got >= t.bid then
      r.made = true
      r.delta = got
    else
      r.made = false
      r.delta = -t.bid
    end
  else
    r.delta = r.meld + r.tricks
  end
  return r
end

-- Who won, once a hand is scored. Both teams can cross 1500 in the same
-- hand -- the declaring side takes it, which is the standard tiebreak and
-- the only fair one: without it a team could be punished for a contract
-- it bid and made.
function M.winner(scores, declaringTeam)
  local a, b = scores[1] >= M.GAME_TO, scores[2] >= M.GAME_TO
  if not a and not b then return nil end
  if a and b then return declaringTeam end
  return a and 1 or 2
end

return M
