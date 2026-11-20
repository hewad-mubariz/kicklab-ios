#!/usr/bin/env python3
"""Original, layered masonry Foley synthesis; no third-party samples.

Pre-rendered mono PCM keeps synthesis off the phone. Emphasise low-mid body
that small speakers reproduce, dry fractures, and irregular rubble arrivals.
No speech, musical finish notes, sustained ringing, or runtime audio DSP.
"""
import json
import math
import random
import struct
import wave
from pathlib import Path

RATE = 44100
ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / 'kicklab/Resources/WallBrickAudio'


def cue(kind, seed):
    rng = random.Random(seed)
    duration = {'crack': .36, 'break': .72, 'smash': .92, 'clear': 1.08}[kind]
    samples = [0.] * int(RATE * duration)
    mass = {'crack': .45, 'break': 1., 'smash': 1.35, 'clear': 1.45}[kind]

    def impact(delay, amplitude, weight, decay):
        """Filtered noise + brief inharmonic body, with a softer high end."""
        start = int(delay * RATE)
        low = mid = smooth = 0.
        frequency = rng.uniform(175, 230) / (0.8 + weight * .18)
        phase = 0.
        for k in range(min(int(RATE * decay * 7), len(samples) - start)):
            t = k / RATE
            noise = rng.uniform(-1, 1)
            low += .045 * (noise - low)
            mid += .22 * (noise - mid)
            smooth += .55 * (noise - smooth)
            attack = min(1, t / .001)
            phase += 2 * math.pi * frequency * (1 - .35 * min(1, t / .11)) / RATE
            body = (low * 3.2 + .28 * math.sin(phase) + .12 * math.sin(phase * 2.39)) * math.exp(-t / decay)
            fracture = ((mid - low) * 1.8 + (smooth - mid) * .32) * math.exp(-t / (.008 + weight * .005))
            samples[start + k] += amplitude * attack * (body * weight + fracture * .8)

    # Immediate body, followed by two slightly offset fissures: one solid hit.
    impact(0, .8, mass, .038 + mass * .016)
    impact(.010, .28, mass * .5, .018)
    impact(.026, .18, mass * .7, .023)

    # Heavy pieces land before fine grit. Uneven arrival times and resonances
    # avoid a mechanical rattle or the older high-pitched clicking tail.
    heavy = {'crack': 2, 'break': 7, 'smash': 11, 'clear': 14}[kind]
    for j in range(heavy):
        delay = .055 + (j / heavy) ** 1.2 * (duration - .23) + rng.uniform(0, .025)
        amplitude = rng.uniform(.11, .23) * math.exp(-delay / .55)
        impact(delay, amplitude, rng.uniform(.45, .95), rng.uniform(.012, .029))

    # Brief granular crunch underneath discrete tumbles, never a long hiss.
    for j in range(9 if kind == 'crack' else 27):
        delay = .025 + rng.random() ** .8 * (duration - .13)
        start = int(delay * RATE)
        length = int(RATE * rng.uniform(.008, .025))
        amp = rng.uniform(.035, .09) * math.exp(-delay / .38)
        filtered = 0.
        for k in range(min(length, len(samples) - start)):
            t = k / RATE
            filtered += .38 * (rng.uniform(-1, 1) - filtered)
            samples[start + k] += amp * filtered * min(1, t / .0008) * math.exp(-t / .004)

    # Compression gives body weight without only making the first sample loud.
    samples = [math.tanh(x * 1.45) for x in samples]
    gain = {'crack': .75, 'break': .84, 'smash': .88, 'clear': .88}[kind] / max(abs(x) for x in samples)
    return [round(x * gain * min(1, (len(samples) - 1 - i) / (RATE * .025)) * 32767)
            for i, x in enumerate(samples)]


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    report = []
    for kind, variants in [('crack', 2), ('break', 3), ('smash', 3), ('clear', 1)]:
        for variant in range(1, variants + 1):
            pcm = cue(kind, 201026 + variant * 97 + len(kind) * 31)
            name = f'wall-brick-{kind}-{variant}.wav'
            with wave.open(str(OUTPUT / name), 'wb') as f:
                f.setnchannels(1); f.setsampwidth(2); f.setframerate(RATE)
                f.writeframes(struct.pack('<' + 'h' * len(pcm), *pcm))
            report.append({'file': name, 'seconds': len(pcm) / RATE,
                           'peak': max(abs(x) for x in pcm) / 32768,
                           'rms': math.sqrt(sum((x / 32768) ** 2 for x in pcm) / len(pcm)),
                           'endsAtZero': pcm[-1] == 0})
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
