-- sounds.lua - Minigolf's audio.
--
-- The three sounds are the ORIGINAL game's own (frozenjs/minigolf, MIT,
-- Iced Development LLC), converted from mp3 to ogg. They are kept because
-- they are already right: a dry plastic clack, a hollow rattle for the
-- cup, and a laugh for a hole that went badly.
--
-- The clack's gain is scaled by IMPACT, exactly as the original did. That
-- detail is most of why the game feels good -- a gentle tap against a rail
-- should not sound like a full-blooded drive, and a fixed-volume clack
-- makes every collision feel the same weight.
local M = {}
local srcs = {}

local function load(name, file)
  local ok, s = pcall(love.audio.newSource, "sounds/" .. file)
  if ok and s then srcs[name] = s end
end

function M.loadAll()
  load("clack", "clack.ogg")   -- ball against a rail, or the putt itself
  load("hole",  "hole.ogg")    -- dropping in the cup
  load("laugh", "laugh.ogg")   -- eight strokes and counting
end

-- volume 0..1; pitch is optional and used to keep repeated clacks from
-- sounding mechanically identical.
function M.play(name, volume, pitch)
  local s = srcs[name]
  if not s then return end
  s:stop()
  s:setVolume(volume or 1)
  if pitch and s.setPitch then s:setPitch(pitch) end
  s:play()
end

return M
