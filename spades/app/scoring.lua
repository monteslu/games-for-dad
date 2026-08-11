-- spades/scoring.lua - the one scoring table, applied per team per hand.
-- Standard partnership scoring: 10x the team bid made, +1 per bag, -10x
-- set; nil is +/-100 scored on the bidder alone, a failed nil's books
-- count as bags but never toward the partner's bid; ten accumulated
-- bags cost 100. Kept pure so the harness can assert every delta.
local M = {}

M.NIL_VALUE = 100
M.BAG_LIMIT = 10
M.BAG_PENALTY = 100
M.GAME_TO = 500

-- t = { members = {seatA, seatB}, bids = {[seat]=n}, books = {[seat]=n} }
-- bagsBefore = the team's carried bag count.
-- Returns a result table; `delta` is the hand's full score change.
function M.scoreTeam(t, bagsBefore)
  local r = { delta = 0, teamBid = 0, toward = 0, bagAdd = 0,
              made = nil, penalty = false, nils = {} }
  for _, seat in ipairs(t.members) do
    local bid, took = t.bids[seat], t.books[seat]
    if bid == 0 then
      local ok = (took == 0)
      r.nils[seat] = ok
      r.delta = r.delta + (ok and M.NIL_VALUE or -M.NIL_VALUE)
      if not ok then r.bagAdd = r.bagAdd + took end
    else
      r.teamBid = r.teamBid + bid
      r.toward = r.toward + took
    end
  end
  if r.teamBid > 0 then
    if r.toward >= r.teamBid then
      r.made = true
      r.delta = r.delta + r.teamBid * 10 + (r.toward - r.teamBid)
      r.bagAdd = r.bagAdd + (r.toward - r.teamBid)
    else
      r.made = false
      r.delta = r.delta - r.teamBid * 10
    end
  end
  r.bags = bagsBefore + r.bagAdd
  while r.bags >= M.BAG_LIMIT do
    r.bags = r.bags - M.BAG_LIMIT
    r.delta = r.delta - M.BAG_PENALTY
    r.penalty = true
  end
  return r
end

return M
