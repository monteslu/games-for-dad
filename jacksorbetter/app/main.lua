-- JACKS OR BETTER - video poker for Dad.
-- Whole control scheme: LEFT/RIGHT moves, A confirms. That's it.
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
BTN.x, BTN.y = (W - BTN.w) / 2, H - 240

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
  anim.update(dt)

  if state == "drawing" and not anim.busy() then settle() end

  if state == "result" then
    if confirmHeld then
      if not (love.pad.isDown("a") or love.pad.isDown("b")) then confirmHeld = false end
    elseif confirmPressed() then
      refillMsg = false
      dealHand()
    end
    return
  end

  if state == "idle" then
    if confirmHeld then                 -- wait for the release after a skip
      if not (love.pad.isDown("a") or love.pad.isDown("b")) then confirmHeld = false end
    elseif confirmPressed() then
      dealHand()
    end
    return
  end

  if state == "holding" then
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

local function drawPaytable()
  local g = love.graphics
  g.setFont(ui.font(theme.fontMid))
  local x, y = 60, 36
  local step = theme.fontMid + 8
  for _, row in ipairs(poker.paytableRows) do
    local key, name, mult = row[1], row[2], row[3]
    if resultKey == key then
      g.setColor(theme.gold)
      g.rectangle("fill", x - 12, y - 2, 700, step)
      g.setColor(theme.ink)
    else
      g.setColor(theme.quiet)
    end
    g.print(name, x, y)
    g.printf("$" .. (mult * BET), x, y, 620, "right")
    y = y + step
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

  -- the one button
  if state == "idle" or state == "result" then
    ui.button("DEAL", BTN.x, BTN.y, BTN.w, BTN.h, true)
    g.setFont(ui.font(theme.fontSmall))
    g.setColor(theme.dim)
    g.printf("press A to deal", 0, BTN.y + BTN.h + 12, W, "center")
  elseif state == "holding" then
    ui.button("DRAW", BTN.x, BTN.y, BTN.w, BTN.h, focus == 0)
    g.setFont(ui.font(theme.fontSmall))
    g.setColor(theme.dim)
    g.printf("LEFT/RIGHT choose a card - A holds it - DOWN then A to DRAW",
             0, BTN.y + BTN.h + 12, W, "center")
  end

  -- result banner: centered in the clear space RIGHT of the paytable
  if resultText then
    local up = lastWin > 0
    g.setFont(ui.font(up and theme.fontHuge or theme.fontBig))
    g.setColor(up and theme.win or theme.quiet)
    g.printf(resultText, 780, 220, W - 780 - 40, "center")
  end
  if refillMsg then
    g.setFont(ui.font(theme.fontMid))
    g.setColor(theme.gold)
    g.printf("FRESH STACK - ON THE HOUSE", 780, 150, W - 780 - 40, "center")
  end

  ui.drawMoney(bankroll, BET, lastWin, moneyMood)
end
