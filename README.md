# Games for Dad

Original card games built for my dad: 85 years old, playing on a TV from
the couch with a gamepad. Every design decision follows from that player.
No timers, no bust-outs, no button chords, big readable type.

The games are [wasmcart](https://www.npmjs.com/package/wasmcart) carts
written in Lua. Each one is a single portable `.wasc` file that runs anywhere the
wasmcart player runs.

## The games

| Game | Folder | What it is |
|---|---|---|
| Jacks or Better | `jacksorbetter/` | Classic video poker. Hold, draw, win on a pair of jacks or better. |
| Five Card Stud | `fivecardstud/` | Heads-up stud against the dealer. One hole card, bet street by street. |
| Seven Card Stud | `sevencardstud/` | The full game: two down, four up, one more down, best five of seven. |

## Playing

```
npx wasmcart jacksorbetter/jacksorbetter.wasc
```

The carts are 1920x1080 and need a wasmcart player new enough to honor
cart resolution.

Controls, in every game:

- **D-pad LEFT/RIGHT** (and UP/DOWN where the layout calls for it) moves
  the gold highlight.
- **South or east face button** confirms. Both always work; there is no
  wrong confirm button.
- That is the entire scheme.

Money rules, in every game: $1000 stack, $5 flat bet, and the bankroll
can never bust. If you cannot cover the next bet, the house refills you
with a fresh stack, cheerfully.

## Repo layout

- `<game>/app/` - the game's Lua source and assets (self-contained)
- `<game>/main.wasm` - the wasmcart-lua engine the cart ships with
- `<game>/<game>.wasc` - the packed, playable cart
- `common/` - the shared card-table library and assets the games are
  built from (`common/sync.sh <game>` copies them into a cart)
- `docs/` - how the games are built, the architecture, and the design
  rules ([start here](docs/MAKING_GAMES.md))

## Rebuilding a cart

```
cd jacksorbetter
npx wasmcart pack --wasm main.wasm --assets app \
  --name "Jacks or Better" --width 1920 --height 1080 \
  -o jacksorbetter.wasc
```

## License and credits

Code is [MIT](LICENSE).

- Card faces: adapted from Byron Knoll's public-domain (CC0) vector
  playing cards, pre-scaled to the exact drawn size.
- Sounds: card and chip one-shots from Kenney's CC0 audio packs.
- Font: Atkinson Hyperlegible Bold, by the Braille Institute. The font
  remains under its own SIL Open Font License. Chosen because it is
  designed for low-vision readers.
