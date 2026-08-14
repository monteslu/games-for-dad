-- cardtable/theme.lua - the ONE look shared by every card cart.
-- Change it here and every game (Jacks or Better, 5-stud, 7-stud) follows.
local T = {}

-- palette (0..1 floats)
T.felt        = {0.055, 0.36, 0.16}   -- classic casino green
T.feltDark    = {0.035, 0.26, 0.115}  -- vignette / panel shade
T.gold        = {0.95, 0.78, 0.25}    -- accents, focus ring, HELD badge
T.white       = {1, 1, 1}
T.ink         = {0.08, 0.08, 0.08}
T.win         = {0.35, 0.95, 0.45}    -- celebratory green
T.winRing     = {0.30, 0.62, 1.0}     -- result-highlight blue (gold = cursor, blue = winners)
T.lossRed     = {1.0, 0.38, 0.32}     -- bankroll flash on a losing round
T.quiet       = {0.85, 0.85, 0.80}    -- neutral text (losses stay calm)
T.dim         = {1, 1, 1, 0.45}

-- ── BOWLING'S OWN COLOURS ─────────────────────────────────────────────
--
-- The alley is a dim room with a lit lane in it, which is right for the
-- 3D but left the UI drawn entirely in white-on-charcoal -- correct, and
-- drab. These are the accents that put some life back into the flat
-- layer without competing with the lane for attention.
--
-- Warm and saturated, and CHOSEN FOR CONTRAST AGAINST A DARK GROUND:
-- every one of these sits above 4.5:1 on the near-black the HUD is drawn
-- over, which matters more here than in most games -- an eighty-five-year-
-- old eye loses contrast sensitivity long before it loses acuity.
T.lane        = {0.95, 0.72, 0.36}   -- the maple of the lane itself
T.strike      = {1.00, 0.55, 0.20}   -- hot orange: the best thing that happens
T.spare       = {0.45, 0.80, 1.00}   -- cool blue: good, but not a strike
T.openFrame   = {0.72, 0.74, 0.80}   -- neutral: an ordinary frame
T.hookLeft    = {0.55, 0.80, 1.00}   -- the two hook directions, mirrored
T.hookRight   = {1.00, 0.72, 0.35}
T.meterTrack  = {0.16, 0.15, 0.22}
T.pinRed      = {0.88, 0.22, 0.26}   -- the pins' own stripe colour

-- card metrics (art is 500x726; keep the ratio)
T.cardW, T.cardH = 260, 378
T.cardGap  = 36
T.holdLift = 36                      -- held cards tuck DOWN toward the player (kept = close to you)

-- type scale (bitfont sizes; big on purpose - 10-foot UI for an 85yo)
T.fontHuge  = 88                     -- result banner
T.fontBig   = 56                     -- money, buttons
T.fontMid   = 34                     -- paytable
T.fontSmall = 30

-- pacing: SLOW and readable. fast reads as "what just happened?"
T.dealTime   = 0.38                  -- one card's slide, seconds
T.dealStep   = 0.15                  -- stagger between cards
T.resultHold = 2.6                   -- how long the result banner sits

return T
