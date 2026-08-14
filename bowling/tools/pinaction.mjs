#!/usr/bin/env node
// Does the pin ACTION work -- do pins knock each other down, or does the
// ball do all the work?
//
// The test: roll down one edge of the lane so the ball can only reach the
// corner pin. In real bowling that still takes several pins down, because
// the corner pin falls into its neighbours and they into theirs. If only
// the pins the ball physically touches fall, there is no pin action.

import { readFileSync } from 'node:fs';

const CART = new URL('../bowling.wasc', import.meta.url).pathname;

// Read MAX_PULL out of the game rather than hardcoding it. It moved from
// 300 to 180 and every harness that kept its own copy would have gone on
// dragging 300px, quietly clamping every throw to full power and making
// its own `power` argument mean nothing.
const MAX_PULL = (() => {
  const src = readFileSync(new URL('../app/main.lua', import.meta.url).pathname, 'utf8');
  const m = src.match(/^local\s+MAX_PULL\s*=\s*([0-9.]+)/m);
  if (!m) throw new Error('could not find MAX_PULL in main.lua');
  return parseFloat(m[1]);
})();
const SESSION = 'bowl-pinaction';
let sid = null;

async function rpc(method, params) {
  const h = { 'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream', 'x-romdev-session': SESSION };
  if (sid) h['mcp-session-id'] = sid;
  const r = await fetch('http://127.0.0.1:7331/mcp', { method: 'POST', headers: h, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) });
  const g = r.headers.get('mcp-session-id'); if (g) sid = g;
  const t = await r.text();
  const l = t.split('\n').find(x => x.startsWith('data: ')) ?? t;
  return JSON.parse(l.replace(/^data: /, ''));
}
async function notify(m) {
  const h = { 'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream', 'x-romdev-session': SESSION };
  if (sid) h['mcp-session-id'] = sid;
  await fetch('http://127.0.0.1:7331/mcp', { method: 'POST', headers: h, body: JSON.stringify({ jsonrpc: '2.0', method: m }) });
}
const call = (n, a) => rpc('tools/call', { name: n, arguments: a });
const step = (f) => call('frame', { op: 'step', frames: f });

async function readField(name) {
  const r = await call('wasm', { op: 'read', name });
  const txt = r.result?.content?.[0]?.text;
  if (!txt) throw new Error(`read ${name}: ${JSON.stringify(r).slice(0, 200)}`);
  return JSON.parse(txt).value;
}
async function readState() {
  const score = await readField('score');
  let aux = await readField('aux');
  const marker = (aux % 201) / 100 - 1;   aux = Math.floor(aux / 201);
  const last = aux % 11;   aux = Math.floor(aux / 11);
  const rolls = aux % 22;  aux = Math.floor(aux / 22);
  const code = aux % 8;    aux = Math.floor(aux / 8);
  const ball = aux % 6;    aux = Math.floor(aux / 6);
  return { score, frame: aux, ball, code, rolls, last, marker };
}

async function throwBall(dx, power) {
  const x0 = 960, y0 = 560, y1 = y0 + Math.round(MAX_PULL * power);
  await call('input', { op: 'pointer', id: 1, x: x0, y: y0, left: true, active: true });
  await step(4);
  await call('input', { op: 'pointer', id: 1, x: x0 + dx, y: y1, left: true, active: true });
  await step(4);
  await call('input', { op: 'pointer', id: 1, x: x0 + dx, y: y1, left: false, active: false });
}

async function settle(max = 1400) {
  let spent = 0;
  while (spent < max) {
    await step(30); spent += 30;
    const s = await readState();
    if (s.code === 1 || s.code === 5) return s;
  }
  throw new Error('never settled');
}

await rpc('initialize', { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'pa', version: '1' } });
await notify('notifications/initialized');
await call('loadMedia', { platform: 'wasmcart', path: CART });
await step(60);

// A spread of aims, from dead centre to well out toward the edge. The
// interesting number is what an EDGE hit takes down: that is almost all
// pin-on-pin, since the ball reaches at most one or two pins itself.
const AIMS = [
  { dx:   0, label: 'dead centre' },
  { dx:  30, label: 'slight right' },
  { dx:  60, label: 'right pocket' },
  { dx:  90, label: 'wide right' },
  { dx: 120, label: 'edge right' },
  { dx: -60, label: 'left pocket' },
  { dx: -90, label: 'wide left' },
  { dx: -120, label: 'edge left' },
];

// THIS TEST IS ABOUT AIM AND PIN ACTION, NOT SPIN.
//
// The spin meter sweeps until it is tapped, so a test that ignores it
// throws with WHATEVER SPIN THE MARKER HAPPENED TO BE AT -- and a
// full-sweep aim plus a full hook compound into the gutter, which reads as
// "pin action broke" when nothing of the sort has happened.
//
// So: stop the marker in the dead zone, giving a straight ball every time.
// The cart publishes the marker's position in aux, so this POLLS it and
// taps when the marker is central. Reading the real value beats assuming a
// phase -- a fixed frame count would drift the moment SPIN_SWEEP changed,
// and would do it silently.
const SPIN_Y = 906, SPIN_H = 96;
async function setSpinStraight() {
  for (let i = 0; i < 400; i++) {
    const pos = (await readState()).marker;
    if (Math.abs(pos) < 0.10) {                    // inside the dead zone
      await call('input', { op: 'pointer', id: 1, x: 960, y: SPIN_Y + SPIN_H / 2, left: true, active: true });
      await step(3);
      await call('input', { op: 'pointer', id: 1, x: 960, y: SPIN_Y + SPIN_H / 2, left: false, active: false });
      await step(4);
      return;
    }
    await step(2);
  }
  throw new Error('spin marker never reached the dead zone');
}

console.log('pin action: how many fall per hit  (spin held straight)\n');
console.log('  aim            knocked');
const results = [];
for (const a of AIMS) {
  await setSpinStraight();
  await throwBall(a.dx, 1.0);
  const after = await settle();
  console.log(`  ${a.label.padEnd(14)} ${String(after.last).padStart(2)}`);
  results.push({ ...a, knocked: after.last });
  // Second ball of the frame: throw it away so the next aim starts on a
  // full rack. It needs its spin stopped too -- an unstopped meter leaves
  // a full hook on a soft throw, which curls into the gutter and then
  // never settles inside the budget.
  if (after.code !== 5 && after.ball === 2) {
    await setSpinStraight();
    await throwBall(0, 0.6);
    await settle();
  }
}

// ── what counts as real pin action ────────────────────────────────────
//
// A ball is 104px across and pins sit on 96px centres, so ONE BALL CAN
// TOUCH AT MOST THREE OR FOUR PINS. Everything past that falls because a
// pin hit it. So: if a hit anywhere near the pocket takes eight or more,
// the chain reaction is working; if it takes one or two, it is not.
//
// This caught the real thing. Before the physics was fixed every pocket
// and edge hit took EXACTLY ONE pin -- a pin would topple and its
// neighbours would ignore it entirely.
const failures = [];
const pocket = results.filter(r => /pocket|slight/.test(r.label));
const edge   = results.filter(r => /edge/.test(r.label));

for (const r of pocket) {
  if (r.knocked < 7) {
    failures.push(`${r.label}: only ${r.knocked} pins. A pocket hit should take 7+; ` +
                  `the ball alone can reach 3-4, so this means pins are not ` +
                  `knocking each other down.`);
  }
}
// An edge hit reaches one or two pins itself. Anything above that IS pin
// action, so this is the sharpest test of the chain reaction there is.
for (const r of edge) {
  if (r.knocked < 3) {
    failures.push(`${r.label}: only ${r.knocked} pins. The ball reaches 1-2 there, ` +
                  `so <3 means the struck pin took nothing with it.`);
  }
}
// And the spread has to be real: if EVERY line takes ten, aim does not
// matter and the game has no skill in it.
if (results.every(r => r.knocked === 10)) {
  failures.push('every aim struck: no line can miss, so aim is meaningless');
}

if (failures.length) {
  console.log('\nFAIL');
  for (const f of failures) console.log('  ' + f);
  process.exit(1);
}
console.log('\nPASS: pins knock each other down, and aim still matters');
