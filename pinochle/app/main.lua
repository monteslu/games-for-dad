-- PINOCHLE - partnership pinochle: you and PARTNER (north) against WEST
-- and EAST. 48 cards, bid for the contract, name trump, lay down meld,
-- then twelve tricks. First team to 1500.
--
-- Controls: LEFT/RIGHT moves the gold cursor (only legal cards), A (south
-- or east button) confirms. Touch is an equal path everywhere: tap a legal
-- card then PLAY, or tap the big buttons directly.
--
-- Deliberately shaped after spades/main.lua -- same seats, same input
-- pattern, same state machine, same layout zones -- because the whole
-- point of a second trick-taking game is that it feels like the first one
-- he already knows. See docs/PINOCHLE.md.

local theme   = require("lib.theme")
local cards   = require("lib.cards")
local ui      = require("lib.ui")
local anim    = require("lib.anim")
local sounds  = require("lib.sounds")
local rules   = require("rules")
local meld    = require("meld")
local scoring = require("scoring")
local bot     = require("bot")

local W, H = 1920, 1080
local NAME = rules.NAME

local SPEED = rawget(_G, "PINOCHLE_FAST") and 0.28 or 1
local function T(sec) return sec * SPEED end

-- ── layout ────────────────────────────────────────────────────────────
-- Twelve cards to a hand rather than thirteen, so the fan is a little
-- tighter than spades' and the step is wider.
local SOUTH_Y, SOUTH_STEP, LIFT = 620, 112, 44
local CPU_SCALE = 0.42
local CPU_W, CPU_H = theme.cardW * CPU_SCALE, theme.cardH * CPU_SCALE
local NORTH_Y, NORTH_STEP = 50, 36
local WEST_X, EAST_X, SIDE_STEP = 40, W - 40 - CPU_W, 26
local TRICK_SCALE = 0.6
local TRICK_POS = {
  [1] = {960, 500}, [2] = {815, 455}, [3] = {960, 380}, [4] = {1105, 455},
}
local ORIGIN = {
  [1] = {960, SOUTH_Y + theme.cardH / 2},
  [2] = {WEST_X + CPU_W / 2, H / 2},
  [3] = {960, NORTH_Y + CPU_H / 2},
  [4] = {EAST_X + CPU_W / 2, H / 2},
}
local DECK_POS = {960, 455}

-- THE FAN STEP IS DERIVED, NOT FIXED. A hand is normally twelve cards,
-- but during the pass the declarer briefly holds SIXTEEN -- and at the
-- twelve-card step of 112 that is 1940px on a 1920px screen, so the hand
-- ran off both edges. Squeeze to fit whatever is held, never past the
-- comfortable step.
local FAN_MAX_W = 1760
local function southStep(n)
  if n <= 1 then return SOUTH_STEP end
  local fit = (FAN_MAX_W - theme.cardW) / (n - 1)
  return math.min(SOUTH_STEP, fit)
end

local function southStartX(n) return (W - ((n - 1) * southStep(n) + theme.cardW)) / 2 end
local function northStartX(n) return (W - ((n - 1) * NORTH_STEP + CPU_W)) / 2 end
local function sideStartY(n) return (H - ((n - 1) * SIDE_STEP + CPU_H)) / 2 end

local PLAY_BTN = {x = 1540, y = 440, w = 220, h = 110}
local DEAL_BTN = {x = 810, y = 500, w = 300, h = 96}

-- ── state ─────────────────────────────────────────────────────────────
local state = "idle"
-- idle|dealing|bid_wait|bid_pick|trump_pick|meld_show|cpu_think|play_pick|
-- anim_play|trick_pause|sweep|hand_result|game_over
local STATE_ID = { idle = 1, dealing = 2, bid_wait = 3, bid_pick = 4,
  trump_pick = 5, meld_show = 6, cpu_think = 7, play_pick = 8,
  anim_play = 9, trick_pause = 10, sweep = 11, hand_result = 12,
  game_over = 13, pass_pick = 14, pass_wait = 15 }

local hands = {{}, {}, {}, {}}
local teamScore = {0, 0}
local teamMeld, teamTricks = {0, 0}, {0, 0}
local meldList = {{}, {}, {}, {}}
local trick = {}
local leader, turn = 2, 2
local trump = nil
local highBid, declarer = nil, nil
local passed = {false, false, false, false}
local tricksPlayed = 0
local announce = nil
local ringSeat = nil
local bidSel, suggested = scoring.MIN_BID, scoring.MIN_BID
local trumpSel = 1
-- THE PASS. After trump is named the declarer's partner sends four cards
-- across and the declarer sends four back. passSel is the human's current
-- selection; passDir says which half of the exchange we are in.
local passSel = {}          -- set of hand indices, at most PASS_N
local passDir = nil         -- "send" (we are the partner) | "return" (we declare)
local legalIdx, focusPos = {}, 1
local result, gameOverData, moodUs = nil, nil, nil
local deck, landedCount = nil, 0
local waitTimer, afterWait = 0, nil
local sched = {}

local AGGRO = {[2] = -0.2, [3] = 0.1, [4] = 0.2}
local SUITS = {"S", "H", "C", "D"}
local SUIT_LABEL = {S = "SPADES", H = "HEARTS", C = "CLUBS", D = "DIAMONDS"}
-- SUIT PIPS ARE DRAWN, NOT TYPED. Atkinson Hyperlegible has no glyphs at
-- U+2660..2666 -- checked, all four are absent -- so a printf of the
-- character renders NOTHING at all, silently. That is the same trap the
-- family rule about the dollar sign exists for, in a new costume.
local SUIT_RED = {H = true, D = true}
local function suitColor(s)
  if SUIT_RED[s] then return 0.85, 0.20, 0.22 else return 0.94, 0.94, 0.96 end
end

-- A pip, centred on (cx, cy), sized to r. Polygons and circles only, so
-- it needs no art and scales to any panel.
local function drawPip(s, cx, cy, r)
  local g = love.graphics
  g.setColor(suitColor(s))
  if s == "D" then
    g.polygon("fill", cx, cy - r, cx + r * 0.72, cy, cx, cy + r, cx - r * 0.72, cy)
  elseif s == "H" then
    g.circle("fill", cx - r * 0.42, cy - r * 0.30, r * 0.52)
    g.circle("fill", cx + r * 0.42, cy - r * 0.30, r * 0.52)
    g.polygon("fill", cx - r * 0.92, cy - r * 0.10, cx + r * 0.92, cy - r * 0.10, cx, cy + r)
  elseif s == "S" then
    g.polygon("fill", cx, cy - r, cx + r * 0.82, cy + r * 0.22, cx - r * 0.82, cy + r * 0.22)
    g.circle("fill", cx - r * 0.40, cy + r * 0.20, r * 0.44)
    g.circle("fill", cx + r * 0.40, cy + r * 0.20, r * 0.44)
    g.polygon("fill", cx - r * 0.16, cy + r * 0.24, cx + r * 0.16, cy + r * 0.24,
                      cx + r * 0.34, cy + r, cx - r * 0.34, cy + r)
  else -- clubs
    g.circle("fill", cx, cy - r * 0.42, r * 0.46)
    g.circle("fill", cx - r * 0.48, cy + r * 0.20, r * 0.46)
    g.circle("fill", cx + r * 0.48, cy + r * 0.20, r * 0.46)
    g.polygon("fill", cx - r * 0.16, cy + r * 0.20, cx + r * 0.16, cy + r * 0.20,
                      cx + r * 0.34, cy + r, cx - r * 0.34, cy + r)
  end
end

local debugValue = love.debugValue or function() end

local function setAnnounce(t, c) announce = {text = t, c = c or theme.white} end

local function pause(frames, fn)
  waitTimer = math.max(1, math.floor(frames * SPEED))
  afterWait = fn
end

local function after(frames, fn)
  sched[#sched + 1] = {t = math.max(1, math.floor(frames * SPEED)), fn = fn}
end

-- ── input: the family readEdges pattern ───────────────────────────────
local prevDown, edges, lastEdgeFrame, frameNo = {}, {}, {}, 0
local DEBOUNCE = 9
local function readEdges()
  frameNo = frameNo + 1
  for k in pairs(edges) do edges[k] = nil end
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

-- Touch as an equal path, never a replacement: poll ALL ten pointer slots,
-- since a mouse-only read silently ignores every finger on a tablet.
local prevPtr, click = {}, nil
local function readClicks()
  click = nil
  local ptr = rawget(_G, "wc") and wc.pointer
  if not ptr then return end
  for slot = 0, 9 do
    local x, y, buttons, active = ptr(slot)
    local down = (active and buttons ~= 0) or false
    if down and not prevPtr[slot] and not click then
      click = {x = x, y = y}
      cards.stir(frameNo)
    end
    prevPtr[slot] = down
  end
end
local function clicked(r)
  return click ~= nil and click.x >= r.x and click.x < r.x + r.w
     and click.y >= r.y and click.y < r.y + r.h
end

function love.load()
  cards.loadArt()
  sounds.loadAll()
  love.graphics.setBackgroundColor(theme.felt[1], theme.felt[2], theme.felt[3])
end

local function relayoutSouth()
  local n = #hands[1]
  local x, st = southStartX(n), southStep(n)
  for i, c in ipairs(hands[1]) do
    c.sx = x + (i - 1) * st
  end
end

local advanceTurn, endTrick

-- ── the pass ──────────────────────────────────────────────────────────
--
-- Four cards each way, after trump is named and before meld -- which is
-- the only order that works: you cannot choose cards without knowing
-- trump, and the exchange changes what melds.
local function moveCards(from, to, idx)
  table.sort(idx, function(a, b) return a > b end)   -- remove high-first
  local moved = {}
  for _, i in ipairs(idx) do
    moved[#moved + 1] = table.remove(from, i)
  end
  for _, c in ipairs(moved) do to[#to + 1] = c end
  return moved
end

local beginReturn, finishPass

-- The chosen indices, always in ascending order so moveCards can reverse
-- them safely.
local function selectedPass()
  local t = {}
  for i in pairs(passSel) do t[#t + 1] = i end
  table.sort(t)
  return t
end

-- Start the exchange. The DECLARER'S PARTNER sends first, always -- the
-- declarer needs to see what arrived before deciding what to send back,
-- which is the standard sequential pass rather than the blind variant.
local function beginPass()
  passSel = {}
  local partner = rules.partner(declarer)
  if partner == 1 then
    -- the human is the partner: he chooses what to arm the declarer with
    passDir = "send"
    announce = nil            -- the panel says it; the lane sits behind it
    state = "pass_pick"
  else
    passDir = nil
    state = "pass_wait"
    setAnnounce(NAME[partner] .. " IS PASSING", theme.quiet)
    pause(50, function()
      local idx = bot.choosePass(hands[partner], trump)
      moveCards(hands[partner], hands[declarer], idx)
      rules.sortHand(hands[declarer], trump)
      if declarer == 1 then relayoutSouth() end
      sounds.play("deal", 0.8)
      beginReturn()
    end)
  end
end

-- The second half: the declarer returns four.
beginReturn = function()
  passSel = {}
  if declarer == 1 then
    passDir = "return"
    announce = nil            -- the panel says it; the lane sits behind it
    rules.sortHand(hands[1], trump)
    relayoutSouth()
    state = "pass_pick"
  else
    passDir = nil
    state = "pass_wait"
    setAnnounce(NAME[declarer] .. " IS PASSING BACK", theme.quiet)
    pause(50, function()
      local idx = bot.chooseReturn(hands[declarer], trump)
      moveCards(hands[declarer], hands[rules.partner(declarer)], idx)
      local p = rules.partner(declarer)
      rules.sortHand(hands[p], trump)
      if p == 1 then relayoutSouth() end
      sounds.play("deal", 0.8)
      finishPass()
    end)
  end
end

-- ── meld, once trump is known ─────────────────────────────────────────
local function layMeld()
  teamMeld = {0, 0}
  for s = 1, 4 do
    local pts, list = meld.score(hands[s], trump)
    meldList[s] = list
    teamMeld[rules.teamOf(s)] = teamMeld[rules.teamOf(s)] + pts
  end
  -- The announce lane sits at y=232, which is inside the meld panel --
  -- so "TRUMP IS SPADES" was being drawn UNDER the word MELD. The panel
  -- names trump itself, so the line has done its job by now.
  announce = nil
  -- Sorting again now that trump is known puts it leftmost, which is what
  -- a player wants to see when deciding what to lead.
  rules.sortHand(hands[1], trump)
  relayoutSouth()
  sounds.play("chips", 0.7)
  state = "meld_show"
  confirmHeld = true
end

finishPass = function()
  passDir, passSel = nil, {}
  announce = nil
  -- EVERY HAND MUST BE BACK TO TWELVE. A pass that dropped or duplicated a
  -- card would be invisible until someone ran out mid-trick, so check here
  -- where it is cheap and obvious.
  for s = 1, 4 do
    if #hands[s] ~= 12 then
      setAnnounce("PASS ERROR: seat " .. s .. " has " .. #hands[s], theme.lossRed)
    end
  end
  layMeld()
end

local function startPlay()
  announce = nil
  leader, turn = declarer, declarer
  advanceTurn()
end

-- ── bidding ───────────────────────────────────────────────────────────
local function beginBidding()
  state = "bid_wait"
  highBid, declarer = nil, nil
  passed = {false, false, false, false}

  -- West opens (left of the permanent dealer, who is south), then round
  -- the table. Dad bids LAST, exactly as in spades: he always decides
  -- with every other bid already on the table.
  local seq, i = {2, 3, 4}, 1
  local function step()
    local seat = seq[i]
    pause(44, function()
      local b, suit = bot.suggestBid(hands[seat],
        {aggro = AGGRO[seat], highBid = highBid})
      if b then
        highBid, declarer = b, seat
        hands[seat].wantTrump = suit
        setAnnounce(NAME[seat] .. " BIDS " .. b)
      else
        passed[seat] = true
        setAnnounce(NAME[seat] .. " PASSES", theme.quiet)
      end
      sounds.play("place", 0.7)
      i = i + 1
      if seq[i] then step()
      else
        pause(38, function()
          local s = bot.suggestBid(hands[1], {highBid = highBid})
          suggested = s or scoring.MIN_BID
          bidSel = math.max(suggested, (highBid or scoring.MIN_BID - 10) + 10)
          state = "bid_pick"
        end)
      end
    end)
  end
  step()
end

local function startHand()
  trick, tricksPlayed = {}, 0
  trump, highBid, declarer = nil, nil, nil
  teamMeld, teamTricks = {0, 0}, {0, 0}
  meldList = {{}, {}, {}, {}}
  announce, ringSeat, result, moodUs = nil, nil, nil, nil
  landedCount = 0
  sounds.play("shuffle")
  deck = rules.newDeck()
  for seat = 1, 4 do
    hands[seat] = {}
    for _ = 1, 12 do hands[seat][#hands[seat] + 1] = table.remove(deck) end
    rules.sortHand(hands[seat])
  end
  state = "dealing"

  -- FOUR AT A TIME, which is how pinochle is dealt and how it looks right:
  -- packets, not one card round the table twelve times.
  local n = 0
  for packet = 0, 2 do
    for _, seat in ipairs({2, 3, 4, 1}) do
      for k = 1, 4 do
        local r = packet * 4 + k
        n = n + 1
        local c = hands[seat][r]
        local south = (seat == 1)
        local tx, ty, ts
        if south then
          c.sx = southStartX(12) + (r - 1) * southStep(12)
          tx, ty, ts = c.sx + theme.cardW / 2, SOUTH_Y + theme.cardH / 2, 1
        elseif seat == 3 then
          tx, ty, ts = northStartX(12) + (r - 1) * NORTH_STEP + CPU_W / 2,
                       NORTH_Y + CPU_H / 2, CPU_SCALE
        else
          local x = (seat == 2) and WEST_X or EAST_X
          tx, ty, ts = x + CPU_W / 2,
                       sideStartY(12) + (r - 1) * SIDE_STEP + CPU_H / 2, CPU_SCALE
        end
        after(3 * (n - 1) + 1, function()
          c.fx, c.fy = DECK_POS[1], DECK_POS[2]
          c.fs, c.frot, c.fflip = 0.55, 0, 0
          c.flying = true
          anim.tween(c, {fx = tx, fy = ty, fs = ts, fflip = south and 1 or 0},
            T(0.30), function()
              c.flying = false
              c.dealt = true
              c.faceUp = south
              landedCount = landedCount + 1
              if landedCount % 4 == 0 then sounds.play("deal", 0.8) end
              if landedCount == 48 then beginBidding() end
            end)
        end)
      end
    end
  end
end

-- ── trick play ────────────────────────────────────────────────────────
local function playCard(seat, idx)
  local c = hands[seat][idx]
  if #trick == 0 then announce = nil end
  table.remove(hands[seat], idx)
  trick[#trick + 1] = {seat = seat, card = c}
  if seat == 1 then relayoutSouth() end
  local pos = TRICK_POS[seat]
  c.fx, c.fy = ORIGIN[seat][1], ORIGIN[seat][2]
  c.fs = (seat == 1) and 1 or CPU_SCALE
  c.frot, c.fflip = 0, (seat == 1) and 1 or 0
  c.flying = true
  state = "anim_play"
  anim.tween(c, {fx = pos[1], fy = pos[2], fs = TRICK_SCALE, fflip = 1},
    T(0.32), function()
      c.flying = false
      c.faceUp = true
      sounds.play("place", 0.8)
      if #trick == 4 then endTrick()
      else
        turn = rules.nextSeat(seat)
        advanceTurn()
      end
    end)
end

advanceTurn = function()
  if turn == 1 then
    legalIdx = rules.legalPlays(hands[1], trick, trump)
    focusPos = 1
    state = "play_pick"
  else
    state = "cpu_think"
    pause(28 + (turn * 7) % 14, function()
      playCard(turn, bot.choosePlay(hands[turn], {
        trump = trump, trick = trick, seat = turn,
        partnerSeat = rules.partner(turn), tricksLeft = 12 - tricksPlayed }))
    end)
  end
end

local function scoreHand()
  local dt = rules.teamOf(declarer)
  local ot = 3 - dt
  local rd = scoring.scoreTeam{ bid = highBid, meld = teamMeld[dt], tricks = teamTricks[dt] }
  local ro = scoring.scoreTeam{ meld = teamMeld[ot], tricks = teamTricks[ot] }
  teamScore[dt] = teamScore[dt] + rd.delta
  teamScore[ot] = teamScore[ot] + ro.delta
  local usDelta = (dt == 1) and rd.delta or ro.delta
  moodUs = (usDelta > 0 and "win") or (usDelta < 0 and "loss") or nil
  result = { dt = dt, rd = rd, ro = ro }
  if usDelta > 0 then sounds.play("win") end
  local w = scoring.winner(teamScore, dt)
  if w then
    gameOverData = { us = teamScore[1], them = teamScore[2], weWin = (w == 1) }
  end
  state = "hand_result"
  confirmHeld = true
end

endTrick = function()
  local winner = rules.trickWinner(trick, trump)
  ringSeat = winner
  local pts = 0
  for _, p in ipairs(trick) do pts = pts + rules.counter[p.card.rank] end
  if tricksPlayed == 11 then pts = pts + rules.LAST_TRICK end
  teamTricks[rules.teamOf(winner)] = teamTricks[rules.teamOf(winner)] + pts
  setAnnounce(NAME[winner] .. ((winner == 1) and " TAKE IT" or " TAKES IT")
              .. (pts > 0 and ("  +" .. pts) or ""),
              rules.teamOf(winner) == 1 and theme.win or theme.quiet)
  sounds.play("chips", 0.7)
  state = "trick_pause"
  pause(58, function()
    state = "sweep"
    local done = 0
    for _, p in ipairs(trick) do
      local c = p.card
      c.flying = true
      anim.tween(c, {fx = ORIGIN[winner][1], fy = ORIGIN[winner][2], fs = 0.2},
        T(0.28), function()
          done = done + 1
          if done == #trick then
            trick = {}
            ringSeat, announce = nil, nil
            tricksPlayed = tricksPlayed + 1
            leader, turn = winner, winner
            if tricksPlayed == 12 then scoreHand()
            else pause(12, advanceTurn) end
          end
        end)
    end
  end)
end

-- ── update ────────────────────────────────────────────────────────────
function love.update(dt)
  readEdges()
  readClicks()
  anim.update(dt)

  for i = #sched, 1, -1 do
    local s = sched[i]
    s.t = s.t - 1
    if s.t <= 0 then table.remove(sched, i); s.fn() end
  end

  if waitTimer > 0 then
    waitTimer = waitTimer - 1
    if waitTimer == 0 and afterWait then
      local fn = afterWait
      afterWait = nil
      fn()
    end

  elseif state == "idle" or state == "hand_result" or state == "game_over" then
    if confirmHeld then
      if not (love.pad.isDown("a") or love.pad.isDown("b")) and not confirmPressed() then
        confirmHeld = false
      end
    elseif confirmPressed()
        or (state == "idle" and clicked(DEAL_BTN))
        or (state ~= "idle" and click ~= nil) then
      confirmHeld = true
      if state == "game_over" then
        teamScore = {0, 0}
        gameOverData, result = nil, nil
        state = "idle"
      elseif state == "hand_result" and gameOverData then
        state = "game_over"
      else
        startHand()
      end
    end

  elseif state == "meld_show" then
    if confirmHeld then
      if not (love.pad.isDown("a") or love.pad.isDown("b")) and not confirmPressed() then
        confirmHeld = false
      end
    elseif confirmPressed() or click ~= nil then
      confirmHeld = true
      startPlay()
    end

  elseif state == "bid_pick" then
    local floor = (highBid or (scoring.MIN_BID - scoring.BID_STEP)) + scoring.BID_STEP
    if edges.left then bidSel = math.max(floor - scoring.BID_STEP, bidSel - scoring.BID_STEP) end
    if edges.right then bidSel = math.min(600, bidSel + scoring.BID_STEP) end
    -- fat tap zones: a whole third of the panel steps the bid, because
    -- fingers are blunter than cursors
    if click then
      if clicked({x = 580, y = 250, w = 240, h = 300}) then
        bidSel = math.max(floor - scoring.BID_STEP, bidSel - scoring.BID_STEP)
        sounds.play("place", 0.4)
      elseif clicked({x = 1100, y = 250, w = 240, h = 300}) then
        bidSel = math.min(600, bidSel + scoring.BID_STEP)
        sounds.play("place", 0.4)
      end
    end
    if confirmPressed() or clicked(PLAY_BTN) then
      if bidSel < floor then
        -- below the floor IS the pass: one control, two meanings, and the
        -- panel says so in words rather than needing a second button
        passed[1] = true
        setAnnounce("YOU PASS", theme.quiet)
        if not declarer then
          -- all four passed: the dealer's team takes it at the minimum,
          -- which is the standard rule and keeps a hand from being dead
          declarer, highBid = 1, scoring.MIN_BID
          setAnnounce("EVERYONE PASSED - YOU TAKE IT AT " .. scoring.MIN_BID)
        end
      else
        highBid, declarer = bidSel, 1
        setAnnounce("YOU BID " .. bidSel)
      end
      sounds.play("place", 0.8)
      pause(30, function()
        if declarer == 1 then
          trumpSel = 1
          state = "trump_pick"
        else
          trump = hands[declarer].wantTrump or meld.bestTrump(hands[declarer])
          setAnnounce(NAME[declarer] .. " NAMES " .. SUIT_LABEL[trump])
          sounds.play("place", 0.8)
          pause(40, beginPass)
        end
      end)
    end

  elseif state == "trump_pick" then
    if edges.left then trumpSel = ((trumpSel - 2) % 4) + 1 end
    if edges.right then trumpSel = (trumpSel % 4) + 1 end
    if click then
      for i = 1, 4 do
        if clicked({x = 560 + (i - 1) * 210, y = 380, w = 190, h = 200}) then
          trumpSel = i
          sounds.play("place", 0.4)
        end
      end
    end
    if confirmPressed() or clicked(PLAY_BTN) then
      trump = SUITS[trumpSel]
      setAnnounce("TRUMP IS " .. SUIT_LABEL[trump])
      sounds.play("place", 0.8)
      pause(30, beginPass)
    end

  elseif state == "pass_pick" then
    -- THE SAME HOLD/UNHOLD GESTURE JACKS OR BETTER USES: move the cursor,
    -- toggle a card, and it tucks up with a badge. He already knows it
    -- from the poker game, so the pass is not a new thing to learn.
    local n = #hands[1]
    if edges.left then focusPos = ((focusPos - 2) % n) + 1 end
    if edges.right then focusPos = (focusPos % n) + 1 end

    local function toggle(i)
      if passSel[i] then
        passSel[i] = nil
        sounds.play("place", 0.4)
      elseif #selectedPass() < bot.PASS_N then
        passSel[i] = true
        sounds.play("place", 0.6)
      end
    end

    if confirmPressed() then toggle(focusPos) end
    -- UP commits, because confirm is busy toggling. The panel says so,
    -- and the PLAY button does the same thing for touch.
    local ready = (#selectedPass() == bot.PASS_N)
    if ready and edges.up then
      click = {x = PLAY_BTN.x + 4, y = PLAY_BTN.y + 4}   -- reuse one path
    end
    if click then
      for i = n, 1, -1 do
        local c = hands[1][i]
        local y = passSel[i] and (SOUTH_Y - LIFT) or SOUTH_Y
        if c.dealt and not c.flying
            and clicked({x = c.sx, y = y, w = theme.cardW, h = theme.cardH}) then
          focusPos = i
          toggle(i)
          break
        end
      end
    end

    -- EXACTLY FOUR, no more and no fewer -- the rule is emphatic and a
    -- short pass would leave hands at the wrong size. The button simply
    -- does not arm until four are chosen.
    if #selectedPass() == bot.PASS_N and clicked(PLAY_BTN) then
      local idx = selectedPass()
      local other = (passDir == "send") and declarer or rules.partner(declarer)
      moveCards(hands[1], hands[other], idx)
      rules.sortHand(hands[other], trump)
      rules.sortHand(hands[1], trump)
      relayoutSouth()
      passSel, focusPos = {}, 1
      sounds.play("deal", 0.8)
      if passDir == "send" then
        -- we armed the declarer; now they send back
        pause(24, beginReturn)
      else
        pause(24, finishPass)
      end
    end

  elseif state == "play_pick" then
    if edges.left then
      focusPos = focusPos - 1
      if focusPos < 1 then focusPos = #legalIdx end
    end
    if edges.right then
      focusPos = focusPos + 1
      if focusPos > #legalIdx then focusPos = 1 end
    end
    if click then
      -- right-to-left: the fan overlaps that way, so the topmost card
      -- under the finger is the one they meant
      for i = #hands[1], 1, -1 do
        local c = hands[1][i]
        local y = (i == legalIdx[focusPos]) and (SOUTH_Y - LIFT) or SOUTH_Y
        if c.dealt and not c.flying
            and clicked({x = c.sx, y = y, w = theme.cardW, h = theme.cardH}) then
          for pos, idx in ipairs(legalIdx) do
            if idx == i then focusPos = pos end
          end
          break
        end
      end
    end
    if confirmPressed() or clicked(PLAY_BTN) then
      playCard(1, legalIdx[focusPos])
    end
  end

  debugValue(0, STATE_ID[state] or 0)
  -- DIAGNOSTIC: pack what input the game is actually seeing, so a driver
  -- can tell "the press never arrived" from "the press arrived and was
  -- rejected" -- which are very different bugs.
  local dbgIn = (love.pad.isDown("a") and 1 or 0)
              + (love.pad.isDown("b") and 2 or 0)
              + (edges.a and 4 or 0) + (edges.b and 8 or 0)
              + (click and 16 or 0) + (confirmHeld and 32 or 0)
  debugValue(1, tricksPlayed * 64 + dbgIn)
end

-- ── draw ──────────────────────────────────────────────────────────────
local function drawTurnMarker(x, y)
  love.graphics.setColor(theme.gold)
  love.graphics.rectangle("fill", x, y, 16, 16)
end

local function drawMeldPanel()
  local g = love.graphics
  -- BETWEEN the two hands: north's fan ends about y=210 and the south fan
  -- starts at 620, so the panel gets that band and no more. At 660 tall it
  -- was drawn straight over both.
  g.setColor(0, 0, 0, 0.88)
  g.rectangle("fill", 300, 222, 1320, 386)
  g.setColor(theme.gold)
  g.rectangle("line", 300, 222, 1320, 386)

  g.setFont(ui.font(theme.fontMid))
  g.setColor(theme.white)
  g.printf("MELD", 300, 236, 1320, "center")
  g.setFont(ui.font(theme.fontSmall - 4))
  g.setColor(theme.quiet)
  g.printf("TRUMP", 300, 236, 1010, "right")
  drawPip(trump, 1338, 250, 15)

  -- Every meld NAMED and valued. This is how the game teaches what a meld
  -- is, the same way the poker games ring the cards that made the hand --
  -- and meld-spotting is the single hardest part of pinochle to learn.
  local cols = {{seat = 1, x = 360, label = "YOU"}, {seat = 3, x = 800, label = "PARTNER"},
                {seat = 2, x = 1200, label = "THEM"}}
  for _, col in ipairs(cols) do
    g.setFont(ui.font(theme.fontSmall))
    g.setColor(theme.gold)
    g.print(col.label, col.x, 288)
    g.setColor(theme.white)
    local y = 326
    local list = meldList[col.seat]
    if col.seat == 2 then
      -- the opponents' two hands share a column
      list = {}
      for _, m in ipairs(meldList[2]) do list[#list + 1] = m end
      for _, m in ipairs(meldList[4]) do list[#list + 1] = m end
    end
    if #list == 0 then
      g.setColor(theme.dim)
      g.print("no meld", col.x, y)
    end
    for _, m in ipairs(list) do
      if y < 540 then
        g.setColor(theme.white)
        g.print(m.name, col.x, y)
        g.setColor(theme.win)
        g.printf(tostring(m.pts), col.x, y, 340, "right")
        y = y + 34
      end
    end
  end

  g.setFont(ui.font(theme.fontMid))
  g.setColor(theme.white)
  g.print("US " .. teamMeld[1], 360, 552)
  g.setColor(theme.quiet)
  g.printf("THEM " .. teamMeld[2], 1160, 552, 380, "right")
  g.setFont(ui.font(theme.fontSmall))
  g.setColor(theme.dim)
  g.printf("press A to play", 300, 566, 1320, "center")
end

local function drawBidPanel()
  local g = love.graphics
  local floor = (highBid or (scoring.MIN_BID - scoring.BID_STEP)) + scoring.BID_STEP
  -- ABOVE the fan. A twelve-card hand at full height reaches y=620, and a
  -- lifted card reaches 576 -- a panel at 280..620 was drawn over.
  g.setColor(0, 0, 0, 0.82)
  g.rectangle("fill", 560, 250, 800, 300)
  g.setColor(theme.gold)
  g.rectangle("line", 560, 250, 800, 300)
  g.setFont(ui.font(theme.fontSmall))
  g.setColor(theme.quiet)
  g.printf(highBid and ("HIGH BID " .. highBid .. " BY " .. NAME[declarer])
                    or "NO BID YET", 560, 272, 800, "center")
  g.setFont(ui.font(theme.fontHuge))
  if bidSel < floor then
    g.setColor(theme.quiet)
    g.printf("PASS", 560, 330, 800, "center")
  else
    g.setColor(theme.white)
    g.printf(tostring(bidSel), 560, 330, 800, "center")
  end
  g.setFont(ui.font(theme.fontSmall))
  g.setColor(theme.dim)
  g.printf("\u{25C0}", 600, 378, 220, "center")
  g.printf("\u{25B6}", 1100, 378, 220, "center")
  g.setColor(theme.quiet)
  g.printf("suggested " .. suggested, 560, 462, 800, "center")
  g.setFont(ui.font(theme.fontSmall))
  g.setColor(theme.dim)
  g.printf("left/right to change, A to confirm", 560, 506, 800, "center")
end

local function drawTrumpPanel()
  local g = love.graphics
  g.setColor(0, 0, 0, 0.72)
  g.rectangle("fill", 500, 280, 920, 380)
  g.setColor(theme.gold)
  g.rectangle("line", 500, 280, 920, 380)
  g.setFont(ui.font(theme.fontMid))
  g.setColor(theme.white)
  g.printf("NAME TRUMP", 500, 306, 920, "center")

  for i, s in ipairs(SUITS) do
    local x = 560 + (i - 1) * 210
    local sel = (i == trumpSel)
    g.setColor(1, 1, 1, sel and 0.18 or 0.06)
    g.rectangle("fill", x, 380, 190, 200)
    if sel then ui.focusRing(x, 380, 190, 200) end
    -- the suit's own colour, which is how a card player reads a suit
    drawPip(s, x + 95, 452, 46)
    g.setFont(ui.font(theme.fontSmall - 4))
    g.setColor(sel and theme.gold or theme.dim)
    g.printf(SUIT_LABEL[s], x, 528, 190, "center")
  end
  g.setFont(ui.font(theme.fontSmall))
  g.setColor(theme.dim)
  g.printf("left/right to choose, A to confirm", 500, 606, 920, "center")
end

local function drawResult()
  local g = love.graphics
  local r = result
  g.setColor(0, 0, 0, 0.78)
  g.rectangle("fill", 420, 220, 1080, 560)
  g.setColor(theme.gold)
  g.rectangle("line", 420, 220, 1080, 560)
  g.setFont(ui.font(theme.fontBig))
  local made = r.rd.made
  g.setColor(made and theme.win or theme.lossRed)
  g.printf(made and "CONTRACT MADE" or "SET", 420, 252, 1080, "center")

  g.setFont(ui.font(theme.fontMid))
  g.setColor(theme.quiet)
  g.printf(NAME[declarer] .. " BID " .. highBid .. " IN " .. SUIT_LABEL[trump],
           420, 330, 1080, "center")

  local rows = {
    {"MELD",   teamMeld[1],   teamMeld[2]},
    {"TRICKS", teamTricks[1], teamTricks[2]},
  }
  g.setFont(ui.font(theme.fontMid))
  local y = 410
  g.setColor(theme.dim)
  g.printf("US", 700, y - 44, 300, "center")
  g.printf("THEM", 1060, y - 44, 300, "center")
  for _, row in ipairs(rows) do
    g.setColor(theme.quiet)
    g.print(row[1], 480, y)
    g.setColor(theme.white)
    g.printf(tostring(row[2]), 700, y, 300, "center")
    g.printf(tostring(row[3]), 1060, y, 300, "center")
    y = y + 46
  end

  local d1 = (r.dt == 1) and r.rd.delta or r.ro.delta
  local d2 = (r.dt == 2) and r.rd.delta or r.ro.delta
  g.setFont(ui.font(theme.fontBig))
  g.setColor(theme.quiet)
  g.print("HAND", 480, y + 16)
  g.setColor(d1 >= 0 and theme.win or theme.lossRed)
  g.printf((d1 >= 0 and "+" or "") .. d1, 700, y + 16, 300, "center")
  g.setColor(theme.white)
  g.printf((d2 >= 0 and "+" or "") .. d2, 1060, y + 16, 300, "center")

  g.setFont(ui.font(theme.fontSmall))
  g.setColor(theme.dim)
  g.printf("press A to deal again", 420, 730, 1080, "center")
end

function love.draw()
  local g = love.graphics

  g.setFont(ui.font(theme.fontSmall))
  g.setColor(theme.dim)
  g.print("PINOCHLE", 60, 28)
  g.printf("FIRST TO " .. scoring.GAME_TO, W - 420, 28, 360, "right")
  g.setFont(ui.font(theme.fontBig))
  if moodUs == "win" then g.setColor(theme.winRing)
  elseif moodUs == "loss" then g.setColor(theme.lossRed)
  else g.setColor(theme.white) end
  g.print("US  " .. teamScore[1], 60, 62)
  g.setColor(theme.quiet)
  g.printf("THEM  " .. teamScore[2], W - 480, 62, 420, "right")

  if trump and state ~= "meld_show" then
    -- LEFT GUTTER, not centred. The north hand's fan runs across the
    -- middle of the top of the screen, so a centred header is drawn on
    -- top of it; the space under the US score is empty and always will be.
    g.setFont(ui.font(theme.fontSmall))
    g.setColor(theme.dim)
    g.print("TRUMP", 60, 140)
    drawPip(trump, 190, 156, 18)
    if highBid then
      g.setColor(theme.dim)
      g.print(NAME[declarer] .. " BID " .. highBid, 60, 186)
    end
  end

  if state == "idle" then
    g.setFont(ui.font(theme.fontMid))
    g.setColor(theme.quiet)
    g.printf("YOU AND PARTNER AGAINST WEST AND EAST", 0, 420, W, "center")
    ui.button("DEAL", DEAL_BTN.x, DEAL_BTN.y, DEAL_BTN.w, DEAL_BTN.h, true)
    g.setFont(ui.font(theme.fontSmall))
    g.setColor(theme.dim)
    g.printf("press A to deal", 810, 610, 300, "center")
    return
  end

  -- CPU hands, face down
  local nN = #hands[3]
  local xN = northStartX(nN)
  for i, c in ipairs(hands[3]) do
    if c.dealt and not c.flying then
      cards.drawBack(xN + (i - 1) * NORTH_STEP, NORTH_Y, CPU_SCALE)
    end
  end
  for _, seat in ipairs({2, 4}) do
    local x = (seat == 2) and WEST_X or EAST_X
    local y0 = sideStartY(#hands[seat])
    for i, c in ipairs(hands[seat]) do
      if c.dealt and not c.flying then
        cards.drawBack(x, y0 + (i - 1) * SIDE_STEP, CPU_SCALE)
      end
    end
  end

  -- seat labels
  g.setFont(ui.font(theme.fontSmall))
  g.setColor(theme.dim)
  g.printf("WEST", 14, 772, 170, "center")
  g.printf("EAST", W - 184, 772, 170, "center")
  g.print("PARTNER", 1230, 64)
  if declarer then
    g.setColor(theme.gold)
    if declarer == 2 then g.printf("BID " .. highBid, 14, 806, 170, "center")
    elseif declarer == 4 then g.printf("BID " .. highBid, W - 184, 806, 170, "center")
    elseif declarer == 3 then g.print("BID " .. highBid, 1230, 98) end
  end

  if state == "cpu_think" or state == "play_pick" or state == "anim_play" then
    if turn == 2 then drawTurnMarker(80, 744)
    elseif turn == 3 then drawTurnMarker(1196, 70)
    elseif turn == 4 then drawTurnMarker(W - 96, 744)
    elseif turn == 1 then drawTurnMarker(28, H - 60) end
  end

  if state == "dealing" and landedCount < 48 then
    for d = 2, 0, -1 do
      cards.drawBackC(DECK_POS[1] + d * 5, DECK_POS[2] - d * 4, 0.55)
    end
  end

  -- the trick
  for _, p in ipairs(trick) do
    local c = p.card
    if not c.flying then
      local pos = TRICK_POS[p.seat]
      local tw, th = theme.cardW * TRICK_SCALE, theme.cardH * TRICK_SCALE
      cards.drawCard(c, pos[1] - tw / 2, pos[2] - th / 2, TRICK_SCALE)
      if ringSeat == p.seat then
        ui.winRing(pos[1] - tw / 2, pos[2] - th / 2, tw, th)
      end
    end
  end

  -- dad's fan
  for i, c in ipairs(hands[1]) do
    if c.dealt and not c.flying then
      local picked = (state == "pass_pick" and passSel[i])
      local lifted = (state == "play_pick" and legalIdx[focusPos] == i) or picked
      local y = lifted and (SOUTH_Y - LIFT) or SOUTH_Y
      cards.drawCard(c, c.sx, y, 1)
      -- ILLEGAL CARDS ARE DIMMED, never hidden and never an error message.
      -- Pinochle's play obligations are strict and easy to break by
      -- accident, and greying the cards he cannot play removes the whole
      -- category of "why won't it let me".
      if state == "play_pick" then
        local legal = false
        for _, idx in ipairs(legalIdx) do if idx == i then legal = true end end
        if not legal then
          g.setColor(0, 0, 0, 0.55)
          g.rectangle("fill", c.sx, y, theme.cardW, theme.cardH)
        end
      end
      -- A PASS MARKER, not jacks-or-better's HELD badge. That badge spans
      -- the card's full width plus 12px, and in an overlapping fan four of
      -- them merge into one solid gold bar across the hand -- unreadable,
      -- and it says the wrong word besides. This sits INSIDE the card's
      -- visible sliver so each pick reads separately.
      if picked then
        local bw = math.min(theme.cardW, southStep(#hands[1]))
        g.setColor(theme.gold)
        g.rectangle("fill", c.sx, y + theme.cardH - 76, bw, 44)
        g.setColor(theme.ink)
        g.setFont(ui.font(theme.fontSmall - 8))
        g.printf("PASS", c.sx, y + theme.cardH - 68, bw, "center")
      end
      if (state == "pass_pick" and focusPos == i) or
         (state == "play_pick" and legalIdx[focusPos] == i) then
        ui.focusRing(c.sx, y, theme.cardW, theme.cardH)
      end
    end
  end

  -- flying cards, on top of everything
  for seat = 1, 4 do
    for _, c in ipairs(hands[seat]) do
      if c.flying then cards.drawFlight(c, c.fx, c.fy, c.fs, c.frot, c.fflip) end
    end
  end
  for _, p in ipairs(trick) do
    local c = p.card
    if c.flying then cards.drawFlight(c, c.fx, c.fy, c.fs, c.frot, c.fflip) end
  end

  if announce then
    g.setFont(ui.font(theme.fontMid))
    g.setColor(announce.c)
    g.printf(announce.text, 0, 232, W, "center")
  end

  if state == "pass_pick" then
    local n = #selectedPass()
    local ready = (n == bot.PASS_N)
    g.setColor(0, 0, 0, 0.82)
    g.rectangle("fill", 560, 250, 800, 210)
    g.setColor(theme.gold)
    g.rectangle("line", 560, 250, 800, 210)
    g.setFont(ui.font(theme.fontMid))
    g.setColor(theme.white)
    g.printf(passDir == "send" and "PASS 4 TO YOUR PARTNER"
                                or "PASS 4 BACK", 560, 272, 800, "center")
    g.setFont(ui.font(theme.fontBig))
    g.setColor(ready and theme.win or theme.quiet)
    g.printf(n .. " OF " .. bot.PASS_N .. " CHOSEN", 560, 322, 800, "center")
    g.setFont(ui.font(theme.fontSmall))
    g.setColor(theme.dim)
    -- WHAT TO SEND, said in words. Choosing four from twelve under a rule
    -- you half-remember is the likeliest place to stall, and the advice is
    -- short enough to read from the couch.
    g.printf(passDir == "send" and "send your trump and aces"
                                or "send back what you cannot use",
             560, 396, 800, "center")
    g.setColor(ready and theme.gold or theme.dim)
    g.printf(ready and "press UP to send" or "A to pick a card",
             560, 428, 800, "center")
    ui.button("SEND", PLAY_BTN.x, PLAY_BTN.y, PLAY_BTN.w, PLAY_BTN.h, ready)

  elseif state == "play_pick" then
    ui.button("PLAY", PLAY_BTN.x, PLAY_BTN.y, PLAY_BTN.w, PLAY_BTN.h, true)
  elseif state == "bid_pick" then
    drawBidPanel()
    ui.button("BID", PLAY_BTN.x, PLAY_BTN.y, PLAY_BTN.w, PLAY_BTN.h, true)
  elseif state == "trump_pick" then
    drawTrumpPanel()
    ui.button("OK", PLAY_BTN.x, PLAY_BTN.y, PLAY_BTN.w, PLAY_BTN.h, true)
  elseif state == "meld_show" then
    drawMeldPanel()
  elseif state == "hand_result" then
    drawResult()
  elseif state == "game_over" then
    g.setColor(0, 0, 0, 0.82)
    g.rectangle("fill", 460, 300, 1000, 420)
    g.setColor(theme.gold)
    g.rectangle("line", 460, 300, 1000, 420)
    g.setFont(ui.font(theme.fontHuge))
    g.setColor(gameOverData.weWin and theme.win or theme.quiet)
    g.printf(gameOverData.weWin and "YOU WIN" or "THEY WIN", 460, 356, 1000, "center")
    g.setFont(ui.font(theme.fontBig))
    g.setColor(theme.white)
    g.printf(gameOverData.us .. "  -  " .. gameOverData.them, 460, 484, 1000, "center")
    g.setFont(ui.font(theme.fontSmall))
    g.setColor(theme.dim)
    g.printf("press A for a new game", 460, 620, 1000, "center")
  end

  -- the bottom strip: tricks taken so far, which is the running story
  if state ~= "idle" and trump then
    g.setFont(ui.font(theme.fontSmall))
    g.setColor(theme.dim)
    g.print("TRICK " .. math.min(tricksPlayed + 1, 12) .. " OF 12", 60, H - 52)
    g.printf("US " .. teamTricks[1] .. "   THEM " .. teamTricks[2],
             W - 480, H - 52, 420, "right")
  end
end
