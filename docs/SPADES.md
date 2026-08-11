# Spades — design

The fourth dad game, and the first that isn't dealer-vs-player poker:
4-player partnership Spades. One human, three CPUs. The human's
partner sits north; east and west are the other team.

## The game

Standard partnership Spades, 52 cards, ace high, spades always trump.

- 13 cards each. Each player bids the books (tricks) they expect to
  win, Nil through 13. Partners' bids add; the team needs the
  combined total.
- **Bidding order is fixed: west, partner (north), east, human
  last.** This is standard rules with the human as permanent dealer
  (bidding starts left of the dealer), and it exists for one reason:
  dad always bids with all three bids already on the table. No
  rotating-dealer concept to track.
- **West leads the first book** of each hand (standard: left of the
  permanent dealer leads). The opening lead is any non-spade. After
  that, takers lead: whoever takes a book leads the next. The fixed
  seats split the positional edges fairly: dad always bids last (the
  information edge), west always leads first (the tempo edge) —
  neither team holds both.
- Follow suit if you can; otherwise anything, and a spade trumps.
  Highest spade wins the book, else highest card of the suit led.
- Spades can't be LED while the leader holds any other suit - the
  house rule, stricter than "until broken." Trump gets into a book by
  ruffing (or a lead from an all-spades hand), never by choice.
- Scoring: make the team bid, 10 x bid, +1 per overtrick (a "bag").
  Get set, -10 x bid. Ten accumulated bags costs 100 points. Nil is
  scored on the bidder alone: +100 made, -100 failed; a failed Nil's
  tricks don't help the partner's bid but do count as bags.
- First team to 500 wins the game.

Family deviations from the standard game:

- **No Blind Nil.** It's a fear mechanic (±200 on an unseen hand)
  built for expert comeback play. Regular Nil stays — it's fun and
  readable.
- **Bags stay, quietly.** Bags are what make overbidding matter, so
  they're kept, but the penalty lands the way losses always land in
  this family: quiet, no klaxon, never shameful.

## Score, not money (v1 decision)

v1 ships score-only: points are Spades' native currency, and running
a bankroll beside them means two numbers per hand that can genuinely
disagree — the team makes its bid the same hand the tenth bag lands,
and money flashes green while the score drops 90. One mood per hand.
The family money laws map onto the score instead:

- The per-hand heartbeat is the result banner: big green "MADE IT!",
  quiet "SET". Wins loud, losses quiet.
- The big mood-colored line is the US score, top-left, whole line.
- Nothing shames: a finished game (win or lose) resets to a fresh
  one on a single press.

The harness invariant: every hand's score delta must equal the
scoring table's answer for (bid, books, bags, nil) — asserted
independently by the test driver on every hand.

If betting ever comes back, the designed shape is: $5 flat on
making the team bid (net +$5/-$5), a made Nil pays double, bags
touch points only. It is one isolated change to the hand-result
path and nothing else.

## Table and cards

- **Seats:** human south, partner north, opponents east and west.
  Partners face each other, as at a real table.
- **Only the human's cards are face up.** The three CPU hands are
  face-down fans; the card backs are the procedural theme backs.
- **The human hand is sorted, spades on the left,** then by value
  within suit. (Suggested suit order S-H-C-D so colors alternate;
  settle in playtest.)
- **Played cards fly from the CENTER of the owner's hand** to the
  trick area mid-screen — never from the card's true position in the
  fan. A sorted face-down hand leaks information positionally: a card
  leaving the left edge says "low spade" even with its back showing.
  One origin per player, no tells. This also keeps the human's own
  play animation from drawing the eye back to the fan when the trick
  is what matters.
- **The trick is a cross: each played card lands offset toward its
  owner's seat** (west's card on the west side of center, north's
  toward north, dad's nearest him). Whose card is whose must be
  obvious at a glance — ownership reads twice, once in the flight
  from the owner's hand, once in where the card rests. At TV
  distance the resting position is the one that matters.
- The completed trick stays on screen (winner indicated) for a
  readable pause before it's swept toward the winner's seat — kept
  cards move toward the keeper, per the family's motion law.
- Per-seat badges show bid and tricks-taken (e.g. "3 of 5") at all
  times; nobody at TV distance should have to remember a bid.
- 13 cards + a center trick + 3 CPU fans is the busiest layout in
  the family. Corner rank and suit must stay visible in the human's
  splay; expect real playtest iteration here.

## Controls

Family scheme, nothing new to learn:

- Bidding is a LEFT/RIGHT number picker, Nil at the far left.
- Play is LEFT/RIGHT across the fan. **The cursor skips illegal
  cards entirely** — the game teaches follow-suit the same way the
  poker games teach hand rankings: through what the UI allows and
  rings, not through error messages.
- South or east face button confirms, both, always.
- Mouse/touch is an optional convenience on hosts that have one, never
  a requirement: click a legal card to move the cursor to it, click the
  gold PLAY button to play it, click DEAL on the idle screen, click
  anywhere to dismiss a result panel. Bidding taps too: the left/right
  thirds of the spinner panel step the bid, and the gold BID button -
  sitting exactly where PLAY sits during tricks - confirms it. The pad
  path is untouched throughout.
- CPU "thinking" is a frame-counted pause. Nothing times out;
  hand results persist until confirm.

## The CPUs

Rule-based, no search. (The literature's fancy approaches — MCTS
with learned inference tables — buy startlingly little over good
rules: AI Factory's history system improved card-inference error
43.3% → 42.6%. A solid heuristic bot is the right spend here.)

- **Bidding:** count likely winners — side-suit aces/kings
  discounted by suit length, high spades, +1 per spade past the
  third. Bid Nil only with no aces or kings, at most two low
  spades, and short-suit escapes.
- **Play:** win cheaply; duck tricks already lost; lead low toward
  partner's shown strength; never beat partner's winning card; cover
  a Nil threat; once the team bid is safe, shed bag-risking winners.
- **Inference:** track voids revealed when a player shows out of a
  suit. Cheap, and it's most of what makes a bot feel smart.
- One bot brain for all three seats, with a slight per-seat
  bid-aggressiveness offset for variety.

## Score keeping

Score keeping means across hands, in memory: the team scores, bag
counts, and bankroll carry from hand to hand through the whole race
to 500 (6-12 hands, 20-40 minutes), like a paper score pad on the
table. Nothing is persisted to disk; closing the cart is a fresh
game, same as the poker carts.

## Settled in the build (screenshot-verified headless)

- Suit order S-H-C-D (colors alternate), high card left per suit.
- Hand fan: 105px step at full card size — every corner rank and
  suit stays visible with 13 cards.
- East/west hands render as vertical face-down stacks at the screen
  edges, badges beneath ("BID n" / "BOOKS n", "NIL" for nil).
- The bid picker is a big center spinner (NIL..13), defaulting to
  the bot's suggested bid for the hand, with the running team total
  ("PARTNER BID 3 - TEAM NEEDS 5") right in the panel.
- UI copy says **books**, dad's word for tricks.

Still open for live playtesting with dad: pacing of the CPU pauses,
turn-marker size at TV distance, west/east stack legibility.
