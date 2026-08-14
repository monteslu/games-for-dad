-- pinochle/bot.lua - the one CPU brain, used by all three seats and for
-- the human's suggested bid.
--
-- Rule-based on purpose, the same as spades/bot.lua: meld is known
-- exactly, trick-taking is estimated from counted winners, and play is a
-- short list of heuristics with void tracking as the only inference. A
-- search would play better and be far harder to reason about when it does
-- something odd -- and "why did my partner do that" is a real cost in a
-- game meant to be relaxing.
local rules = require("rules")
local meld  = require("meld")
local M = {}

local P = rules.power

local function bySuit(hand)
  local s = {S = {}, H = {}, C = {}, D = {}}
  for _, c in ipairs(hand) do
    local t = s[c.suit]
    t[#t + 1] = P[c.rank]
  end
  for _, t in pairs(s) do table.sort(t, function(a, b) return a > b end) end
  return s
end

-- ── BIDDING ───────────────────────────────────────────────────────────
--
-- A bid is a claim about MELD + TRICKS, and the two are estimated very
-- differently: meld is known exactly (you can see your own cards), while
-- tricks have to be guessed.
--
-- The trick estimate counts probable winners. In pinochle an ace is
-- nearly always good for a trick, a ten is good once the aces are gone,
-- and long trump is worth a lot because you can draw and then run the
-- suit. Each trick carries about 20 points of counters on average (250
-- over 12 tricks), so winners are converted at 20 and then discounted --
-- bidding what you hope for rather than what you expect is how a team
-- goes set.
function M.estimateTricks(hand, trump)
  local s = bySuit(hand)
  local est = 0
  local nTrump = #s[trump]

  for _, v in ipairs(s[trump]) do
    if v == P.A then est = est + 1
    elseif v == P.T then est = est + 0.8
    elseif v == P.K then est = est + 0.55
    elseif v == P.Q then est = est + 0.3 end
  end
  -- length beyond five draws the opponents out and the rest run
  if nTrump > 5 then est = est + (nTrump - 5) * 0.8 end

  for _, su in ipairs({"S", "H", "C", "D"}) do
    if su ~= trump then
      local t = s[su]
      for _, v in ipairs(t) do
        if v == P.A then est = est + 0.85
        elseif v == P.T then est = est + (#t >= 3 and 0.35 or 0.15) end
      end
      -- shortness is only worth something with trump to ruff with
      if nTrump >= 4 then
        if #t == 0 then est = est + 0.9
        elseif #t == 1 then est = est + 0.4 end
      end
    end
  end
  return est
end

-- ctx: { aggro = -0.25..0.25, highBid = the bid to beat or nil }
-- Returns bid (a multiple of BID_STEP) or nil to pass, plus the suit.
--
-- A BID IS A CLAIM ABOUT THE TEAM, NOT ABOUT YOUR OWN HAND. This is the
-- thing that makes pinochle bidding feel wrong if you get it backwards,
-- and it did: estimating only the bidder's cards made every seat pass,
-- because a median hand is worth about 115 on its own against a 250
-- minimum. 1904 of 2000 simulated hands passed out.
--
-- The partner is unseen but not unknown. They hold twelve of the
-- remaining thirty-six cards, so on average they carry a third of what is
-- left -- which works out to roughly a median hand's worth of meld and
-- about three trick-winners. That expectation is what the minimum bid is
-- built around, and it has to be in the estimate.
local PARTNER_MELD   = 45      -- median meld in an unseen hand
local PARTNER_TRICKS = 3.0     -- and their share of the winners

function M.suggestBid(hand, ctx)
  ctx = ctx or {}
  local suit, meldPts = meld.bestTrump(hand)
  local tricks = M.estimateTricks(hand, suit)

  -- What the TEAM should make: our meld plus theirs, and the counters
  -- our combined winners drag in. 20 points a trick (250 over 12), then
  -- discounted -- a hand rarely takes every trick it looks like it
  -- should, and being set costs the entire bid rather than the shortfall.
  local teamMeld   = meldPts + PARTNER_MELD
  local teamTricks = tricks + PARTNER_TRICKS
  local expect = teamMeld + teamTricks * 20 * 0.68
  expect = expect * (1 + (ctx.aggro or 0) * 0.10)

  local MIN = require("scoring").MIN_BID
  local bid = math.floor(expect / 10) * 10

  -- WILL WE BID AT ALL?
  --
  -- Measured over 600 played hands, a median declaring team scores about
  -- 228 -- against a 250 minimum. So most hands genuinely CANNOT make the
  -- minimum, and that is not a bug in the estimate (which predicts 232
  -- against an actual 228, within 2%): it is why the dealer-forced-bid
  -- rule exists in the real game.
  --
  -- A bidder therefore has to be a little optimistic to bid at all. The
  -- threshold is the CEILING -- what the hand makes when things go well --
  -- rather than the expectation, because someone who only bids on
  -- certainties never opens and the auction dies every hand.
  local ceiling = teamMeld + teamTricks * 20 * 1.05

  if ctx.highBid then
    local next_ = ctx.highBid + 10
    -- Climbing past what the hand can pay for is how a team goes set, and
    -- the set penalty is the WHOLE bid. Leave real margin.
    if next_ > ceiling then return nil, suit end
    bid = math.max(bid, next_)
  elseif bid < MIN then
    -- Opening at the minimum on a hand that cannot reach it is a gift to
    -- the other side, so only do it when the ceiling is genuinely close.
    if ceiling < MIN * 0.92 then return nil, suit end
    bid = MIN
  end
  if bid > ceiling then return nil, suit end

  return bid, suit
end

-- ── PLAY ──────────────────────────────────────────────────────────────
--
-- ctx: { trump, trick, seat, partnerSeat, voids, played, tricksLeft }
function M.choosePlay(hand, ctx)
  local legal = rules.legalPlays(hand, ctx.trick, ctx.trump)
  if #legal == 1 then return legal[1] end     -- forced, and often is

  local trick, trump = ctx.trick, ctx.trump
  local function counterOf(i) return rules.counter[hand[i].rank] end
  local function powerOf(i) return P[hand[i].rank] end

  -- LEADING
  if #trick == 0 then
    -- Pull trump while you still hold the top of it: in pinochle the
    -- danger is not losing a trick, it is losing a TEN, and drawing the
    -- opponents' trump is what protects them.
    local topTrump, nTrump = nil, 0
    for _, i in ipairs(legal) do
      if hand[i].suit == trump then
        nTrump = nTrump + 1
        if not topTrump or powerOf(i) > powerOf(topTrump) then topTrump = i end
      end
    end
    if topTrump and powerOf(topTrump) >= P.T and nTrump >= 4 and
       (ctx.tricksLeft or 12) > 4 then
      return topTrump
    end
    -- otherwise lead an off-suit ace: it banks its counters now, before
    -- anyone is void and can trump it
    local bestAce
    for _, i in ipairs(legal) do
      if hand[i].suit ~= trump and hand[i].rank == "A" then
        bestAce = bestAce or i
      end
    end
    if bestAce then return bestAce end
    -- nothing good: lead the cheapest thing that is not a counter
    local cheap = legal[1]
    for _, i in ipairs(legal) do
      if counterOf(i) < counterOf(cheap) or
         (counterOf(i) == counterOf(cheap) and powerOf(i) < powerOf(cheap)) then
        cheap = i
      end
    end
    return cheap
  end

  -- FOLLOWING
  local win = rules.winningPlay(trick, trump)
  local partnerWinning = (win.seat == ctx.partnerSeat)
  local isLast = (#trick == 3)

  -- Partner has it and we are last to play: throw counters on, they are
  -- ours. This is the single biggest source of points a simple bot can
  -- collect, and it is the play a human notices and appreciates.
  if partnerWinning and isLast then
    local best = legal[1]
    for _, i in ipairs(legal) do
      if counterOf(i) > counterOf(best) then best = i end
    end
    return best
  end

  -- Can we take it? Take it if it is worth taking.
  local takers = {}
  for _, i in ipairs(legal) do
    local c = hand[i]
    local beats
    if c.suit == win.card.suit then beats = P[c.rank] > P[win.card.rank]
    elseif c.suit == trump then beats = (win.card.suit ~= trump)
    else beats = false end
    if beats then takers[#takers + 1] = i end
  end
  if #takers > 0 then
    local pot = 0
    for _, p in ipairs(trick) do pot = pot + rules.counter[p.card.rank] end
    -- last to play with counters on the table, or a fat trick: take it
    -- with the CHEAPEST card that wins, never the dearest
    if isLast or pot >= 20 or not partnerWinning then
      local cheapest = takers[1]
      for _, i in ipairs(takers) do
        if powerOf(i) < powerOf(cheapest) then cheapest = i end
      end
      return cheapest
    end
  end

  -- Cannot or should not win: throw the least valuable card. Counters
  -- first, then power -- a ten given away is ten points to the other side.
  local worst = legal[1]
  for _, i in ipairs(legal) do
    if counterOf(i) < counterOf(worst) or
       (counterOf(i) == counterOf(worst) and powerOf(i) < powerOf(worst)) then
      worst = i
    end
  end
  return worst
end

return M
