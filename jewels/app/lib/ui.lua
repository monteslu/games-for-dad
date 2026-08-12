-- cardtable/ui.lua - shared HUD, focus ring, and the whole-family control idiom:
-- LEFT/RIGHT moves focus, A confirms. Nothing else. Ever.
local theme = require("lib.theme")
local M = {}

local fonts = {}
function M.font(size)
  if not fonts[size] then fonts[size] = love.graphics.newFont("fonts/AtkinsonBold.ttf", size) end
  return fonts[size]
end

-- money HUD along the bottom. `mood` colors the bankroll for the round
-- just played: "win" = highlight blue, "loss" = red, nil = white (fresh).
function M.drawMoney(bankroll, bet, winAmount, mood)
  local g = love.graphics
  local W, H = g.getWidth(), g.getHeight()
  g.setFont(M.font(theme.fontBig))
  if mood == "win" then g.setColor(theme.winRing)
  elseif mood == "loss" then g.setColor(theme.lossRed)
  else g.setColor(theme.white) end
  g.print("BANKROLL  $" .. bankroll, 60, H - 70)
  g.setColor(theme.quiet)
  g.print("BET  $" .. bet, W / 2 - 100, H - 70)
  if winAmount and winAmount > 0 then
    g.setColor(theme.win)
    g.print("WIN  $" .. winAmount, W - 460, H - 70)
  end
end

-- gold focus ring around a rect (the "you are here" marker)
function M.focusRing(x, y, w, h)
  local g = love.graphics
  g.setColor(theme.gold)
  for i = 0, 5 do g.rectangle("line", x - 8 - i, y - 8 - i, w + 16 + i * 2, h + 16 + i * 2) end
end

-- blue ring for the cards that made the final hand (distinct from the
-- gold cursor ring - selection and result are different ideas)
function M.winRing(x, y, w, h)
  local g = love.graphics
  g.setColor(theme.winRing)
  for i = 0, 5 do g.rectangle("line", x - 8 - i, y - 8 - i, w + 16 + i * 2, h + 16 + i * 2) end
end

-- HELD banner across the card's center: rank + suit stay visible above it
function M.heldBadge(x, y, w, h)
  local g = love.graphics
  h = h or theme.cardH
  local bh = 54
  local by = y + (h - bh) / 2
  g.setColor(theme.gold)
  g.rectangle("fill", x - 6, by, w + 12, bh)
  g.setColor(theme.ink)
  g.setFont(M.font(theme.fontSmall + 6))
  g.printf("HELD", x - 6, by + 6, w + 12, "center")
end

-- big rounded pill button (DEAL / DRAW)
function M.button(label, x, y, w, h, focused)
  local g = love.graphics
  g.setColor(focused and theme.gold or theme.feltDark)
  g.rectangle("fill", x, y, w, h)
  g.setColor(focused and theme.ink or theme.quiet)
  g.setFont(M.font(theme.fontBig))
  g.printf(label, x, y + (h - theme.fontBig) / 2 - 6, w, "center")
  g.setColor(theme.white)
  g.rectangle("line", x, y, w, h)
end

-- centered banner text (result line)
function M.banner(text, y, color, size)
  local g = love.graphics
  g.setFont(M.font(size or theme.fontHuge))
  g.setColor(color or theme.white)
  g.printf(text, 0, y, g.getWidth(), "center")
end

return M
