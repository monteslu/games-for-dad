-- pinochle/meld.lua - what a hand is worth before a card is played.
--
-- Pure logic. Give it a hand and a trump suit, get back a list of named
-- melds and a total, which is what the UI shows and what scoring adds.
--
-- ── THE ONE RULE THAT MATTERS ─────────────────────────────────────────
--
-- A card may be used in ONE MELD OF EACH CLASS, but never twice within
-- the same class. There are three classes:
--
--   A  runs, marriages, the dix        (suit-shaped melds)
--   B  pinochle                        (Q-spades + J-diamonds)
--   C  arounds                         (one of a rank in all four suits)
--
-- This is the single most-botched rule in pinochle implementations, and
-- it fails in both directions:
--
--   * paying 190 for a bare trump run -- wrong, because the run and the
--     royal marriage are BOTH class A, so the run absorbs its own K-Q
--   * refusing to pay both a marriage and a pinochle on the same Q-spades
--     -- wrong, because those are different classes
--
-- Modelling it as three independent passes, each consuming cards from its
-- own copy of the hand, makes both cases fall out correctly without a
-- special case for either.
local M = {}

local RUN_RANKS = {"A", "T", "K", "Q", "J"}

M.VALUES = {
  run            = 150,
  doubleRun      = 1500,
  royalMarriage  = 40,
  marriage       = 20,
  dix            = 10,
  pinochle       = 40,
  doublePinochle = 300,
  acesAround     = 100,  doubleAces   = 1000,
  kingsAround    = 80,   doubleKings  = 800,
  queensAround   = 60,   doubleQueens = 600,
  jacksAround    = 40,   doubleJacks  = 400,
}

local SUIT_NAME = {S = "SPADES", H = "HEARTS", C = "CLUBS", D = "DIAMONDS"}

-- Count each rank+suit in the hand: how many copies (0, 1 or 2).
local function census(hand)
  local n = {}
  for _, c in ipairs(hand) do
    n[c.rank .. c.suit] = (n[c.rank .. c.suit] or 0) + 1
  end
  return n
end

-- ── CLASS A: runs, marriages, the dix ─────────────────────────────────
--
-- Scored in that order, each consuming what it uses, so a K-Q already
-- inside a run cannot be sold a second time as a marriage. Any DUPLICATE
-- K-Q left over is a real, separate marriage -- which is exactly how the
-- classic 190 (run + an extra royal marriage) arises, without being a
-- named special case at all.
--
-- The 230 the tables also list is NOT reachable in a single suit, whatever
-- they say: it would need two spare K-Q pairs sitting on top of a run, and
-- only two copies of each card exist. Verified by enumeration -- a full
-- twelve-card spade holding tops out at 1520 (double run + both dixes).
local function classA(n, trump, out)
  local total = 0
  local left = {}
  for k, v in pairs(n) do left[k] = v end

  -- the run, and the double run
  local minCopies = 2
  for _, r in ipairs(RUN_RANKS) do
    minCopies = math.min(minCopies, left[r .. trump] or 0)
  end
  if minCopies >= 2 then
    total = total + M.VALUES.doubleRun
    out[#out + 1] = { name = "DOUBLE RUN", pts = M.VALUES.doubleRun }
    for _, r in ipairs(RUN_RANKS) do left[r .. trump] = left[r .. trump] - 2 end
  elseif minCopies == 1 then
    total = total + M.VALUES.run
    out[#out + 1] = { name = "RUN IN " .. SUIT_NAME[trump], pts = M.VALUES.run }
    for _, r in ipairs(RUN_RANKS) do left[r .. trump] = left[r .. trump] - 1 end
  end

  -- marriages from whatever K and Q survive, in every suit
  for _, s in ipairs({"S", "H", "C", "D"}) do
    local pairs_ = math.min(left["K" .. s] or 0, left["Q" .. s] or 0)
    for _ = 1, pairs_ do
      local royal = (s == trump)
      local v = royal and M.VALUES.royalMarriage or M.VALUES.marriage
      total = total + v
      out[#out + 1] = {
        name = (royal and "ROYAL MARRIAGE" or ("MARRIAGE IN " .. SUIT_NAME[s])),
        pts = v }
      left["K" .. s] = left["K" .. s] - 1
      left["Q" .. s] = left["Q" .. s] - 1
    end
  end

  -- the dix: the nine of trump, each one worth 10
  local dixes = left["9" .. trump] or 0
  for _ = 1, dixes do
    total = total + M.VALUES.dix
    out[#out + 1] = { name = "DIX", pts = M.VALUES.dix }
  end

  return total
end

-- ── CLASS B: pinochle ─────────────────────────────────────────────────
-- The queen of spades and the jack of diamonds. Both pairs is not 80, it
-- is 300 -- the arounds and pinochle both use a jackpot value for the
-- double rather than simply doubling.
local function classB(n, out)
  local p = math.min(n["QS"] or 0, n["JD"] or 0)
  if p >= 2 then
    out[#out + 1] = { name = "DOUBLE PINOCHLE", pts = M.VALUES.doublePinochle }
    return M.VALUES.doublePinochle
  elseif p == 1 then
    out[#out + 1] = { name = "PINOCHLE", pts = M.VALUES.pinochle }
    return M.VALUES.pinochle
  end
  return 0
end

-- ── CLASS C: arounds ──────────────────────────────────────────────────
-- One of a rank in all four suits. There is no tens-around and no
-- nines-around: tens around is worth nothing, and nines around is a
-- standing joke, so neither is implemented.
local AROUND = {
  { rank = "A", name = "ACES",   single = "acesAround",   double = "doubleAces" },
  { rank = "K", name = "KINGS",  single = "kingsAround",  double = "doubleKings" },
  { rank = "Q", name = "QUEENS", single = "queensAround", double = "doubleQueens" },
  { rank = "J", name = "JACKS",  single = "jacksAround",  double = "doubleJacks" },
}

local function classC(n, out)
  local total = 0
  for _, a in ipairs(AROUND) do
    local m = 2
    for _, s in ipairs({"S", "H", "C", "D"}) do
      m = math.min(m, n[a.rank .. s] or 0)
    end
    if m >= 2 then
      local v = M.VALUES[a.double]
      total = total + v
      out[#out + 1] = { name = "DOUBLE " .. a.name, pts = v }
    elseif m == 1 then
      local v = M.VALUES[a.single]
      total = total + v
      out[#out + 1] = { name = a.name .. " AROUND", pts = v }
    end
  end
  return total
end

-- Returns total, list-of-{name, pts}. The list is what gets shown to the
-- player -- naming each meld is how the game teaches what a meld IS,
-- which is the same trick the poker games use to teach hand rankings.
function M.score(hand, trump)
  local n = census(hand)
  local out = {}
  local total = classA(n, trump, out) + classB(n, out) + classC(n, out)
  return total, out
end

-- The best trump for a hand: whatever suit melds highest. Used by the bot
-- to decide what to name, and to suggest a bid.
function M.bestTrump(hand)
  local bestSuit, bestPts = "S", -1
  for _, s in ipairs({"S", "H", "C", "D"}) do
    local pts = M.score(hand, s)
    if pts > bestPts then bestSuit, bestPts = s, pts end
  end
  return bestSuit, bestPts
end

return M
