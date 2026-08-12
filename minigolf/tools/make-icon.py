#!/usr/bin/env python3
"""make-icon.py - the Android launcher icon.

WHY PYTHON AND NOT THE ENGINE. Every other icon in this repo is rendered
by its own game and chroma-keyed. That does not work here: the engine
squashes a 1:1 cart horizontally -- measured, a circle asked to be 600px
wide came out 416x589 -- so a golf ball rendered that way is an egg. This
is a build-time asset, not something the game draws, so composing it here
with exact pixel control is both correct and reproducible.

The BALL is still the game's own texture (app/assets/ball.png), so the
icon cannot drift from what the game looks like.

ANDROID ADAPTIVE-ICON CONTRACT, verified at the end of this script:
  * transparent background -- the launcher supplies its own
  * all content inside the centre ~61% safe zone (200..824 of 1024),
    because launchers mask to a circle or squircle and may zoom

    python3 tools/make-icon.py
"""
from PIL import Image, ImageDraw

N = 1024
CX = CY = N // 2
SAFE_LO, SAFE_HI = 200, 824
R = 300                       # 212..812, comfortably inside the safe zone

FAIRWAY = (61, 140, 66, 255)
STRIPE  = (69, 153, 74, 255)
ROUGH   = (38, 92, 46, 255)
CUP     = (13, 13, 15, 255)
RIM     = (217, 217, 224, 165)
POLE    = (235, 235, 240, 255)
GOLD    = (242, 230, 128, 255)
FLAG    = (230, 51, 56, 255)

img = Image.new("RGBA", (N, N), (0, 0, 0, 0))
d = ImageDraw.Draw(img)

d.ellipse([CX - R, CY - R, CX + R, CY + R], fill=FAIRWAY)

# mow stripes, clipped to the disc
stripes = Image.new("RGBA", (N, N), (0, 0, 0, 0))
sd = ImageDraw.Draw(stripes)
w = 60
for i in range(-6, 7):
    if i % 2 == 0:
        x = CX + i * w
        sd.rectangle([x - w // 2, CY - R, x + w // 2, CY + R], fill=STRIPE)
mask = Image.new("L", (N, N), 0)
ImageDraw.Draw(mask).ellipse([CX - R, CY - R, CX + R, CY + R], fill=255)
img.paste(stripes, (0, 0),
          Image.composite(mask, Image.new("L", (N, N), 0), stripes.split()[3]))

d.ellipse([CX - R, CY - R, CX + R, CY + R], outline=ROUGH, width=18)

# cup and flag, upper right
hx, hy = CX + 92, CY - 96
d.ellipse([hx - 52, hy - 40, hx + 52, hy + 40], fill=CUP)
d.arc([hx - 52, hy - 40, hx + 52, hy + 40], 190, 350, fill=RIM, width=7)
d.line([hx, hy, hx + 6, hy - 168], fill=POLE, width=11)
d.ellipse([hx - 4, hy - 184, hx + 16, hy - 164], fill=GOLD)
d.polygon([(hx + 6, hy - 168), (hx + 104, hy - 142), (hx + 6, hy - 108)], fill=FLAG)

# the ball, from the game's own texture
ball = Image.open("app/assets/ball.png").convert("RGBA")
BR = 176
ball = ball.resize((BR, BR), Image.LANCZOS)
img.paste(ball, (CX - 104 - BR // 2, CY + 104 - BR // 2), ball)

img.save("icon.png")

bbox = img.split()[3].getbbox()
inside = (bbox[0] >= SAFE_LO and bbox[1] >= SAFE_LO
          and bbox[2] <= SAFE_HI and bbox[3] <= SAFE_HI)
transparent = img.getpixel((5, 5))[3] == 0
print(f"icon.png  bbox {bbox}  safe zone {SAFE_LO}..{SAFE_HI}")
if not (inside and transparent):
    raise SystemExit("ADAPTIVE ICON CONTRACT VIOLATED")
print("adaptive icon contract OK")
