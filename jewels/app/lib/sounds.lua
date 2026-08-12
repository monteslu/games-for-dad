-- sounds.lua - Jewels' audio, mapped onto the shared Kenney one-shots (CC0).
--
-- This overrides the cardtable sounds lib because a match-3 needs a
-- different vocabulary than a card game. The card slides and chip stacks
-- are the right MATERIAL though: dry, short, tactile, no music.
--
-- Sound is not decoration here. Playing Bejeweled muted measurably hurts
-- people's play, because the audio reports what happened faster than the
-- eye can parse the board. So: every action gets a distinct sound, and
-- CASCADES RISE IN PITCH -- that rising run is the game telling you the
-- chain is still going without you having to watch for it.
local M = {}
local srcs = {}

local function load(name, file)
  srcs[name] = srcs[name] or {}
  local ok, s = pcall(love.audio.newSource, "sounds/" .. file)
  if ok and s then table.insert(srcs[name], s) end
end

function M.loadAll()
  -- moving the cursor: the quietest thing in the game
  load("move",  "card-slide-1.ogg")
  -- picking a jewel up
  load("pick",  "card-place-1.ogg")
  load("pick",  "card-place-2.ogg")
  -- a legal swap
  load("swap",  "card-slide-2.ogg")
  load("swap",  "card-slide-3.ogg")
  -- an ILLEGAL swap: soft and neutral. Never a buzzer, never a failure
  -- noise -- an illegal swap costs nothing, so it must not SOUND like a
  -- mistake. It is just a nudge.
  load("bump",  "chips-handle-1.ogg")
  -- jewels clearing
  load("clear", "chips-collide-1.ogg")
  load("clear", "chips-stack-1.ogg")
  -- jewels landing after a fall
  load("fall",  "card-place-2.ogg")
  -- the board reshuffling itself
  load("shuffle", "card-shuffle.ogg")
end

-- play a random variant so repeats don't sound robotic.
-- `pitch` lets the caller push a cascade up the scale.
function M.play(name, volume, pitch)
  local group = srcs[name]
  if not group or #group == 0 then return end
  local s = group[love.math.random(#group)]
  s:stop()
  s:setVolume(volume or 1)
  if pitch and s.setPitch then s:setPitch(pitch) end
  s:play()
end

return M
