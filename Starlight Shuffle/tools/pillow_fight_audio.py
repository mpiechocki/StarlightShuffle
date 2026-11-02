#!/usr/bin/env python3
"""Synthesizes Pillow Fight's original audio into assets/audio/pillow_fight/.

A port of the prototype's procedural audio (its audio.js), rendered to files
with the helpers in blast_mining_audio.py: the sleep-time music-box lullaby
(sparse bell plucks with soft overtones over a slow warm triangle bass, 48
steps of 0.6 s, looping seamlessly), the fabric whoosh of your own throw, the
distinct two-note warning ring (a pillow is about to land on you), the soft
low thud of a hit on you and a very soft dodge swish. Run from the project
folder: python3 tools/pillow_fight_audio.py
"""
import math, os, random, sys

sys.path.insert(0, os.path.dirname(__file__))
import blast_mining_audio  # noqa: E402
from blast_mining_audio import RATE, add, hz, mix, triangle, write  # noqa: E402

OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "audio", "pillow_fight")
blast_mining_audio.OUT = OUT  # write() saves there

MELODY = [76, None, 79, 81, 79, None, 76, None, 74, 72, None, None, 74, None, 76, 79, 76, None, 72, None, 71, 69, None, None,
          72, None, 76, 77, 76, None, 74, None, 72, 69, None, None, 71, None, 74, 76, 74, None, 72, None, None, None, None, None]
BASS = [48, 45, 41, 43]
STEP = 0.6


def tone(freq, length, volume, shape="sine"):
    # Exponential swell to [volume] over min(0.6, length / 5), then away by [length].
    rise = min(0.6, length * 0.2)
    n, out, phase = int((length + 0.05) * RATE), [], 0.0
    for i in range(n):
        t = i / RATE
        if t < rise:
            g = 0.0001 * (volume / 0.0001) ** (t / rise)
        else:
            g = volume * (0.0001 / volume) ** min(1.0, (t - rise) / (length - rise))
        phase += freq / RATE
        out.append(g * (triangle(phase) if shape == "triangle" else math.sin(2 * math.pi * phase)))
    return out


def music_box(midi):
    # A bell pluck: the note and two quiet inharmonic overtones.
    f = hz(midi)
    voices = []
    for ratio, level, length in ((1, 0.115, 2.4), (2.76, 0.018, 1.1), (4.01, 0.004, 0.6)):
        n, out = int((length + 0.03) * RATE), []
        for i in range(n):
            t = i / RATE
            if t < 0.014:
                g = level * t / 0.014
            elif t < 0.2:
                g = level * 0.32 ** ((t - 0.014) / 0.186)
            else:
                g = level * 0.32 * (0.0001 / (level * 0.32)) ** min(1.0, (t - 0.2) / (length - 0.2))
            out.append(g * math.sin(2 * math.pi * f * ratio * t))
        voices.append(out)
    return mix(*voices)


def lullaby():
    buffer = [0.0] * int(len(MELODY) * STEP * RATE)
    for i, note in enumerate(MELODY):
        at = i * STEP
        if note is not None:
            add(buffer, at, music_box(note))
        if i % 6 == 0:
            root = BASS[i // 12]
            add(buffer, at, tone(hz(root), 3.5, 0.045, "triangle"))
            add(buffer, at + 0.6, tone(hz(root + 7), 2.5, 0.022))
    return buffer


def filtered_noise(length, kind, freq, volume, seed):
    # Softened noise through one-pole filters ("low", "high", or "band": the
    # low-pass minus a low-pass a third as high) whose corner falls to 30%; a
    # 25 ms swell, then an exponential fade.
    rng = random.Random(seed)
    n, out, low, floor, last = int(length * RATE), [], 0.0, 0.0, 0.0
    for i in range(n):
        t = i / RATE
        corner = freq * 0.3 ** (t / length)
        last = 0.7 * last + 0.3 * rng.uniform(-1, 1)
        low += (1 - math.exp(-2 * math.pi * corner / RATE)) * (last - low)
        floor += (1 - math.exp(-2 * math.pi * corner / 3 / RATE)) * (last - floor)
        sample = {"low": low, "high": last - low, "band": low - floor}[kind]
        g = volume * (t / 0.025 if t < 0.025 else (0.0001 / volume) ** ((t - 0.025) / (length - 0.025)))
        out.append(g * sample)
    return out


def delayed(seconds, voice):
    return [0.0] * int(seconds * RATE) + voice


def thud():
    n, out, phase = int(0.24 * RATE), [], 0.0
    for i in range(n):
        t = i / RATE
        f = 115 * (48 / 115) ** min(1.0, t / 0.17)
        phase += f / RATE
        out.append(0.2 * (0.0001 / 0.2) ** min(1.0, t / 0.22) * math.sin(2 * math.pi * phase))
    return out


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    write("lullaby.wav", lullaby(), 0.5)
    write("throw.wav", mix(filtered_noise(0.32, "band", 2200, 0.75, 1), delayed(0.07, filtered_noise(0.18, "low", 950, 0.32, 2))), 0.5)
    write("warning.wav", mix(tone(1396.9, 0.45, 0.15), delayed(0.13, tone(1174.66, 0.45, 0.105)), tone(2793.8, 0.25, 0.025)), 0.55)
    write("hit.wav", mix(filtered_noise(0.23, "low", 260, 0.85, 3), thud()), 0.6)
    write("dodge.wav", filtered_noise(0.18, "high", 1600, 0.22, 4), 0.25)
    print("wrote", sorted(os.listdir(OUT)))
