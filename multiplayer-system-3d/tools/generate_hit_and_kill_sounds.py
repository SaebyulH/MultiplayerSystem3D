#!/usr/bin/env python3
"""Generate the hitmarker tick and the jazz kill-sting base note.

    python tools/generate_hit_and_kill_sounds.py

Writes two 16-bit mono 44.1 kHz WAVs into assets/sounds/:

  hitmarker_tick.wav    short, bright, punchy hit confirmation
  kill_note_sax_e4.wav  short, punchy E4 sax stab (0.26 s)

The kill sting (world/game_menu.gd) pitch-scales the base note by a semitone
ratio, so the sample's ROOT PITCH MATTERS: it is E4 (329.63 Hz).  Replacing the
file with a note at another pitch shifts the whole 30-kill theme.

No dependencies beyond the standard library.
"""

import math
import random
import struct
import wave

SR = 44100
OUT_DIR = "assets/sounds"


def write_wav(path, samples):
    # The generators below already normalise; do not renormalise here or the
    # per-sound headroom (the kill sting needs room for stacked notes) is lost.
    data = b"".join(struct.pack("<h", int(max(-1.0, min(1.0, s)) * 32767)) for s in samples)
    with wave.open(path, "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(SR)
        f.writeframes(data)


def fade_tail(samples, seconds=0.01):
    n = int(SR * seconds)
    for i in range(n):
        samples[-n + i] *= 1.0 - i / n


def make_hit():
    """Crisp high tick + low thump.  ~140 ms."""
    rng = random.Random(7)
    n = int(SR * 0.14)
    out = []
    phase_thump = 0.0
    prev_noise = 0.0
    for i in range(n):
        t = i / SR
        # Two inharmonic high partials: the "tick".
        tick = 0.55 * math.sin(2 * math.pi * 2350.0 * t) * math.exp(-t / 0.020)
        tick += 0.30 * math.sin(2 * math.pi * 3480.0 * t) * math.exp(-t / 0.011)
        # Falling low body: the "thock" that gives the hit weight.
        freq = 190.0 * math.exp(-t / 0.030) + 105.0
        phase_thump += 2 * math.pi * freq / SR
        thump = 0.85 * math.sin(phase_thump) * math.exp(-t / 0.042)
        # First-difference white noise = cheap high-pass snap.
        noise = rng.uniform(-1.0, 1.0)
        snap = (noise - prev_noise) * math.exp(-t / 0.0025) * 0.45
        prev_noise = noise
        out.append(tick + thump + snap)
    fade_tail(out, 0.012)
    # Peak-normalise to 0.9 so the tick is forceful but leaves headroom.
    peak = max(abs(s) for s in out)
    return [s / peak * 0.9 for s in out]


def make_sax_e4():
    """E4 alto/tenor-sax-style note: reed-rich harmonics + formants, breath, vibrato.

    Additive synthesis shaped by broad sax formants (~900 / 1500 / 2800 Hz),
    with a short pitch scoop, delayed vibrato and breath noise.  Pitch-shifting
    this up/down by the kill theme's semitone ratios moves the formants with it,
    which reads as a smaller/larger sax rather than a synth.
    """
    f0 = 329.63  # E4 - the root the kill theme is written against.
    # Short staccato stab, not a held note: the kill theme plays one per event
    # and stacks chords, so a long sustain would smear the phrase together.
    n = int(SR * 0.26)
    # Harmonic weights: a gentler-than-sawtooth rolloff (k^-0.65) shaped by the
    # sax formants, which keep harmonics 5-12 strong enough to read as a reed.
    harmonics = []
    formants = ((900.0, 250.0, 0.90), (1500.0, 350.0, 0.70), (2800.0, 500.0, 0.35))
    for k in range(1, 48):
        f = k * f0
        if f > 8000.0:  # keep content clear of resampling alias on high notes
            break
        formant = 0.35
        for fc, bw, gain in formants:
            formant += gain * math.exp(-0.5 * ((f - fc) / bw) ** 2)
        harmonics.append((k, formant / (k ** 0.65)))

    out = []
    rng = random.Random(23)
    phase = 0.0
    prev_noise = 0.0
    lp_noise = 0.0
    for i in range(n):
        t = i / SR
        # Pitch scoop (~35 cents flat) into a short jazz fall-off at the release.
        vib = 0.0
        if t > 0.08:
            vib = 0.006 * min(1.0, (t - 0.08) / 0.08) * math.sin(2 * math.pi * 5.4 * t)
        fall = 1.0
        if t > 0.16:
            fall = 1.0 - 0.035 * min(1.0, (t - 0.16) / 0.09)
        freq = f0 * (1.0 - 0.022 * math.exp(-t / 0.06)) * (1.0 + vib) * fall
        phase += 2 * math.pi * freq / SR

        tone = 0.0
        for k, weight in harmonics:
            tone += weight * math.sin(k * phase)

        # Breath: first-difference noise (high-pass) then a ~4 kHz low-pass.
        noise_in = rng.uniform(-1.0, 1.0)
        hp = noise_in - prev_noise
        prev_noise = noise_in
        lp_noise += (hp - lp_noise) * 0.35

        # Punchy stab envelope: near-instant attack, quick decay, hard release.
        attack = 1.0 - math.exp(-t / 0.005)
        body = 0.30 + 0.70 * math.exp(-t / 0.070)
        release = 1.0
        if t > 0.17:
            release = max(0.0, 1.0 - (t - 0.17) / 0.09)
        env = attack * body * release
        # Reed chiff on the attack, then a breath layer under the tone.
        chiff = lp_noise * math.exp(-t / 0.008) * 0.10
        out.append(tone * env * 0.9 + (lp_noise * 0.05 + chiff) * env)

    fade_tail(out, 0.01)
    # 0.34 peak: the sting stacks up to 4 simultaneous chord notes.
    peak = max(abs(s) for s in out)
    return [s / peak * 0.34 for s in out]


if __name__ == "__main__":
    write_wav(f"{OUT_DIR}/hitmarker_tick.wav", make_hit())
    write_wav(f"{OUT_DIR}/kill_note_sax_e4.wav", make_sax_e4())
    print("wrote hitmarker_tick.wav and kill_note_sax_e4.wav")
