#!/usr/bin/env python3
"""Paints the lobby's night sky into assets/textures/lobby/night_sky.png.

An equirectangular map for the sky dome (u: azimuth, 0.5 straight ahead past
the back wall; v: 0 at the zenith), after the lobby renders: deep indigo above,
two soft green aurora ribbons, tiny stars and four-point sparkles, a rose glow
over the horizon and a sea of pale pink clouds below. Standard library only,
written through ImageMagick. Run from the project folder:
python3 tools/lobby_sky.py
"""
import math, random, struct, sys
W, H = 2048, 1024
rng = random.Random(7)
def hexc(h): return ((h >> 16) & 255, (h >> 8) & 255, h & 255)
# Elevation colour stops (degrees, colour), top to bottom.
STOPS = [(90, 0x221a40), (55, 0x34285e), (30, 0x52417f), (14, 0x7a5fa3), (4, 0xa985bd), (0, 0xc29acb),
         (-6, 0xcfa3cf), (-20, 0x9d7cb6), (-50, 0x5c4886), (-90, 0x3a2d60)]
def base(el):
    for (e0, c0), (e1, c1) in zip(STOPS, STOPS[1:]):
        if el <= e0 and el >= e1:
            t = (e0 - el) / (e0 - e1); t = t * t * (3 - 2 * t)
            a, b = hexc(c0), hexc(c1)
            return [a[k] + (b[k] - a[k]) * t for k in range(3)]
    return list(hexc(STOPS[-1][1]))
img = [[0.0, 0.0, 0.0] for _ in range(W * H)]
def mixin(i, c, a):
    p = img[i]
    for k in range(3): p[k] += (c[k] - p[k]) * a
aur = hexc(0x6fdcb4); aur2 = hexc(0x9fd8e8); rose = hexc(0xf2a7cf)
for y in range(H):
    el = 90 - (y + 0.5) / H * 180
    row = base(el)
    for x in range(W):
        az = (x + 0.5) / W * 360 - 180
        i = y * W + x
        img[i] = list(row)
        if 8 < el < 60:
            # Two soft aurora ribbons sweeping across the front, with faint curtains.
            for centre, amp, freq, col, strength in ((34, 7, 2.1, aur, 0.42), (46, 5, 1.6, aur2, 0.22)):
                c = centre + amp * math.sin(math.radians(az * freq + 40))
                d = (el - c) / 4.5
                curtain = 0.82 + 0.18 * math.sin(math.radians(az * 37)) * math.sin(math.radians(az * 11 + 20))
                front = max(0.0, math.cos(math.radians(az * 0.55)))
                a = strength * math.exp(-d * d) * curtain * front
                if a > 0.004: mixin(i, col, a)
        if -4 < el < 22:
            # A rose glow over the horizon.
            a = 0.22 * math.exp(-((el - 6) / 7) ** 2) * (0.75 + 0.25 * math.sin(math.radians(az * 3)))
            mixin(i, rose, a)
def blob(cx, cy, r, col, alpha):
    for y in range(max(0, int(cy - r)), min(H, int(cy + r) + 1)):
        for x in range(int(cx - r), int(cx + r) + 1):
            d = math.hypot(x - cx, y - cy) / r
            if d < 1:
                a = alpha * (1 - d * d) ** 1.5
                mixin(y * W + (x % W), col, a)
# A sea of soft clouds below the horizon (and a few drifting above it).
for _ in range(420):
    el = -4 - abs(rng.gauss(0, 9))
    cx, cy = rng.random() * W, (90 - el) / 180 * H
    shade = rng.choice((0xf3d2ea, 0xe7c2e4, 0xd4b2e2, 0xfbe3ef))
    blob(cx, cy, rng.uniform(26, 72), hexc(shade), rng.uniform(0.18, 0.4))
for _ in range(40):
    el = rng.uniform(2, 14); cx = rng.random() * W
    blob(cx, (90 - el) / 180 * H, rng.uniform(6, 16), hexc(0xd9b8e6), rng.uniform(0.12, 0.3))
# Stars: many tiny dim ones and some four-point sparkles.
for _ in range(2600):
    el = rng.uniform(-2, 88) if rng.random() < 0.9 else rng.uniform(-2, 20)
    x, y = int(rng.random() * W), int((90 - el) / 180 * H)
    a = rng.uniform(0.25, 0.85)
    mixin(y * W + x, (255, 246, 235), a)
for _ in range(110):
    el = rng.uniform(4, 80)
    cx, cy = rng.random() * W, (90 - el) / 180 * H
    size = rng.uniform(3, 9)
    col = rng.choice(((255, 247, 225), (255, 236, 196), (240, 230, 255)))
    for t in range(-int(size), int(size) + 1):
        f = (1 - abs(t) / (size + 1)) ** 2
        for (dx, dy) in ((t, 0), (0, t)):
            x, y = int(cx + dx) % W, int(cy + dy)
            if 0 <= y < H: mixin(y * W + x, col, 0.9 * f)
    blob(cx, cy, size * 0.9, col, 0.35)
import os, subprocess, tempfile
out = os.path.join(os.path.dirname(__file__), "..", "assets", "textures", "lobby", "night_sky.png")
with tempfile.NamedTemporaryFile(suffix=".ppm", delete=False) as f:
    f.write(b'P6 %d %d 255\n' % (W, H))
    f.write(bytes(max(0, min(255, int(round(c)))) for p in img for c in p))
subprocess.run(["magick", f.name, "-quality", "92", out], check=True)
os.remove(f.name)
print("wrote", out)
