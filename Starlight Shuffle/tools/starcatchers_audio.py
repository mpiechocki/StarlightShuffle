#!/usr/bin/env python3
"""Synthesizes Starcatchers' original audio into assets/audio/starcatchers/.

A render of the reference's procedural music (its music.js): a quiet celestial
loop of soft sine bell arpeggios (24 steps of 0.31 s) over a gentle low pulse
every six steps; and three effects: a light rising hook tone, a two-note bank
chime and a short low satellite-hit thud. Uses the helpers in
blast_mining_audio.py. Run from the project folder:
python3 tools/starcatchers_audio.py
"""
import math, os, sys

sys.path.insert(0, os.path.dirname(__file__))
import blast_mining_audio  # noqa: E402
from blast_mining_audio import RATE, add, hz, mix, noise_burst, sweep, write  # noqa: E402

OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "audio", "starcatchers")
blast_mining_audio.OUT = OUT  # write() saves there

ARPEGGIO = [72, 79, 83, 86, 83, 79, 74, 81, 84, 88, 84, 81, 71, 78, 83, 86, 83, 78, 69, 76, 81, 84, 81, 76]
PULSE = [48, 50, 47, 45]
STEP = 0.31


def bell(midi, length, volume):
    # A 25 ms swell, then an exponential fade to silence by [length].
    f, n = hz(midi), int((length + 0.02) * RATE)
    out = []
    for i in range(n):
        t = i / RATE
        g = volume * (t / 0.025 if t < 0.025 else (0.0001 / volume) ** min(1.0, (t - 0.025) / (length - 0.025)))
        out.append(g * math.sin(2 * math.pi * f * t))
    return out


def loop():
    buffer = [0.0] * int(len(ARPEGGIO) * STEP * RATE)
    for i, note in enumerate(ARPEGGIO):
        add(buffer, i * STEP, bell(note, 0.8, 0.07))
        if i % 6 == 0:
            add(buffer, i * STEP, bell(PULSE[(i // 6) % 4], 1.6, 0.09))
    return buffer


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    write("celestial_loop.wav", loop(), 0.45)
    write("hook.wav", sweep(880, 1320, 0.2, 0.5, 14), 0.4)
    write("bank.wav", mix(sweep(660, 990, 0.2, 0.5, 12), [0.0] * int(0.08 * RATE) + bell(88, 0.35, 0.3)), 0.5)
    write("snap.wav", mix(sweep(120, 180, 0.22, 0.8, 10), noise_burst(0.18, 0.35, 20, 9)), 0.6)
    print("wrote", sorted(os.listdir(OUT)))
