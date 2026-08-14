-- pinochle/rules.lua - the deck, seats, legality, and who takes the trick.
--
-- Pure logic, no rendering: the tests re-derive everything here
-- independently, so keep this file free of UI state. Same contract as
-- spades/rules.lua, which this is deliberately shaped after.
local cards = require("lib.cards")
local M = {}

-- ── THE DECK ──────────────────────────────────────────────────────────
--
-- Pinochle is 48 cards: TWO each of A, 10, K, Q, J, 9 in all four suits.
-- The shared card art is a normal 52-card deck, so the ranks are its own
-- strings and the duplicates are simply dealt twice -- no new art, and the
-- ten is the "T" the art already has.
--
-- THE TEN RANKS SECOND, between the ace and the king. This is the single
-- most surprising thing about the game to anyone who has played anything
-- else, and it is why the ranking below is a table rather than reusing
-- cards.val (where a ten is worth less than a jack).
M.RANKS = {"A", "T", "K", "Q", "J", "9"}
M.SUITS = {"S", "H", "C", "D"}

-- Trick-taking power. Higher wins.
M.power = {A = 6, T = 5, K = 4, Q = 3, J = 2, ["9"] = 1}

-- COUNTERS: what a card is worth in trick points. Ace, ten and king are
-- worth TEN each; queen, jack and nine are worth nothing.
--
-- NOT the "Avondale" 4-3-2-1-0 schedule, which belongs to Bid Euchre and
-- is not a pinochle scheme at all -- and not the 11/10/4/3/2 table on the
-- Bicycle site, which is the TWO-HANDED draw game and wrong here.
--
-- The invariant worth holding onto: every legitimate pinochle counter
-- scheme totals 250 a hand. 8 aces + 8 tens + 8 kings = 24 counters at 10
-- = 240, plus 10 for the last trick = 250.
M.counter = {A = 10, T = 10, K = 10, Q = 0, J = 0, ["9"] = 0}

M.TRICK_POINTS = 240      -- all the counters
M.LAST_TRICK   = 10
M.HAND_POINTS  = 250      -- what a hand is always worth in tricks

function M.newDeck()
  local d = {}
  for _, s in ipairs(M.SUITS) do
    for _, r in ipairs(M.RANKS) do
      -- TWO of each, and they need DIFFERENT ids: the renderer keys card
      -- art on id, and two cards sharing one id makes the second
      -- untrackable through a tween.
      for copy = 1, 2 do
        d[#d + 1] = { rank = r, suit = s, id = r .. s, copy = copy,
                      uid = r .. s .. copy }
      end
    end
  end
  -- Fisher-Yates with the shared stirred RNG, so a deal is as unpredictable
  -- as the player's own input timing makes it.
  for i = #d, 2, -1 do
    local j = cards.rand(i)
    d[i], d[j] = d[j], d[i]
  end
  return d
end

-- ── SEATS ─────────────────────────────────────────────────────────────
-- Identical to spades: 1=south (dad), 2=west, 3=north (partner), 4=east.
M.SOUTH, M.WEST, M.NORTH, M.EAST = 1, 2, 3, 4
M.NAME = {"YOU", "WEST", "PARTNER", "EAST"}

function M.nextSeat(s) return s % 4 + 1 end
function M.partner(s) return (s + 1) % 4 + 1 end
function M.teamOf(s) return (s % 2 == 1) and 1 or 2 end   -- team 1 = us

-- Sort for the visible hand: trump first if known, then alternating
-- colours, high card left within a suit. Duplicates sit together.
local SUIT_ORDER = {S = 1, H = 2, C = 3, D = 4}
function M.sortHand(hand, trump)
  table.sort(hand, function(a, b)
    if a.suit ~= b.suit then
      local ao = (trump and a.suit == trump) and 0 or SUIT_ORDER[a.suit]
      local bo = (trump and b.suit == trump) and 0 or SUIT_ORDER[b.suit]
      if ao ~= bo then return ao < bo end
    end
    if M.power[a.rank] ~= M.power[b.rank] then
      return M.power[a.rank] > M.power[b.rank]
    end
    return (a.copy or 1) < (b.copy or 1)
  end)
end

-- ── LEGAL PLAYS ───────────────────────────────────────────────────────
--
-- PINOCHLE IS NOT SPADES, and this is the rule that catches people. The
-- obligations, in order:
--
--   1. FOLLOW SUIT if you can.
--   2. And if you can, you must also BEAT the card currently winning the
--      trick ("play over"). Following suit with a low card when you hold a
--      higher one is illegal.
--   3. Void in the suit led? You MUST TRUMP if you hold trump.
--   4. Already trumped by someone? You must OVERTRUMP if you can.
--   5. Only when you can do none of that may you discard anything.
--
-- The "must beat" rule is what makes pinochle feel tense rather than
-- loose, and it also means the legal set is often a single card -- which
-- the UI leans on, since a forced play needs no thought from the player.
function M.legalPlays(hand, trick, trump)
  local out = {}
  local function all()
    local t = {}
    for i = 1, #hand do t[i] = i end
    return t
  end
  if #trick == 0 then return all() end

  local led = trick[1].card.suit
  local win = M.winningPlay(trick, trump)
  local winIsTrump = (win.card.suit == trump)

  -- 1 + 2: hold the suit led
  local inSuit = {}
  for i, c in ipairs(hand) do
    if c.suit == led then inSuit[#inSuit + 1] = i end
  end
  if #inSuit > 0 then
    -- must play over if the trick is not already trumped away from us
    if not winIsTrump or led == trump then
      for _, i in ipairs(inSuit) do
        if M.power[hand[i].rank] > M.power[win.card.rank] then
          out[#out + 1] = i
        end
      end
      if #out > 0 then return out end
    end
    return inSuit          -- can't beat it: any card of the suit
  end

  -- 3 + 4: void, so trump if you hold any
  local trumps = {}
  for i, c in ipairs(hand) do
    if c.suit == trump then trumps[#trumps + 1] = i end
  end
  if #trumps > 0 then
    if winIsTrump then
      for _, i in ipairs(trumps) do
        if M.power[hand[i].rank] > M.power[win.card.rank] then
          out[#out + 1] = i
        end
      end
      if #out > 0 then return out end
      -- cannot overtrump: rules differ on whether you must still trump.
      -- The common (and kinder) reading is that you may discard, so fall
      -- through to a free choice.
      return all()
    end
    return trumps
  end

  return all()             -- 5: nothing to follow, nothing to trump
end

-- The winning play of a (possibly partial) trick.
--
-- TRUMP IS PASSED IN, never stored on the module. A hidden M._trump would
-- make this file stateful, and the whole point of keeping it pure is that
-- the tests can re-derive a hand independently -- which they cannot do if
-- correctness depends on some earlier call having set a global.
--
-- IDENTICAL CARDS: when two of the same card are played to one trick, the
-- FIRST one played wins. That is the standard rule, and it falls out of
-- the strict > below rather than needing a special case.
function M.winningPlay(trick, trump)
  if #trick == 0 then return nil end
  local w = trick[1]
  for i = 2, #trick do
    local c, wc = trick[i].card, w.card
    if c.suit == wc.suit then
      if M.power[c.rank] > M.power[wc.rank] then w = trick[i] end
    elseif c.suit == trump and wc.suit ~= trump then
      w = trick[i]
    end
  end
  return w
end

function M.trickWinner(trick, trump) return M.winningPlay(trick, trump).seat end

return M
