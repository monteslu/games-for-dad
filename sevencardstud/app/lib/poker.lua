-- cardtable/poker.lua - 5-card hand evaluation, shared by video poker + stud.
local cards = require("lib.cards")
local M = {}

-- classify a 5-card hand -> key, pretty name
-- keys: royal, sflush, quads, boat, flush, straight, trips, twopair,
--       jacksup, pair, high
function M.evaluate(hand)
  local vals, suits, counts, byRank = {}, {}, {}, {}
  for i, c in ipairs(hand) do
    vals[#vals + 1] = cards.val[c.rank]
    suits[c.suit] = (suits[c.suit] or 0) + 1
    counts[c.rank] = (counts[c.rank] or 0) + 1
    byRank[c.rank] = byRank[c.rank] or {}
    byRank[c.rank][#byRank[c.rank] + 1] = i
  end
  table.sort(vals)

  local isFlush = false
  for _, n in pairs(suits) do if n == 5 then isFlush = true end end

  -- straight: 5 distinct ascending, or the wheel A-2-3-4-5
  local isStraight, highV = false, vals[5]
  local distinct = true
  for i = 2, 5 do if vals[i] == vals[i - 1] then distinct = false end end
  if distinct then
    if vals[5] - vals[1] == 4 then isStraight = true
    elseif vals[5] == 14 and vals[4] == 5 and vals[1] == 2 then
      isStraight, highV = true, 5   -- wheel: five high
    end
  end

  local pairs_, trips, quads, pairHigh = 0, false, false, 0
  for r, n in pairs(counts) do
    if n == 2 then pairs_ = pairs_ + 1; pairHigh = math.max(pairHigh, cards.val[r]) end
    if n == 3 then trips = true end
    if n == 4 then quads = true end
  end

  -- which card indices make the hand (1..5, as a set {i=true})
  local ALL = {[1]=true,[2]=true,[3]=true,[4]=true,[5]=true}
  local function ofCount(n)
    local set = {}
    for r, list in pairs(byRank) do
      if #list == n then for _, i in ipairs(list) do set[i] = true end end
    end
    return set
  end

  if isStraight and isFlush and highV == 14 then return "royal",   "ROYAL FLUSH", ALL end
  if isStraight and isFlush                 then return "sflush",  "STRAIGHT FLUSH", ALL end
  if quads                                  then return "quads",   "FOUR OF A KIND", ofCount(4) end
  if trips and pairs_ == 1                  then return "boat",    "FULL HOUSE", ALL end
  if isFlush                                then return "flush",   "FLUSH", ALL end
  if isStraight                             then return "straight","STRAIGHT", ALL end
  if trips                                  then return "trips",   "THREE OF A KIND", ofCount(3) end
  if pairs_ == 2                            then return "twopair", "TWO PAIR", ofCount(2) end
  if pairs_ == 1 and pairHigh >= 11         then return "jacksup", "JACKS OR BETTER", ofCount(2) end
  if pairs_ == 1                            then return "pair",    "PAIR", ofCount(2) end
  -- high card: just the single best card
  local bestI, bestV = 1, 0
  for i, c in ipairs(hand) do
    if cards.val[c.rank] > bestV then bestV = cards.val[c.rank]; bestI = i end
  end
  return "high", "HIGH CARD", {[bestI] = true}
end

-- full-pay 9/6 Jacks or Better multipliers (win = bet * mult; 0 = no pay)
M.jacksOrBetter = {
  royal = 250, sflush = 50, quads = 25, boat = 9, flush = 6,
  straight = 4, trips = 3, twopair = 2, jacksup = 1, pair = 0, high = 0,
}

-- display order for the paytable
M.paytableRows = {
  {"royal",    "ROYAL FLUSH",     250},
  {"sflush",   "STRAIGHT FLUSH",   50},
  {"quads",    "FOUR OF A KIND",   25},
  {"boat",     "FULL HOUSE",        9},
  {"flush",    "FLUSH",             6},
  {"straight", "STRAIGHT",          4},
  {"trips",    "THREE OF A KIND",   3},
  {"twopair",  "TWO PAIR",          2},
  {"jacksup",  "JACKS OR BETTER",   1},
}


-- ── full hand comparison (showdowns need more than the category) ──────
-- strength(hand) -> array: {categoryRank, tiebreaker1, tiebreaker2, ...}
-- compare lexicographically. Category ranks: high=1 .. royal=10.
local CAT_RANK = { high=1, pair=2, jacksup=2, twopair=3, trips=4,
                   straight=5, flush=6, boat=7, quads=8, sflush=9, royal=10 }

function M.strength(hand)
  local key = M.evaluate(hand)
  local counts, vals = {}, {}
  for _, c in ipairs(hand) do
    counts[c.rank] = (counts[c.rank] or 0) + 1
  end
  for r, n in pairs(counts) do
    vals[#vals + 1] = { n = n, v = cards.val[r] }
  end
  -- groups first by size, then by rank: quads > trips > pairs > kickers
  table.sort(vals, function(a, b)
    if a.n ~= b.n then return a.n > b.n end
    return a.v > b.v
  end)
  local out = { CAT_RANK[key] or 1 }
  -- straights/straight flushes compare by top card (wheel = 5-high)
  if key == "straight" or key == "sflush" or key == "royal" then
    local vs = {}
    for _, c in ipairs(hand) do vs[#vs + 1] = cards.val[c.rank] end
    table.sort(vs)
    local high = vs[5]
    if vs[5] == 14 and vs[4] == 5 then high = 5 end   -- the wheel
    out[2] = high
    return out
  end
  for _, g in ipairs(vals) do
    for _ = 1, g.n do out[#out + 1] = g.v end
  end
  return out
end

-- 1 = a wins, -1 = b wins, 0 = tie
function M.compare(a, b)
  local sa, sb = M.strength(a), M.strength(b)
  for i = 1, math.max(#sa, #sb) do
    local x, y = sa[i] or 0, sb[i] or 0
    if x ~= y then return x > y and 1 or -1 end
  end
  return 0
end

-- ── best 5-card hand out of N cards (7-card stud: C(7,5)=21 subsets) ──
-- returns key, name, contributing indices mapped to ORIGINAL positions
function M.best5(hand)
  local n = #hand
  if n <= 5 then
    local k, nm, ci = M.evaluate(hand)
    return k, nm, ci
  end
  local bestSub, bestMap = nil, nil
  local idx = {1, 2, 3, 4, 5}
  local function consider()
    local sub = {}
    for k = 1, 5 do sub[k] = hand[idx[k]] end
    if not bestSub or M.compare(sub, bestSub) > 0 then
      bestSub = sub
      bestMap = {idx[1], idx[2], idx[3], idx[4], idx[5]}
    end
  end
  -- iterate all 5-combinations of 1..n in lexicographic order
  while true do
    consider()
    -- advance
    local i = 5
    while i >= 1 and idx[i] == n - (5 - i) do i = i - 1 end
    if i < 1 then break end
    idx[i] = idx[i] + 1
    for j = i + 1, 5 do idx[j] = idx[j - 1] + 1 end
  end
  local key, name, cidx = M.evaluate(bestSub)
  local orig = {}
  for k, v in pairs(cidx) do if v then orig[bestMap[k]] = true end end
  return key, name, orig
end

return M
