#!/usr/bin/env python3
"""Synthesizes Lucky Shot's original audio into assets/audio/lucky_shot/.

Generated from scratch with the helpers in blast_mining_audio.py: a quiet,
playful pentatonic loop (soft sine melody over slow bass fifths), a soft pop
for white and gold clouds (gold a little higher), a short low thunder for
storm clouds and a small slingshot twang. Run from the project folder:
python3 tools/lucky_shot_audio.py
"""
import math, os, random, sys

sys.path.insert(0, os.path.dirname(__file__))
import blast_mining_audio  # noqa: E402
from blast_mining_audio import RATE, add, hz, mix, sweep, write  # noqa: E402

OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "audio", "lucky_shot")
blast_mining_audio.OUT = OUT  # write() saves there


def tone(midi, length, volume, attack=0.015):
    f, n = hz(midi), int(length * RATE)
    return [volume * min(1.0, (i / RATE) / attack) * math.exp(-(i / RATE) * 4.2 / length) * math.sin(2 * math.pi * f * i / RATE)
            for i in range(n)]


def song():
    step = 0.27
    melody = [76, 0, 79, 83, 81, 0, 79, 0, 74, 0, 76, 79, 74, 0, 71, 0,
              72, 0, 76, 79, 81, 0, 79, 76, 74, 0, 71, 74, 76, 0, 0, 0]
    buffer = [0.0] * int(len(melody) * step * RATE)
    for i, n in enumerate(melody):
        if n:
            add(buffer, i * step, tone(n, 1.2, 0.27))
        if i % 8 == 0:
            bass = [48, 55, 53, 50][(i // 8) % 4]
            add(buffer, i * step, tone(bass, 2.5, 0.16, 0.05))
            add(buffer, i * step, tone(bass + 7, 2.4, 0.09, 0.05))
    return buffer


def thunder(length=0.55, seed=4):
    rng, out, low, lower = random.Random(seed), [], 0.0, 0.0
    n = int(length * RATE)
    for i in range(n):
        # Two one-pole low-passes over white noise: a soft rumble.
        low += 0.12 * (rng.uniform(-1, 1) - low)
        lower += 0.12 * (low - lower)
        out.append(lower * (1 - i / n) ** 2)
    return out


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    write("meadow_song.wav", song(), 0.6)
    write("pop.wav", sweep(850, 280, 0.14, 0.8, 22), 0.6)
    write("pop_gold.wav", mix(sweep(1100, 280, 0.14, 0.8, 22), sweep(1650, 420, 0.1, 0.25, 28)), 0.6)
    write("thunder.wav", thunder(), 0.8)
    write("twang.wav", sweep(320, 180, 0.12, 0.6, 30, lambda x: math.sin(x) + 0.3 * math.sin(2 * x)), 0.35)
    print("wrote", sorted(os.listdir(OUT)))
