-- merge.lua - the rules of Combo, such as they are.
--
-- The rule and its economy are NuSan's, from Combo Pool (PICO-8, p8jam2
-- 2019, https://www.lexaloffle.com/bbs/?tid=3467). Independently
-- implemented here, but the design is theirs.
--
-- There is exactly one rule: two balls of the same tier that touch become
-- one ball of the next tier up. Everything else in this file is the
-- consequence of that rule.
--
-- The whole design rests on the two tables in balls.lua being INVERTED
-- against each other:
--
--   tier      1    2    3    4    5    6    7
--   value     1    2    3    5   10   20  100
--   cost      4  3.5    3    2  1.5    1    0
--
-- A junk ball is worth nothing and costs the most to keep; the top tier is
-- worth everything and costs nothing. So "clear the clutter" and "score
-- points" are the same instruction, and the player never has to be taught
-- the strategy -- they discover it by watching the life bar move.

local ballart = require("balls")

local M = {}

-- How much life the balls currently on the table are costing.
function M.lifeCost(balls)
  local c = 0
  for _, b in ipairs(balls) do
    if not b.dead then c = c + (ballart.COST[b.tier] or 0) end
  end
  return c
end

-- Life remaining, 0..100.
--
-- CUBIC, deliberately. Linear would make the game a slow constant squeeze;
-- the cube means half a table full costs only 12% of your life and 80%
-- costs half of it. The game stays relaxed while there is room to work and
-- then turns urgent quickly, which is the shape that makes someone lean in.
-- (NuSan's curve from Combo Pool. Do not flatten it.)
function M.life(balls, maxAllowed)
  local ratio = M.lifeCost(balls) / maxAllowed
  local life = 100 - 100 * ratio * ratio * ratio
  if life < 0 then return 0 end
  if life > 100 then return 100 end
  return life
end

-- Is the table close enough to full that the player should be warned?
-- Four cost units of headroom, i.e. one more junk ball.
function M.warning(balls, maxAllowed)
  return M.lifeCost(balls) + 4 > maxAllowed
end

-- What a merge is worth. The combo multiplier is carried by the balls
-- themselves: a ball that has been banked off a wall, or that has just
-- merged, is worth more for a short window afterwards.
function M.mergeScore(tier, combo)
  return (ballart.VALUE[tier] or 0) * math.max(1, combo)
end

return M
