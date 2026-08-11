-- SPADES - partnership spades: you and PARTNER (north) against WEST and
-- EAST. Books, bags, nil, first team to 500. No money - the score is
-- the one currency, big and mood-colored per the family laws.
-- Controls: LEFT/RIGHT moves the gold cursor (only legal cards), A (south
-- or east button) confirms. Mouse/touch is an optional extra: click a
-- legal card to select it, click PLAY to play it. Dad always bids last;
-- west always leads the first book; takers lead after that. See
-- docs/SPADES.md.

pcall(require, "testdrive")   -- DEV ONLY: headless driver hooks; absent in ships

local theme   = require("lib.theme")
local cards   = require("lib.cards")
local ui      = require("lib.ui")
local anim    = require("lib.anim")
local sounds  = require("lib.sounds")
local rules   = require("rules")
local scoring = require("scoring")
local bot     = require("bot")

local W, H = 1920, 1080
local V = cards.val
local NAME = rules.NAME

local SPEED = rawget(_G, "SPADES_FAST") and 0.28 or 1
local function T(sec) return sec * SPEED end

-- ── layout ────────────────────────────────────────────────────────────
-- Zones, top to bottom: score corners + north hand / announcement lane /
-- the trick cross / dad's fan / the bottom status strip. Trick cards may
-- overlap EACH OTHER (cards land on a real table); they never enter the
-- text lanes.
local SOUTH_Y, SOUTH_STEP, LIFT = 620, 105, 44
local CPU_SCALE = 0.42
local CPU_W, CPU_H = theme.cardW * CPU_SCALE, theme.cardH * CPU_SCALE
local NORTH_Y, NORTH_STEP = 50, 34
local WEST_X, EAST_X, SIDE_STEP = 40, W - 40 - CPU_W, 24
local TRICK_SCALE = 0.6
local TRICK_POS = {  -- card centers, offset toward the owner's seat
  [1] = {960, 500}, [2] = {815, 455}, [3] = {960, 380}, [4] = {1105, 455},
}
local ORIGIN = {  -- flights start at the CENTER of the owner's hand
  [1] = {960, SOUTH_Y + theme.cardH / 2},
  [2] = {WEST_X + CPU_W / 2, H / 2},
  [3] = {960, NORTH_Y + CPU_H / 2},
  [4] = {EAST_X + CPU_W / 2, H / 2},
}
local DECK_POS = {960, 455}

local function southStartX(n) return (W - ((n - 1) * SOUTH_STEP + theme.cardW)) / 2 end
local function northStartX(n) return (W - ((n - 1) * NORTH_STEP + CPU_W)) / 2 end
local function sideStartY(n) return (H - ((n - 1) * SIDE_STEP + CPU_H)) / 2 end

-- ── state ─────────────────────────────────────────────────────────────
local state = "idle"
-- idle|dealing|bid_wait|bid_pick|cpu_think|play_pick|anim_play|book_pause|
-- sweep|hand_result|game_over
local STATE_ID = { idle = 1, dealing = 2, bid_wait = 3, bid_pick = 4,
  cpu_think = 5, play_pick = 6, anim_play = 7, book_pause = 8, sweep = 9,
  hand_result = 10, game_over = 11 }

local hands = {{}, {}, {}, {}}
local bids, books = {}, {0, 0, 0, 0}
local teamScore, teamBags = {0, 0}, {0, 0}
local trick = {}
local leader, turn = 2, 2
local spadesBroken = false
local booksPlayed = 0
local voids = {{}, {}, {}, {}}
local playedSuit = {S = {}, H = {}, C = {}, D = {}}
local announce = nil          -- {text=, c=}
local ringSeat = nil          -- winner ring during the book pause
local bidSel, suggested = 3, 3
local legalIdx, focusPos = {}, 1
local result = nil            -- hand_result panel data
local gameOverData = nil
local moodUs = nil
local deck = nil
local landedCount = 0
local waitTimer, afterWait = 0, nil
local sched = {}              -- delayed one-shots for the deal stagger

local AGGRO = {[2] = -0.25, [3] = 0, [4] = 0.25}

local debugValue = love.debugValue or function() end

local function emit(name, data)
  local h = rawget(_G, "SPADES_TEST_EVENT")
  if h then h(name, data) end
end

local function pause(frames, fn)
  waitTimer = math.max(1, math.floor(frames * SPEED))
  afterWait = fn
end

local function after(frames, fn)
  sched[#sched + 1] = {t = math.max(1, math.floor(frames * SPEED)), fn = fn}
end

-- ── input: the family readEdges pattern (debounce + entropy stir) ─────
local prevDown, edges, lastEdgeFrame, frameNo = {}, {}, {}, 0
local DEBOUNCE = 9
local AUTO = rawget(_G, "SPADES_DRIVER")
local function readEdges()
  frameNo = frameNo + 1
  for k in pairs(edges) do edges[k] = nil end
  if AUTO then
    local b = AUTO(frameNo)
    if b then edges[b] = true; cards.stir(frameNo) end
    return
  end
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

-- ── pointer: click/tap as an alternative to the pad, never a replacement.
-- Raw wc.pointer slots: 0 = mouse, 1-9 = touch fingers. Poll them ALL -
-- a mouse-only read would silently ignore every touch on a phone. A
-- click is a rising edge on any slot; the pad path is untouched.
local PLAY_BTN = {x = 1540, y = 440, w = 220, h = 110}
local DEAL_BTN = {x = 810, y = 500, w = 300, h = 96}
local prevPtr = {}
local click = nil             -- {x=, y=} on the frame a press lands, else nil
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

-- ── helpers ───────────────────────────────────────────────────────────
local function teamNeed(team)
  local teamBid, toward = 0, 0
  for seat = 1, 4 do
    if rules.teamOf(seat) == team and bids[seat] and bids[seat] > 0 then
      teamBid = teamBid + bids[seat]
      toward = toward + books[seat]
    end
  end
  return teamBid > 0 and toward < teamBid
end

local function nilActive(seat)
  return bids[seat] == 0 and books[seat] == 0
end

local function botCtx(seat)
  local partner = rules.partner(seat)
  local oppNilSeat = nil
  for o = 1, 4 do
    if rules.teamOf(o) ~= rules.teamOf(seat) and bids[o] and nilActive(o) then
      oppNilSeat = o
    end
  end
  return {
    seat = seat, trick = trick, spadesBroken = spadesBroken,
    needMore = teamNeed(rules.teamOf(seat)),
    myNilActive = nilActive(seat),
    partnerSeat = partner, partnerNilActive = nilActive(partner),
    oppNilSeat = oppNilSeat, voids = voids, playedSuit = playedSuit,
  }
end

local function setAnnounce(text, c) announce = {text = text, c = c or theme.white} end

local function relayoutSouth()
  local hand = hands[1]
  local x0 = southStartX(#hand)
  for i, c in ipairs(hand) do
    anim.tween(c, {sx = x0 + (i - 1) * SOUTH_STEP}, T(0.2))
  end
end

local function handIds(seat)
  local t = {}
  for i, c in ipairs(hands[seat]) do t[i] = c.id end
  return t
end

-- ── the deal ──────────────────────────────────────────────────────────
local advanceTurn, endBook   -- fwd decls

local function beginBidding()
  state = "bid_wait"
  local seq, i = {2, 3, 4}, 1
  local function step()
    local seat = seq[i]
    pause(46, function()
      bids[seat] = bot.suggestBid(hands[seat],
        {bids = bids, partnerSeat = rules.partner(seat), aggro = AGGRO[seat]})
      setAnnounce(NAME[seat] ..
        (bids[seat] == 0 and " BIDS NIL" or (" BIDS " .. bids[seat])))
      sounds.play("place", 0.7)
      i = i + 1
      if seq[i] then step()
      else
        pause(40, function()
          suggested = bot.suggestBid(hands[1], {bids = bids, partnerSeat = 3})
          bidSel = suggested
          state = "bid_pick"
        end)
      end
    end)
  end
  step()
end

local function startHand()
  bids, books = {}, {0, 0, 0, 0}
  trick, booksPlayed = {}, 0
  spadesBroken = false
  voids = {{}, {}, {}, {}}
  playedSuit = {S = {}, H = {}, C = {}, D = {}}
  announce, ringSeat, result, moodUs = nil, nil, nil, nil
  landedCount = 0
  sounds.play("shuffle")
  deck = cards.newDeck()
  for seat = 1, 4 do
    hands[seat] = {}
    for _ = 1, 13 do hands[seat][#hands[seat] + 1] = table.remove(deck) end
    rules.sortHand(hands[seat])
  end
  emit("deal", {hands = {handIds(1), handIds(2), handIds(3), handIds(4)}})
  state = "dealing"
  -- one card at a time, clockwise from west (left of the permanent
  -- dealer), landing pre-sorted; dad's face up, everyone else's down
  local n = 0
  for r = 1, 13 do
    for _, seat in ipairs({2, 3, 4, 1}) do
      n = n + 1
      local c = hands[seat][r]
      local south = (seat == 1)
      local tx, ty, ts
      if south then
        c.sx = southStartX(13) + (r - 1) * SOUTH_STEP
        tx, ty, ts = c.sx + theme.cardW / 2, SOUTH_Y + theme.cardH / 2, 1
      elseif seat == 3 then
        tx, ty, ts = northStartX(13) + (r - 1) * NORTH_STEP + CPU_W / 2,
                     NORTH_Y + CPU_H / 2, CPU_SCALE
      else
        local x = (seat == 2) and WEST_X or EAST_X
        tx, ty, ts = x + CPU_W / 2, sideStartY(13) + (r - 1) * SIDE_STEP + CPU_H / 2,
                     CPU_SCALE
      end
      after(3 * (n - 1) + 1, function()
        c.fx, c.fy = DECK_POS[1], DECK_POS[2]
        c.fs, c.frot, c.fflip = 0.55, 0, 0
        c.flying = true
        anim.tween(c, {fx = tx, fy = ty, fs = ts, fflip = south and 1 or 0},
          T(0.32), function()
            c.flying = false
            c.dealt = true
            c.faceUp = south
            landedCount = landedCount + 1
            if landedCount % 4 == 0 then sounds.play("deal", 0.8) end
            if landedCount == 52 then beginBidding() end
          end)
      end)
    end
  end
end

-- ── trick play ────────────────────────────────────────────────────────
local function playCard(seat, idx)
  local c = hands[seat][idx]
  if #trick == 0 then announce = nil end   -- bid/book lines go stale here
  emit("play", {seat = seat, id = c.id, suit = c.suit, rank = c.rank,
    led = #trick > 0 and trick[1].card.suit or nil, trickN = #trick,
    hand = handIds(seat), broken = spadesBroken})
  if #trick > 0 and c.suit ~= trick[1].card.suit then
    voids[seat][trick[1].card.suit] = true
  end
  playedSuit[c.suit][V[c.rank]] = true
  table.remove(hands[seat], idx)
  trick[#trick + 1] = {seat = seat, card = c}
  if c.suit == "S" and not spadesBroken then
    spadesBroken = true
    setAnnounce("SPADES ARE BROKEN", theme.quiet)
  end
  if seat == 1 then relayoutSouth() end
  local pos = TRICK_POS[seat]
  c.fx, c.fy = ORIGIN[seat][1], ORIGIN[seat][2]
  c.fs = (seat == 1) and 1 or CPU_SCALE
  c.frot, c.fflip = 0, (seat == 1) and 1 or 0
  c.flying = true
  state = "anim_play"
  anim.tween(c, {fx = pos[1], fy = pos[2], fs = TRICK_SCALE, fflip = 1},
    T(0.34), function()
      c.flying = false
      c.faceUp = true
      sounds.play("place", 0.8)
      if #trick == 4 then endBook()
      else
        turn = rules.nextSeat(seat)
        advanceTurn()
      end
    end)
end

advanceTurn = function()
  if turn == 1 then
    legalIdx = rules.legalPlays(hands[1], trick, spadesBroken)
    focusPos = 1
    state = "play_pick"
  else
    state = "cpu_think"
    pause(30 + (turn * 7) % 14, function()
      playCard(turn, bot.choose(hands[turn], botCtx(turn)))
    end)
  end
end

endBook = function()
  local winner = rules.bookWinner(trick)
  local plays = {}
  for i, p in ipairs(trick) do plays[i] = {seat = p.seat, id = p.card.id} end
  emit("book", {plays = plays, winner = winner})
  ringSeat = winner
  setAnnounce(NAME[winner] .. ((winner == 1) and " TAKE THE BOOK" or " TAKES THE BOOK"),
    rules.teamOf(winner) == 1 and theme.win or theme.quiet)
  sounds.play("chips", 0.7)
  state = "book_pause"
  pause(62, function()
    state = "sweep"
    local done = 0
    for _, p in ipairs(trick) do
      local c = p.card
      c.flying = true
      anim.tween(c, {fx = ORIGIN[winner][1], fy = ORIGIN[winner][2], fs = 0.2},
        T(0.3), function()
          done = done + 1
          if done == #trick then
            trick = {}
            ringSeat, announce = nil, nil
            books[winner] = books[winner] + 1
            booksPlayed = booksPlayed + 1
            leader, turn = winner, winner
            if booksPlayed == 13 then
              -- score the hand
              local r1 = scoring.scoreTeam({members = {1, 3}, bids = bids, books = books}, teamBags[1])
              local r2 = scoring.scoreTeam({members = {2, 4}, bids = bids, books = books}, teamBags[2])
              teamScore[1] = teamScore[1] + r1.delta
              teamScore[2] = teamScore[2] + r2.delta
              local bagsBefore = {teamBags[1], teamBags[2]}
              teamBags[1], teamBags[2] = r1.bags, r2.bags
              moodUs = (r1.delta > 0 and "win") or (r1.delta < 0 and "loss") or nil
              result = {r1 = r1, r2 = r2}
              emit("score", {bids = {bids[1], bids[2], bids[3], bids[4]},
                books = {books[1], books[2], books[3], books[4]},
                bagsBefore = bagsBefore, d1 = r1.delta, d2 = r2.delta,
                bags1 = r1.bags, bags2 = r2.bags,
                scores = {teamScore[1], teamScore[2]}})
              if r1.delta > 0 then sounds.play("win") end
              if (teamScore[1] >= scoring.GAME_TO or teamScore[2] >= scoring.GAME_TO)
                  and teamScore[1] ~= teamScore[2] then
                gameOverData = {us = teamScore[1], them = teamScore[2],
                                weWin = teamScore[1] > teamScore[2]}
              end
              state = "hand_result"
              confirmHeld = true
            else
              pause(14, advanceTurn)
            end
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
        teamScore, teamBags = {0, 0}, {0, 0}
        gameOverData, result = nil, nil
        state = "idle"
      elseif state == "hand_result" and gameOverData then
        state = "game_over"
      else
        startHand()
      end
    end
  elseif state == "bid_pick" then
    if edges.left then bidSel = math.max(0, bidSel - 1) end
    if edges.right then bidSel = math.min(13, bidSel + 1) end
    -- fat tap zones: the whole left/right THIRD of the panel steps the
    -- bid, not just the arrow glyph - fingers are blunter than cursors
    if click then
      if clicked({x = 640, y = 300, w = 210, h = 300}) then
        bidSel = math.max(0, bidSel - 1)
        sounds.play("place", 0.4)
      elseif clicked({x = 1070, y = 300, w = 210, h = 300}) then
        bidSel = math.min(13, bidSel + 1)
        sounds.play("place", 0.4)
      end
    end
    -- BID sits in the SAME spot PLAY uses during tricks: confirm always
    -- lives in one place
    if confirmPressed() or clicked(PLAY_BTN) then
      bids[1] = bidSel
      setAnnounce("YOU BID " .. (bidSel == 0 and "NIL" or bidSel))
      sounds.play("place", 0.8)
      leader, turn = 2, 2
      pause(26, advanceTurn)
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
      -- right-to-left = topmost card first (the fan overlaps that way);
      -- only legal cards take the cursor, same rule the pad follows
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
  debugValue(1, booksPlayed * 8 + #trick)
  _G.SPADES_UI = {state = state, bidSel = bidSel, suggested = suggested,
    nLegal = #legalIdx, focusPos = focusPos, booksPlayed = booksPlayed}
end

-- ── draw ──────────────────────────────────────────────────────────────
local function fmtDelta(d) return (d >= 0 and ("+" .. d) or tostring(d)) end

local function seatBadge(seat)
  if not bids[seat] then return nil end
  local b = (bids[seat] == 0) and "NIL" or tostring(bids[seat])
  return "BID " .. b, "BOOKS " .. books[seat]
end

local function drawTurnMarker(x, y)
  love.graphics.setColor(theme.gold)
  love.graphics.rectangle("fill", x, y, 16, 16)
end

function love.draw()
  local g = love.graphics

  -- top corners: the two scores (US mood-colored, per the family law)
  g.setFont(ui.font(theme.fontSmall))
  g.setColor(theme.dim)
  g.print("SPADES", 60, 28)
  g.printf("FIRST TO " .. scoring.GAME_TO, W - 420, 28, 360, "right")
  g.setFont(ui.font(theme.fontBig))
  if moodUs == "win" then g.setColor(theme.winRing)
  elseif moodUs == "loss" then g.setColor(theme.lossRed)
  else g.setColor(theme.white) end
  g.print("US  " .. teamScore[1], 60, 62)
  g.setColor(theme.quiet)
  g.printf("THEM  " .. teamScore[2], W - 480, 62, 420, "right")
  g.setFont(ui.font(theme.fontSmall))
  g.setColor(theme.dim)
  g.print("BAGS " .. teamBags[1], 60, 134)
  g.printf("BAGS " .. teamBags[2], W - 420, 134, 360, "right")

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

  -- CPU hands (face-down fans) --------------------------------------
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

  -- seat labels + badges --------------------------------------------
  g.setFont(ui.font(theme.fontSmall))
  g.setColor(theme.dim)
  g.printf("WEST", 14, 772, 170, "center")
  g.printf("EAST", W - 184, 772, 170, "center")
  g.print("PARTNER", 1230, 64)
  g.setColor(theme.white)
  local b1, b2 = seatBadge(2)
  if b1 then g.printf(b1, 14, 806, 170, "center"); g.printf(b2, 14, 840, 170, "center") end
  b1, b2 = seatBadge(4)
  if b1 then g.printf(b1, W - 184, 806, 170, "center"); g.printf(b2, W - 184, 840, 170, "center") end
  b1, b2 = seatBadge(3)
  if b1 then g.print(b1 .. " - " .. b2, 1230, 98) end

  -- whose turn (thinking or picking)
  if state == "cpu_think" or state == "play_pick" or state == "anim_play" then
    if turn == 2 then drawTurnMarker(80, 744)
    elseif turn == 3 then drawTurnMarker(1196, 70)
    elseif turn == 4 then drawTurnMarker(W - 96, 744)
    elseif turn == 1 then drawTurnMarker(28, H - 60) end
  end

  -- deck pile while dealing ------------------------------------------
  if state == "dealing" and landedCount < 52 then
    for d = 2, 0, -1 do
      cards.drawBackC(DECK_POS[1] + d * 5, DECK_POS[2] - d * 4, 0.55)
    end
  end

  -- the trick cross ---------------------------------------------------
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

  -- dad's hand --------------------------------------------------------
  -- The focused card lifts but keeps its slot in the splay, so the
  -- neighbors to its right stay visible (they overlap it like any fan).
  local focusIdx = (state == "play_pick") and legalIdx[focusPos] or nil
  for i, c in ipairs(hands[1]) do
    if c.dealt and not c.flying then
      local y = (i == focusIdx) and (SOUTH_Y - LIFT) or SOUTH_Y
      cards.drawCard(c, c.sx, y, 1)
      if i == focusIdx then
        ui.focusRing(c.sx, y, theme.cardW, theme.cardH)
      end
    end
  end

  -- play button: the click/tap twin of the A button ------------------
  if state == "play_pick" then
    ui.button("PLAY", PLAY_BTN.x, PLAY_BTN.y, PLAY_BTN.w, PLAY_BTN.h, true)
  end

  -- flights over everything -------------------------------------------
  for seat = 1, 4 do
    for _, c in ipairs(hands[seat]) do
      if c.flying then cards.drawFlight(c, c.fx, c.fy, c.fs, c.frot or 0, c.fflip) end
    end
  end
  for _, p in ipairs(trick) do
    local c = p.card
    if c.flying then cards.drawFlight(c, c.fx, c.fy, c.fs, c.frot or 0, c.fflip) end
  end

  -- announcement lane -------------------------------------------------
  if announce then
    g.setFont(ui.font(theme.fontMid))
    g.setColor(announce.c)
    g.printf(announce.text, 0, 224, W, "center")
  end

  -- bid spinner -------------------------------------------------------
  if state == "bid_pick" then
    g.setColor(theme.feltDark)
    g.rectangle("fill", 640, 300, 640, 300)
    g.setColor(theme.white)
    g.rectangle("line", 640, 300, 640, 300)
    g.setFont(ui.font(theme.fontMid))
    g.setColor(theme.quiet)
    g.printf("YOUR BID", 640, 318, 640, "center")
    g.setFont(ui.font(theme.fontHuge))
    g.setColor(theme.gold)
    g.printf(bidSel == 0 and "NIL" or tostring(bidSel), 640, 372, 640, "center")
    g.setFont(ui.font(theme.fontHuge))
    g.setColor(theme.white)
    g.print("<", 676, 380)
    g.printf(">", 640, 380, 610, "right")
    g.setFont(ui.font(theme.fontSmall))
    g.setColor(theme.quiet)
    local pb = bids[3]
    local teamLine
    if pb == 0 then teamLine = "PARTNER BID NIL - YOUR BOOKS CARRY THE TEAM"
    elseif bidSel == 0 then teamLine = "NIL - WIN NO BOOKS AND SCORE 100"
    else teamLine = "PARTNER BID " .. pb .. " - TEAM NEEDS " .. (pb + bidSel) end
    g.printf(teamLine, 640, 492, 640, "center")
    g.setColor(theme.dim)
    g.printf("tap < or > to choose, then BID - or LEFT/RIGHT and A", 640, 540, 640, "center")
    ui.button("BID", PLAY_BTN.x, PLAY_BTN.y, PLAY_BTN.w, PLAY_BTN.h, true)
  end

  -- hand result panel --------------------------------------------------
  if state == "hand_result" and result then
    local r1, r2 = result.r1, result.r2
    g.setColor(theme.feltDark)
    g.rectangle("fill", 360, 250, 1200, 430)
    g.setColor(theme.white)
    g.rectangle("line", 360, 250, 1200, 430)
    local banner, bc
    if r1.delta > 0 then banner, bc = "MADE IT!", theme.win
    elseif r1.delta < 0 then banner, bc = "SET", theme.quiet
    else banner, bc = "EVEN HAND", theme.quiet end
    g.setFont(ui.font(theme.fontHuge))
    g.setColor(bc)
    g.printf(banner, 360, 268, 1200, "center")
    g.setFont(ui.font(theme.fontMid))
    local function teamLine(label, r)
      if r.teamBid > 0 then
        return label .. "  BID " .. r.teamBid .. " - TOOK " .. r.toward ..
               "   " .. fmtDelta(r.delta)
      end
      return label .. "   " .. fmtDelta(r.delta)
    end
    if r1.delta > 0 then g.setColor(theme.winRing) else g.setColor(theme.quiet) end
    g.printf(teamLine("US", r1), 420, 392, 1080, "left")
    g.setColor(theme.quiet)
    g.printf(teamLine("THEM", r2), 420, 444, 1080, "left")
    g.setFont(ui.font(theme.fontSmall))
    g.setColor(theme.dim)
    local y = 500
    for _, pr in ipairs({{r1, "US"}, {r2, "THEM"}}) do
      local r, label = pr[1], pr[2]
      for seat, ok in pairs(r.nils) do
        g.printf(NAME[seat] .. (ok and " MADE NIL  +100" or " MISSED NIL  -100"),
          420, y, 1080, "left")
        y = y + 36
      end
      if r.penalty then
        g.printf(label .. " TOOK THE BAG PENALTY  -100", 420, y, 1080, "left")
        y = y + 36
      end
    end
    g.printf("A deals the next hand", 360, 636, 1200, "center")
  end

  -- game over ----------------------------------------------------------
  if state == "game_over" and gameOverData then
    g.setColor(theme.feltDark)
    g.rectangle("fill", 260, 300, 1400, 380)
    g.setColor(theme.white)
    g.rectangle("line", 260, 300, 1400, 380)
    g.setFont(ui.font(theme.fontHuge))
    if gameOverData.weWin then
      g.setColor(theme.win)
      g.printf("YOU AND PARTNER WIN!", 260, 340, 1400, "center")
    else
      g.setColor(theme.quiet)
      g.printf("WEST AND EAST TAKE THIS ONE", 260, 340, 1400, "center")
    end
    g.setFont(ui.font(theme.fontBig))
    g.setColor(gameOverData.weWin and theme.winRing or theme.quiet)
    g.printf("FINAL   US " .. gameOverData.us .. "  -  THEM " .. gameOverData.them,
      260, 480, 1400, "center")
    g.setFont(ui.font(theme.fontSmall))
    g.setColor(theme.dim)
    g.printf("press A for a fresh game", 260, 580, 1400, "center")
  end

  -- bottom strip: dad's own status + control hint ----------------------
  g.setFont(ui.font(theme.fontMid))
  g.setColor(theme.white)
  local mine = "YOU"
  if bids[1] then
    mine = "YOU  BID " .. (bids[1] == 0 and "NIL" or bids[1]) .. " - BOOKS " .. books[1]
  end
  g.print(mine, 60, H - 64)
  if state == "play_pick" then
    g.setFont(ui.font(theme.fontSmall))
    g.setColor(theme.dim)
    g.printf("LEFT/RIGHT choose - A plays", W - 620, H - 58, 560, "right")
  end
end
