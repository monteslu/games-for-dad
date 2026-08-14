# Bowling — dev notes

Most of what follows is here because it was got **wrong first**, measured,
and then corrected. The numbers are not preferences: nearly every constant
in `bowling/app/main.lua` is derived from a real bowling alley, and the
places where the game diverges from life are marked as such.

If you change one number here, read the section it belongs to first. Several
of them are coupled in ways that are not obvious, and the failures are
usually silent — the game keeps running and just plays wrong.

---

## The scale

The whole alley is derived from two facts:

* pins sit on **12in centres**, and `PIN_SPACING` is **96px**
* so the lane runs at **8px per inch**, or ~68px per foot

Every other dimension follows. When something looks wrong, convert it to
inches and compare with a real alley before adjusting it.

| thing | real | here | why |
|---|---|---|---|
| lane width | 42in (3.5 × spacing) | `LANE_W` 344 (3.58 ×) | +6px clearance, see below |
| pin belly | 4.766in | `PIN_R` 19 | the widest radius |
| pin height | 15in | `PIN_H` 120 | |
| ball | 8.5in | `BALL_R` 52 (104 dia) | oversized, deliberately |
| pit | ~10ft | `PIT_LEN` 680 | |
| approach | 15ft | 52ft of geometry | see "the approach" |

The **ball is deliberately too big**: at true scale it would be 68px across
and nearly invisible on a tablet at this camera distance. It is the one
proportion knowingly wrong, and it is why the mass ratio has to be set
explicitly rather than falling out of the volumes.

---

## The rack has to fit on the boards

`LANE_W` is **not a free choice**. The outermost pins sit 1.5 spacings out
(144px) with a 19px radius, so their outer edge lands at 163 against a
half-width of 172 — 9px of clearance, or 2.6% of the width, against a real
lane's 1.5%.

It was 300 once. That put the outer edge at 166 against a half-width of 150:
**the corner pins overhung the lane by 16px** and stood partly over the
gutter. Not a tight rack — an impossible one.

`tools/rack.mjs` asserts this as arithmetic, reads the constants straight out
of `main.lua`, and runs in milliseconds without an emulator.

---

## Pin action is the game

A ball 104px across on 96px centres can physically touch **three or four
pins**. Everything past that falls because a pin hit it. That chain reaction
is what separates a strike from a split, and it is sensitive to four things
at once:

| constant | value | what happens if it drifts |
|---|---|---|
| `PIN_LIN_DAMP` / `PIN_ANG_DAMP` | 0.04 / 0.06 | was 0.6/0.7 — bled a struck pin's speed away before it reached its neighbours, so pins fell **in place** |
| `PIN_REST` | 0.55 | was 0.08 — pins absorbed impacts instead of passing them on |
| ball : pin mass | 4:1 | was 7.66:1, then 11.4:1 after the pins slimmed — a too-heavy ball ploughs through without deflecting, and the deflection is what carries it into the 5 pin |
| solver substeps | 8 | was 4 — a tight rack is a dense contact island that has to resolve as one system |

**The mass ratio does not maintain itself.** `PIN_DENSITY` and
`BALL_DENSITY` are set against the pin's *computed volume*, so any change to
the pin profile silently changes the ratio. When the pins were slimmed to
true scale the volume fell from 187899 to 65771 and the ratio jumped to
11.4:1 with no other edit. Re-solve it:

```
ratio = (4/3·π·BALL_R³ · BALL_DENSITY) / (pin_volume · PIN_DENSITY)
```

`tools/pinaction.mjs` measures the spread across eight aims. Its thresholds
come from the geometry rather than from taste: a pocket hit should take 7+,
an edge hit 3+ (the ball reaches one or two there, so anything above that
*is* pin action), and it fails if **every** aim strikes — aim that cannot
miss is aim that does not matter.

---

## Aim was 9.5× too loose, and it looked like a physics bug

The useful aim range on a bowling lane is genuinely tiny. The ball travels
~3100px from the foul line to the headpin, and the furthest its centre can
be off the centreline when it arrives is about half the lane — an angle of
under two degrees.

`MAX_AIM` was **0.28 rad, 16 degrees**. A 60px drag put the ball 272px off
the centreline on a lane 172px to the gutter. Every "aimed" shot was really
a gutter ball clipping the corner pin on its way past — which is why pin
action looked broken when the ball was simply never reaching the rack.

It is now derived from `LANE_W`, `GUTTER_W` and the run, and a **full sweep
reaches the gutter on purpose**. The first correction clamped at the last
line the ball can hold on the boards, which put the entire aim range inside
a rack spanning ±144 and made *every* shot strike. A game where no line can
miss is not easier; it is not a game.

---

## The hook is a real hook

A real hook is **side roll**, not a ball spinning like a top. The ball leaves
the hand rotating about a tilted axis, skids down the oiled front of the
lane barely gripping, then bites on the dry back end and arcs into the
pocket. The curve happens **late**, which is the entire point — it comes in
at an angle no straight ball can.

The old code set angular velocity about **Y**, which produces no lateral
force at all, so the hook did nothing. Meanwhile the aim overlay drew a
21-board curve, so the preview promised an arc the physics never delivered.

Now: angular velocity about **Z** (the direction of travel), plus a lateral
force via `b3.body_apply_force`, ramped in from `HOOK_START` (0.55 of the
run) so the ball goes straight early and turns late.

`HOOK_FORCE` is **solved, not tuned**. Over the bite phase, with the ramp
giving a mean acceleration of `HOOK_FORCE·g/2`, the lateral displacement is
`½at²`. A full hook should move the ball about ten boards (a board is
`LANE_W/39` ≈ 8.8px, so ~88px), which puts it at 0.27. The first value, 0.62,
worked out to 23 boards — measured on screen as a dead-centre ball hooking
clean off the lane.

> USBC's textbook shot hooks 7½ boards, so the maximum here is slightly
> above the classic reference line. If hard-hook ever feels unusable, this
> constant is the first place to look.

---

## The controls are three independent things

Direction, power and spin. They were **two axes for a while**: aim and spin
both read the sideways drag, so you could not aim right without also hooking
right, and results degraded monotonically with aim (9, 7, 6, 1 pins) because
the hook never got the chance to help.

Real bowling separates them, and it matters. USBC's textbook shot lays down
on board 14, crosses the arrow at 10 *heading toward the gutter*, and hooks
back to the pocket — "if a bowler were to achieve this angle by bowling a
straight game, he or she would have to line up two lanes away." **Line is a
function of hook; hook is not a function of line.**

So spin has its own control: a sweeping meter, tapped. This is the third
click of the classic golf meter, and the dexterity it asks for is *rhythm* —
watch a thing move, press when it is where you want it — which outlasts fine
motor control for small targets. Nothing to drag, nothing small to hit.

**The dead zone is wide and drawn.** A tap anywhere near centre is a
straight ball, so someone who taps without watching gets the simple game and
never knows the meter was doing anything.

### Accessibility numbers that are not arbitrary

* **24mm minimum touch target.** The Xbox Accessibility Guidelines (107) and
  the Game Accessibility Guidelines arrive at this independently for
  tablets. On a 10in tablet (1920px over ~217mm) that is 212px. An earlier
  spin dial used 128px stops — 14.5mm, above what a phone app would use and
  below what an eighty-five-year-old hand is entitled to.
* **Activate on release, not on touch**, with slide-off to cancel. The throw
  already worked this way; the meter matches it.
* **`MAX_PULL` is 180, not 300.** The pull is `dy` measured downward from
  wherever the finger lands. With the scoreboard owning the top 200px and
  the meter's tap zone below y=846, a 300px drag needed clear travel inside
  a 646px band — start any lower than y=546 and **full power was
  unreachable**, with nothing on screen to say so.

---

## Layout gotchas

**The camera is derived, not fixed.** It stands off at `dist` and rides
`dist·tan(52°)` above the deck, and `dist` grows with the span it has to
hold. At the setup framing it reaches x=−2730, y=2795 — so the room is sized
from *that*, not from the lane. A ceiling at y=1160 put the eye above the
roof looking down at its underside, and the frame was a dark slab with the
alley nowhere in it.

**The approach is 52ft of geometry for 15ft of visible floor.** Lengthening
it alone does nothing: the camera fits ball-to-rack, so anything behind the
foul line falls outside the frame — 632px of a 780px approach was off
screen. `APPROACH_SHOWN` in `love.draw` is what actually brings it into
shot. The extra length exists so the platform runs off the top and left
edges instead of ending in a visible corner; it is one static box the ball
can never reach, and the renderer shares meshes by size signature, so it
costs nothing.

**`FOUL_Z` is where the boards start and where the ball sits.** The ball is
placed at `FOUL_Z + BALL_R` so the two cannot drift apart. Four separate
places used to hardcode the ball's start — the aim range, the hook's ramp,
the camera's default framing, and the approach length — and all four now
measure from `FOUL_Z`.

**The pit is a hole, not a wall.** The backboard sat 179px past the back row
(2.6ft) and pins bounced straight back onto the deck. The floor now falls
away into a 680px well with kickback walls, and the backboard is far away,
low, and padded to restitution 0.02.

---

## Testing

```
./tools/test.sh          # all four, cheapest first
```

| tool | needs | what it proves |
|---|---|---|
| `rack.mjs` | nothing | the rack fits the boards; finger holes are round on the sphere |
| `framing.mjs` | romdev + GL | the camera holds the ball and pins at both framings |
| `pinaction.mjs` | romdev + GL | pins knock each other down, and aim still matters |
| `playgame.mjs` | romdev + GL | ten frames play to completion and the scoring is right |

`playgame.mjs` checks the cart against an **independent scorer** implemented
in the harness, because checking the cart's score against the cart's score
proves nothing. That scorer is itself verified against the canonical games
(300 / 150 / 0 / 90) before it is trusted to judge anything — an oracle that
is wrong is worse than no test, since it fails correct code and passes
broken code with nothing in the output to say which.

### These tests keep breaking in the same way

Three times now, a screenshot test has gone on **passing while silently
measuring the wrong thing**:

* it matched debug magenta to find the ball and pins; when the art landed it
  kept passing while measuring the ball alone, reporting a 1680px margin for
  a composition whose real margin was 41px
* the ball turned grey and the violet rule stopped matching — this one
  correctly **failed**, which is what the `sawPins`/`sawBall` assertions are
  for
* the new scoreboard's grid line is (57,61,78), inside the ball's colour
  range, and pinned the right margin to 1px while the pins had 100px

If you change the art, **check that the detectors still find what they
claim to.** They assert they found both objects for exactly this reason, and
they search only the play area, not the HUD bands.

Also: harnesses that keep their own copy of a game constant will drift.
`playgame.mjs` and `pinaction.mjs` parse `MAX_PULL` out of `main.lua`;
`rack.mjs` parses the pin geometry. When `MAX_PULL` moved 300 → 180, a
hardcoded copy would have clamped every throw to full power and made the
harness's own `power` argument mean nothing.

### Running the tests needs a real GL context

The romdev server must be up on `127.0.0.1:7331` **with a display**. A
headless shell fails at `loadMedia` with `failed to create EGL context`.
It needs `DISPLAY`, and the *live* Xauthority cookie — which is not always
what `$XAUTHORITY` points at:

```sh
ps -o args= -C Xwayland          # find the -auth path it is really using
DISPLAY=:0 WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/run/user/1000 \
  XAUTHORITY=/run/user/1000/.mutter-Xwaylandauth.XXXXXX \
  setsid nohup node src/mcp/server.js > /tmp/rom-dev-mcp.log 2>&1 < /dev/null &
```

---

## The scoreboard

Frames 1–9 carry two roll boxes, the tenth carries three. A blank box and a
dash mean **different things** — blank is "not bowled yet", `-` is "bowled
and knocked nothing down" — and a frame's total stays empty until it *can*
be known, back-filling in a cascade when the bonus balls land.

**A strike's X goes in the first box.** The sources genuinely disagree: USBC
puts it upper-right (an artifact of the paper sheet's single notched corner
box), the International Bowling Federation puts it upper-left. Left-to-right
wins because it is what every modern automatic scorer does, and it is the
only rule that survives the tenth frame — `X X X` has to read left to right.

Colour-coding strikes and spares is **not** canonical on real boards, where
the X and / do the work. It is here anyway: for an eighty-five-year-old on a
tablet the extra channel is worth more than strict fidelity.

---

## Sounds

The six in `app/sounds/` were synthesized for this game. The three it
inherited were minigolf's, and they were wrong with the volume up: a dry
plastic putter clack for a 7kg ball hitting maple, and a *laugh* for a bad
frame, which is the opposite of the tone this family is built for.

`roll` is pitched by throw speed and cut when the ball arrives or drops in
the channel. `pinhit` fires once per shot, read from the ball's own position
rather than a collision callback. `pinclack` is driven by the standing-pin
count, so the scatter gets its own sound without per-contact callbacks.
