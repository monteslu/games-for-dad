-- cardtable/anim.lua - tiny tween helper. Slow, deliberate motion only.
local M = {}

local active = {}

-- ease-out cubic: fast start, gentle landing - reads as "a card being placed"
local function easeOut(t) local u = 1 - t; return 1 - u * u * u end

-- tween arbitrary numeric fields on obj: anim.tween(card, {x=..,y=..,s=..,rot=..,flip=..}, dur, onDone)
function M.tween(obj, to, dur, onDone)
  local from = {}
  for k, v in pairs(to) do from[k] = obj[k] or 0 end
  active[#active + 1] = { obj = obj, from = from, to = to, t = 0, dur = dur, onDone = onDone }
end

-- back-compat: slide only x/y
function M.slide(obj, tx, ty, dur, onDone)
  M.tween(obj, {x = tx, y = ty}, dur, onDone)
end

function M.update(dt)
  for i = #active, 1, -1 do
    local a = active[i]
    a.t = a.t + dt
    local k = easeOut(math.min(a.t / a.dur, 1))
    for f, target in pairs(a.to) do
      a.obj[f] = a.from[f] + (target - a.from[f]) * k
    end
    if a.t >= a.dur then
      table.remove(active, i)
      if a.onDone then a.onDone() end
    end
  end
end

function M.busy() return #active > 0 end

return M
