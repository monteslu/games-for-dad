-- JACKS OR BETTER - video poker for Dad.
-- Whole control scheme: LEFT/RIGHT moves, A confirms. That's it.
-- On a touch screen it's even less: tap a card to hold it, tap the button.
-- $1000 bankroll, $5 a hand, and the stack quietly refills if it ever
-- runs dry - no pressure, no fear of losing, play forever.

local theme  = require("lib.theme")
local cards  = require("lib.cards")
local ui     = require("lib.ui")
local poker  = require("lib.poker")
local anim   = require("lib.anim")
local sounds = require("lib.sounds")

local BET = 5
local START_BANK = 1000

local bankroll = START_BANK
local state = "idle"        -- idle | dealing | holding | drawing | result
local hand = {}             -- 5 slots: {rank,suit,id,x,y,held}
local deck = nil
local focus = 0             -- 0 = the button; 1..5 = cards
local lastWin = 0
local resultText, resultKey, resultIdx = nil, nil, nil
local moneyMood = nil       -- "win" | "loss" | nil, drives bankroll color
local refillMsg = false

-- layout (1920x1080)
local W, H = 1920, 1080
local slotY = 420
local slotX = {}
do
  local total = 5 * theme.cardW + 4 * theme.cardGap
  local x0 = (W - total) / 2
  for i = 1, 5 do slotX[i] = x0 + (i - 1) * (theme.cardW + theme.cardGap) end
end
-- the deck: face-down pile the deals visibly come FROM
local DECK = {scale = 0.55}
DECK.cx = W - 150
DECK.cy = 40 + (theme.cardH * DECK.scale) / 2

local BTN = {w = 320, h = 96}
-- hint line right under the cards, button BELOW it — a thumb aiming at
-- DEAL/DRAW never hovers over the hand (held cards tuck down 36px, so the
-- hint clears them too)
local HINT_Y = 856
BTN.x, BTN.y = (W - BTN.w) / 2, HINT_Y + theme.fontSmall + 16

function love.load()
  cards.loadArt()
  sounds.loadAll()
  love.graphics.setBackgroundColor(theme.felt[1], theme.felt[2], theme.felt[3])
end

-- Our own edge detection from raw isDown state. Host/key repeat can fire
-- wasPressed() again while a button is HELD - and a resting thumb on the
-- confirm button must never machine-gun deals or hold-toggles.
local prevDown = {}
local edges = {}
local lastEdgeFrame = {}
local frameNo = 0
-- A real finger cannot press twice inside 9 frames (150ms). Anything faster
-- is contact bounce or a host mapping flap - swallow it.
local DEBOUNCE = 9
local function readEdges()
  frameNo = frameNo + 1
  for _, b in ipairs({"a", "b", "left", "right", "up", "down"}) do
    local d = love.pad.isDown(b)
    local edge = d and not prevDown[b]
    if edge and (frameNo - (lastEdgeFrame[b] or -100)) < DEBOUNCE then
      edge = false                       -- inhumanly fast repeat: ignore
    end
    if edge then
      lastEdgeFrame[b] = frameNo
      cards.stir(frameNo)              -- human timing -> shuffle entropy
    end
    edges[b] = edge
    prevDown[b] = d
  end
end
local function confirmPressed() return edges.b or edges.a end
local confirmHeld = false     -- release gate: must let go before next deal

-- Touch / mouse taps. Raw wc.pointer polling across all ten slots (0 is
-- the mouse, 1..9 are fingers) - a game that reads only love.mouse works
-- on a desk and ignores every touch on a phone. Deliberately NOT
-- love.mousepressed: on a pad-only host that callback synthesizes a click
-- from the same A press confirmPressed() already consumes, and one press
-- must never both confirm and click. A tap is a slot's press EDGE; it
-- shares the pad's debounce window and feeds the same shuffle entropy.
local ptrPrev = {}
local tapX, tapY = nil, nil   -- this frame's tap position, or nil
local lastTapFrame = -100
local function readTaps()
  tapX, tapY = nil, nil
  for slot = 0, 9 do
    local x, y, buttons, active = wc.pointer(slot)
    local down = active and buttons ~= 0
    if down and not ptrPrev[slot]
       and tapX == nil
       and (frameNo - lastTapFrame) >= DEBOUNCE then
      tapX, tapY = x, y
      lastTapFrame = frameNo
      cards.stir(frameNo)              -- human timing -> shuffle entropy
    end
    ptrPrev[slot] = down
  end
end
-- Hit test against this frame's tap. `pad` grows the target - fingers are
-- blunter than cursors, and Dad's doubly so.
local function tapIn(x, y, w, h, pad)
  pad = pad or 0
  return tapX ~= nil
     and tapX >= x - pad and tapX < x + w + pad
     and tapY >= y - pad and tapY < y + h + pad
end

local function dealHand()
  if bankroll < BET then         -- never bust: quietly refill the stack
    bankroll = START_BANK
    refillMsg = true
  end
  bankroll = bankroll - BET
  lastWin = 0
  resultText, resultKey, resultIdx = nil, nil, nil
  moneyMood = nil
  sounds.play("shuffle")
  sounds.play("chips", 0.6)      -- the ante clinks in
  deck = cards.newDeck()
  hand = {}
  state = "dealing"
  for i = 1, 5 do
    local c = table.remove(deck)
    c.held = false
    -- flight fields: center pos, scale, rotation, flip (0=back, 1=face)
    c.fx, c.fy = DECK.cx, DECK.cy
    c.fs, c.frot, c.fflip = DECK.scale, math.pi, 0
    c.flying = true
    hand[i] = c
    anim.tween(c, {fx = slotX[i] + theme.cardW / 2, fy = slotY + theme.cardH / 2,
                   fs = 1, frot = 0, fflip = 1},
      theme.dealTime + (i - 1) * theme.dealStep,
      function()
        c.flying = false
        c.x, c.y = slotX[i], slotY
        sounds.play("deal", 0.9)
        if i == 5 then state = "holding"; focus = 1 end
      end)
  end
end

local function drawPhase()
  state = "drawing"
  local pending = 0
  for i = 1, 5 do
    if not hand[i].held then
      local c = table.remove(deck)
      c.held = false
      c.fx, c.fy = DECK.cx, DECK.cy
      c.fs, c.frot, c.fflip = DECK.scale, math.pi, 0
      c.flying = true
      hand[i] = c
      pending = pending + 1
      anim.tween(c, {fx = slotX[i] + theme.cardW / 2, fy = slotY + theme.cardH / 2,
                     fs = 1, frot = 0, fflip = 1},
        theme.dealTime + pending * theme.dealStep,
        function()
          c.flying = false
          c.x, c.y = slotX[i], slotY
          sounds.play("deal", 0.9)
        end)
    end
  end
end

local function settle()
  local key, name, idx = poker.evaluate(hand)
  local mult = poker.jacksOrBetter[key] or 0
  resultKey = key
  resultIdx = idx
  if mult > 0 then
    lastWin = BET * mult
    bankroll = bankroll + lastWin
    resultText = name .. "!"
    moneyMood = "win"
    sounds.play("win")
  else
    resultText = name                    -- calm, no exclamation, no "lose"
    moneyMood = "loss"
  end
  state = "result"
  confirmHeld = true            -- require a real release + press to deal again
end

function love.update(dt)
  readEdges()
  readTaps()
  anim.update(dt)

  if state == "drawing" and not anim.busy() then settle() end

  if state == "result" then
    -- A tap is a fresh press by construction, so it skips the pad's
    -- release gate: you cannot "still be holding" a tap from last hand.
    if tapIn(BTN.x, BTN.y, BTN.w, BTN.h, 24) then
      refillMsg = false
      dealHand()
      return
    end
    if confirmHeld then
      if not (love.pad.isDown("a") or love.pad.isDown("b")) then confirmHeld = false end
    elseif confirmPressed() then
      refillMsg = false
      dealHand()
    end
    return
  end

  if state == "idle" then
    if tapIn(BTN.x, BTN.y, BTN.w, BTN.h, 24) then
      dealHand()
      return
    end
    if confirmHeld then                 -- wait for the release after a skip
      if not (love.pad.isDown("a") or love.pad.isDown("b")) then confirmHeld = false end
    elseif confirmPressed() then
      dealHand()
    end
    return
  end

  if state == "holding" then
    if tapIn(BTN.x, BTN.y, BTN.w, BTN.h, 24) then
      drawPhase()
      return
    end
    if tapX then
      for i = 1, 5 do
        -- The rect tracks the draw position: a held card sits holdLift
        -- lower, and its tap target moves with it.
        local y = slotY + (hand[i].held and theme.holdLift or 0)
        if tapIn(slotX[i], y, theme.cardW, theme.cardH, 12) then
          focus = i
          hand[i].held = not hand[i].held
          sounds.play("place", 0.8)
          break
        end
      end
    end
    -- DOWN drops to the DRAW button (it sits below the cards, so down is
    -- the natural motion); UP climbs back to the middle card.
    if edges.down then focus = 0 end
    if edges.up and focus == 0 then focus = 3 end
    if edges.left then
      if focus == 0 then focus = 3
      else focus = focus - 1; if focus < 1 then focus = 5 end end
    end
    if edges.right then
      if focus == 0 then focus = 3
      else focus = focus + 1; if focus > 5 then focus = 1 end end
    end
    if confirmPressed() then
      if focus == 0 then
        drawPhase()
      else
        hand[focus].held = not hand[focus].held
        sounds.play("place", 0.8)
      end
    end
  end
end

-- Two columns, 5 + 4: half the height of the old single column, so the
-- top strip keeps clear air for the result banner. Values in win-green -
-- they're the good news - except inside the gold highlight, where ink
-- stays readable.
local function drawPaytable()
  local g = love.graphics
  g.setFont(ui.font(theme.fontMid))
  local step = theme.fontMid + 8
  -- column 2 is narrower so its dollar column ends before the title,
  -- which owns the top-right corner
  local colX, colW, perCol = {60, 700}, {560, 420}, 5
  for i, row in ipairs(poker.paytableRows) do
    local key, name, mult = row[1], row[2], row[3]
    local col = (i > perCol) and 2 or 1
    local x, w = colX[col], colW[col]
    local y = 36 + ((i - 1) % perCol) * step
    if resultKey == key then
      g.setColor(theme.gold)
      g.rectangle("fill", x - 12, y - 2, w + 24, step)
      g.setColor(theme.ink)
      g.print(name, x, y)
      g.printf("$" .. (mult * BET), x, y, w, "right")
    else
      g.setColor(theme.quiet)
      g.print(name, x, y)
      g.setColor(theme.win)
      g.printf("$" .. (mult * BET), x, y, w, "right")
    end
  end
end

function love.draw()
  local g = love.graphics

  drawPaytable()

  -- title
  g.setFont(ui.font(theme.fontBig))
  g.setColor(theme.gold)
  g.printf("JACKS OR BETTER", 0, 48, W - 320, "right")

  -- the deck pile (visible whenever cards remain to deal from)
  if deck and #deck > 0 then
    for d = 2, 0, -1 do
      cards.drawBackC(DECK.cx + d * 5, DECK.cy - d * 4, DECK.scale)
    end
  end

  -- pass 1: slots + landed cards (flights draw after, on top)
  for i = 1, 5 do
    local c = hand[i]
    if c and c.flying then
      g.setColor(theme.feltDark)
      g.rectangle("fill", slotX[i], slotY, theme.cardW, theme.cardH)
    elseif c then
      local y = c.y + (c.held and theme.holdLift or 0)
      cards.drawCard(c, c.x, y)
      if c.held then ui.heldBadge(c.x, y, theme.cardW) end
      if state == "holding" and focus == i then
        ui.focusRing(c.x, y, theme.cardW, theme.cardH)
      end
      if state == "result" and resultIdx and resultIdx[i] then
        ui.winRing(c.x, y, theme.cardW, theme.cardH)
      end
    else
      g.setColor(theme.feltDark)
      g.rectangle("fill", slotX[i], slotY, theme.cardW, theme.cardH)
    end
  end

  -- pass 2: in-flight cards over the shadow slots
  for i = 1, 5 do
    local c = hand[i]
    if c and c.flying then
      cards.drawFlight(c, c.fx, c.fy, c.fs, c.frot, c.fflip)
    end
  end

  -- the one button: hint first, button beneath it
  if state == "idle" or state == "result" then
    g.setFont(ui.font(theme.fontSmall))
    g.setColor(theme.dim)
    g.printf("tap DEAL - or press A", 0, HINT_Y, W, "center")
    ui.button("DEAL", BTN.x, BTN.y, BTN.w, BTN.h, true)
  elseif state == "holding" then
    g.setFont(ui.font(theme.fontSmall))
    g.setColor(theme.dim)
    g.printf("tap a card to hold it, then tap DRAW - or LEFT/RIGHT and A",
             0, HINT_Y, W, "center")
    ui.button("DRAW", BTN.x, BTN.y, BTN.w, BTN.h, focus == 0)
  end

  -- result banner: centered in the clear strip between paytable and cards
  if resultText then
    local up = lastWin > 0
    g.setFont(ui.font(up and theme.fontHuge or theme.fontBig))
    g.setColor(up and theme.win or theme.quiet)
    g.printf(resultText, 0, 276, W, "center")
  end
  if refillMsg then
    g.setFont(ui.font(theme.fontMid))
    g.setColor(theme.gold)
    g.printf("FRESH STACK - ON THE HOUSE", 0, 216, W, "center")
  end

  ui.drawMoney(bankroll, BET, lastWin, moneyMood)
end
