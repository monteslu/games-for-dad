# How these games were made (and how to make more)

## The tooling: romdev

These games were developed through
[romdevtools](https://www.npmjs.com/package/romdevtools) (`npx
romdevtools`), an MCP server that gives a coding agent - or a human at a
REPL - a full dev harness around retro/cart runtimes, including
wasmcart:

- **loadMedia** boots a `.wasc` in the server-side host.
- **input** schedules button sequences frame-accurately ("press b, wait
  40 frames, press right, ..."), which is how every betting line and
  menu path was driven without a human.
- **frame** steps the emulation and captures screenshots of exactly what
  the player sees, including mid-animation frames.
- **playtest** opens a real window for a human tester while the agent
  watches the same framebuffer, so "the results only flash for a
  second" style feedback lands with a screenshot attached.

The loop that built these games: edit Lua, repack, drive the state
machine through romdev, look at the screenshots, then hand the window to
a human and fix what they feel. Every layout bug found during
development was visible in a screenshot before a human ever hit it.

## Verification: prove money can't leak

Card games live and die on money correctness, so the acceptance harness
is an auto-play driver plus an invariant, run headless:

1. A scratch copy of the cart gets a `testDrive()` hooked into
   `love.update` that plays hands by itself (always betting/raising when
   offered, calling otherwise) and records the bankroll before each deal.
2. At every result it asserts the invariant from
   [ARCHITECTURE.md](ARCHITECTURE.md): bankroll delta is exactly
   `+staked`, `-staked`, or `0`. Anything else prints FAIL.
3. **Run a control that must fail.** Before trusting a green run,
   re-introduce a known money bug and confirm the harness catches it. A
   harness that can't fail is not a harness. (The real control caught
   11-14 failing hands out of 40; the fixed carts ran 160 hands and
   about 200 dealer raises across seeds with zero failures.)
4. One trap worth knowing: the deck RNG folds in human input timing via
   `cards.stir()`, so a scripted driver must call `stir()` itself or
   every automated run deals identical hands and your "40 hands" are
   really one hand 40 times.

## Recipe for a new game

1. Copy an existing cart folder (`fivecardstud/` is the smallest full
   example): `app/main.lua`, `manifest.json`, `main.wasm`.
2. Sync the shared library and assets: `./common/sync.sh <newgame>`
   (from the repo root). Reuse theme/cards/ui/poker/anim/sounds; a new
   game should mostly be a new `main.lua`.
3. Keep the state machine flat (`idle -> dealing -> ... -> result`) and
   route every input through the `readEdges()` pattern.
4. Keep the family laws: $1000 / $5 flat / never busts; results persist
   until confirm; the design rules in [DESIGN.md](DESIGN.md).
5. Pack:

   ```
   cd <newgame>
   npx wasmcart pack --wasm main.wasm --assets app \
     --name "My Game" --width 1920 --height 1080 -o mygame.wasc
   ```

   Note: without `--width/--height` the manifest defaults to 720p and a
   1080p layout will letterbox.
6. Verify in this order, every time: headless screenshots of every state
   including mid-animation, then scripted drives through the full
   decision tree, then a human with a real gamepad. The human always
   finds something the screenshots did not.
