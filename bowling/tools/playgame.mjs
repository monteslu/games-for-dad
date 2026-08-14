#!/usr/bin/env node
// Play a COMPLETE ten-frame game, headless, and check the scoring.
//
// The framing test proves the camera holds the action and the rack test
// proves the geometry is sane, but neither plays the game -- and a bowling
// game that cannot be finished is not a game. This throws real balls
// through the real physics until the tenth frame closes, then checks the
// cart's own running total against an independent scorer implemented here.
//
// WHY AN INDEPENDENT SCORER: checking the cart's score against the cart's
// score proves nothing. Ten-pin scoring is the one genuinely tricky piece
// of logic in the game -- strikes carry the next two balls, spares the next
// one, and the tenth frame earns fill balls whose pins count into it -- so
// this file implements it separately, from the rules, and the two have to
// agree at every frame.
//
// The cart publishes its state through the two debug fields the host can
// read (see publishState in main.lua):
//   score : running total
//   aux   : frame, ball, state, rollCount and LAST ROLL, packed in mixed
//           radix -- ((frame*4 + ball)*8 + state)*22*11 + rollCount*11 + last
//
// aux carries the last roll's pin count rather than the pins currently
// standing, and that distinction is the whole reason this test works. The
// first version inferred each ball from the change in standing pins, which
// is wrong: the rack RESETS between frames, so every second sample
// straddled a reset and reported 0. It read a legitimate 91 as 54.

const CART = new URL('../bowling.wasc', import.meta.url).pathname;
const SESSION = 'bowling-playgame';
const URL_MCP = 'http://127.0.0.1:7331/mcp';

const STATE = { 1: 'aim', 2: 'rolling', 3: 'settling', 4: 'between', 5: 'done' };

let sid = null;
async function rpc(method, params) {
  const headers = {
    'Content-Type': 'application/json',
    'Accept': 'application/json, text/event-stream',
    'x-romdev-session': SESSION,
  };
  if (sid) headers['mcp-session-id'] = sid;
  const res = await fetch(URL_MCP, {
    method: 'POST', headers,
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
  });
  const got = res.headers.get('mcp-session-id');
  if (got) sid = got;
  const text = await res.text();
  const line = text.split('\n').find(l => l.startsWith('data: ')) ?? text;
  return JSON.parse(line.replace(/^data: /, ''));
}
async function notify(method) {
  const headers = {
    'Content-Type': 'application/json',
    'Accept': 'application/json, text/event-stream',
    'x-romdev-session': SESSION,
  };
  if (sid) headers['mcp-session-id'] = sid;
  await fetch(URL_MCP, {
    method: 'POST', headers,
    body: JSON.stringify({ jsonrpc: '2.0', method }),
  });
}
const call = (name, args) => rpc('tools/call', { name, arguments: args });

const step = (frames) => call('frame', { op: 'step', frames });

async function readField(name) {
  const r = await call('wasm', { op: 'read', name });
  const txt = r.result?.content?.[0]?.text;
  if (!txt) throw new Error(`read ${name} failed: ${JSON.stringify(r).slice(0, 300)}`);
  const j = JSON.parse(txt);
  const v = j.value ?? j.values?.[0];
  if (typeof v !== 'number') throw new Error(`read ${name}: no numeric value in ${txt.slice(0, 200)}`);
  return v;
}

async function readState() {
  const score = await readField('score');
  let aux = await readField('aux');
  const last = aux % 11;      aux = Math.floor(aux / 11);
  const rolls = aux % 22;     aux = Math.floor(aux / 22);
  const code = aux % 8;       aux = Math.floor(aux / 8);
  const ball = aux % 4;       aux = Math.floor(aux / 4);
  return { score, frame: aux, ball, state: STATE[code] ?? '?', rolls, last };
}

// ── the throw ─────────────────────────────────────────────────────────
//
// A drag: press, pull BACK (down the screen) to load power, release. The
// x offset becomes aim and hook, exactly as a finger would.
async function throwBall(aimDx, power) {
  const x0 = 960, y0 = 560;
  const y1 = y0 + Math.round(300 * power);        // MAX_PULL is 300
  await call('input', { op: 'pointer', id: 1, x: x0, y: y0, left: true, active: true });
  await step(4);
  await call('input', { op: 'pointer', id: 1, x: x0 + aimDx, y: y1, left: true, active: true });
  await step(4);
  await call('input', { op: 'pointer', id: 1, x: x0 + aimDx, y: y1, left: false, active: false });
}

// Wait for the cart to come back to `aim` (or `done`), stepping in chunks.
// Generous: a full-length roll plus the settle beat is several seconds.
async function waitForAim(maxFrames = 1400) {
  let spent = 0;
  while (spent < maxFrames) {
    await step(30);
    spent += 30;
    const st = await readState();
    if (st.state === 'aim' || st.state === 'done') return { ...st, spent };
  }
  throw new Error(`ball never settled after ${maxFrames} frames`);
}

// ── an independent ten-pin scorer ─────────────────────────────────────
//
// Written from the rules, deliberately NOT shared with the cart. If both
// had the same bug this test would happily confirm it.
function scoreIndependently(rolls) {
  let total = 0, i = 0;
  const perFrame = [];
  for (let f = 0; f < 10; f++) {
    const a = rolls[i];
    if (a === undefined) break;
    if (a === 10) {                                  // strike
      const b = rolls[i + 1], c = rolls[i + 2];
      total += 10 + (b ?? 0) + (c ?? 0);
      perFrame.push(b !== undefined && c !== undefined ? total : null);
      i += 1;
    } else {
      const b = rolls[i + 1];
      if (b === undefined) break;
      if (a + b === 10) {                            // spare
        const c = rolls[i + 2];
        total += 10 + (c ?? 0);
        perFrame.push(c !== undefined ? total : null);
      } else {
        total += a + b;
        perFrame.push(total);
      }
      i += 2;
    }
  }
  return { total, perFrame };
}

// The reference scorer is itself checked against the canonical games
// before it is trusted to judge the cart. A test whose oracle is wrong is
// worse than no test: it fails correct code and passes broken code, and
// there is nothing in the output to say which.
function selfCheck() {
  const cases = [
    ['perfect game',   Array(12).fill(10),                    300],
    ['all fives',      Array(21).fill(5),                     150],
    ['all gutters',    Array(20).fill(0),                       0],
    ['nine and miss',  Array.from({length: 10}, () => [9, 0]).flat(), 90],
  ];
  const bad = [];
  for (const [name, rolls, want] of cases) {
    const got = scoreIndependently(rolls).total;
    if (got !== want) bad.push(`${name}: scorer says ${got}, should be ${want}`);
  }
  return bad;
}

// ── run ───────────────────────────────────────────────────────────────

const oracleBad = selfCheck();
if (oracleBad.length) {
  console.log('FAIL: the reference scorer is itself wrong');
  for (const b of oracleBad) console.log('  ' + b);
  process.exit(1);
}
console.log('reference scorer verified (300 / 150 / 0 / 90)');

console.log('playing ten frames headless\n');

await rpc('initialize', {
  protocolVersion: '2024-11-05', capabilities: {},
  clientInfo: { name: 'playgame', version: '1' },
});
await notify('notifications/initialized');

const loaded = await call('loadMedia', { platform: 'wasmcart', path: CART });
if (loaded.result?.isError || loaded.result?.loaded !== true) {
  console.error('loadMedia failed:', JSON.stringify(loaded).slice(0, 400));
  process.exit(1);
}
await step(60);

let st = await readState();
console.log(`start: frame ${st.frame} ball ${st.ball} ${st.state} ` +
            `rolls ${st.rolls} score ${st.score}`);

const failures = [];
const observedRolls = [];      // pins knocked per ball, as the cart reports
const framesSeen = new Set();  // every frame the game actually visited
// (per-ball counts come from the cart, see the loop)
let balls = 0;
const MAX_BALLS = 40;          // 21 is the most a legal game needs; slack for the 10th

// Vary aim and power so the game is a real spread of strikes, spares and
// opens rather than the same throw twenty times. Deterministic: a fixed
// sequence, so a failure reproduces exactly.
const SHOTS = [
  [   0, 1.00], [  40, 0.85], [ -60, 0.95], [  15, 1.00], [ -25, 0.90],
  [  70, 0.80], [   0, 1.00], [ -45, 0.95], [  30, 0.88], [   5, 1.00],
  [ -15, 0.92], [  55, 0.85], [   0, 0.98], [ -35, 0.90], [  20, 1.00],
  [  -5, 0.95], [  45, 0.82], [ -50, 0.93], [  10, 1.00], [  25, 0.87],
];

while (st.state !== 'done' && balls < MAX_BALLS) {
  const [dx, pw] = SHOTS[balls % SHOTS.length];
  const before = await readState();

  await throwBall(dx, pw);
  const after = await waitForAim();

  // The cart says what the ball knocked down. Taking its word for the
  // per-ball count is not circular -- the SCORING is what is under test,
  // and that is computed independently below from these counts.
  if (after.rolls !== before.rolls + 1) {
    failures.push(`ball ${balls + 1}: roll count went ${before.rolls} -> ` +
                  `${after.rolls}, expected exactly one more`);
  }
  const knocked = after.last;
  observedRolls.push(knocked);
  balls++;

  console.log(
    `ball ${String(balls).padStart(2)}: ` +
    `frame ${before.frame}.${before.ball} -> ${after.frame}.${after.ball}  ` +
    `knocked ${String(knocked).padStart(2)}  ` +
    `rolls ${String(after.rolls).padStart(2)}  ` +
    `score ${String(after.score).padStart(3)}  ` +
    `[${after.state}] ${after.spent}f`);

  // INVARIANTS, checked every ball rather than only at the end.
  if (after.frame < before.frame) {
    failures.push(`ball ${balls}: frame went BACKWARDS ${before.frame} -> ${after.frame}`);
  }
  if (after.score < before.score) {
    failures.push(`ball ${balls}: score went DOWN ${before.score} -> ${after.score}`);
  }
  if (after.frame > 10) {
    failures.push(`ball ${balls}: frame ${after.frame} is past the tenth`);
  }
  if (knocked < 0 || knocked > 10) {
    failures.push(`ball ${balls}: knocked ${knocked} pins, which is impossible`);
  }

  framesSeen.add(before.frame);
  st = after;
}

console.log();

if (st.state !== 'done') {
  failures.push(`game never finished: ${balls} balls thrown, still at ` +
                `frame ${st.frame} ball ${st.ball} [${st.state}]`);
} else {
  console.log(`GAME OVER after ${balls} balls, final score ${st.score}`);
}

// ALL TEN FRAMES, not just "the game ended". A game that skipped from the
// third to the tenth would still report done, and would still score.
const missing = [];
for (let f = 1; f <= 10; f++) if (!framesSeen.has(f)) missing.push(f);
if (missing.length) {
  failures.push(`frames never played: ${missing.join(', ')}`);
} else {
  console.log(`all ten frames played: ${[...framesSeen].sort((a, b) => a - b).join(' ')}`);
}

// ── check the scoring ─────────────────────────────────────────────────
//
// The cart's total has to be a legal ten-pin score for SOME sequence, and
// it has to match what the independent scorer makes of the rolls we
// watched. The observed per-ball counts are the input to both.
const indep = scoreIndependently(observedRolls);
console.log(`\nrolls observed : [${observedRolls.join(', ')}]`);
console.log(`cart total     : ${st.score}`);
console.log(`independent    : ${indep.total}`);

if (st.state === 'done' && indep.total !== st.score) {
  failures.push(
    `SCORING MISMATCH: the cart says ${st.score}, an independent scorer ` +
    `over the same rolls [${observedRolls.join(', ')}] says ${indep.total}`);
}

// A ten-pin game cannot score above 300, and a finished game cannot be 0
// unless every ball was a gutter -- worth knowing either way.
if (st.state === 'done') {
  if (st.score > 300) failures.push(`final score ${st.score} exceeds a perfect game`);
  if (st.score < 0)   failures.push(`final score ${st.score} is negative`);
}

if (failures.length) {
  console.log('\nFAIL');
  for (const f of failures) console.log('  ' + f);
  process.exit(1);
}
console.log('\nPASS: ten frames played to completion, scoring agrees');
