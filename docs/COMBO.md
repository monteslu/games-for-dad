# Combo (working title) - design spec

The sixth dad game, and the second 3D one. Same stack as Eight Ball:
**Box3D** for physics, **3DreamEngine** for rendering, wasmcart-lua cart.

Inspired by **Combo Pool** by NuSan (PICO-8, p8jam2 2019), which monteslu
ported to the GameTank (`~/code/cliemu/gtlua-ports/combo-pool/`). That is
the design reference, not the code reference: this is an original game
taking the merge mechanic into our own layout, physics and 3D look.

## What we take from Combo Pool

**The merge.** Two balls of the same colour that touch become ONE ball of
the next colour up. Seven tiers. Merging the top tier detonates and clears
the board.

**Life is clutter, not time.** This is the mechanic worth stealing, and the
reason the game has tension without a clock:

```
plife = 100 - 100*(lifecost/maxallowed)^3
```

Every ball on the table costs life by tier, and the costs are INVERTED
against the scores:

| tier      | 1 | 2   | 3 | 4 | 5   | 6  | 7   |
|-----------|---|-----|---|---|-----|----|-----|
| value     | 1 | 2   | 3 | 5 | 10  | 20 | 100 |
| life cost | 4 | 3.5 | 3 | 2 | 1.5 | 1  | 0   |

So low balls are worth nearly nothing AND cost the most to keep. Merging
up is simultaneously how you score and how you survive: one number does
both jobs, and the player never has to be told the strategy. Clearing
clutter IS the strategy.

The CUBIC is load-bearing. At half capacity you have lost only 12% of your
life; at 80% you have lost half. The game stays relaxed and then panics
fast, which is the right shape. Do not linearise it.

Nothing times out, which is also the family rule (see DESIGN.md).

**Bounces build the multiplier.** A ball that bounces off a wall raises its
own multiplier before it merges. With no pockets, the walls are the whole
toolkit, so this rewards the bank shot.

## What we change, and why

**LAYOUT: 4:3 field on the LEFT, shoot from the RIGHT.** monteslu's call,
and playing the GameTank port shows why. Combo Pool launches from the
BOTTOM of a square arena, and dead balls drift into the bottom corners --
directly on top of the firing line, in the exact space you need to aim
through. A wide field with a side launcher gives a long clear lane and
collects clutter AWAY from where you are working.

```
 1920 x 1080
 +--------------------------------+---------+
 |                                | WARNING |   <- life bar, top right
 |                                +---------+
 |     4:3 PLAY FIELD             |         |
 |     1440 x 1080                |   cue   |   <- pull the cue right,
 |                                |  space  |      shoot LEFT
 |                                +---------+
 |                                |   HUD   |   <- score / multiplier
 +--------------------------------+---------+
                                   480 wide
```

**BIGGER BALLS.** `BALL_R = 52`, so the field is 13.8 x 10.4 ball
diameters. Combo Pool is 16 across, Eight Ball is 33 -- this sits deliberately
chunkier than either, because a merge has to be readable at a glance from
across a room, and because a 7-tier colour ramp needs the ball big enough to
carry the colour.

Consequence: `maxallowed` MUST be retuned. The original's 34-50 budget
assumes ~16 diameters of space. Fewer, bigger balls means a smaller budget.
That constant is the difficulty dial and it is the thing to playtest first.

**NO POCKETS.** Nothing to sink, so the walls are the only geometry. Worth
considering angled corners so a shot can be worked around the field rather
than just banked off flat walls.

**3D, not sprites.** Seven tiers = seven textured spheres, reusing Eight
Ball's ball rendering wholesale: baked spherical shading, tight specular,
Fresnel rim, cloth bounce light, and the contact shadows that stop a ball
reading as a flat disc. That work is done and verified; see
`eightball/app/balls.lua` and the `pool-ball-3d-rendering` memory.

**CONTROLS: Eight Ball's, unchanged -- and the REAL CUE, not a pointer.**
Combo Pool aims with a little rotating arrow at the launcher. We use the
actual 3D cue stick from Eight Ball: it sits behind the ball, swings with
the aim, draws back as you load power, and fades cream -> red as the shot
grows. The stick IS the power meter, so nothing extra is on screen and
nothing is timed.

LEFT/RIGHT swing the aim, UP/DOWN draw the cue back, confirm strikes; on
touch, drag from the ball and release. Already built, already playtested
with dad, and a cue is a cue. (Combo Pool's "hold for fine aim" is worth
keeping as a refinement.)

Because the launcher is on the RIGHT and shots travel LEFT, the cue's
rest angle is mirrored from Eight Ball's, and the pull-back extends into
the right-hand column -- which is exactly why that column is reserved for
the cue rather than packed with HUD.

## Open questions for playtest

1. `maxallowed` at r=52. Start near 24 (about 6 junk balls) and tune.
2. Does the cue ball persist, or is each shot a NEW ball entering play?
   Combo Pool launches a fresh marble every time, and that is probably
   right -- it is what makes clutter accumulate.
3. Do merged balls keep momentum? Combo Pool's merge is inelastic. With
   real rigid-body physics that will feel different and needs a look.
4. Angled corners: do they add anything, or just make the bank shot
   harder to read?
