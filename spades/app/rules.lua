-- spades/rules.lua - seats, legality, and who takes the book.
-- Pure logic, no rendering: the test driver re-derives everything here
-- independently, so keep this file free of UI state.
local cards = require("lib.cards")
local M = {}

-- Seats: 1=south (dad), 2=west, 3=north (partner), 4=east.
-- Clockwise on screen from south is west, so seat%4+1 walks S->W->N->E.
M.SOUTH, M.WEST, M.NORTH, M.EAST = 1, 2, 3, 4
M.NAME = {"YOU", "WEST", "PARTNER", "EAST"}

function M.nextSeat(s) return s % 4 + 1 end
function M.partner(s) return (s + 1) % 4 + 1 end
function M.teamOf(s) return (s % 2 == 1) and 1 or 2 end   -- team 1 = us

-- Sort for the visible hand: spades leftmost, then alternating colors
-- (H, C, D), high card left within each suit.
local SUIT_ORDER = {S = 1, H = 2, C = 3, D = 4}
function M.sortHand(hand)
  table.sort(hand, function(a, b)
    if a.suit ~= b.suit then return SUIT_ORDER[a.suit] < SUIT_ORDER[b.suit] end
    return cards.val[a.rank] > cards.val[b.rank]
  end)
end

-- Legal plays: indices into `hand`. Follow the led suit if you hold it;
-- void, anything goes. Leading: NO spade while another suit remains in
-- hand - the family rule, stricter than "spades broken". You lead trump
-- only when trump is all you have. (Ruffing when void still breaks
-- spades; broken drives the announcement and the bots' judgment, not
-- lead legality.)
function M.legalPlays(hand, trick, spadesBroken)
  local out = {}
  if #trick > 0 then
    local led = trick[1].card.suit
    for i, c in ipairs(hand) do
      if c.suit == led then out[#out + 1] = i end
    end
    if #out > 0 then return out end
    for i = 1, #hand do out[i] = i end
    return out
  end
  for i, c in ipairs(hand) do
    if c.suit ~= "S" then out[#out + 1] = i end
  end
  if #out > 0 then return out end
  for i = 1, #hand do out[i] = i end
  return out
end

-- The winning play of a (possibly partial) trick: highest spade if any
-- spade was played, else highest card of the suit led.
function M.winningPlay(trick)
  if #trick == 0 then return nil end
  local w = trick[1]
  for i = 2, #trick do
    local c, wc = trick[i].card, w.card
    if c.suit == "S" and wc.suit ~= "S" then
      w = trick[i]
    elseif c.suit == wc.suit and cards.val[c.rank] > cards.val[wc.rank] then
      w = trick[i]
    end
  end
  return w
end

function M.bookWinner(trick) return M.winningPlay(trick).seat end

return M
