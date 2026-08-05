# Design rules

These games are tuned for one player: 85 years old, sitting across the
room from a TV, holding a gamepad. Almost all of it is just good card
game UX. Every rule below was earned in live playtesting, not theorized.

## Controls

- **The entire scheme is d-pad + one confirm.** Nothing else to learn.
- **Both the south AND east face buttons confirm.** Different pads and
  different habits disagree about which button is "the" button; accept
  both, always, and there is no wrong press.
- **Navigation must match the geometry on screen.** If the button is
  drawn BELOW the cards, DOWN reaches it. Requiring right-past-the-last
  card to reach something visually below is a real failure.
- **Debounce every button edge: 9 frames (150ms).** A human cannot press
  twice that fast; a resting thumb, a bouncing contact, or a flaky host
  mapping can. Do edge detection yourself from the raw down-state.
- **Release-gate the big actions.** After dismissing a result with
  confirm, require an actual release before the next deal starts. A held
  button must never machine-gun hands.

## No pressure, no fear

- **The bankroll can never bust.** Short of the bet at deal time, the
  stack refills with "FRESH STACK - ON THE HOUSE" in gold. Cheerful,
  never shameful.
- **Flat bet, no bet sizing.** "How much?" is the most cognitively
  expensive decision in gambling; remove it entirely.
- **Losses are quiet, wins are loud.** A losing hand shows the hand
  name, no exclamation point, and the words "YOU LOSE" never appear.
  Wins get the name, an exclamation point, bigger type, and color.
- **Nothing times out.** Results stay on screen until the player deals
  again. They study the outcome as long as they like.

## Teach through the UI

- **Ring the cards that made the hand.** The evaluator reports which
  cards contribute; drawing rings on exactly those cards is how the game
  teaches hand rankings without a manual.
- **One meaning per color, everywhere:**

  | Color | Meaning | Never used for |
  |---|---|---|
  | Gold | the cursor / current selection | results |
  | Blue | result: the cards that won, win amounts | selection |
  | Red | bankroll after a losing round | anything else |
  | Green | win banner text | - |
  | White | neutral | - |

  Selection and result are different ideas; giving them the same color
  (gold rings on winning cards) reads as "these are selected."

## Cards on screen

- **Deal from a visible deck.** Every card FLIES from the deck pile,
  scaling up, flipping back-to-face, landing with the card sound ON the
  landing. Motion with a visible source reads at a glance; cards
  materializing from nowhere don't.
- **Pace the deal.** Roughly 0.4s per card with a stagger. Faster reads
  as "wait, what happened?"
- **Overlays never cover identity.** Any badge on a card sits across its
  CENTER so the corner rank and suit stay visible.
- **Kept cards move toward the player, discards away.** Physical
  intuition: you hold what you keep close.

## Type and money

- **Atkinson Hyperlegible Bold for everything.** Designed by the Braille
  Institute for low-vision readers, and it shows at TV distance.
- **Never render money in a font without a `$` glyph.** Engine debug
  fonts often lack it and silently print a space.
- **The money line is big (56px at 1080p minimum) and the WHOLE line
  changes color with the round's mood.** A patch of color reads from the
  couch; a colored digit does not.
