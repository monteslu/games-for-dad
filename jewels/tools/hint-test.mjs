// The hint must be ASKED FOR, never offered.
//
// Jewels used to show a hint after eight idle seconds. That reads as a
// clock: sitting and thinking turns into a race to move before the game
// decides you are stuck, which is the exact pressure this family of games
// exists to remove. Nothing here moves unless he moves it, and that has to
// include the help.
//
// Two assertions, and the second matters as much as the first: removing
// the timer is easy to do in a way that also breaks the button. It did --
// pressing HINT sets `acted`, and the first version of the fix cleared the
// hint on `acted` in the same frame it was created, so the status text
// appeared and the highlight never did.

import { execFileSync } from 'node:child_process';

const HOST = 'http://127.0.0.1:7331';
const CART = new globalThis.URL('../jewels.wasc', import.meta.url).pathname;
const session = 'hint-' + Math.random().toString(36).slice(2, 8);

async function tool(name, body) {
  const r = await fetch(`${HOST}/tool/${name}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-romdev-session': session },
    body: JSON.stringify(body),
  });
  try { return JSON.parse(await r.text()); } catch { return {}; }
}
async function shot(p) { await tool('frame', { op: 'screenshot', outputPath: p }); return p; }

// Does the board show a hint RIGHT NOW?
//
// The highlight is a bright, near-white outlined box drawn over a cell.
// Detecting it by frame-to-frame difference does not work for the idle
// case: if a hint appears early and is still up in both samples, the two
// frames agree and the test reports "nothing happened" while a hint sits
// on screen. That is exactly how the first version of this test passed its
// own control. Look for the thing itself instead.
function hintOnBoard(png) {
  const py = `
from PIL import Image
im = Image.open(${JSON.stringify(png)}).convert('RGB')
# The highlight is CYAN -- drawn as (0.35, 0.85, 1.0), so blue and green
# both run well ahead of red. Nothing else on the board is that colour: the
# blue jewels are blue-dominant but their green sits low, and the white
# jewel is neutral.
#
# An earlier version looked for "a long straight run of near-white", which
# matched the white jewel's own disc and reported a hint in every sample of
# an idle board -- passing its own control and then failing a correct
# build. Detect the colour the hint is actually drawn in.
# Measured from real frames: the outline lands around (104,207,230) and
# the tinted fill around (60..67, 108..115, 127..134). Both are BRIGHT
# blue-green with green close under blue -- the board's blue jewel is
# (54,119,217) with green far below blue, and the green jewel is
# (61,243,136) with blue far below green. Neither matches.
n = 0
for y in range(60, 1020, 2):
    for x in range(60, 1260, 2):
        r, g, b = im.getpixel((x, y))
        if b > 100 and b - r > 60 and abs(int(b) - int(g)) < 40 and g - r > 40:
            n += 1
print(n)
`;
  return Number(execFileSync('python3', ['-c', py], { encoding: 'utf8' }).trim());
}
// Measured separation on real frames: ~510 of this cyan on an idle board
// (jewel edges and antialiasing), ~3300 with a hint up. 1500 sits clear of
// both, so neither a busy board nor a faint one can straddle it.

// How much of the BOARD changes between two frames. A pulsing hint
// highlight cannot help but differ; a still board does not.
function boardDelta(a, b) {
  const py = `
from PIL import Image, ImageChops
a = Image.open(${JSON.stringify(a)}).convert('RGB')
b = Image.open(${JSON.stringify(b)}).convert('RGB')
d = ImageChops.difference(a.crop((60,60,1260,1020)), b.crop((60,60,1260,1020)))
print(sum(1 for v in d.get_flattened_data() if sum(v) > 25))
`;
  return Number(execFileSync('python3', ['-c', py], { encoding: 'utf8' }).trim());
}

const fails = [];
const ok = (name, cond, detail) => {
  console.log(`  ${cond ? 'ok  ' : 'FAIL'}  ${name}${cond ? '' : ' -- ' + detail}`);
  if (!cond) fails.push(name);
};

await tool('loadMedia', { platform: 'wasmcart', path: CART });
await tool('frame', { op: 'step', frames: 60 });

// ── 1. idling must not summon a hint ─────────────────────────────────
// 900 frames is 15 seconds: the old timer fired at 8.
// Sample REPEATEDLY across the idle period: a hint that appears and fades
// between two lone samples would be missed entirely.
let sawHint = 0;
for (let i = 0; i < 10; i++) {
  await tool('frame', { op: 'step', frames: 120 });   // 2s each, 20s total
  const n = hintOnBoard(await shot(`/tmp/claude-1000/hint-idle-${i}.png`));
  if (n > 1500) sawHint++;
}
ok('idling for 20s summons NOTHING', sawHint === 0,
   `a hint was on the board in ${sawHint} of 10 samples taken while ` +
   'nobody touched anything');

// ── 2. the HINT button still works ───────────────────────────────────
await tool('input', { op: 'pointer', id: 0, x: 1584, y: 954, left: true });
await tool('frame', { op: 'step', frames: 4 });
await tool('input', { op: 'pointer', id: 0, x: 1584, y: 954, active: false });
await tool('frame', { op: 'step', frames: 10 });
const pressed = hintOnBoard(await shot('/tmp/claude-1000/hint-on.png'));
ok('pressing HINT highlights a move', pressed > 1500,
   'no highlight outline on the board -- the hint is not drawing, even ' +
   'though the status text may be');

console.log();
if (fails.length) { console.log('HINT TEST FAILED'); process.exit(1); }
console.log('HINT TEST OK');
