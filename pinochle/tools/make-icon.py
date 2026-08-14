#!/usr/bin/env python3
"""The launcher icon: the pinochle itself.

THE MELD IS THE LOGO. A pinochle is the jack of diamonds and the queen of
spades -- the one combination the game is named after -- so the icon is
those two cards, fanned, with their pips large enough to read at a launcher
size. Nothing else in the collection uses a red-and-black pair, so it is
distinguishable from Spades and the poker games at a glance.

Adaptive-icon contract: transparent background, content inside the middle
66% of the canvas (200..824 of 1024), or a circular or squircle launcher
mask clips it. The fan is sized against that, not against the full canvas.
"""
import struct, zlib, math

N = 1024
px = bytearray(N * N * 4)

FELT_D = (14, 62, 34)      # the card table, as a rounded plate behind
CARD   = (247, 245, 238)   # bone white, matching the deck art
INK    = (24, 24, 28)
RED    = (196, 30, 42)
EDGE   = (188, 184, 172)
GOLD   = (214, 168, 66)


def put(x, y, r, g, b, a=255):
    if 0 <= x < N and 0 <= y < N and a > 0:
        o = (y * N + x) * 4
        ia = a / 255.0
        px[o]     = int(px[o]     * (1 - ia) + r * ia)
        px[o + 1] = int(px[o + 1] * (1 - ia) + g * ia)
        px[o + 2] = int(px[o + 2] * (1 - ia) + b * ia)
        px[o + 3] = max(px[o + 3], a)


def rrect(cx, cy, hw, hh, rad, col, rot=0.0, aa=1.6):
    """A rounded rect, optionally rotated about its own centre."""
    c, s = math.cos(-rot), math.sin(-rot)
    span = int(math.hypot(hw, hh)) + 4
    for y in range(int(cy - span), int(cy + span + 1)):
        for x in range(int(cx - span), int(cx + span + 1)):
            dx, dy = x - cx, y - cy
            lx, ly = dx * c - dy * s, dx * s + dy * c
            # signed distance to a rounded box
            qx, qy = abs(lx) - (hw - rad), abs(ly) - (hh - rad)
            d = math.hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - rad
            if d <= aa:
                a = 255 if d <= -aa else int(255 * (aa - d) / (2 * aa))
                put(x, y, col[0], col[1], col[2], max(0, min(255, a)))


def poly(pts, col, cx=0, cy=0, rot=0.0, scale=1.0, aa=1.0):
    """Filled polygon, rotated and scaled about (cx, cy)."""
    c, s = math.cos(rot), math.sin(rot)
    P = []
    for (x, y) in pts:
        x, y = x * scale, y * scale
        P.append((cx + x * c - y * s, cy + x * s + y * c))
    ys = [p[1] for p in P]
    for y in range(int(min(ys)) - 1, int(max(ys)) + 2):
        xs = []
        for i in range(len(P)):
            x1, y1 = P[i]
            x2, y2 = P[(i + 1) % len(P)]
            if (y1 <= y < y2) or (y2 <= y < y1):
                xs.append(x1 + (y - y1) / (y2 - y1) * (x2 - x1))
        xs.sort()
        for i in range(0, len(xs) - 1, 2):
            for x in range(int(xs[i]), int(xs[i + 1]) + 1):
                put(x, y, col[0], col[1], col[2], 255)


# ── the pips ──────────────────────────────────────────────────────────
# Drawn as polygons rather than glyphs: a font would have to ship with the
# icon script, and these are two shapes.

def spade(cx, cy, size, col, rot=0.0):
    # lobes
    for (ox, oy, rr) in ((-0.30, -0.06, 0.34), (0.30, -0.06, 0.34)):
        r = size * rr
        px_, py_ = cx + ox * size, cy + oy * size
        for y in range(int(py_ - r - 2), int(py_ + r + 3)):
            for x in range(int(px_ - r - 2), int(px_ + r + 3)):
                d = math.hypot(x - px_, y - py_)
                if d <= r + 1:
                    a = 255 if d <= r - 1 else int(255 * (r + 1 - d) / 2)
                    put(x, y, col[0], col[1], col[2], max(0, min(255, a)))
    # the point, and the stem
    poly([(0, -0.92), (0.62, 0.02), (-0.62, 0.02)], col, cx, cy, rot, size)
    poly([(-0.09, 0.10), (0.09, 0.10), (0.22, 0.72), (-0.22, 0.72)],
         col, cx, cy, rot, size)


def diamond(cx, cy, size, col, rot=0.0):
    poly([(0, -1.0), (0.66, 0), (0, 1.0), (-0.66, 0)], col, cx, cy, rot, size)


# ── the plate ─────────────────────────────────────────────────────────
# A felt disc behind the cards, so the white reads against any launcher
# wallpaper. Inside the 66% safe area with room to spare.
rrect(N / 2, N / 2, 318, 318, 96, FELT_D)
rrect(N / 2, N / 2, 318, 318, 96, GOLD, aa=1.2)
rrect(N / 2, N / 2, 308, 308, 88, FELT_D)

# ── the two cards ─────────────────────────────────────────────────────
# Fanned apart, the black one behind and the red one in front, which is the
# order they sit in a sorted hand.
CW, CH, CR = 132, 190, 18

# Q of spades, tilted left
rrect(452, 520, CW, CH, CR, EDGE, rot=-0.30)
rrect(452, 518, CW - 5, CH - 5, CR, CARD, rot=-0.30)
spade(452, 512, 74, INK)

# J of diamonds, tilted right, overlapping in front
rrect(590, 520, CW, CH, CR, EDGE, rot=0.30)
rrect(590, 518, CW - 5, CH - 5, CR, CARD, rot=0.30)
diamond(590, 512, 70, RED)


def png(path):
    raw = bytearray()
    for y in range(N):
        raw.append(0)
        raw += px[y * N * 4:(y + 1) * N * 4]
    def chunk(tag, data):
        c = struct.pack('>I', len(data)) + tag + data
        return c + struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff)
    out = b'\x89PNG\r\n\x1a\n'
    out += chunk(b'IHDR', struct.pack('>IIBBBBB', N, N, 8, 6, 0, 0, 0))
    out += chunk(b'IDAT', zlib.compress(bytes(raw), 9))
    out += chunk(b'IEND', b'')
    open(path, 'wb').write(out)


if __name__ == '__main__':
    import os
    here = os.path.dirname(os.path.abspath(__file__))
    png(os.path.join(here, '..', 'icon.png'))
    print('wrote icon.png')
