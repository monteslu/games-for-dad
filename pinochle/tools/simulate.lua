-- Play complete pinochle hands headlessly, with no engine and no
-- graphics, and assert the invariants that must hold every time.
--
-- This is the test that matters most for a card game. The UI can be
-- checked with a screenshot; the RULES cannot -- a game that quietly
-- misdeals, loses a card, or scores 240 instead of 250 looks perfectly
-- fine in a picture and is broken.
--
--   lua tools/simulate.lua [hands]
--
-- Run from the game's app/ directory, or anywhere: it fixes its own path.

local here = arg[0]:match("(.*)/tools/") or "."
package.path = here .. "/app/?.lua;" .. package.path

-- The shared cards lib wants love.graphics; the pure logic does not.
package.preload["lib.cards"] = function()
  local seed = 20250814
  return {
    rand = function(n)
      -- xorshift, so a run is reproducible and a failure can be re-run
      seed = seed ~ (seed << 13); seed = seed & 0x7fffffff
      seed = seed ~ (seed >> 7)
      seed = seed ~ (seed << 17); seed = seed & 0x7fffffff
      return (seed % n) + 1
    end,
    val = {},
  }
end

local rules   = require("rules")
local meld    = require("meld")
local scoring = require("scoring")
local bot     = require("bot")

local N = tonumber(arg[1]) or 2000
local fail = {}
local function check(cond, msg)
  if not cond then fail[#fail + 1] = msg end
  return cond
end

local stats = {
  bids = {}, setCount = 0, madeCount = 0, meldTotal = 0,
  declarerTeam = {0, 0}, handPoints = {}, passOut = 0,
  trumpNamed = {S = 0, H = 0, C = 0, D = 0},
}

for hand = 1, N do
  -- ── deal ────────────────────────────────────────────────────────────
  local deck = rules.newDeck()
  check(#deck == 48, ("hand %d: deck is %d cards"):format(hand, #deck))
  local hands = {{}, {}, {}, {}}
  for i = 1, 48 do
    hands[(i - 1) % 4 + 1][#hands[(i - 1) % 4 + 1] + 1] = deck[i]
  end
  for s = 1, 4 do
    check(#hands[s] == 12, ("hand %d: seat %d got %d cards"):format(hand, s, #hands[s]))
  end

  -- ── bid ─────────────────────────────────────────────────────────────
  -- West opens (left of the permanent dealer, who is south), then round.
  local AGGRO = {[1] = 0, [2] = -0.2, [3] = 0.1, [4] = 0.2}
  local highBid, declarer, declTrump = nil, nil, nil
  local wasForced = false
  local out = {false, false, false, false}
  local order = {2, 3, 4, 1}
  local live = 4
  local guard = 0
  while live > 1 and guard < 40 do
    for _, seat in ipairs(order) do
      guard = guard + 1
      if not out[seat] and live > 1 then
        local b, suit = bot.suggestBid(hands[seat], {aggro = AGGRO[seat], highBid = highBid})
        if b and (not highBid or b > highBid) then
          highBid, declarer, declTrump = b, seat, suit
        else
          out[seat] = true
          live = live - 1
        end
      end
    end
  end
  if not declarer then
    -- everyone passed: the dealer's team is stuck with the minimum
    stats.passOut = stats.passOut + 1
    wasForced = true
    declarer = 1
    declTrump = meld.bestTrump(hands[1])
    highBid = scoring.MIN_BID
  end
  stats.bids[#stats.bids + 1] = highBid
  stats.trumpNamed[declTrump] = (stats.trumpNamed[declTrump] or 0) + 1

  -- ── the pass ────────────────────────────────────────────────────────
  -- Four across from the declarer's partner, four back. This is where a
  -- card would go missing if moveCards were wrong, and a lost card is
  -- invisible until someone runs out mid-trick.
  do
    local partner = rules.partner(declarer)
    local function move(from, to, idx)
      table.sort(idx, function(a, b) return a > b end)
      local moved = {}
      for _, i in ipairs(idx) do moved[#moved + 1] = table.remove(from, i) end
      for _, c in ipairs(moved) do to[#to + 1] = c end
    end
    move(hands[partner], hands[declarer], bot.choosePass(hands[partner], declTrump))
    check(#hands[declarer] == 16,
          ("hand %d: declarer holds %d after receiving"):format(hand, #hands[declarer]))
    check(#hands[partner] == 8,
          ("hand %d: partner holds %d after sending"):format(hand, #hands[partner]))
    move(hands[declarer], hands[partner], bot.chooseReturn(hands[declarer], declTrump))
    for s = 1, 4 do
      check(#hands[s] == 12,
            ("hand %d: seat %d holds %d after the pass, not 12")
            :format(hand, s, #hands[s]))
    end
  end

  -- ── meld ────────────────────────────────────────────────────────────
  local teamMeld = {0, 0}
  for s = 1, 4 do
    local pts = meld.score(hands[s], declTrump)
    teamMeld[rules.teamOf(s)] = teamMeld[rules.teamOf(s)] + pts
    stats.meldTotal = stats.meldTotal + pts
  end

  -- ── play twelve tricks ──────────────────────────────────────────────
  local teamTricks = {0, 0}
  local lead = declarer
  local seen = {}
  for t = 1, 12 do
    local trick = {}
    local seat = lead
    for _ = 1, 4 do
      local legal = rules.legalPlays(hands[seat], trick, declTrump)
      check(#legal > 0, ("hand %d trick %d: seat %d had no legal play"):format(hand, t, seat))
      local idx = bot.choosePlay(hands[seat], {
        trump = declTrump, trick = trick, seat = seat,
        partnerSeat = rules.partner(seat), tricksLeft = 13 - t })
      -- THE BOT MUST PICK A LEGAL CARD. If it ever does not, the game
      -- would let a CPU cheat, which is the worst possible bug here.
      local ok = false
      for _, i in ipairs(legal) do if i == idx then ok = true end end
      check(ok, ("hand %d trick %d: seat %d chose an ILLEGAL card"):format(hand, t, seat))
      if not ok then idx = legal[1] end

      local c = table.remove(hands[seat], idx)
      -- no card may appear twice in a hand
      local key = c.uid
      check(not seen[key], ("hand %d: card %s played twice"):format(hand, key))
      seen[key] = true
      trick[#trick + 1] = {seat = seat, card = c}
      seat = rules.nextSeat(seat)
    end
    check(#trick == 4, "trick did not have four cards")
    local w = rules.trickWinner(trick, declTrump)
    local pts = 0
    for _, p in ipairs(trick) do pts = pts + rules.counter[p.card.rank] end
    if t == 12 then pts = pts + rules.LAST_TRICK end
    teamTricks[rules.teamOf(w)] = teamTricks[rules.teamOf(w)] + pts
    lead = w
  end

  for s = 1, 4 do
    check(#hands[s] == 0, ("hand %d: seat %d still holds cards"):format(hand, s))
  end

  -- ── the invariant that catches almost everything ────────────────────
  -- Every hand is worth EXACTLY 250 in trick points. If the counters or
  -- the last-trick bonus are wrong anywhere, this is where it shows.
  local total = teamTricks[1] + teamTricks[2]
  check(total == rules.HAND_POINTS,
        ("hand %d: trick points were %d, not %d"):format(hand, total, rules.HAND_POINTS))
  stats.handPoints[total] = (stats.handPoints[total] or 0) + 1

  -- ── score ───────────────────────────────────────────────────────────
  local dt = rules.teamOf(declarer)
  stats.declarerTeam[dt] = stats.declarerTeam[dt] + 1
  local r = scoring.scoreTeam{ bid = highBid, meld = teamMeld[dt], tricks = teamTricks[dt] }
  if r.made then stats.madeCount = stats.madeCount + 1 else stats.setCount = stats.setCount + 1 end
  -- Forced dealer contracts are a different population: nobody WANTED
  -- them, so they are expected to fail often. Counting them together with
  -- real auctions hides whether the bidding itself is sane.
  stats.forced = stats.forced or {made = 0, set = 0}
  stats.chosen = stats.chosen or {made = 0, set = 0}
  local bucket = wasForced and stats.forced or stats.chosen
  if r.made then bucket.made = bucket.made + 1 else bucket.set = bucket.set + 1 end

  if #fail > 8 then break end
end

-- ── report ────────────────────────────────────────────────────────────
local function avg(t) local s = 0 for _, v in ipairs(t) do s = s + v end return s / #t end
table.sort(stats.bids)

print(("hands played      %d"):format(N))
print(("average bid       %.0f   (min %d, max %d)")
      :format(avg(stats.bids), stats.bids[1], stats.bids[#stats.bids]))
print(("average meld/hand %.0f  (all four seats)"):format(stats.meldTotal / N))
print(("contracts made    %d  (%.0f%%)")
      :format(stats.madeCount, 100 * stats.madeCount / N))
print(("contracts set     %d  (%.0f%%)")
      :format(stats.setCount, 100 * stats.setCount / N))
print(("passed out        %d"):format(stats.passOut))
if stats.chosen then
  local c, f = stats.chosen, stats.forced or {made=0,set=0}
  local ct = c.made + c.set
  if ct > 0 then
    print(("CHOSEN contracts  %d made, %d set  (%.0f%% set)")
          :format(c.made, c.set, 100 * c.set / ct))
  end
  local ft = f.made + f.set
  if ft > 0 then
    print(("FORCED on dealer  %d made, %d set  (%.0f%% set)")
          :format(f.made, f.set, 100 * f.set / ft))
  end
end
-- WHICH SUIT GETS NAMED. A THIRD OF HANDS TIE on meld -- most hands have
-- no meld at all in most suits, and every one of those ties at zero -- so
-- a strict `>` over a fixed S,H,C,D scan hands every tie to spades and
-- names it 37% of the time against diamonds' 16%. Worse than unfair: on a
-- tie it named a bare spade suit over a long strong heart one.
local tn = stats.trumpNamed
print(("trump named       S %.0f%%  H %.0f%%  C %.0f%%  D %.0f%%")
      :format(100 * tn.S / N, 100 * tn.H / N, 100 * tn.C / N, 100 * tn.D / N))

local distinct = 0
for _ in pairs(stats.handPoints) do distinct = distinct + 1 end
print(("trick totals seen %d distinct value(s) -- must be 1 (always 250)")
      :format(distinct))

if #fail > 0 then
  print("\nFAIL")
  for _, f in ipairs(fail) do print("  " .. f) end
  os.exit(1)
end

-- A bot that never gets set is not bidding; one that is always set is
-- reckless. Real partnership pinochle sets the contract maybe a quarter
-- of the time, so this is a wide but real band.
-- Judge the CHOSEN contracts. A forced dealer bid on a hand nobody wanted
-- is supposed to fail often; folding it in would let a bad bidder hide.
local c = stats.chosen or {made = 0, set = 0}
local chosenTotal = c.made + c.set
local setRate = chosenTotal > 0 and (c.set / chosenTotal) or 0
if setRate > 0.55 then
  print("\nFAIL: set " .. math.floor(setRate * 100) .. "% of contracts -- the bot overbids")
  os.exit(1)
end
if setRate < 0.02 then
  print("\nFAIL: set " .. math.floor(setRate * 100) .. "% -- the bot is not really bidding")
  os.exit(1)
end

-- SPADES LEGITIMATELY LEADS A LITTLE, and it took measuring to know how
-- much. Over ALL hands bestTrump splits 25/25/26/25 -- dead even. But the
-- auction does not sample all hands: it picks the strongest of four, and
-- among hands melding 80 or more, spades is 33%. The pinochle itself is a
-- spade queen, so spade-heavy hands meld higher and those are exactly the
-- hands that win auctions.
--
-- So the band has to allow ~30% for spades while still catching the old
-- bug, which named it 39%. Verified both ways: reverting the tiebreak
-- fails this check, the fix passes it.
for _, s in ipairs({"S", "H", "C", "D"}) do
  local share = stats.trumpNamed[s] / N
  if share > 0.35 or share < 0.17 then
    print(("\nFAIL: %s named %.0f%% of hands -- the trump tiebreak is biased")
          :format(s, share * 100))
    os.exit(1)
  end
end

print("\nPASS: rules hold over " .. N .. " hands, the bidding is sane,")
print("      and no suit is favoured when the meld ties")
