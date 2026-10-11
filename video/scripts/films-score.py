#!/usr/bin/env python3
"""
The film looks reel's score: a synthwave track in F sharp minor at 112.5 BPM, 14 bars and 29.9 seconds
on the reel's cue sheet, src/films/cues.json, whose build drives the cuts: a look a bar, then every two
beats, every beat and every half beat, a camera's shutter firing on each, until the shutters run like a
motor drive into the stop; the drop lands the pull back to the contact sheet.

The chords go round the minor key's i, VI, III and VII, a bar each, with their colour notes: F#m9, Dmaj9,
Amaj9 and E6, then F#m9 and Dmaj9 again; through the build they change every two beats and climb, Bm9,
C#m7, Dmaj9, E6 and Dmaj7#11, to C#7sus4 letting down to C#7 into the drop on F#m9; on the end line
Dmaj9, Bm9 and C#7, and F#m9 on the last hit. The riff is two bars on a lead that rings as it's struck:
F sharp, A and up to C sharp, then B, A and down to E; F sharp, A and B, then A, F sharp and down to C
sharp. The answer climbs over A major and E: E, G sharp and B, then A, G sharp and E; E, F sharp and G
sharp up to B, held. Through the build a single line rises a step every two beats from C sharp to B,
held through the stop, and the drop brings the riff back doubled an octave up; the closing phrase turns
through E sharp, the leading note, to F sharp on the last hit.

Under it a supersaw pad on each chord, opening through the build; a pluck in sixteenths climbing each
half bar, brighter as the cuts quicken; an octave bass in eighths; a kick on 1 and 3 with a push on the
and of 4 from the first look, a gated snare on 2 and 4 from the looks every two beats, four on the floor
and a tambourine in sixteenths from the looks every beat, and a snare roll doubling into the stop. On the
drop, a deep kick, a crash and air rising as the picture pulls back; the icons coming up across the sheet
ring a run of glass up the chord.

    python3 scripts/films-score.py     writes public/films/score.wav and score.json
"""

import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import synth as s  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
sheet = json.loads((ROOT / "src/films/cues.json").read_text())
cue = sheet["cues"]
LOOKS = sheet["looks"]
BEAT = 60 / sheet["bpm"]
BEATS = sheet["bars"] * sheet["beatsPerBar"]
LENGTH = BEATS * BEAT
FIRST, PAIRS, EVERY, HALVES = cue["first"], cue["pairs"], cue["beats"], cue["halves"]
STOP, DROP, END_LINE, END, LAST, FADE = cue["stop"], cue["drop"], cue["endLine"], cue["end"], cue["lastHit"], cue["fade"]


def at(beat):
    return beat * BEAT


def playing(first, last, step):
    """Beats from `first` up to `last`, every `step`, leaving out the stop before the drop."""
    return [b for b in np.arange(first, last - 1e-9, step) if not STOP <= b < DROP]


def opening(beat, start, end, low, high):
    """`low` before `start`, `high` after `end`, and between them a curve that hurries at the end."""
    t = min(1.0, max(0.0, (beat - start) / (end - start)))
    return low + (high - low) * t**1.6


def dying(x, seconds):
    """`x`, dying away by 1/e every `seconds`."""
    fall = np.exp(-np.arange(len(x)) / s.SR / seconds)
    return x * (fall[:, None] if x.ndim == 2 else fall)


def trim(bus, cutoff):
    """Takes what's under `cutoff` Hz out of a bus: a phone plays none of it, and it takes headroom."""
    bus.dry = s.highpass(bus.dry, cutoff, order=2)
    bus.send = s.highpass(bus.send, cutoff, order=2)


def cut(x, seconds):
    """`x` stopped after `seconds`, with a short fade."""
    out = x[: max(0, int(round(seconds * s.SR)))].copy()
    fade = min(len(out), int(0.03 * s.SR))
    out[len(out) - fade :] *= np.linspace(1, 0, fade)[:, None] if out.ndim == 2 else np.linspace(1, 0, fade)
    return out


# Each chord: the bass's root; the pad's voicing, moving by step from chord to chord and keeping the
# colour notes: F sharp minor's ninth and the major sevenths and ninths of D and A, E's sixth, B minor's
# ninth, D's sharp eleventh, and C sharp's suspended fourth letting down to E sharp, the leading note;
# and the pluck's four notes, climbing.
VOICINGS = {
    "F#m9": (42, [57, 61, 64, 68], [66, 69, 73, 76]),
    "Dmaj9": (38, [57, 61, 64, 66], [62, 66, 69, 76]),
    "Amaj9": (45, [56, 61, 64, 71], [61, 64, 68, 71]),
    "E6": (40, [56, 59, 61, 64], [64, 68, 71, 73]),
    "Bm9": (47, [57, 61, 62, 66], [62, 66, 69, 73]),
    "C#m7": (49, [56, 59, 61, 64], [61, 64, 68, 71]),
    "Dmaj7#11": (38, [56, 61, 62, 66], [62, 66, 68, 73]),
    "C#7sus4": (49, [54, 56, 59, 61], [61, 66, 68, 71]),
    "C#7": (49, [53, 56, 59, 61], [61, 65, 68, 71]),
}
CHORDS = sheet["chords"]


def chord(beat):
    return VOICINGS[[name for name, first, _ in CHORDS if first <= beat][-1]]


# The riff and its answer, [beat, note, beats] from where each starts; the rising line through the build;
# and the closing phrase, through E sharp to F sharp on the last hit.
RIFF = [(0, 78, 0.5), (0.5, 81, 0.5), (1, 85, 1.0), (2, 83, 0.5), (2.5, 81, 0.5), (3, 76, 1.0),
        (4, 78, 0.5), (4.5, 81, 0.5), (5, 83, 1.0), (6, 81, 0.5), (6.5, 78, 0.5), (7, 73, 1.0)]
ANSWER = [(0, 76, 0.5), (0.5, 80, 0.5), (1, 83, 1.0), (2, 81, 0.5), (2.5, 80, 0.5), (3, 76, 1.0),
          (4, 76, 0.5), (4.5, 78, 0.5), (5, 80, 1.0), (6, 83, 2.0)]
RISE = [(0, 73, 2), (2, 76, 2), (4, 78, 2), (6, 80, 2), (8, 81, 2), (10, 83, 2)]
CLOSE = [(0, 78, 0.5), (0.5, 81, 0.5), (1, 85, 1.0), (2, 83, 0.5), (2.5, 81, 0.5), (3, 77, 1.0), (4, 78, 4.0)]


def placed(start, phrase):
    return [(start + beat, note, beats) for beat, note, beats in phrase]


TUNE = placed(FIRST, RIFF) + placed(PAIRS, ANSWER) + placed(EVERY, RIFF) + placed(HALVES, RISE) + placed(DROP, RIFF)
TUNE += placed(END, CLOSE)

# How fully the arrangement plays from each cue: held back under the hook, growing with each quickening,
# full on the drop, easing a little for the end line.
SWELL = [(0, 0.55), (FIRST, 0.7), (PAIRS, 0.8), (EVERY, 0.8), (HALVES, 0.86), (32, 0.93), (36, 1.0), (DROP, 1.25), (END_LINE, 1.1), (END, 1.15), (LAST, 1.0)]


def swell(beat):
    return [level for first, level in SWELL if first <= beat][-1]


# The pluck's notes for each sixteenth of a half bar: three steps up from the lowest, from the next and
# from the next again.
CLIMB = (0, 1, 2, 1, 2, 3, 2, 3)


def score():
    s.reset(112)
    length = LENGTH + 4
    room = s.reverb(2.2, 0.5, 0.02)
    drums, low, pads, arps, lead, shutters, fx = (s.Bus(length) for _ in range(7))
    kicks = []

    # The first frame lands as a deep hit under the hook, with the pad swelling in.
    drums.add(at(0), s.deep_kick(0.85), gain=0.6, wet=0.12)
    fx.add(at(0), s.boom(1.6, 0.7), gain=0.2, wet=0.3)

    # The pad on each chord, a supersaw opening through the build; the last chord rings out.
    for name, first, beats in CHORDS:
        _, voicing, _ = VOICINGS[name]
        final = first == LAST
        cutoff = 4600 if first >= DROP else opening(first, 0, STOP, 1500, 3800)
        seconds = (BEATS - LAST) * BEAT if final else beats * BEAT
        pad = s.supersaw(voicing, seconds, voices=7, spread=18, cutoff=cutoff, attack=0.7 if first == 0 else 0.03,
                         release=1.8 if final else 0.2)
        if final:
            pad = dying(pad, 3.5)
        pads.add(at(first), pad, gain=0.11 * swell(first), wet=0.4)

    # The pluck in sixteenths, climbing each half bar; dark and quiet under the hook, brightening as the
    # cuts quicken, doubled an octave up from the drop, with an echo a dotted eighth later.
    for i, beat in enumerate(playing(0, LAST, 0.25)):
        notes = chord(beat)[2]
        note = notes[CLIMB[round(beat * 4) % 8]]
        bright = 0.12 + 0.2 * beat / FIRST if beat < FIRST else opening(beat, FIRST, STOP, 0.35, 0.85) if beat < DROP else 0.85
        tone = s.pluck(note, 0.8, 0.16, bright=bright)
        level = 0.16 * swell(beat) * (0.5 + 0.5 * min(1, beat / FIRST))
        arps.add(at(beat), tone, gain=level, pan_to=(-0.3, 0.3)[i % 2], wet=0.25)
        arps.add(at(beat + 0.75), s.lowpass(tone, 2200), gain=level * 0.35, pan_to=(0.4, -0.4)[i % 2], wet=0.45)
        if beat >= DROP:
            arps.add(at(beat), s.pluck(note + 12, 0.6, 0.14, bright=0.6), gain=level * 0.4, pan_to=(0.35, -0.35)[i % 2], wet=0.3)

    # The bass holds its root under the hook, then plays octaves in eighths from the first look; the last
    # root rings out.
    held = s.bass(42, 0.8, at(FIRST) - 0.05, bright=0.15)
    low.add(at(0), held * np.clip(np.arange(len(held)) / s.SR / 0.6, 0, 1), gain=0.3, wet=0.05)
    for beat in playing(FIRST, LAST, 0.5):
        root = chord(beat)[0]
        octave = 12 if round(beat * 2) % 2 else 0
        bright = opening(beat, FIRST, STOP, 0.3, 0.65) if beat < DROP else 0.75
        low.add(at(beat), s.bass(root + octave, 0.9 if not octave else 0.7, 0.2, bright=bright), gain=0.24 * swell(beat), wet=0.04)
    low.add(at(LAST), dying(s.bass(54, 0.9, 3.5, bright=0.35), 1.4), gain=0.32, wet=0.15)

    # The beat: a kick through a wall under the hook; a kick on 1 and 3 with a push on the and of 4 from the
    # first look; four on the floor from the looks every beat; a gated snare on 2 and 4 from the looks every
    # two beats; hats in eighths from then, a tambourine in sixteenths from the looks every beat, and a
    # snare roll doubling into the stop.
    for beat in range(1, FIRST):
        drums.add(at(beat), s.lowpass(s.kick(0.9), 220), gain=0.45, wet=0.02)
        kicks.append(at(beat))
    for beat in playing(FIRST, LAST, 0.5):
        if beat < EVERY and beat % 4 not in (0, 2, 3.5) or beat >= EVERY and beat % 1:
            continue
        drums.add(at(beat), s.kick(0.95, length=0.32, click=0.7), gain=0.55 * swell(beat) ** 0.5, wet=0.03)
        kicks.append(at(beat))
    for beat in playing(PAIRS, LAST, 1):
        if beat % 2 == 1 and not 36 <= beat < DROP:
            drums.add(at(beat), s.gated_snare(0.85, tone=190, gate=0.22), gain=0.3 * swell(beat) ** 0.5, pan_to=0.05, wet=0.3)
    for beat in playing(PAIRS, LAST, 0.5):
        drums.add(at(beat), s.hat(0.8 if beat % 1 else 0.45), gain=0.07 * swell(beat), pan_to=0.3, wet=0.05)
    for beat in playing(EVERY, LAST, 0.25):
        drums.add(at(beat), s.tambourine((0.45, 0.3, 0.9, 0.3)[round(beat * 4) % 4]), gain=0.09 * swell(beat), pan_to=-0.3, wet=0.15)
    for first, last, step in ((32, 36, 0.5), (36, 38, 0.25), (38, STOP, 0.125)):
        for beat in np.arange(first, last - 1e-9, step):
            p = (beat - 32) / (STOP - 32)
            drums.add(at(beat), s.snare(0.3 + 0.6 * p, tone=180 + 90 * p, length=0.14), gain=0.15, pan_to=-0.2 + 0.4 * p, wet=0.25)

    # A camera's shutter on every look, a little harder as the cuts quicken.
    for i, beat in enumerate(LOOKS):
        p = i / (len(LOOKS) - 1)
        shutters.add(at(beat), s.shutter(0.75 + 0.25 * p), gain=0.3 - 0.1 * p, pan_to=(-0.12, 0.12)[i % 2], wet=0.12)

    # The riff on the ringing lead, with an echo a dotted eighth later that stops before the drop and the
    # last hit; doubled an octave up on the drop.
    for beat, note, beats in TUNE:
        final = beat >= LAST
        tone = s.chime_lead(note, beats * BEAT * 0.94, 0.9, cutoff=3600 if beat >= DROP else 3000, vibrato=0.12 if beats >= 1 else 0.0)
        if final:
            tone = dying(tone, 1.6)
        level = 0.42 * swell(beat) ** 0.5
        lead.add(at(beat), tone, gain=level, wet=0.3)
        stop = DROP if beat < DROP else LAST if beat < LAST else BEATS
        echo = cut(s.lowpass(tone.mean(axis=1), 1800), (stop - beat - 0.75) * BEAT)
        lead.add(at(beat + 0.75), echo, gain=level * 0.3, pan_to=-0.45, wet=0.5)
        if DROP <= beat < END or END <= beat < LAST:
            lead.add(at(beat), s.chime_lead(note + 12, beats * BEAT * 0.9, 0.55, cutoff=4200), gain=level * 0.32, wet=0.4)

    # The build: a riser, and the drop's own chord in the room swelling up into it through the stop.
    hit = s.supersaw([n + 12 for n in VOICINGS["F#m9"][1]], 1.4, cutoff=5200, attack=0.01, release=0.6)
    fx.add(at(HALVES), s.riser(at(DROP) - at(HALVES), 300, 7500, curve=2.2), gain=0.05, wet=0.35)
    fx.add(at(STOP), s.swell_into(hit, at(DROP) - at(STOP), room), gain=0.2, wet=0.0)

    # The drop: a deep kick, the chord struck and a crash, and air rising as the picture pulls back; the
    # icons coming up across the sheet, from the corner the camera left, ring glass up the chord.
    drums.add(at(DROP), s.deep_kick(1.0), gain=0.5, wet=0.08)
    kicks.append(at(DROP))
    fx.add(at(DROP), s.boom(2.2, 1.0), gain=0.22, wet=0.3)
    pads.add(at(DROP), hit, gain=0.16, wet=0.3)
    drums.add(at(DROP), s.lowpass(s.crash(0.9, 3.0, decay=1.3), 6500), gain=0.2, wet=0.35)
    fx.add(at(DROP), s.whoosh(at(cue["sheet"]) - at(DROP), 300, 2200), gain=0.12, pan_to=-0.1, wet=0.3)
    run = [66, 69, 73, 76, 78, 81, 85, 88, 90, 93, 97]
    for i, note in enumerate(run):
        fx.add(at(DROP + 1) + i * 1.5 / sheet["fps"], s.glass(note, 1.4, 0.5), gain=0.05, pan_to=0.4 - 0.08 * i, wet=0.5)

    # The end line on Dmaj9, and the last hit under the end card: a deep kick, a crash, the last chord
    # ringing, and the pluck's last chord rising after it into the room.
    drums.add(at(END_LINE), s.lowpass(s.crash(0.6, 2.0, decay=0.9), 6000), gain=0.1, wet=0.35)
    drums.add(at(END), s.lowpass(s.crash(0.8, 2.6, decay=1.1), 6500), gain=0.15, wet=0.35)
    drums.add(at(LAST), s.deep_kick(1.0), gain=0.5, wet=0.1)
    kicks.append(at(LAST))
    fx.add(at(LAST), s.boom(2.4, 0.9), gain=0.18, wet=0.3)
    drums.add(at(LAST), s.lowpass(s.crash(0.8, 3.0, decay=1.4), 6000), gain=0.16, wet=0.4)
    for i, (note, p) in enumerate(zip(VOICINGS["F#m9"][2], (-0.3, -0.1, 0.1, 0.3))):
        arps.add(at(LAST + i / 4), s.pluck(note + 12, 0.7, 0.3, bright=0.5), gain=0.11, pan_to=p, wet=0.55)

    pump = s.sidechain(length, kicks, depth=0.5, release=0.18)
    low.duck(1 - 0.5 * (1 - pump))
    pads.duck(1 - 0.4 * (1 - pump))
    arps.duck(1 - 0.2 * (1 - pump))
    trim(drums, 50)
    trim(low, 70)
    trim(fx, 60)
    trim(shutters, 120)
    return [drums, low, pads, arps, lead, shutters, fx], room


def main():
    buses, room = score()
    mix = s.master(buses, seconds=LENGTH, target=-14.0, ceiling=-1.4, room=room, wet=0.55, presence=3.0, fade=at(BEATS) - at(FADE))
    out = ROOT / "public/films"
    out.mkdir(parents=True, exist_ok=True)
    s.write(out / "score.wav", mix)
    fps = sheet["fps"]
    per = s.SR // fps
    frames = len(mix) // per
    rms = np.sqrt((mix[: frames * per] ** 2).mean(axis=1).reshape(frames, per).mean(axis=1))
    (out / "score.json").write_text(json.dumps({"fps": fps, "level": [round(float(x), 4) for x in rms / rms.max()]}))
    print(f"==> public/films/score.wav ({LENGTH:.1f} s, {s.loudness(mix):.1f} LUFS, true peak {s.true_peak(mix):.1f} dBFS)")


if __name__ == "__main__":
    main()
