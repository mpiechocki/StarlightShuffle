#!/usr/bin/env python3
"""Synthesizes Star Pass's original audio into assets/audio/star_pass/.

Generated with the helpers in blast_mining_audio.py: the warning clock's two
soft "tick" and "tock" voices (short triangle tones falling 1550->650 Hz and
1050->420 Hz over about 28 ms, gone by about 48 ms), a little catch chime, a
pass whoosh, a soft burst and a very quiet playful loop. Run from the project
folder: python3 tools/star_pass_audio.py
"""
import math, os, sys

sys.path.insert(0, os.path.dirname(__file__))
import blast_mining_audio  # noqa: E402
from blast_mining_audio import RATE, add, mix, noise_burst, sweep, triangle, write  # noqa: E402

OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "audio", "star_pass")
blast_mining_audio.OUT = OUT  # write() saves there


def clock(f0, f1):
    n, out, phase = int(0.05 * RATE), [], 0.0
    for i in range(n):
        t = i / RATE
        f = f0 * (f1 / f0) ** min(1.0, t / 0.028)
        phase += f / RATE
        out.append(min(1.0, t / 0.002) * (1 - t / 0.05) ** 2 * triangle(phase))
    return out


def loop():
    notes = [659, 0, 784, 880, 0, 784, 659, 0, 587, 0, 659, 784, 0, 587, 523, 0]
    step = 0.38
    buffer = [0.0] * int(len(notes) * step * RATE)
    for i, f in enumerate(notes):
        if f:
            n = int(1.1 * RATE)
            add(buffer, i * step, [0.3 * min(1.0, (k / RATE) / 0.02) * math.exp(-(k / RATE) * 3.2) * math.sin(2 * math.pi * f * k / RATE)
                                   for k in range(n)])
    return buffer


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    write("tick.wav", clock(1550, 650), 0.7)
    write("tock.wav", clock(1050, 420), 0.7)
    write("catch.wav", mix(sweep(880, 1320, 0.16, 0.5, 18), sweep(1320, 1760, 0.12, 0.25, 24)), 0.5)
    write("pass.wav", mix(noise_burst(0.14, 0.4, 24, 5), sweep(500, 1100, 0.12, 0.2, 20)), 0.4)
    write("burst.wav", mix(sweep(700, 220, 0.2, 0.6, 16), noise_burst(0.2, 0.3, 22, 6)), 0.55)
    write("garden_song.wav", loop(), 0.4)
    print("wrote", sorted(os.listdir(OUT)))
