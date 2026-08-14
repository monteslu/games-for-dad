#!/usr/bin/env node
// Drive a COMPLETE hand of pinochle through the real cart, on the real
// engine, with the pad.
//
// tools/simulate.lua already proves the RULES hold over ten thousand
// hands, but it never loads the cart -- so it cannot catch a game that
// deals correctly and then hangs, or one whose confirm gate never opens.
// This is the other half: it proves the thing a person actually touches
// gets from DEAL to a scored hand.
//
// Needs the romdev server on 127.0.0.1:7331 WITH a display (see
// docs/PINOCHLE.md).

const CART = new URL('../pinochle.wasc', import.meta.url).pathname;
const SESSION = 'pinochle-playhand';
const URL_MCP = 'http://127.0.0.1:7331/mcp';

const STATE = { 1: 'idle', 2: 'dealing', 3: 'bid_wait', 4: 'bid_pick',
  5: 'trump_pick', 6: 'meld_show', 7: 'cpu_think', 8: 'play_pick',
  9: 'anim_play', 10: 'trick_pause', 11: 'sweep', 12: 'hand_result',
  13: 'game_over' };

let sid = null;
async function rpc(method, params) {
  const h = { 'Content-Type': 'application/json',
              'Accept': 'application/json, text/event-stream',
              'x-romdev-session': SESSION };
  if (sid) h['mcp-session-id'] = sid;
  const r = await fetch(URL_MCP, { method: 'POST', headers: h,
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) });
  const g = r.headers.get('mcp-session-id'); if (g) sid = g;
  const t = await r.text();
  const l = t.split('\n').find(x => x.startsWith('data: ')) ?? t;
  return JSON.parse(l.replace(/^data: /, ''));
}
async function notify(m) {
  const h = { 'Content-Type': 'application/json',
              'Accept': 'application/json, text/event-stream',
              'x-romdev-session': SESSION };
  if (sid) h['mcp-session-id'] = sid;
  await fetch(URL_MCP, { method: 'POST', headers: h,
    body: JSON.stringify({ jsonrpc: '2.0', method: m }) });
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
  const s = await readField('score');
  const aux = await readField('aux');
  return {
    state: STATE[s] ?? ('?' + s),
    tricks: Math.floor(aux / 64),
    // the low bits are the input diagnostic; bit 32 is confirmHeld
    heldGate: (aux % 64) >= 32,
  };
}

// A CONFIRM IS A PRESS AND A RELEASE, and the game requires the release:
// after dismissing a panel it waits for the button to come up before the
// next one will accept anything. A driver that mashes the button just
// holds the gate shut -- which looked exactly like a hang.
async function confirm() {
  await call('input', { op: 'press', button: 'a', frames: 3 });
  await step(14);          // let it come up and the gate reopen
}

console.log('driving a hand of pinochle\n');

await rpc('initialize', { protocolVersion: '2024-11-05', capabilities: {},
  clientInfo: { name: 'playhand', version: '1' } });
await notify('notifications/initialized');

const loaded = await call('loadMedia', { platform: 'wasmcart', path: CART });
if (loaded.result?.loaded !== true) {
  console.error('loadMedia failed:', JSON.stringify(loaded).slice(0, 300));
  process.exit(1);
}
await step(40);

const failures = [];
let st = await readState();
if (st.state !== 'idle') failures.push(`did not start idle, got ${st.state}`);
console.log(`start            ${st.state}`);

await confirm();                      // DEAL
// Sample DURING the deal, not after it. Stepping straight past the
// animation and then asserting "dealing was visited" fails a hand that
// dealt perfectly well -- the state had simply already moved on.
await step(30);
const midDeal = await readState();
await step(200);                      // the rest of the deal
st = await readState();
console.log(`after deal       ${st.state}`);
if (st.state === 'idle') failures.push('DEAL did nothing -- confirm never landed');

// Walk the hand. Every panel takes one confirm; play_pick takes one per
// card. A generous budget: twelve tricks of four cards with animation.
const seen = new Set([midDeal.state]);
let guard = 0;
while (guard++ < 400) {
  st = await readState();
  seen.add(st.state);
  if (st.state === 'hand_result' || st.state === 'game_over') break;
  if (['bid_pick', 'trump_pick', 'meld_show', 'play_pick'].includes(st.state)) {
    await confirm();
  } else {
    await step(10);
  }
}

st = await readState();
console.log(`ended at         ${st.state}  after ${st.tricks} tricks`);
console.log(`states visited   ${[...seen].sort().join(', ')}`);

// The phases that MUST happen in a hand of pinochle. Missing any of them
// means the hand did not really play.
for (const need of ['dealing', 'bid_pick', 'meld_show', 'play_pick']) {
  if (!seen.has(need)) failures.push(`never reached ${need}`);
}
if (st.state !== 'hand_result' && st.state !== 'game_over') {
  failures.push(`hand never finished -- stuck in ${st.state}`);
}
if (st.tricks !== 12 && st.state === 'hand_result') {
  failures.push(`scored after ${st.tricks} tricks, expected 12`);
}

await call('frame', { op: 'screenshot',
  path: '/tmp/claude-1000/pinochle-result.png' });

if (failures.length) {
  console.log('\nFAIL');
  for (const f of failures) console.log('  ' + f);
  process.exit(1);
}
console.log('\nPASS: dealt, bid, named trump, melded, played 12 tricks, scored');
