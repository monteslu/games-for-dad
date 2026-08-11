-- cardtable/sounds.lua - Kenney casino audio (CC0). Gentle, real, tactile.
local M = {}
local srcs = {}

local function load(name, file)
  srcs[name] = srcs[name] or {}
  local s = love.audio.newSource("sounds/" .. file)
  table.insert(srcs[name], s)
end

function M.loadAll()
  load("deal", "card-slide-1.ogg")
  load("deal", "card-slide-2.ogg")
  load("deal", "card-slide-3.ogg")
  load("place", "card-place-1.ogg")
  load("place", "card-place-2.ogg")
  load("shuffle", "card-shuffle.ogg")
  load("chips", "chips-handle-1.ogg")
  load("win", "chips-stack-1.ogg")
end

-- play a random variant so repeats don't sound robotic
function M.play(name, volume)
  local group = srcs[name]
  if not group then return end
  local s = group[love.math.random(#group)]
  s:stop()
  s:setVolume(volume or 1)
  s:play()
end

return M
