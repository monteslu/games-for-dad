-- The layout in main.lua is authored on a 1920x1080 table; without this the
-- engine renders it at its 1280x720 default and the whole game goes soft.
function love.conf(t)
  t.window.width = 1920
  t.window.height = 1080
end
