# Architecture

## The stack

```
app/main.lua + app/lib/*.lua      the game (plain Lua)
        |
main.wasm                          wasmcart-lua engine (Lua 5.4 compiled
        |                          to WASM, LOVE-style API: love.graphics,
        |                          love.audio, love.pad, love.math)
        |
<game>.wasc                        zip of main.wasm + app/ + manifest,
        |                          produced by `npx wasmcart pack`
        |
wasmcart player                    any host that implements the wasmcart
                                   spec (desktop player, web, libretro)
```

The engine ships INSIDE each cart, so a `.wasc` is fully self-contained:
one file, no install, same behavior on every host. If the engine gets a
fix, carts must be repacked to pick it up.

Carts declare their resolution in the manifest (these are 1920x1080) and
hosts size their window to it.

## The shared library (`common/lib/`)

Every game is a thin `main.lua` over the same six modules. Reuse them;
do not fork them.

- **theme.lua** - one source of truth for colors, card metrics, font
  sizes, and animation pacing. If two games disagree on a color, one of
  them is wrong.
- **cards.lua** - deck building, shuffling, card art, and the flight
  animation for dealing. Also `cards.stir(frameNo)`: mixes human input
  timing into the RNG on every button edge, so no two sessions ever deal
  the same sequence even on a host that seeds deterministically.
- **ui.lua** - fonts, buttons, focus rings, win rings, badges, and the
  money line.
- **poker.lua** - hand evaluation. `evaluate(hand)` returns the hand key,
  display name, and WHICH card indices make the hand (so the UI can ring
  them). `strength`/`compare` do full tiebreaker-aware showdowns.
  `best5(hand)` finds the best five of N (seven card stud is 21
  combinations over the same evaluator).
- **anim.lua** - a tiny tween system with completion callbacks. All card
  motion runs through it.
- **sounds.lua** - loads the one-shot samples and plays a random variant
  per event so repeats don't sound robotic.

## The state machine pattern

Every game is a flat state machine driven from `love.update`:

```
idle -> dealing -> (decide -> dealer_act ->)* -> showdown -> result
```

- `result` persists until the player confirms; nothing ever times out.
- Dealer "thinking" is a frame-counted `pause(frames, fn)`; no
  coroutines, no nested callbacks beyond the deal animations.
- ALL input goes through one `readEdges()` at the top of update: edge
  detection done by hand from `love.pad.isDown`, a 9-frame (150ms)
  debounce per button, and a release gate on big actions so a held
  button can never machine-gun deals. Never trust a host's "was pressed"
  to not repeat.

## Money

One variable, `staked`, tracks the player's contribution to the pot.
The dealer always matches, so the pot is `staked * 2` and results are:

- win: `bankroll += staked * 2` (net `+staked`)
- loss/fold: nothing back (net `-staked`)
- push: `bankroll += staked` (net `0`)

That gives a testable invariant: from deal to result, the bankroll delta
is exactly `+staked`, `-staked`, or `0`. The verification harness in
[MAKING_GAMES.md](MAKING_GAMES.md) asserts it on every hand. Any money
line that touches `bankroll` without going through this model is a bug
(one such bug shipped briefly: charging the player at dealer-raise time
AND at call time, which leaked $5 per raise).

## Rendering and audio constraints

- The engine packs every loaded image and font glyph into one texture
  atlas. Budget rule: size card art to the exact size it is DRAWN
  (`common/assets/cards/` is pre-scaled; originals live in
  `cards-src/`). If the log shows `atlas-upload` lines after boot, the
  atlas is thrashing and something is oversized.
- Sound effects are sub-second one-shots. Keep them that way.
- Card backs are drawn procedurally (the CC0 deck ships no back), so
  they match the theme at any scale.
