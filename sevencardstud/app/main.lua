-- SEVEN CARD STUD - heads-up against the dealer.
-- Structure: 2 down + 1 up, then three more up cards, a final DOWN card,
-- and showdown: best 5 of your 7. The best SHOWING hand opens the betting
-- on every street (the home rule - no casino bring-in). Dealer's three
-- hidden cards flip at the end.
-- Family law: LEFT/RIGHT + A. $1000, $5 flat, never busts, quiet losses.

local theme  = require("lib.theme")
local cards  = require("lib.cards")
local ui     = require("lib.ui")
local poker  = require("lib.poker")
local anim   = require("lib.anim")
local sounds = require("lib.sounds")

local BET = 5
local START_BANK = 1000
local N = 7

local W, H = 1920, 1080

-- ── layout: same table as 5-stud, cards sized down to seat seven ──────
local DEALER_IMG = nil
local PSCALE = 0.70
local DSCALE = 0.55
local dealSlotX, dealSlotY = {}, 240
local slotX, slotY = {}, 620
do
  local dw = theme.cardW * DSCALE
  local dgap = 20
  local DEAL_X0 = 217
  for i = 1, N do dealSlotX[i] = DEAL_X0 + (i - 1) * (dw + dgap) end
  local pw = theme.cardW * PSCALE
  local pgap = 26
  local LEFT_X = 118
  for i = 1, N do slotX[i] = LEFT_X + (i - 1) * (pw + pgap) end
end

local DECK = {scale = 0.55}
DECK.cx = 1440
DECK.cy = 170       -- clearly ABOVE the dealer's row, or it reads as his 8th card

local MENU = {}
-- gap sized so a 3-item menu FILLS the column: FOLD lands just above the
-- money row instead of leaving dead felt below
local MENU_X, MENU_Y0, MENU_W, MENU_H, MENU_GAP = 1600, 540, 300, 92, 80

-- ── state ─────────────────────────────────────────────────────────────
local bankroll = START_BANK
local state = "idle"
local pHand, dHand = {}, {}
local deck = nil
local street = 0         -- cards per side so far (3..7)
local staked = 0
local focus = 1
local resultText, resultColor = nil, nil
local winIdx = nil
local moneyMood = nil
local refillMsg = false
local dealerLine = nil
local actionLine = nil
local dealerFace = "normal"
local pendingBet = 0
local raisedThisStreet = false
local waitTimer = 0
local afterWait = nil

-- ── input: family readEdges (debounce + entropy stir) ─────────────────
local prevDown, edges, lastEdgeFrame, frameNo = {}, {}, {}, 0
local DEBOUNCE = 9
local AUTO = {}
local function readEdges()
  frameNo = frameNo + 1
  if AUTO[frameNo] then edges[AUTO[frameNo]] = true; prevDown[AUTO[frameNo]] = true; return end
  for _, b in ipairs({"a", "b", "left", "right", "up", "down"}) do
    local d = love.pad.isDown(b)
    local edge = d and not prevDown[b]
    if edge and (frameNo - (lastEdgeFrame[b] or -100)) < DEBOUNCE then edge = false end
    if edge then
      lastEdgeFrame[b] = frameNo
      cards.stir(frameNo)
    end
    edges[b] = edge
    prevDown[b] = d
  end
end
local function confirmPressed() return edges.b or edges.a end
local confirmHeld = false

-- Taps: poll ALL ten pointer slots (0 = mouse, 1-9 = touch fingers) - a
-- mouse-only read ignores every touch on a phone. Deliberately NOT
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

function love.load()
  cards.loadArt()
  sounds.loadAll()
  DEALER_IMG = {
    normal = love.graphics.newImage("dealer.png"),
    smirk  = love.graphics.newImage("dealer_smirk.png"),
    angry  = love.graphics.newImage("dealer_angry.png"),
  }
  love.graphics.setBackgroundColor(theme.felt[1], theme.felt[2], theme.felt[3])
end

local function flyCard(c, tx, ty, scale, faceUp, delay, onDone)
  c.fx, c.fy = DECK.cx, DECK.cy
  c.fs, c.frot, c.fflip = DECK.scale, math.pi, 0
  c.flying = true
  anim.tween(c, {fx = tx, fy = ty, fs = scale, frot = 0,
                 fflip = faceUp and 1 or 0},
    theme.dealTime + (delay or 0),
    function()
      c.flying = false
      c.faceUp = faceUp
      sounds.play("deal", 0.9)
      if onDone then onDone() end
    end)
end

local function flyTo(hand, i, faceUp, delay, onDone)
  local isDealer = hand == dHand
  local scale = isDealer and DSCALE or PSCALE
  local sx = isDealer and dealSlotX or slotX
  local sy = isDealer and dealSlotY or slotY
  local w = theme.cardW * scale
  local h = theme.cardH * scale
  local c = table.remove(deck)
  hand[i] = c
  flyCard(c, sx[i] + w / 2, sy + h / 2, scale, faceUp, delay, onDone)
end

-- showing cards are 3..6 (holes: 1, 2, and the 7th)
local function boardStrength(hand)
  local seen, pairV, highV = {}, 0, 0
  for i = 3, math.min(#hand, 6) do
    local v = cards.val[hand[i].rank]
    if seen[v] then pairV = math.max(pairV, v) end
    seen[v] = true
    if v > highV then highV = v end
  end
  if pairV > 0 then return {2, pairV} end
  return {1, highV}
end

local function dealerHas()
  local seen, pairV, highV = {}, 0, 0
  for i = 1, #dHand do
    local v = cards.val[dHand[i].rank]
    if seen[v] then pairV = math.max(pairV, v) end
    seen[v] = true
    if v > highV then highV = v end
  end
  return pairV, highV
end

local function playerActsFirst()
  -- The HIGH board opens every street, third included - the home rule,
  -- same as five stud. (The casino bring-in has the LOW door card open
  -- third street, which just looks wrong at the kitchen table.)
  local p, d = boardStrength(pHand), boardStrength(dHand)
  if p[1] ~= d[1] then return p[1] > d[1] end
  return p[2] >= d[2]
end

local function buildMenu(facingBet)
  MENU = {}
  if facingBet then
    MENU[1] = {label = "CALL  $" .. pendingBet, act = "call"}
    if not raisedThisStreet then MENU[2] = {label = "RAISE  $" .. BET, act = "raise"} end
    MENU[#MENU + 1] = {label = "FOLD", act = "fold"}
  else
    MENU[1] = {label = "CHECK", act = "check"}
    MENU[2] = {label = "BET  $" .. BET, act = "bet"}
    MENU[3] = {label = "FOLD", act = "fold"}
  end
  focus = 1
end

local function pause(frames, fn) waitTimer = frames; afterWait = fn end

local advanceStreet

local function dealerOpens()
  local pairV, highV = dealerHas()
  if pairV > 0 or highV >= 13 then
    pendingBet = BET
    actionLine = "DEALER BETS $" .. BET
    sounds.play("chips", 0.7)
    pause(30, function() state = "decide"; buildMenu(true) end)
  else
    actionLine = "DEALER CHECKS"
    pause(30, function() state = "decide"; buildMenu(false) end)
  end
end

local function dealerResponds(amount)
  local pairV, highV = dealerHas()
  if pairV == 0 and highV <= 11 then
    actionLine = "DEALER FOLDS"
    pause(40, function()
      bankroll = bankroll + staked * 2
      dealerFace = "angry"
      resultText = "DEALER FOLDS - YOU WIN!"
      resultColor = theme.win
      moneyMood = "win"
      sounds.play("win")
      state = "result"; confirmHeld = true
    end)
  elseif pairV >= 9 and not raisedThisStreet and amount == BET then
    raisedThisStreet = true
    -- the raise costs the player nothing until he CALLS (which charges
    -- pendingBet with stake credit); charging here loses the $5 twice
    actionLine = "DEALER RAISES $" .. BET
    sounds.play("chips", 0.8)
    pendingBet = BET
    pause(34, function() state = "decide"; buildMenu(true) end)
  else
    actionLine = "DEALER CALLS"
    sounds.play("chips", 0.6)
    pause(30, function() advanceStreet() end)
  end
end

advanceStreet = function()
  pendingBet = 0
  raisedThisStreet = false
  actionLine = nil
  if street == 7 then state = "showdown"
  else state = "street_deal" end
end

local function dealerUpLine()
  local up = {}
  for i = 3, math.min(#dHand, 6) do up[#up + 1] = dHand[i] end
  if #up == 0 then return nil end
  local names = {["T"]="10",["J"]="JACK",["Q"]="QUEEN",["K"]="KING",["A"]="ACE"}
  local best, bestV = nil, 0
  local seen, pairR = {}, nil
  for _, c in ipairs(up) do
    if seen[c.rank] then pairR = c.rank end
    seen[c.rank] = true
    if cards.val[c.rank] > bestV then bestV = cards.val[c.rank]; best = c.rank end
  end
  local function pretty(r) return names[r] or r end
  if pairR then return "DEALER SHOWS A PAIR OF " .. pretty(pairR) .. "S" end
  return "DEALER SHOWS " .. pretty(best) .. " HIGH"
end

local function startHand()
  if bankroll < BET then bankroll = START_BANK; refillMsg = true end
  bankroll = bankroll - BET
  staked = BET
  moneyMood = nil
  resultText, winIdx, dealerLine, actionLine = nil, nil, nil, nil
  dealerFace = "normal"
  sounds.play("shuffle")
  sounds.play("chips", 0.6)
  deck = cards.newDeck()
  pHand, dHand = {}, {}
  street = 3
  state = "dealing"
  -- third street: two down + one up each (player sees his own holes)
  flyTo(dHand, 1, false, 0)
  flyTo(pHand, 1, true,  theme.dealStep)
  flyTo(dHand, 2, false, theme.dealStep * 2)
  flyTo(pHand, 2, true,  theme.dealStep * 3)
  flyTo(dHand, 3, true,  theme.dealStep * 4)
  flyTo(pHand, 3, true,  theme.dealStep * 5, function()
    dealerLine = dealerUpLine()
    if playerActsFirst() then
      state = "decide"; buildMenu(false)
    else
      state = "dealer_act"
      pause(24, dealerOpens)
    end
  end)
end

local function nextStreet()
  street = street + 1
  state = "dealing"
  local i = street
  local up = street < 7        -- seventh street lands face-down
  flyTo(dHand, i, up, 0)
  flyTo(pHand, i, true, theme.dealStep, function()
    dealerLine = (street == 7) and "DOWN AND DIRTY" or dealerUpLine()
    if playerActsFirst() then
      state = "decide"; buildMenu(false)
    else
      state = "dealer_act"
      pause(24, dealerOpens)
    end
  end)
end

local function bestCards(hand)
  local k, nm, idxSet = poker.best5(hand)
  local list = {}
  for i = 1, N do if idxSet[i] then list[#list + 1] = hand[i] end end
  return list
end

local function showdown()
  -- flip the dealer's three hidden cards in sequence
  local hidden = {1, 2, 7}
  for n, i in ipairs(hidden) do
    local c = dHand[i]
    if c and not c.faceUp then
      local w = theme.cardW * DSCALE
      local h = theme.cardH * DSCALE
      c.flying = true
      c.fx, c.fy = dealSlotX[i] + w / 2, dealSlotY + h / 2
      c.fs, c.frot, c.fflip = DSCALE, 0, 0
      anim.tween(c, {fflip = 1, fs = DSCALE * 1.05}, 0.45 + (n - 1) * 0.25, function()
        c.flying = false; c.faceUp = true
        sounds.play("place")
      end)
    end
  end
  pause(80, function()
    local _, pName, pIdx = poker.best5(pHand)
    local _, dName, dIdx = poker.best5(dHand)
    local cmp = poker.compare(bestCards(pHand), bestCards(dHand))
    if cmp > 0 then
      bankroll = bankroll + staked * 2
      dealerFace = "angry"
      resultText = "YOU WIN - " .. pName .. "!"
      resultColor = theme.win
      moneyMood = "win"
      winIdx = {p = pIdx}
      sounds.play("win")
    elseif cmp < 0 then
      dealerFace = "smirk"
      resultText = "DEALER WINS - " .. dName
      resultColor = theme.quiet
      moneyMood = "loss"
      winIdx = {d = dIdx}
    else
      bankroll = bankroll + staked
      resultText = "PUSH - " .. pName
      resultColor = theme.quiet
      winIdx = {p = pIdx, d = dIdx}
    end
    state = "result"
    confirmHeld = true
  end)
end

local function fold()
  dealerFace = "smirk"
  actionLine = nil
  resultText = "FOLDED"
  resultColor = theme.quiet
  moneyMood = "loss"
  dealerLine = nil
  state = "result"
  confirmHeld = true
end

function love.update(dt)
  readEdges()
  readTaps()
  anim.update(dt)

  if waitTimer > 0 then
    waitTimer = waitTimer - 1
    if waitTimer == 0 and afterWait then
      local fn = afterWait; afterWait = nil; fn()
    end
    return
  end

  if state == "street_deal" then
    nextStreet()
    return
  end

  if state == "showdown" and not anim.busy() then
    state = "showdown_run"
    showdown()
    return
  end

  if state == "idle" or state == "result" then
    if confirmHeld then
      if not (love.pad.isDown("a") or love.pad.isDown("b")) then confirmHeld = false end
    elseif confirmPressed() or tapIn(1600, 540, 300, 96, 24) then
      refillMsg = false
      startHand()
    end
    return
  end

  if state == "decide" then
    if edges.left or edges.up then
      focus = focus - 1; if focus < 1 then focus = #MENU end
    end
    if edges.right or edges.down then
      focus = focus + 1; if focus > #MENU then focus = 1 end
    end
    local tapped = nil
    for i = 1, #MENU do
      if tapIn(MENU_X, MENU_Y0 + (i - 1) * (MENU_H + MENU_GAP),
               MENU_W, MENU_H, 12) then
        tapped = i
      end
    end
    if tapped then focus = tapped end
    if (confirmPressed() or tapped) and MENU[focus] then
      local act = MENU[focus].act
      -- INSTANT feedback: the press lands on screen (and in the ear) the
      -- same frame, BEFORE the dealer starts thinking - a silent half
      -- second after a tap reads as a dead button
      if act == "check" then
        actionLine = "YOU CHECK"
        sounds.play("place", 0.6)
      elseif act == "bet" then
        actionLine = "YOU BET $" .. BET
      elseif act == "raise" then
        actionLine = "YOU RAISE $" .. BET
      elseif act == "call" then
        actionLine = "YOU CALL"
      end
      if act == "check" then
        state = "dealer_act"
        pause(24, function()
          local pairV, highV = dealerHas()
          if pairV > 0 or highV >= 13 then
            pendingBet = BET
            actionLine = "DEALER BETS $" .. BET
            sounds.play("chips", 0.7)
            pause(30, function() state = "decide"; buildMenu(true) end)
          else
            actionLine = "DEALER CHECKS"
            pause(26, advanceStreet)
          end
        end)
      elseif act == "bet" or act == "raise" then
        bankroll = bankroll - (pendingBet + BET)
        staked = staked + pendingBet + BET
        pendingBet = 0
        sounds.play("chips", 0.8)
        state = "dealer_act"
        pause(28, function() dealerResponds(BET) end)
      elseif act == "call" then
        bankroll = bankroll - pendingBet
        staked = staked + pendingBet
        pendingBet = 0
        sounds.play("chips", 0.6)
        state = "dealer_act"
        pause(22, advanceStreet)
      else
        fold()
      end
    end
  end
end

local function drawCardRow(hand, sx, sy, scale)
  for i = 1, N do
    local c = hand[i]
    local w = theme.cardW * scale
    local h = theme.cardH * scale
    if c and not c.flying and c.faceUp then
      cards.drawCard(c, sx[i], sy, scale)
    elseif c and not c.flying then
      cards.drawBackC(sx[i] + w / 2, sy + h / 2, scale)
    else
      love.graphics.setColor(theme.feltDark)
      love.graphics.rectangle("fill", sx[i], sy, w, h)
    end
  end
end

local function drawFlights(hand)
  for i = 1, N do
    local c = hand[i]
    if c and c.flying then
      cards.drawFlight(c, c.fx, c.fy, c.fs, c.frot, c.fflip)
    end
  end
end

function love.draw()
  local g = love.graphics

  if DEALER_IMG then
    g.setColor(1, 1, 1)
    g.draw(DEALER_IMG[dealerFace] or DEALER_IMG.normal, 1540, 100)
  end

  g.setFont(ui.font(theme.fontBig))
  g.setColor(theme.gold)
  g.print("7 CARD STUD", 60, 48)

  if deck and #deck > 0 then
    for d = 2, 0, -1 do
      cards.drawBackC(DECK.cx + d * 5, DECK.cy - d * 4, DECK.scale)
    end
  end

  if #dHand > 0 then drawCardRow(dHand, dealSlotX, dealSlotY, DSCALE) end
  drawCardRow(pHand, slotX, slotY, PSCALE)
  drawFlights(dHand)
  drawFlights(pHand)

  if winIdx then
    if winIdx.p then
      local w, h = theme.cardW * PSCALE, theme.cardH * PSCALE
      for i = 1, N do
        if winIdx.p[i] and pHand[i] then ui.winRing(slotX[i], slotY, w, h) end
      end
    end
    if winIdx.d then
      local w, h = theme.cardW * DSCALE, theme.cardH * DSCALE
      for i = 1, N do
        if winIdx.d[i] and dHand[i] then ui.winRing(dealSlotX[i], dealSlotY, w, h) end
      end
    end
  end

  if state == "decide" then
    for i, m in ipairs(MENU) do
      ui.button(m.label, MENU_X, MENU_Y0 + (i - 1) * (MENU_H + MENU_GAP),
                MENU_W, MENU_H, focus == i)
    end
  elseif state == "idle" or state == "result" then
    ui.button("DEAL", 1600, 540, 300, 96, true)
    g.setFont(ui.font(theme.fontSmall))
    g.setColor(theme.dim)
    g.printf("tap DEAL - or press A", 1600, 648, 300, "center")
  end

  if dealerLine and state ~= "result" then
    g.setFont(ui.font(theme.fontSmall))
    g.setColor(theme.dim)
    g.printf(dealerLine, 60, 490, 1400, "center")
  end
  if actionLine and state ~= "result" then
    g.setFont(ui.font(theme.fontMid))
    g.setColor(theme.white)
    g.printf(actionLine, 60, 530, 1400, "center")
  end
  if resultText then
    g.setFont(ui.font(theme.fontBig))
    g.setColor(resultColor or theme.white)
    g.printf(resultText, 60, 510, 1400, "center")
  end
  if refillMsg then
    g.setFont(ui.font(theme.fontMid))
    g.setColor(theme.gold)
    g.printf("FRESH STACK - ON THE HOUSE", 60, 462, 1400, "center")
  end

  -- money row: everything stays LEFT of the button column
  g.setFont(ui.font(theme.fontBig))
  if moneyMood == "win" then g.setColor(theme.winRing)
  elseif moneyMood == "loss" then g.setColor(theme.lossRed)
  else g.setColor(theme.white) end
  g.print("BANKROLL  $" .. bankroll, 60, H - 70)
  g.setColor(theme.quiet)
  g.print("BET  $" .. BET, 700, H - 70)
  if staked > 0 and state ~= "idle" then
    g.setColor(theme.gold)
    g.print("POT  $" .. (staked * 2), 1120, H - 70)
  end
end
