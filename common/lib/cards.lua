-- cardtable/cards.lua - deck, art, and card drawing shared by every cart.
local theme = require("lib.theme")
local M = {}

local RANKS = {"2","3","4","5","6","7","8","9","T","J","Q","K","A"}
local SUITS = {"C","D","H","S"}
M.RANKS, M.SUITS = RANKS, SUITS

-- rank -> numeric value (A high = 14; evaluators may also treat A as 1)
M.val = {}
for i, r in ipairs(RANKS) do M.val[r] = i + 1 end

local images = nil
function M.loadArt()
  if images then return end
  images = {}
  for _, s in ipairs(SUITS) do
    for _, r in ipairs(RANKS) do
      local id = r .. s
      images[id] = love.graphics.newImage("cards/" .. id .. ".png")
    end
  end
end

-- Shuffle RNG. The wasmcart HOST owns love.math.random's seed and seeds it
-- identically every boot (determinism is an engine feature) - so a deck
-- shuffled purely from it deals the SAME first hand every power-on.
-- Fix: the oldest console trick - stir HUMAN TIMING into the pot. Nobody
-- presses a button on the same frame twice.
local rngState = 0x9E3779B9
function M.stir(n)
  -- floor: a fractional n (e.g. a time value) would make rngState lose its
  -- integer representation and crash the xorshift's bitwise ops later.
  n = math.floor(n or 0)
  rngState = (rngState + n * 2654435761 + love.math.random(2 ^ 30)) % 4294967296
  if rngState == 0 then rngState = 0x9E3779B9 end
end
local function rnd(n)          -- xorshift32 -> 1..n
  local x = rngState
  x = x ~ ((x << 13) % 4294967296)
  x = x ~ (x >> 17)
  x = x ~ ((x << 5) % 4294967296)
  rngState = x % 4294967296
  return (rngState % n) + 1
end
M.rand = rnd   -- exposed for carts whose deck model isn't the 52-card one
               -- (deck-builders inject this into their own shuffle)

-- a fresh 52-card deck
function M.newDeck()
  local d = {}
  for _, s in ipairs(SUITS) do
    for _, r in ipairs(RANKS) do d[#d + 1] = {rank = r, suit = s, id = r .. s} end
  end
  for i = #d, 2, -1 do
    local j = rnd(i)
    d[i], d[j] = d[j], d[i]
  end
  return d
end

-- draw a card face at x,y scaled to theme card size (art: 500x726)
function M.drawCard(card, x, y, scale)
  scale = scale or 1
  local img = images[card.id]
  local sx = theme.cardW / img:getWidth() * scale
  local sy = theme.cardH / img:getHeight() * scale
  love.graphics.setColor(1, 1, 1)
  love.graphics.draw(img, x, y, 0, sx, sy)
end

-- FLIGHT draw: card centered at (cx,cy), scaled, rotated, mid-flip.
-- flip 0 = face-down, 1 = face-up; the visual flip happens by squashing
-- horizontally through the midpoint and swapping back->face there.
function M.drawFlight(card, cx, cy, scale, rot, flip)
  flip = flip or 1
  local squash = math.abs(2 * flip - 1)   -- 1..0..1 across the flip
  if squash < 0.06 then squash = 0.06 end -- never fully edge-on (invisible)
  if flip < 0.5 then
    M.drawBackC(cx, cy, scale * squash, scale)
  else
    local img = images[card.id]
    local sx = theme.cardW / img:getWidth() * scale * squash
    local sy = theme.cardH / img:getHeight() * scale
    love.graphics.setColor(1, 1, 1)
    love.graphics.draw(img, cx, cy, rot, sx, sy, img:getWidth() / 2, img:getHeight() / 2)
  end
end

-- center-origin back (for flights + the deck pile)
function M.drawBackC(cx, cy, sx, sy, rot)
  local g = love.graphics
  local w, h = theme.cardW * sx, theme.cardH * (sy or sx)
  -- rotation for the procedural back is approximated by the squash alone
  -- (rot on rectangles isn't supported); flights spend most of the flip
  -- face-up anyway, where the real card art rotates properly.
  local x, y = cx - w / 2, cy - h / 2
  g.setColor(1, 1, 1);            g.rectangle("fill", x, y, w, h)
  g.setColor(0.55, 0.12, 0.14);   g.rectangle("fill", x + 4, y + 4, w - 8, h - 8)
  g.setColor(0.75, 0.55, 0.25)
  g.rectangle("line", x + 8, y + 8, w - 16, h - 16)
end

-- procedural card back: matches the theme, crisp at any size.
-- (the CC0 pack ships no back; drawing one keeps the style ours)
function M.drawBack(x, y, scale)
  scale = scale or 1
  local w, h = theme.cardW * scale, theme.cardH * scale
  local g = love.graphics
  g.setColor(1, 1, 1);            g.rectangle("fill", x, y, w, h)
  g.setColor(0.55, 0.12, 0.14);   g.rectangle("fill", x + 6, y + 6, w - 12, h - 12)
  g.setColor(0.75, 0.55, 0.25)
  local step = 26 * scale
  for i = 0, math.floor((w - 24) / step) do
    local cx = x + 12 + i * step
    g.line(cx, y + 12, math.min(cx + step, x + w - 12), y + h - 12)
    g.line(math.min(cx + step, x + w - 12), y + 12, cx, y + h - 12)
  end
  g.setColor(1, 1, 1); g.rectangle("line", x + 6, y + 6, w - 12, h - 12)
end

return M
