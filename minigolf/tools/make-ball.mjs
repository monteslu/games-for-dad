#!/usr/bin/env node
// make-ball.mjs - generate the golf ball texture.
//
// WHY GENERATED, NOT SOURCED: a golf ball is a sphere covered in dimples
// laid out on a geodesic, lit from one side. That is a handful of lines of
// maths and completely deterministic, whereas a stock photo would carry a
// licence question, a fixed light direction and JPEG mush. Generating it
// means the light matches the course lighting exactly and the dimples sit
// on a real sphere rather than being a flat pattern pasted over a circle.
//
// The output is a single RGBA PNG the cart draws as a sprite. It is a
// TEXTURE, not a render: the ball is drawn as a flat sprite because at
// 23px on screen a real 3D sphere buys nothing a good texture does not.
//
//   node tools/make-ball.mjs [size]

import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { deflateSync } from "node:zlib";

const HERE = dirname(fileURLToPath(import.meta.url));
const N = Number(process.argv[2] || 256);

// ── dimple layout ────────────────────────────────────────────────────
//
// Real golf balls use an icosahedral arrangement; a Fibonacci sphere is
// the cheap way to get the same EVEN spacing without building a geodesic,
// and at this size the difference is invisible. 392 is a common real
// dimple count.
const DIMPLES = 392;
const GOLDEN = Math.PI * (3 - Math.sqrt(5));
const dimples = [];
for (let i = 0; i < DIMPLES; i++) {
  const y = 1 - (i / (DIMPLES - 1)) * 2;        // 1 .. -1
  const r = Math.sqrt(Math.max(0, 1 - y * y));
  const th = GOLDEN * i;
  dimples.push([Math.cos(th) * r, y, Math.sin(th) * r]);
}

// Light from up-left-front, matching the course's own key light.
const L = (() => { const v = [-0.45, -0.6, 0.66]; const m = Math.hypot(...v);
                   return v.map((c) => c / m); })();

const px = new Uint8Array(N * N * 4);
const R = N / 2 - 2;
const DIMPLE_R = 0.085;        // angular radius on the unit sphere
const DIMPLE_DEPTH = 0.34;     // how much a dimple tilts the local normal

for (let py = 0; py < N; py++) {
  for (let pxi = 0; pxi < N; pxi++) {
    const dx = (pxi - N / 2 + 0.5) / R;
    const dy = (py - N / 2 + 0.5) / R;
    const d2 = dx * dx + dy * dy;
    const o = (py * N + pxi) * 4;

    if (d2 > 1) { px[o + 3] = 0; continue; }     // outside the sphere

    // surface normal of a unit sphere seen head on
    let nx = dx, ny = dy, nz = Math.sqrt(Math.max(0, 1 - d2));

    // ── dimples ──
    // Find the nearest dimple centre on the visible hemisphere and, if
    // this pixel falls inside it, TILT THE NORMAL toward the dimple's
    // centre. That is what makes a dimple read as a depression rather
    // than a painted dot: the shading follows a real bowl.
    let best = -1, bestDot = -1;
    for (let i = 0; i < DIMPLES; i++) {
      const dm = dimples[i];
      if (dm[2] < 0) continue;                   // back of the ball
      const dot = nx * dm[0] + ny * dm[1] + nz * dm[2];
      if (dot > bestDot) { bestDot = dot; best = i; }
    }
    let cav = 0;
    if (best >= 0) {
      const ang = Math.acos(Math.min(1, bestDot));
      if (ang < DIMPLE_R) {
        const t = ang / DIMPLE_R;                // 0 centre .. 1 rim
        cav = Math.cos(t * Math.PI / 2);         // smooth bowl profile
        const dm = dimples[best];
        // push the normal toward the dimple centre, strongest at the rim
        const k = DIMPLE_DEPTH * Math.sin(t * Math.PI);
        nx += (dm[0] - nx) * k; ny += (dm[1] - ny) * k; nz += (dm[2] - nz) * k;
        const m = Math.hypot(nx, ny, nz);
        nx /= m; ny /= m; nz /= m;
      }
    }

    // ── shading ──
    const lam = Math.max(0, nx * L[0] + ny * L[1] + nz * L[2]);
    // wrapped diffuse: real balls are bright well past the terminator
    const diff = Math.pow((lam + 0.45) / 1.45, 1.1);

    // specular highlight, tight and bright -- the wet look
    const h = [L[0], L[1], L[2] + 1];
    const hm = Math.hypot(...h);
    const spec = Math.pow(Math.max(0, (nx * h[0] + ny * h[1] + nz * h[2]) / hm), 42) * 0.85;

    // rim light: a thin cool edge so the ball separates from the fairway
    const rim = Math.pow(1 - nz, 3) * 0.30;

    // dimples darken slightly in the pit, which is the ambient occlusion
    const ao = 1 - cav * 0.22;

    let v = (0.16 + 0.84 * diff) * ao + spec;
    let r = v * 255, g = v * 255, b = v * 252;   // very slightly warm white
    r += rim * 120; g += rim * 140; b += rim * 175;

    // antialias the silhouette over the last texel
    let a = 255;
    const edge = (1 - Math.sqrt(d2)) * R;
    if (edge < 1) a = Math.max(0, Math.min(255, edge * 255));

    px[o]     = Math.max(0, Math.min(255, r));
    px[o + 1] = Math.max(0, Math.min(255, g));
    px[o + 2] = Math.max(0, Math.min(255, b));
    px[o + 3] = a;
  }
}

// ── PNG ──────────────────────────────────────────────────────────────
function crc32(buf) {
  let c, t = [];
  for (let n = 0; n < 256; n++) {
    c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  let crc = 0xffffffff;
  for (const b of buf) crc = t[(crc ^ b) & 0xff] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}
function chunk(type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type, "ascii"), data]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td));
  return Buffer.concat([len, td, crc]);
}
const raw = Buffer.alloc((N * 4 + 1) * N);
for (let y = 0; y < N; y++) {
  raw[y * (N * 4 + 1)] = 0;
  Buffer.from(px.buffer, y * N * 4, N * 4).copy(raw, y * (N * 4 + 1) + 1);
}
const ihdr = Buffer.alloc(13);
ihdr.writeUInt32BE(N, 0); ihdr.writeUInt32BE(N, 4);
ihdr[8] = 8; ihdr[9] = 6; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
const png = Buffer.concat([
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
  chunk("IHDR", ihdr),
  chunk("IDAT", deflateSync(raw, { level: 9 })),
  chunk("IEND", Buffer.alloc(0)),
]);
const out = join(HERE, "..", "app", "assets", "ball.png");
writeFileSync(out, png);
console.log(`${out}: ${N}x${N}, ${DIMPLES} dimples, ${(png.length / 1024).toFixed(1)} KB`);
