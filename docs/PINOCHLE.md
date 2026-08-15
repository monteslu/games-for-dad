# Pinochle — design and dev notes

The sixth dad game and the second trick-taking one: four-handed
partnership pinochle, one human, three CPUs. You sit south with PARTNER
opposite; WEST and EAST are the other team.

**It is deliberately shaped after [Spades](SPADES.md)** — same seats, same
input pattern, same state machine, same layout zones — because the whole
point of a second trick-taking game is that it feels like the one he
already knows. What differs is what pinochle actually adds: a 48-card
double deck, bidding to a number, naming trump, and meld.

---

## The game

- **48 cards**: two each of A, 10, K, Q, J, 9 in every suit. Twelve to a
  player, dealt four at a time.
- **The ten ranks second**, between the ace and the king. This is the
  single most surprising rule to anyone who has played anything else.
- **Bidding** starts at 250 in steps of 10. West bids first and **dad bids
  last**, exactly as in Spades, so he always decides with every other bid
  already on the table. Pass is final. If all four pass, the dealer's team
  takes it at the minimum.
- The high bidder **names trump**, then the **pass**: the declarer's
  partner sends **4 cards** across and the declarer sends **4 back** (which
  may include cards just received). The declarer then **leads**.
- **Meld** is laid down before play: partners' melds add, and both teams
  score theirs.
- Twelve tricks. Counters are **A, 10 and K at ten each**; last trick is
  ten. Every hand is worth exactly **250** in trick points.
- Making the bid scores meld + tricks. **Going set loses the whole bid**
  and the meld with it. Defenders always score.
- First team to **1500**. If both cross in one hand, the declaring team
  wins.

### Family deviations, flagged honestly

- **No "save your meld" rule.** Standard play voids a team's meld if they
  take zero tricks. It fires perhaps once in hundreds of hands and looks,
  to a casual player, like the game stole their points for no visible
  reason.
- **Meld is computed and named for you.** Standard play makes you find and
  declare your own, and missing meld is your loss. Meld-spotting is the
  hardest, most eyestrain-heavy part of pinochle; the game does it and
  names each one on screen.
- **The traditional "must always head the trick" rule**, not the post-1945
  relaxation where heading is only required on a trump lead. About half of
  US players use each; "always beat if you can" is one rule to remember
  instead of a conditional one.
- **No kitty and no three-handed variant.**

---

## The pass, and a rule I got wrong first

**I originally shipped this without a passing phase**, on research that
said passing belonged to double-deck pinochle and was rare in the
single-deck partnership game. That was wrong, and it took a second look to
establish it — the first pass conflated *"distinctive to double-deck"*
with *"rare in single-deck."*

Passing is standard. [Pagat](https://www.pagat.com/marriage/pinmain.html)
is emphatic — *"Exactly four cards must be sent; no more and no fewer"* —
and frames the NON-passing game as the variant ("cutthroat").
[cardgames.io](https://cardgames.io/blog/how-to-play-pinochle/) says
"Passing cards is not optional." Every serious digital implementation does
it: NeuralPlay defaults to 4 and makes it configurable 0–5, Trickster
offers none/2/3/4, cardgames.io and World of Card Games are always-on at 4.

**Four each way is dominant; three is a real minority variant** (gamerules
documents a 3-card *blind* pass). This game uses four, sequential — the
partner sends first and the declarer sees what arrived before choosing the
return, which is both the majority rule and the more forgiving one.

**It happens after trump is named**, which is forced rather than chosen:
you cannot sensibly pick cards to pass without knowing trump, and the
exchange changes what melds, so it must sit between `trump_pick` and
`meld_show`.

Strategy, and what the bot does: the **partner sends trump first, then
aces** — you are arming the player who has to make the contract — and the
**declarer sends back losers and off-suit junk**, never trump if it can be
helped.

**Adding it moved the numbers a lot.** The set rate fell from 38% to 21%,
because four cards of trump and aces makes contracts markedly more
makeable. That is the pass doing its job, but it left the bid estimate too
timid, so the discount was re-tuned 0.68 → 0.86 and the rate is back to
~26% — about what real partnership pinochle sets.

---

## The research, and two things it corrected

Sources: [pagat](https://www.pagat.com/marriage/pinmain.html),
[Wikipedia](https://en.wikipedia.org/wiki/Pinochle),
[NeuralPlay](https://www.neuralplay.com/pinochle_help.html),
[SCW Pinochle Club](https://pinochle.scwclubs.com/rules-of-the-game/).

**Two traps worth recording**, because both are easy to walk into:

1. **The "Avondale" 4-3-2-1-0 counter schedule is Bid Euchre, not
   pinochle.** I had written it before the research came back. The
   invariant to hold onto instead: every legitimate pinochle counter
   scheme totals **250 a hand**.
2. **The Bicycle/USPC page documents the TWO-HANDED draw game.** Its
   11/10/4/3/2 card values and its "only one meld per turn" restriction
   are artifacts of that variant and are wrong in a partnership game.

Where sources genuinely disagree — the minimum bid (150 vs 250), the game
target (1000 vs 1500), and whether you must head the trick always or only
on a trump lead — this game picks the most common US partnership answer
and says so above.

---

## Meld is three independent classes

This is the rule implementations usually get wrong, and it fails in **both
directions**:

- paying 190 for a bare trump run — wrong, because the run and the royal
  marriage are both class A, so the run absorbs its own K-Q
- refusing to pay both a marriage and a pinochle on the same Q♠ — wrong,
  because those are different classes

> **A card may be used in one meld of EACH class, never twice within the
> same class.**

| class | melds |
|---|---|
| **A** | trump run, marriages, the dix |
| **B** | pinochle (Q♠ + J♦) |
| **C** | arounds (one of a rank in all four suits) |

`meld.lua` models it as three passes, each consuming cards from its own
copy of the hand. Both cases then fall out with no special case — and
**190 emerges naturally** as run-plus-spare-marriage rather than being a
named value.

```
CLASS A  run 150   double run 1500   royal marriage 40
         marriage 20                 dix 10 (each)
CLASS B  pinochle 40                 double pinochle 300
CLASS C  aces 100/1000   kings 80/800   queens 60/600   jacks 40/400
```

There is **no tens-around and no nines-around**. Tens around is worth
nothing and nines around is a standing joke.

**230 is not reachable in one suit**, whatever the tables say: it needs two
spare K-Q pairs on top of a run and only two copies of each card exist.
Verified by enumeration — a full twelve-card spade holding tops out at 1520
(double run + both dixes).

---

## Play obligations are stricter than Spades

In order:

1. **Follow suit** if you can.
2. And if you can, **beat the current winner** — *even when your own
   partner is winning it*.
3. Void? **You must trump** if you hold any.
4. Already trumped? **You must overtrump** if you can.
5. Only then may you discard anything.

**The UI hard-blocks illegal plays** by dimming those cards rather than
showing an error. For a casual player this is the single most valuable
decision in the list: the obligations are strict and easy to violate
accidentally, and greying out removes the entire category of "why won't it
let me."

**Two identical cards on one trick: the first played wins.** It falls out
of a strict `>` in play order and needs no special case.

---

## The bot

Rule-based, like Spades' — counted winners for the bid, and a short list of
play heuristics. A search would play better and be far harder to reason
about when it does something odd, and "why did my partner do that" is a
real cost in a game meant to be relaxing.

**The bid was conceptually wrong at first, not merely mistuned.** It
estimated the *bidder's own hand*, when a bid is a claim about the **team**.
A median hand is worth about 115 against a 250 minimum, so **1904 of 2000**
simulated hands passed out. Adding the unseen partner's expectation
(median meld ~45, about three trick-winners) fixed the model — measured,
the estimator now predicts 232 against an actual 228, within 2%.

**A median declaring team scores about 228 against a 250 minimum**, which
is not a bug in the estimate: it is why the dealer-forced-bid rule exists.
The bidder therefore bids off the *ceiling* rather than the expectation,
since a bot that only bids on certainties never opens and the auction dies
every hand.

### Naming trump, and the tiebreak

`bestTrump` picks the highest-melding suit, and **a third of hands tie** --
most hands have no meld at all in most suits, and every one of those ties
at zero. A strict `>` over a fixed S,H,C,D scan therefore handed every tie
to spades, naming it 39% of the time against diamonds' 17%.

Worse than unfair: on a tie it would name a bare spade suit over a long,
strong heart one. Trump is where tricks come from, so when meld cannot
separate two suits, **length and high cards** do. Measured on identical
hands, the tiebreak makes 45 more contracts out of 2869 at the same
average bid.

**Spades still leads a little, and that is correct.** Over *all* hands the
split is 25/25/26/25, dead even -- but the auction picks the strongest of
four hands, and among hands melding 80 or more spades is 33%. The pinochle
itself is a spade queen, so spade-heavy hands meld higher and those are
exactly the hands that win auctions. `simulate.lua` asserts the share
stays in a band that allows this while still failing the old bug.

---

## Testing

```
./tools/test.sh
```

| tool | needs | what it proves |
|---|---|---|
| `simulate.lua` | a standalone Lua 5.4 | the rules hold over thousands of hands |
| `playhand.mjs` | romdev + GL | the cart gets from DEAL to a scored hand |

**Neither replaces the other.** `simulate` plays ten thousand hands and
asserts every invariant, but never loads the cart — so it cannot catch a
game that deals correctly and then hangs. `playhand` drives the real cart
with the pad, but plays one hand, so it cannot tell you the meld table is
right.

`simulate` asserts, every hand: exactly 250 trick points, no bot ever picks
an illegal card, no card played twice, hands empty at the end. It separates
**chosen** contracts from ones **forced** on the dealer, because folding
them together hid whether the bidding was sane — 38% set on chosen, 71% on
forced, which is the split the real game has.

Build the Lua it needs from the engine's own vendored copy:

```sh
cd ../../wasmcart-lua/runtime/vendor/lua && make linux
```

### The stubbing trap that cost the most time

`rules.lua` shuffles with `cards.rand`. Spades' bundled copy of the shared
library predates that export, and **my unit tests stubbed it** — so every
pure test passed while the real cart died on frame one with *"attempt to
call a nil value (field 'rand')"*, showing a title screen that ignored
every button.

Two lessons, both now in the tooling: **sync from `common/`** rather than
copying a sibling game's `app/lib`, and a pure-logic test that stubs a
dependency proves nothing about the dependency.

### Running playhand needs a real GL context

The romdev server must be up on `127.0.0.1:7331` **with a display**. A
headless shell fails at `loadMedia` with `failed to create EGL context`.
It needs `DISPLAY` and the *live* Xauthority cookie — which is not always
what `$XAUTHORITY` points at:

```sh
ps -o args= -C Xwayland          # find the -auth path it is really using
DISPLAY=:0 WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/run/user/1000 \
  XAUTHORITY=/run/user/1000/.mutter-Xwaylandauth.XXXXXX \
  setsid nohup node src/mcp/server.js > /tmp/rom-dev-mcp.log 2>&1 < /dev/null &
```

### A confirm is a press AND a release

The game release-gates its big actions: after dismissing a panel it waits
for the button to come up before the next one accepts anything. A driver
that mashes the button just holds the gate shut — which looks exactly like
a hang. `playhand.mjs` presses for 3 frames then steps 14.

---

## Layout notes

The screen is three bands and everything has to stay inside its own:

| band | y | who owns it |
|---|---|---|
| north hand | 50–210 | PARTNER's face-down fan |
| the middle | 222–608 | the trick, and every panel |
| south fan | 620–998 | dad's twelve cards |

Panels that ignored this were drawn straight over the hands — the meld
panel was 660px tall in a 386px gap. **Trump goes in the left gutter**
under the US score rather than centred, because the north fan runs across
the middle of the top of the screen.

**Suit pips are drawn, not typed.** Atkinson Hyperlegible has no glyphs at
U+2660–2666 — all four verified absent from the font's cmap — so printing
the character renders *nothing at all*, silently. Same trap as the family
rule about never rendering money in a font without a `$`.
