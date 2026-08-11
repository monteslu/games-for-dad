-- spades/bot.lua - the one CPU brain, used by all three seats (and for
-- the human's suggested bid). Rule-based on purpose: counted winners
-- for the bid, cheap-win / duck / cover-partner heuristics for play,
-- with void tracking as the only inference. See docs/SPADES.md.
local cards = require("lib.cards")
local rules = require("rules")
local M = {}
local V = cards.val

local SIDE = {"H", "C", "D"}

local function bySuit(hand)
  local s = {S = {}, H = {}, C = {}, D = {}}
  for _, c in ipairs(hand) do
    local t = s[c.suit]
    t[#t + 1] = V[c.rank]
  end
  for _, t in pairs(s) do table.sort(t, function(a, b) return a > b end) end
  return s
end

-- A hand worth bidding nil on: no ace or king anywhere, short low
-- spades, at most one queen to get caught with.
local function nilWorthy(s)
  if #s.S > 3 then return false end
  for _, v in ipairs(s.S) do if v > 10 then return false end end
  local queens = 0
  for _, su in ipairs(SIDE) do
    for _, v in ipairs(s[su]) do
      if v >= 13 then return false end
      if v == 12 then queens = queens + 1 end
    end
  end
  return queens <= 1
end

-- ctx: { bids = {[seat]=bid so far}, partnerSeat, aggro }
function M.suggestBid(hand, ctx)
  ctx = ctx or {}
  local s = bySuit(hand)
  local est = 0
  for _, v in ipairs(s.S) do
    if v == 14 then est = est + 1
    elseif v == 13 then est = est + (#s.S >= 2 and 0.9 or 0.5)
    elseif v == 12 then est = est + (#s.S >= 3 and 0.6 or 0.3) end
  end
  if #s.S > 3 then est = est + (#s.S - 3) * 0.7 end   -- length books
  for _, su in ipairs(SIDE) do
    local t = s[su]
    for _, v in ipairs(t) do
      if v == 14 then est = est + 1
      elseif v == 13 then est = est + (#t >= 2 and 0.65 or 0.4)
      elseif v == 12 then est = est + (#t >= 3 and 0.25 or 0.1) end
    end
    -- shortness ruffs only count with trumps to ruff with
    if #s.S >= 3 then
      if #t == 0 then est = est + 1
      elseif #t == 1 then est = est + 0.5 end
    end
  end
  est = est + (ctx.aggro or 0)
  local b = math.floor(est + 0.5)

  local partnerNil = false
  local sum = b
  if ctx.bids then
    for seat, ob in pairs(ctx.bids) do
      sum = sum + ob
      if seat == ctx.partnerSeat and ob == 0 then partnerNil = true end
    end
  end
  if not partnerNil and nilWorthy(s) then return 0 end
  if sum > 11 and b > 1 then b = b - 1 end   -- somebody's wrong; assume us
  if partnerNil then b = b + 1 end           -- covering a nil costs books
  if b < 1 then b = 1 end
  if b > 7 then b = 7 end
  return b
end

-- ── play ──────────────────────────────────────────────────────────────
-- ctx: { seat, trick, spadesBroken, needMore, myNilActive,
--        partnerSeat, partnerNilActive, oppNilSeat,
--        voids = {[seat] = {[suit]=true}}, playedSuit = {[suit]={[v]=true}} }
-- Returns an index into `hand`.

-- weight: low non-spades are the cheapest cards to spend; spades cost extra
local function spend(c) return V[c.rank] + (c.suit == "S" and 100 or 0) end

function M.choose(hand, ctx)
  local legal = rules.legalPlays(hand, ctx.trick, ctx.spadesBroken)
  local trick = ctx.trick
  local w = rules.winningPlay(trick)

  local function beats(c)
    if not w then return true end
    local wc = w.card
    if c.suit == "S" then
      if wc.suit == "S" then return V[c.rank] > V[wc.rank] end
      return true
    end
    if wc.suit == "S" then return false end
    if c.suit ~= wc.suit then return false end
    return V[c.rank] > V[wc.rank]
  end

  -- pick the legal card minimizing (or maximizing) a key, with a filter
  local function pick(filter, key, high)
    local bi, bk
    for _, i in ipairs(legal) do
      local c = hand[i]
      if not filter or filter(c) then
        local k = key(c)
        if bi == nil or (high and k > bk) or (not high and k < bk) then
          bi, bk = i, k
        end
      end
    end
    return bi
  end
  local function cheapest(filter) return pick(filter, spend, false) end
  local function dearest(filter) return pick(filter, spend, true) end

  -- has any opponent shown void in this suit? (they would trump a lead)
  local function oppVoid(suit)
    for seat, vs in pairs(ctx.voids or {}) do
      if seat ~= ctx.seat and seat ~= ctx.partnerSeat and vs[suit] then
        return true
      end
    end
    return false
  end

  -- is v the highest card of `suit` still out there (not played, not mine)?
  local function isBoss(suit, v)
    local played = (ctx.playedSuit or {})[suit] or {}
    local mine = {}
    for _, c in ipairs(hand) do
      if c.suit == suit then mine[V[c.rank]] = true end
    end
    for hv = 14, v + 1, -1 do
      if not played[hv] and not mine[hv] then return false end
    end
    return true
  end

  -- ── nil bidder protecting the nil: lose this trick at all costs ──
  if ctx.myNilActive then
    if #trick == 0 then return cheapest() end
    local under = pick(function(c) return not beats(c) end,
                       function(c) return V[c.rank] end, true)
    if under then return under end
    return cheapest()   -- forced to win something; spend the least
  end

  -- ── an opposing nil bidder is winning the trick: leave them in it ──
  if w and ctx.oppNilSeat and w.seat == ctx.oppNilSeat then
    local under = pick(function(c) return not beats(c) end,
                       function(c) return V[c.rank] end, true)
    if under then return under end
  end

  if #trick == 0 then
    -- ── leading ──
    if ctx.partnerNilActive then
      -- cover partner: put our biggest card out front
      return pick(nil, function(c) return V[c.rank] end, true)
    end
    if not ctx.needMore then
      -- bid is safe: lead junk, steer clear of suits opponents ruff
      return cheapest(function(c) return not oppVoid(c.suit) end) or cheapest()
    end
    -- cash a boss side card if the lead is safe from ruffs
    for _, i in ipairs(legal) do
      local c = hand[i]
      if c.suit ~= "S" and isBoss(c.suit, V[c.rank]) and not oppVoid(c.suit) then
        return i
      end
    end
    -- lead the boss spade - only reachable when spades are all we have
    -- (the house rule bars spade leads while another suit remains)
    if ctx.spadesBroken then
      for _, i in ipairs(legal) do
        local c = hand[i]
        if c.suit == "S" and isBoss("S", V[c.rank]) then return i end
      end
    end
    return cheapest(function(c) return not oppVoid(c.suit) end) or cheapest()
  end

  -- ── following ──
  if w.seat == ctx.partnerSeat then
    -- partner has it: stay out of the way, spend the least
    if not ctx.needMore then
      -- shedding future winners is how a made team dodges bags
      return dearest(function(c) return c.suit ~= "S" and not beats(c) end)
          or cheapest()
    end
    return cheapest()
  end
  if ctx.needMore then
    local cw = cheapest(beats)
    if cw then return cw end
  end
  if not ctx.needMore then
    local shed = dearest(function(c) return c.suit ~= "S" and not beats(c) end)
    if shed then return shed end
  end
  return cheapest()
end

return M
