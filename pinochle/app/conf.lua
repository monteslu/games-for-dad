-- The layout in main.lua is authored on a 1920x1080 table. Declare it here
-- (the LOVE idiom) instead of relying on an engine default: the older engine
-- these carts were first packed against defaulted to 1920x1080, the current
-- one defaults to 1280x720 and reads this file. Stating it makes the cart
-- render identically on ANY engine build -- including the native Android
-- runtime, which is built from current sources.
function love.conf(t)
  t.window.width = 1920
  t.window.height = 1080
end
