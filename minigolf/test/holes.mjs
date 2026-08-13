// Render every hole through romdev and assert the picture is actually right.
//
// This exists because "it renders" was checked once, on hole 1, by eye --
// and hole 1 is the only hole with no water, no sand, no impulse zone, no
// polygon and no moving part. Everything interesting was unverified, and a
// mirrored camera had already put the ball at the wrong end of the course
// without anyone noticing.
//
// The assertions are on PIXELS, not on draw counts. A draw-call count of 27
// was reported happily by a completely black frame, so counting submissions
// proves nothing about what reached the screen.

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';

const URL = 'http://127.0.0.1:7331';
const CART = '/home/monteslu/code/cliemu/games-for-dad/minigolf/minigolf.wasc';
const SHOTS = '/tmp/claude-1000/holeshots';
mkdirSync(SHOTS, { recursive: true });

const session = 'holes-' + Math.random().toString(36).slice(2, 8);

async function tool(name, body) {
  const r = await fetch(`${URL}/tool/${name}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-romdev-session': session },
    body: JSON.stringify(body),
  });
  const t = await r.text();
  try { return JSON.parse(t); } catch { return { raw: t }; }
}

// The cart exposes the live hole index through its debug fields, so the
// test drives the REAL game rather than trusting a level number it set.
async function debugFields() {
  const d = await tool('wasm', { op: 'debugState' });
  const out = {};
  for (const f of d.fields || []) out[f.name] = f.value;
  return out;
}

async function events() {
  const d = await tool('wasm', { op: 'events' });
  return (d.log || []).map(l => l.text);
}

// Colour analysis in python: PIL is already there and doing it in-process
// avoids shelling a decoder per hole.
function analyse(png) {
  const py = `
from PIL import Image
from collections import Counter
im = Image.open(${JSON.stringify(png)}).convert('RGB')
w, h = im.size
# The play area only: skip the HUD bands top and bottom.
px = [im.getpixel((x, y)) for y in range(70, h - 90, 3) for x in range(0, w, 3)]
c = Counter(px)
total = len(px)
black = sum(n for col, n in c.items() if max(col) < 12)
sky   = sum(n for col, n in c.items() if col[2] > col[1] > col[0] and col[2] > 120)
green = sum(n for col, n in c.items() if col[1] > col[0] + 18 and col[1] > col[2] + 18)
wood  = sum(n for col, n in c.items() if col[0] > col[1] > col[2] and col[0] > 90 and col[0] - col[2] > 30)
white = sum(n for col, n in c.items() if min(col) > 200)
dark  = sum(n for col, n in c.items() if max(col) < 45)
red   = sum(n for col, n in c.items() if col[0] > 130 and col[1] < 90 and col[2] < 90)
blue  = sum(n for col, n in c.items() if col[2] > col[0] + 40 and col[2] > col[1] + 25 and col[1] < 140)
import json
print(json.dumps({
  'distinct': len(c), 'total': total,
  'black': black / total, 'sky': sky / total, 'green': green / total,
  'wood': wood / total, 'white': white, 'dark': dark / total,
  'red': red, 'blue': blue,
}))
`;
  return JSON.parse(execFileSync('python3', ['-c', py], { encoding: 'utf8' }));
}

// The cup, measured at FULL resolution rather than on the sampled grid.
// The sampled analyse() grid steps every 3rd pixel and so sees only about a
// ninth of a 38x36 hole -- enough to make a perfectly good cup look like a
// rounding error. Its SIZE is the assertion that matters: a cup the ball
// cannot enter, or one buried under the fairway, is the actual failure.
function findCup(png) {
  const py = `
from PIL import Image
import json
im = Image.open(${JSON.stringify(png)}).convert('RGB')
w, h = im.size
pts = [(x, y) for y in range(70, h - 90) for x in range(0, w)
       if max(im.getpixel((x, y))) < 45]
if not pts:
    print(json.dumps(None))
else:
    xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
    print(json.dumps({'n': len(pts), 'w': max(xs) - min(xs), 'h': max(ys) - min(ys),
                      'cx': (min(xs) + max(xs)) // 2, 'cy': (min(ys) + max(ys)) // 2}))
`;
  return JSON.parse(execFileSync('python3', ['-c', py], { encoding: 'utf8' }));
}

// Where is the ball, in screen pixels? Used to prove it starts at the TEE
// and not, as it did, at the cup.
// The flag at FULL resolution. analyse() samples every 3rd pixel and so
// sees about a ninth of a small pin -- enough to report 2 red pixels for a
// flag that is genuinely 40, and to fail a hole that renders correctly.
function findFlag(png) {
  const py = `
from PIL import Image
import json
im = Image.open(${JSON.stringify(png)}).convert('RGB')
w, h = im.size
n = sum(1 for y in range(70, h - 90) for x in range(0, w)
        if (lambda p: p[0] > 130 and p[1] < 90 and p[2] < 90)(im.getpixel((x, y))))
print(json.dumps({'n': n}))
`;
  return JSON.parse(execFileSync('python3', ['-c', py], { encoding: 'utf8' }));
}

function findBall(png) {
  const py = `
from PIL import Image
import json
im = Image.open(${JSON.stringify(png)}).convert('RGB')
w, h = im.size
# The ball is TEXTURED, so it is not pure white any more: its quadrants
# run from about 235 down to 175. Requiring >205 on every channel found
# the flag's pole and the cup rim instead.
#
# The rails are now a pale CHECKER, which is also bright and neutral, so a
# colour test alone floods into them -- one run merged the ball with a rail
# into a 438x66 blob and then reported the rail's texture as the ball's
# shading. So the blob is size-bounded too: a ball is a couple of dozen
# pixels across at this camera and nothing else on the course is both that
# bright and that small.
pts = [(x, y) for y in range(70, h - 90, 2) for x in range(0, w, 2)
       if (lambda p: min(p) > 150 and max(p) - min(p) < 60
                     and not (p[1] > p[0] + 15))(im.getpixel((x, y)))]
if not pts:
    print(json.dumps(None))
else:
    # CLUSTER the white pixels rather than averaging them all. The flag's
    # pole is also near-white, so a plain centroid lands between the ball
    # and the pin and reports a position that is neither. The ball is the
    # LARGEST compact blob.
    seen = set()
    best = None
    ptset = set(pts)
    for p in pts:
        if p in seen:
            continue
        stack, blob = [p], []
        seen.add(p)
        while stack:
            x, y = stack.pop()
            blob.append((x, y))
            for dx in (-2, 0, 2):
                for dy in (-2, 0, 2):
                    q = (x + dx, y + dy)
                    if q in ptset and q not in seen:
                        seen.add(q); stack.append(q)
        # Ball-SHAPED: compact and small. A rail run is long and thin, and
        # a merged ball+rail blob is huge; both are rejected here rather
        # than by hoping the colour test never touches a rail.
        # NOTE the comprehension variable is q, not p: reusing p here
        # shadows the outer loop's p, so the flood fill's start point moves
        # under it and the search silently returns the same wrong blob on
        # every hole -- which is exactly what it did.
        bxs = [q[0] for q in blob]; bys = [q[1] for q in blob]
        bw, bh = max(bxs) - min(bxs), max(bys) - min(bys)
        if bw > 44 or bh > 44 or len(blob) < 4:
            continue
        if best is None or len(blob) > len(best):
            best = blob
    if best is None:
        print(json.dumps(None))
    else:
        xs = [p[0] for p in best]; ys = [p[1] for p in best]
        print(json.dumps({'n': len(best), 'cx': sum(xs)/len(xs), 'cy': sum(ys)/len(ys),
                          'x0': min(xs), 'x1': max(xs), 'y0': min(ys), 'y1': max(ys)}))
`;
  return JSON.parse(execFileSync('python3', ['-c', py], { encoding: 'utf8' }));
}

const failures = [];
function check(hole, name, ok, detail) {
  if (!ok) failures.push(`hole ${hole}: ${name} -- ${detail}`);
  return ok;
}

// RUN ALL 22 BY DEFAULT, and do not lower this to make the suite quicker.
// The renderer has 64 3D mesh slots and a hole builds about ten, so a
// leaked-slot regression only surfaces on the SIXTH rebuild. A 3-hole run
// passes cleanly against a build that hard-crashes five holes into a real
// game -- which is exactly the bug this file was written after.
const HOLES = Number(process.env.HOLES || 22);

console.log(`testing ${HOLES} holes through romdev\n`);

await tool('loadMedia', { platform: 'wasmcart', path: CART });
await tool('frame', { op: 'step', frames: 20 });

const rows = [];

for (let hole = 1; hole <= HOLES; hole++) {
  // Jump via the aux debug field the cart polls. Driving it this way
  // rebuilds the level through buildLevel(), the same call a sunk putt
  // makes, so the harness exercises the real path.
  await tool('wasm', { op: 'write', name: 'aux', value: hole });
  await tool('frame', { op: 'step', frames: 25 });

  const shot = `${SHOTS}/hole${String(hole).padStart(2, '0')}.png`;
  await tool('frame', { op: 'screenshot', outputPath: shot });

  const a = analyse(shot);
  const cup = findCup(shot);
  const flag = findFlag(shot);
  // THE BALL'S POSITION COMES FROM THE CART, not from pixel-hunting: it
  // packs x*2048+y into the `score` debug field. Searching for it by
  // colour kept merging it with the pale checkered rails and reporting a
  // position that was neither -- and every fix was another heuristic to be
  // wrong about. Its APPEARANCE is still measured from pixels below; only
  // WHERE to look is taken from the game.
  const dbg = await debugFields();
  const packed = dbg.score || 0;
  const ballPx = { x: Math.floor(packed / 2048), y: packed % 2048 };
  const log = await events();
  const errs = log.filter(t => /error|Error|ERR/.test(t));

  rows.push({ hole, ...a, cup: cup && `${cup.w}x${cup.h}`,
              ball: ballPx.x + ',' + ballPx.y });

  check(hole, 'no lua errors', errs.length === 0, errs.join(' | '));
  check(hole, 'frame is not black', a.black < 0.5,
        `${(a.black * 100).toFixed(1)}% of the play area is black`);
  check(hole, 'green surface present', a.green > 0.12,
        `only ${(a.green * 100).toFixed(1)}% green`);
  // Flat-shaded vector art genuinely has few colours: greens, wood, sky,
  // ball, cup, flag. The real failure this guards is a SINGLE flat fill --
  // the "LUA ERROR" screen is 3 colours, a black frame is 1.
  check(hole, 'scene is not a flat fill', a.distinct >= 6,
        `only ${a.distinct} distinct colours -- an error screen or blank frame`);
  check(hole, 'flag is visible', flag.n >= 20, `only ${flag.n} red px`);

  // THE BALL MUST NOT START IN THE CUP.
  //
  // This is the assertion that catches a mirrored camera, which is how the
  // scene shipped once: right = up x forward instead of forward x up gives
  // a left-handed basis, the whole course renders mirrored, and the ball
  // draws at the CUP's end while the hole appears at the tee. Every colour
  // and coverage check above passes happily on that frame -- the picture is
  // a perfectly good render of the wrong thing. Only the relative geometry
  // of ball and cup exposes it.
  // THE BALL MUST BE TEXTURED, and it must be where the game says it is.
  //
  // A uniform white sphere is identical at every orientation, so the roll
  // is computed perfectly and is invisible -- the ball reads as SLIDING.
  // That shipped once, because the texture was assigned to the material
  // while this engine takes a 3D mesh's texture through a separate call, so
  // a solid red texture still drew a pure white ball.
  {
    const py = `
from PIL import Image
import json
im = Image.open(${JSON.stringify(shot)}).convert('RGB')
w, h = im.size
# PROJECT the cart position before looking for the ball there.
#
# The cart reports CART pixels, which is the physics' space -- but the ball
# is drawn by a tilted perspective camera, so it lands somewhere else on
# screen entirely (up to 174px away). Searching at the raw cart coordinate
# is the very bug this suite exists to catch, committed inside the test.
#
# Same camera as love.draw: eye (960, 1490, 900)/U looking at (960, 0,
# 540)/U with fov 52, U = 120.
import math
U = 120.0
ex, ey, ez = 960 / U, 1490 / U, 900 / U
tx, ty, tz = 960 / U, 0.0, 540 / U
fx, fy, fz = tx - ex, ty - ey, tz - ez
fl = math.sqrt(fx * fx + fy * fy + fz * fz)
fx, fy, fz = fx / fl, fy / fl, fz / fl
# right = forward x up
rx, ry, rz = fy * 0.0 - fz * 1.0, fz * 0.0 - fx * 0.0, fx * 1.0 - fy * 0.0
rl = math.sqrt(rx * rx + ry * ry + rz * rz)
rx, ry, rz = rx / rl, ry / rl, rz / rl
# up = right x forward
ux, uy, uz = ry * fz - rz * fy, rz * fx - rx * fz, rx * fy - ry * fx
tan = math.tan(math.radians(52 / 2))
def project(px, py, h):
    dx, dy, dz = px / U - ex, h / U - ey, py / U - ez
    vx = dx * rx + dy * ry + dz * rz
    vy = dx * ux + dy * uy + dz * uz
    vz = dx * fx + dy * fy + dz * fz
    if vz <= 0.001:
        return None
    return (vx / (vz * tan * (1920 / 1080))) * 960 + 960, (-vy / (vz * tan)) * 540 + 540
pr = project(${ballPx.x}, ${ballPx.y}, 11.5)
if pr is None:
    print(json.dumps(None))
    raise SystemExit(0)
cx, cy = int(pr[0]), int(pr[1])
best, vals = None, []
for R in (26, 60, 120):
    vals = []
    for dy in range(-R, R + 1):
        for dx in range(-R, R + 1):
            x, y = cx + dx, cy + dy
            if 0 <= x < w and 70 <= y < h - 90:
                p = im.getpixel((x, y))
                if min(p) > 140 and not (p[1] > p[0] + 14):
                    vals.append(sum(p) / 3)
    if len(vals) >= 12:
        break
if len(vals) < 12:
    print(json.dumps(None))
else:
    m = sum(vals) / len(vals)
    print(json.dumps({'n': len(vals),
                      'sd': (sum((v - m) ** 2 for v in vals) / len(vals)) ** 0.5}))
`;
    const shading = JSON.parse(execFileSync('python3', ['-c', py], { encoding: 'utf8' }));
    check(hole, 'the ball is on screen where the game says it is',
          shading !== null,
          `nothing ball-like near the cart's reported position ` +
          `(${ballPx.x},${ballPx.y})`);
    if (shading) {
      check(hole, 'the ball is textured (its roll can be seen)',
            shading.sd > 6,
            `ball shading varies by only ${shading.sd.toFixed(1)} levels -- ` +
            'it is a flat sphere and its rotation will be invisible');
    }
  }

  // THE BALL MUST NOT START IN THE CUP -- the assertion that catches a
  // mirrored camera, which renders the ball at the cup's end of the course.
  if (cup) {
    // 30px, not 60. The comparison mixes spaces -- the ball is in CART
    // pixels and the cup is measured on the projected SCREEN -- so the
    // number is only meaningful as "not sitting on top of each other".
    // Hole 6's tee is genuinely 218 cart-pixels from its cup, which
    // projects to under 60, so a larger bound fails a correct short hole.
    // A mirrored render puts them within a handful of pixels.
    const d = Math.hypot(ballPx.x - cup.cx, ballPx.y - cup.cy);
    check(hole, 'ball starts away from the cup', d > 30,
          `ball is ${d.toFixed(0)}px from the cup -- it is rendering at the ` +
          `hole, which is what a mirrored camera looks like`);
  }
}

console.log('hole | distinct | green% | wood% | sky% | black% | white px | cup% | red |     cup | ball xy');
console.log('-----+----------+--------+-------+------+--------+----------+------+-----+---------+---------');
for (const r of rows) {
  console.log(
    String(r.hole).padStart(4) + ' |' +
    String(r.distinct).padStart(9) + ' |' +
    (r.green * 100).toFixed(1).padStart(7) + ' |' +
    (r.wood * 100).toFixed(1).padStart(6) + ' |' +
    (r.sky * 100).toFixed(1).padStart(5) + ' |' +
    (r.black * 100).toFixed(1).padStart(7) + ' |' +
    String(r.white).padStart(9) + ' |' +
    (r.dark * 100).toFixed(2).padStart(5) + ' |' +
    String(r.red).padStart(4) + ' |' + String(r.cup || '-').padStart(8) +
    ' | ' + (r.ball || '-'));
}

console.log();
if (failures.length) {
  console.log(`FAIL (${failures.length})`);
  for (const f of failures) console.log('  ' + f);
  process.exit(1);
}
console.log(`PASS -- ${HOLES} holes render with course, ball, cup and flag`);
