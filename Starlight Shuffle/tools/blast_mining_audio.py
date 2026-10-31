#!/usr/bin/env python3
"""Synthesizes Blast Mining's original audio into assets/audio/blast_mining/.

Everything is generated here from scratch (no samples): a quiet, bouncy
work-song loop (plucked melody, walking bass pulse, soft chord taps and two
chant-like "hey" / "ho" vowel voices) and four short effects. Run it from the
project folder: python3 tools/blast_mining_audio.py
"""
import math, os, random, struct, wave

RATE = 22050
OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "audio", "blast_mining")


def hz(midi):
    return 440.0 * 2 ** ((midi - 69) / 12)


def write(name, samples, peak=0.85):
    top = max(1e-9, max(abs(s) for s in samples))
    scale = peak / top
    with wave.open(os.path.join(OUT, name), "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(RATE)
        f.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, s * scale)) * 32767)) for s in samples))


def add(buffer, at, voice):
    start = int(at * RATE)
    for i, v in enumerate(voice):
        j = (start + i) % len(buffer)  # wraps, so the loop's tail joins its head
        buffer[j] += v


def triangle(phase):
    x = phase % 1.0
    return 4 * x - 1 if x < 0.5 else 3 - 4 * x


def pluck(midi, length, volume):
    f, n = hz(midi), int(length * RATE)
    out = []
    for i in range(n):
        t = i / RATE
        env = min(1.0, t / 0.012) * math.exp(-t * 7.5)
        out.append(volume * env * (0.8 * triangle(f * t) + 0.2 * math.sin(2 * math.pi * 2 * f * t)))
    return out


def bass(midi, length, volume):
    f, n = hz(midi), int(length * RATE)
    return [volume * min(1.0, (i / RATE) / 0.01) * math.exp(-(i / RATE) * 6) * math.sin(2 * math.pi * f * i / RATE)
            for i in range(n)]


# Vowel formants (Hz, relative level): "hey" brighter, "ho" rounder.
VOWELS = {"hey": [(530, 1.0), (1840, 0.35), (2480, 0.1)], "ho": [(450, 1.0), (830, 0.45), (2400, 0.06)]}


def chant(midi, vowel, length, volume):
    f, n = hz(midi), int(length * RATE)
    harmonics = []
    for k in range(1, 40):
        fk = f * k
        if fk > RATE / 2.2:
            break
        level = sum(a * math.exp(-((fk - c) / 120.0) ** 2) for c, a in VOWELS[vowel]) / k ** 0.3
        harmonics.append((fk, level))
    out = []
    for i in range(n):
        t = i / RATE
        env = min(1.0, t / 0.08) * (1 - t / length) ** 1.6
        vib = 1 + 0.006 * math.sin(2 * math.pi * 5.2 * t)
        out.append(volume * env * sum(a * math.sin(2 * math.pi * fk * vib * t) for fk, a in harmonics))
    return out


def song():
    step = 60 / 108 / 2  # eighth notes at 108 bpm
    steps = 32
    buffer = [0.0] * int(steps * step * RATE)
    melody = [64, None, 67, 69, 67, None, 64, 62, 60, None, 62, 64, 62, None, 60, None,
              64, None, 67, 72, 71, None, 69, 67, 64, None, 62, 64, 60, None, None, None]
    for i in range(steps):
        at = i * step
        chord = 48 if i < 8 or i >= 24 else (53 if i < 16 else 55)
        if i % 4 == 0:
            add(buffer, at, bass(chord - 12, 0.34, 0.5))
            add(buffer, at, pluck(chord, 0.16, 0.10))
        if i % 4 == 2:
            for n in (chord + 4, chord + 7):
                add(buffer, at, pluck(n + 12, 0.14, 0.07))
        if melody[i] is not None:
            add(buffer, at, pluck(melody[i], 0.3, 0.26))
    # Call and answer: "hey" ... "ho".
    for i, vowel, note in [(6, "hey", 60), (14, "ho", 55), (22, "hey", 62), (30, "ho", 55)]:
        add(buffer, i * step, chant(note, vowel, 0.45, 0.05))
    return buffer


def noise_burst(length, volume, decay, seed):
    rng = random.Random(seed)
    n, out, last = int(length * RATE), [], 0.0
    for i in range(n):
        t = i / RATE
        last = 0.7 * last + 0.3 * rng.uniform(-1, 1)  # softened noise
        out.append(volume * math.exp(-t * decay) * last)
    return out


def sweep(f0, f1, length, volume, decay, shape=math.sin):
    n, out, phase = int(length * RATE), [], 0.0
    for i in range(n):
        t = i / RATE
        f = f0 * (f1 / f0) ** min(1.0, t / length)
        phase += f / RATE
        out.append(volume * min(1.0, t / 0.004) * math.exp(-t * decay) * shape(2 * math.pi * phase))
    return out


def mix(*voices):
    n = max(len(v) for v in voices)
    return [sum(v[i] if i < len(v) else 0 for v in voices) for i in range(n)]


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    write("work_song.wav", song(), 0.7)
    write("rock.wav", mix(sweep(520, 1500, 0.09, 0.6, 38), noise_burst(0.05, 0.35, 70, 1)), 0.6)
    write("gem.wav", mix(sweep(950, 1900, 0.22, 0.5, 14), sweep(1425, 2850, 0.18, 0.25, 18)), 0.6)
    write("bomb.wav", mix(sweep(130, 45, 0.32, 0.9, 9, lambda x: triangle(x / (2 * math.pi))), noise_burst(0.25, 0.5, 16, 2)), 0.8)
    write("swing.wav", noise_burst(0.12, 0.6, 30, 3), 0.3)
    print("wrote", sorted(os.listdir(OUT)))
