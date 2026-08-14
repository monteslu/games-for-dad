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
  -- BOWLING'S OWN, synthesized for this game. The three minigolf sounds
  -- that used to be here were wrong in a way that is obvious with the
  -- volume up: a dry plastic putter clack for a 7kg ball hitting maple, and
  -- a LAUGH for a bad frame -- which is the opposite of the tone this
  -- family of games is built for.
  load("roll",     "roll.ogg")      -- the ball running down the boards
  load("pinhit",   "pinhit.ogg")    -- the ball into the rack
  load("pinclack", "pinclack.ogg")  -- one pin knocking another
  load("gutter",   "gutter.ogg")    -- into the channel, and the heart sinks
  load("strike",   "strike.ogg")    -- warm, major, earned
  load("spare",    "spare.ogg")     -- smaller, still pleasant

  -- kept: the old clack is still a serviceable UI tick
  load("clack", "clack.ogg")
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

-- Stop a sound early. The ball's roll is 3 seconds long and a roll that
-- ends in the gutter at 1.2s should not keep rumbling underneath the
-- gutter sound.
function M.stop(name)
  local s = srcs[name]
  if s then s:stop() end
end

function M.isPlaying(name)
  local s = srcs[name]
  if not s or not s.isPlaying then return false end
  local ok, v = pcall(function() return s:isPlaying() end)
  return ok and v or false
end

return M
