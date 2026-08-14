#!/usr/bin/env node
// Does the rack actually FIT on the lane?
//
// This is a numeric invariant, not a pixel one, so it needs no emulator and
// runs in milliseconds -- read the constants out of main.lua and do the
// arithmetic.
//
// It exists because the lane was 300px wide with pins on 96px centres, and
// that is not a tight rack: the outermost pins sit 1.5 spacings out (144px)
// with a 22px radius, so their outer edge landed at 166px against a
// half-width of 150. The corner pins OVERHUNG THE LANE by 16px and stood
// partly over the gutter. It looked like "the pins are near the edges" in a
// screenshot; it was geometrically impossible.
//
// A real lane is 42in wide with pins on 12in centres -- exactly 3.5 times
// the spacing -- which clears the gutter by about 0.6in, or 1.5% of the
// lane's width. That ratio is the thing being asserted here.

import { readFileSync } from 'node:fs';

const SRC = new URL('../app/main.lua', import.meta.url).pathname;
const src = readFileSync(SRC, 'utf8');

// Pull a `local NAME = <number>` out of the source. Deliberately reads the
// real file rather than duplicating the numbers here -- a copy would drift,
// and a test that asserts against its own stale copy asserts nothing.
function num(name) {
  const m = src.match(new RegExp(`^local\\s+${name}\\s*=\\s*(-?[0-9.]+)`, 'm'));
  if (!m) throw new Error(`could not find "local ${name} = <number>" in main.lua`);
  return parseFloat(m[1]);
}

const LANE_W      = num('LANE_W');
const PIN_SPACING = num('PIN_SPACING');
const PIN_R       = num('PIN_R');
const GUTTER_W    = num('GUTTER_W');

// Row 3 is the back row: x = (i - row/2) * spacing, so the outermost centre
// is at 1.5 spacings either side.
const outerCentre = 1.5 * PIN_SPACING;
const outerEdge   = outerCentre + PIN_R;
const halfWidth   = LANE_W / 2;
const clearance   = halfWidth - outerEdge;

// Real-world reference, in inches.
const REAL_LANE = 42, REAL_SPACING = 12, REAL_PIN_D = 4.766;
const realClear = REAL_LANE / 2 - (1.5 * REAL_SPACING + REAL_PIN_D / 2);
const realFrac  = realClear / REAL_LANE;

console.log('rack geometry');
console.log(`  lane width      ${LANE_W}  (half ${halfWidth})`);
console.log(`  pin spacing     ${PIN_SPACING}   radius ${PIN_R}`);
console.log(`  outer pin edge  ${outerEdge}`);
console.log(`  clearance       ${clearance > 0 ? '+' : ''}${clearance.toFixed(1)}px ` +
            `(${(clearance / LANE_W * 100).toFixed(2)}% of width)`);
console.log(`  real bowling    ${realClear.toFixed(2)}in ` +
            `(${(realFrac * 100).toFixed(2)}% of width)`);
console.log(`  lane/spacing    ${(LANE_W / PIN_SPACING).toFixed(3)}  ` +
            `(real ${(REAL_LANE / REAL_SPACING).toFixed(3)})`);

const failures = [];

// THE ONE THAT MATTERS: every pin must stand fully on the boards.
if (clearance <= 0) {
  failures.push(
    `corner pins overhang the lane by ${(-clearance).toFixed(1)}px -- ` +
    `they stand over the gutter. Lane must be at least ` +
    `${(outerEdge * 2).toFixed(0)}px wide for this spacing.`);
}

// And not absurdly wide either: a rack swimming in the middle of a broad
// lane is as wrong as one hanging off it, just less obviously.
if (clearance / LANE_W > 0.08) {
  failures.push(
    `lane is far too wide for the rack: ${(clearance / LANE_W * 100).toFixed(1)}% ` +
    `clearance either side against about ${(realFrac * 100).toFixed(1)}% on a real lane.`);
}

// The gutter has to be able to swallow the ball, or a gutter ball rides the
// lip instead of dropping.
const BALL_R = num('BALL_R');
if (GUTTER_W < BALL_R * 1.5) {
  failures.push(`gutter ${GUTTER_W}px is narrow for a ${BALL_R * 2}px ball`);
}

// ── THE FINGER HOLES ARE ROUND ON THE BALL ────────────────────────────
//
// uv is not an equal-area map, so a circle in uv is an ELLIPSE on the
// sphere. u wraps the whole way round (2*pi) while v only spans pole to
// pole (pi), so one unit of u is worth twice one unit of v before latitude
// even enters into it -- and near the poles sin(latitude) compresses u
// further. art.lua corrects for both; this checks that it still does.
//
// The bug this catches shipped: the factor of 2 was missing, every hole
// came out exactly twice as wide as it was tall, and they read as ovals
// smeared into crescents.
function holeRoundness() {
  const art = readFileSync(new URL('../app/art.lua', import.meta.url).pathname, 'utf8');
  // Match to the closing brace that sits ON ITS OWN LINE. A non-greedy
  // `\}` stops at the first hole's own closing brace and finds exactly one
  // entry -- which is how this test first ran.
  const block = art.match(/local HOLES = \{([\s\S]*?)\n\s*\}/);
  if (!block) throw new Error('could not find HOLES in art.lua');
  const holes = [...block[1].matchAll(/u\s*=\s*([0-9.]+),\s*v\s*=\s*([0-9.]+),\s*r\s*=\s*([0-9.]+)/g)]
    .map(m => ({ u: +m[1], v: +m[2], r: +m[3] }));
  if (holes.length !== 3) throw new Error(`expected 3 holes, found ${holes.length}`);

  // uv -> unit sphere, exactly as buildSphere does it
  const p3 = (u, v) => {
    const phi = v * Math.PI, th = u * 2 * Math.PI;
    return [Math.sin(phi) * Math.cos(th), Math.cos(phi), Math.sin(phi) * Math.sin(th)];
  };
  const dist = (a, b) => Math.hypot(a[0] - b[0], a[1] - b[1], a[2] - b[2]);

  return holes.map(h => {
    // art.lua's own test, replicated
    const inside = (u, v) => {
      const sp = Math.max(0.15, Math.sin(v * Math.PI));
      let du = Math.abs(u - h.u);
      if (du > 0.5) du = 1 - du;
      return Math.hypot(du * 2 * sp, v - h.v) < h.r;
    };
    let u = h.u; while (inside(u, h.v) && u < h.u + 0.5) u += 0.0005;
    let v = h.v; while (inside(h.u, v) && v < h.v + 0.5) v += 0.0005;
    const wu = dist(p3(h.u, h.v), p3(u, h.v));
    const wv = dist(p3(h.u, h.v), p3(h.u, v));
    return { h, ratio: wu / wv, diaIn: 2 * wu * 4.25 };
  });
}

console.log('\nfinger holes');
for (const [i, r] of holeRoundness().entries()) {
  console.log(`  hole ${i}: roundness ${r.ratio.toFixed(2)} ` +
              `(1.00 = round on the ball)   dia ${r.diaIn.toFixed(2)}in`);
  // 8% tolerance: the walk is a discrete step, not an analytic solve.
  if (Math.abs(r.ratio - 1) > 0.08) {
    failures.push(
      `hole ${i} is not round on the ball: ${r.ratio.toFixed(2)}:1 ` +
      `(${r.ratio > 1 ? 'wider than tall' : 'taller than wide'}). ` +
      `Check the 2*sin(v*pi) correction in art.lua.`);
  }
}

if (failures.length) {
  console.log('\nFAIL');
  for (const f of failures) console.log('  ' + f);
  process.exit(1);
}
console.log('\nPASS: the rack stands on the boards');
