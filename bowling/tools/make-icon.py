#!/usr/bin/env python3
"""The launcher icon: a ball and three pins, drawn rather than sourced.

Adaptive-icon contract: transparent background, content inside the middle
66% of the canvas (200..824 of 1024), or a circular or squircle launcher
mask clips it.
"""
import struct, zlib, math

N = 1024
px = bytearray(N * N * 4)

def put(x, y, r, g, b, a=255):
    if 0 <= x < N and 0 <= y < N:
        o = (y * N + x) * 4
        ia = a / 255.0
        px[o]   = int(px[o]   * (1 - ia) + r * ia)
        px[o+1] = int(px[o+1] * (1 - ia) + g * ia)
        px[o+2] = int(px[o+2] * (1 - ia) + b * ia)
        px[o+3] = max(px[o+3], a)

def disc(cx, cy, rad, col, aa=2):
    for y in range(int(cy - rad - 2), int(cy + rad + 3)):
        for x in range(int(cx - rad - 2), int(cx + rad + 3)):
            d = math.hypot(x - cx, y - cy)
            if d <= rad + aa:
                a = 255 if d <= rad - aa else int(255 * (rad + aa - d) / (2 * aa))
                put(x, y, col[0], col[1], col[2], max(0, min(255, a)))

def capsule(cx, cy, half, rad, col):
    disc(cx, cy - half, rad, col)
    disc(cx, cy + half, rad, col)
    for y in range(int(cy - half), int(cy + half + 1)):
        for x in range(int(cx - rad - 2), int(cx + rad + 3)):
            d = abs(x - cx)
            if d <= rad + 2:
                a = 255 if d <= rad - 2 else int(255 * (rad + 2 - d) / 4)
                put(x, y, col[0], col[1], col[2], max(0, min(255, a)))

# Three pins behind, a ball in front -- the game in one glance. Everything
# sits between 200 and 824 so no launcher mask can cut it.
PIN = (238, 238, 230)
NECK = (206, 60, 66)
for cx, cy in ((392, 400), (512, 340), (632, 400)):
    capsule(cx, cy, 68, 46, PIN)
    disc(cx, cy - 88, 30, PIN)
    capsule(cx, cy - 52, 6, 30, NECK)

BALL = (58, 96, 214)
disc(512, 636, 158, BALL)
for hx, hy in ((470, 596), (554, 596), (512, 664)):
    disc(hx, hy, 26, (14, 22, 52))

raw = bytearray()
for y in range(N):
    raw.append(0)
    raw += px[y * N * 4:(y + 1) * N * 4]

def chunk(tag, data):
    c = tag + data
    return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c))

png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", N, N, 8, 6, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
       + chunk(b"IEND", b""))

import os
out = os.path.join(os.path.dirname(__file__), "..", "icon.png")
open(out, "wb").write(png)
print("wrote", os.path.normpath(out))
