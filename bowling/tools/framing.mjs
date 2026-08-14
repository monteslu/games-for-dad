#!/usr/bin/env node
// Does the side view actually hold the whole alley?
//
// The camera fits the ball-to-rack span analytically, but the fit is exact
// only for the lane centreline: the near gutter is a lane-width closer to
// the camera and projects wider. The first three attempts at this camera all
// LOOKED plausible in a screenshot and were each clipped at the edges (1px
// and 6px margins, measured). So this asserts margins instead of eyeballing.
//
// Sampled at the two framings that matter: the setup (ball at the foul line,
// longest span) and mid-roll (ball near the pins, shortest span).

import { execFileSync } from 'node:child_process';

const CART = new URL('../bowling.wasc', import.meta.url).pathname;
const SHOT = '/tmp/claude-1000/bowl-framing.png';
const SESSION = 'bowling-framing';

// The ball and pins must sit at least this far inside the frame. Small
// enough to allow a tight composition, large enough that a clipped rack
// cannot pass.
const MIN_MARGIN = 14;

// The server hands back an Mcp-Session-Id on initialize and rejects every
// later call that does not carry it.
let mcpSessionId = null;

async function rpc(method, params) {
  const headers = {
    'Content-Type': 'application/json',
    'Accept': 'application/json, text/event-stream',
    'x-romdev-session': SESSION,
  };
  if (mcpSessionId) headers['mcp-session-id'] = mcpSessionId;
  const res = await fetch('http://127.0.0.1:7331/mcp', {
    method: 'POST',
    headers,
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
  });
  const sid = res.headers.get('mcp-session-id');
  if (sid) mcpSessionId = sid;
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
  if (mcpSessionId) headers['mcp-session-id'] = mcpSessionId;
  await fetch('http://127.0.0.1:7331/mcp', {
    method: 'POST', headers,
    body: JSON.stringify({ jsonrpc: '2.0', method }),
  });
}

const call = (name, args) => rpc('tools/call', { name, arguments: args });

// Measure the bounding box of the BALL AND PINS -- the magenta, dynamic
// bodies.
//
// Deliberately NOT the green static geometry. The lane runs the length of
// the shot and the back wall behind the pit is seen nearly edge-on, so both
// touch the frame edge at any camera distance; asserting on them measures
// the backdrop rather than the composition, and no amount of pulling the
// camera back can satisfy it. What has to stay in frame is the action.
function extent(path) {
  const py = `
from PIL import Image
im = Image.open(${JSON.stringify(path)}).convert('RGB')
W, H = im.size
px = im.load()
x0, x1, y0, y1 = W, -1, H, -1
for y in range(H):
    for x in range(W):
        r, g, b = px[x, y]
        if r > 140 and b > 110 and g < 110:
            if x < x0: x0 = x
            if x > x1: x1 = x
            if y < y0: y0 = y
            if y > y1: y1 = y
print(W, H, x0, x1, y0, y1)
`;
  const out = execFileSync('python3', ['-c', py], { encoding: 'utf8' }).trim();
  const [W, H, x0, x1, y0, y1] = out.split(/\s+/).map(Number);
  return { W, H, x0, x1, y0, y1 };
}

async function shoot(label) {
  const r = await call('frame', { op: 'screenshot', path: SHOT });
  if (r.error) throw new Error(`screenshot failed: ${JSON.stringify(r.error)}`);
  const e = extent(SHOT);
  if (e.x1 < 0) throw new Error(`${label}: NO ball or pins on screen at all`);
  const margins = {
    left:   e.x0,
    right:  e.W - 1 - e.x1,
    top:    e.y0,
    bottom: e.H - 1 - e.y1,
  };
  return { label, extent: e, margins };
}

const failures = [];
function check(m) {
  console.log(`  ${m.label}: margins L=${m.margins.left} R=${m.margins.right} ` +
              `T=${m.margins.top} B=${m.margins.bottom}`);
  // Only left/right matter: the lane fills the frame vertically by design,
  // and the HUD legitimately overlaps the bottom.
  for (const side of ['left', 'right']) {
    if (m.margins[side] < MIN_MARGIN) {
      failures.push(`${m.label}: ${side} margin ${m.margins[side]}px < ${MIN_MARGIN}px (ball/pins clipped)`);
    }
  }
}

console.log('side-view framing');

await rpc('initialize', {
  protocolVersion: '2024-11-05', capabilities: {},
  clientInfo: { name: 'framing', version: '1' },
});
await notify('notifications/initialized');
await call('loadMedia', { platform: 'wasmcart', path: CART });

// Setup: ball at the foul line, the longest span the camera has to hold.
await call('frame', { op: 'step', frames: 90 });
check(await shoot('setup   '));

// Mid-roll: throw, then look while the ball is among the pins.
await call('input', { op: 'pointer', id: 1, x: 960, y: 700, left: true, active: true });
await call('frame', { op: 'step', frames: 6 });
await call('input', { op: 'pointer', id: 1, x: 960, y: 950, left: true, active: true });
await call('frame', { op: 'step', frames: 6 });
await call('input', { op: 'pointer', id: 1, x: 960, y: 950, left: false, active: false });
await call('frame', { op: 'step', frames: 75 });
check(await shoot('mid-roll'));

if (failures.length) {
  console.log('\nFAIL');
  for (const f of failures) console.log('  ' + f);
  process.exit(1);
}
console.log('\nPASS: ball and pins fully inside the frame at both framings');
