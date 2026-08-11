// Headless spades driver on the reference CartHost: replays the pointer
// click sequence that corrupted rendering under romdev, and a pad-only
// control. Dumps PNGs + per-checkpoint pixel stats.
import { CartHost } from '/Users/monteslu/code/cliemu/wasmcart/src/CartHost.js';
import { BUTTON } from '/Users/monteslu/code/cliemu/wasmcart/src/abi.js';
import { writeFileSync } from 'fs';
import { deflateSync } from 'zlib';

const CART = '/Users/monteslu/code/cliemu/games-for-dad/spades/spades.wasc';
const OUT = '/Users/monteslu/.claude/jobs/feccb790/tmp';

// minimal PNG (RGB8, filter 0) — framebuffer words are B,G,R,X
const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();
function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}
function chunk(type, data) {
  const out = Buffer.alloc(8 + data.length + 4);
  out.writeUInt32BE(data.length, 0);
  out.write(type, 4, 'ascii');
  data.copy(out, 8);
  out.writeUInt32BE(crc32(out.subarray(4, 8 + data.length)), 8 + data.length);
  return out;
}
function png(fb, w, h) {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; ihdr[9] = 2;
  const raw = Buffer.alloc(h * (1 + w * 3));
  for (let y = 0; y < h; y++) {
    const row = y * (1 + w * 3);
    for (let x = 0; x < w; x++) {
      const s = (y * w + x) * 4, d = row + 1 + x * 3;
      raw[d] = fb[s + 2]; raw[d + 1] = fb[s + 1]; raw[d + 2] = fb[s];
    }
  }
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr), chunk('IDAT', deflateSync(raw)), chunk('IEND', Buffer.alloc(0)),
  ]);
}

function stats(fb) {
  let black = 0, total = 0;
  for (let p = 0; p + 2 < fb.length; p += 4 * 16) {
    total++;
    if (fb[p] < 12 && fb[p + 1] < 12 && fb[p + 2] < 12) black++;
  }
  return { blackPct: Math.round((black / total) * 1000) / 10 };
}

async function run(mode) {
  const host = new CartHost();
  await host.load(CART, {});
  let frame = null, n = 0;
  let buttons = 0;

  // GL carts draw on the GPU; read the frame back like wasmcart-play does
  const glCtx = host.getGlContext();
  let glReadback = null;
  if (host.usesGL && glCtx) {
    const gi = host.getInfo();
    const gw = gi.width, gh = gi.height;
    const rgba = new Uint8Array(gw * gh * 4);
    const out = new Uint8Array(gw * gh * 4);
    glReadback = () => {
      glCtx.finish();
      glCtx.readPixels(0, 0, gw, gh, glCtx.RGBA, glCtx.UNSIGNED_BYTE, rgba);
      for (let y = 0; y < gh; y++) {
        const src = (gh - 1 - y) * gw * 4, dst = y * gw * 4;
        for (let x = 0; x < gw * 4; x += 4) {
          out[dst + x] = rgba[src + x + 2];
          out[dst + x + 1] = rgba[src + x + 1];
          out[dst + x + 2] = rgba[src + x];
          out[dst + x + 3] = 255;
        }
      }
      return { framebuffer: out, width: gw, height: gh };
    };
  }
  const hasContent = (buf) => {
    for (let p = 0; p + 2 < buf.length; p += 4 * 64) {
      if (buf[p] > 8 || buf[p + 1] > 8 || buf[p + 2] > 8) return true;
    }
    return false;
  };
  const step = (frames) => {
    for (let i = 0; i < frames; i++) {
      frame = host.runFrame([{ connected: true, buttons }]);
      n++;
    }
    if (glReadback) {
      const gf = glReadback();
      if (hasContent(gf.framebuffer)) frame = { ...frame, ...gf };
    }
  };
  const hold = (name, frames) => { buttons = BUTTON[name]; step(frames); buttons = 0; };
  const click = (x, y) => {
    host.pointerDown(0, x, y, 0);
    step(4);
    host.pointerUp(0, 0);
    step(2);
  };
  const shot = (tag) => {
    const s = stats(frame.framebuffer);
    console.log(`${mode} f=${n} ${tag} black=${s.blackPct}% dbg=` +
      JSON.stringify((host.readDebugState?.() || []).map(d => [d.name, d.value])));
    writeFileSync(`${OUT}/${mode}-${tag}.png`, png(frame.framebuffer, frame.width, frame.height));
  };

  step(30);
  if (mode === 'ptr') click(960, 548); else hold('A', 12);   // DEAL
  step(700);
  hold('A', 12);                                             // bid confirm
  step(220); shot('pick1');
  if (mode === 'ptr') { click(660, 700); step(4); shot('select'); click(1650, 495); }
  else hold('A', 12);                                        // play card
  step(130); shot('afterplay');
  // long soak: checkpoint every 300 frames
  for (let i = 1; i <= 8; i++) {
    step(300);
    const s = stats(frame.framebuffer);
    console.log(`${mode} f=${n} soak${i} black=${s.blackPct}%`);
    if (s.blackPct > 60) { shot(`soak${i}-corrupt`); break; }
    // keep the game moving: mash A occasionally so tricks keep playing
    hold('A', 10);
  }
  shot('end');
  host.destroy();
}

const mode = process.argv[2] || 'ptr';
run(mode).catch(e => { console.error('HARNESS ERROR:', e); process.exit(1); });
