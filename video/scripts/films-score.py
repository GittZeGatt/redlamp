#!/usr/bin/env python3
"""
The film looks reel's score: a dark, driving synth track in E minor at 112.5 BPM, 14 bars and 29.9 seconds
on the reel's cue sheet, src/films/cues.json, whose build drives the cuts: a look a bar, then every two
beats, every beat and every half beat, a camera's shutter firing on each, until the shutters run like a
motor drive into the stop; the drop lands heavily on the pull back to the contact sheet.

The owner asked for it darker, grittier and more energetic than the first cut's F sharp minor synthwave
(11 October 2026). So the harmony turns on E minor's darkest neighbours: Em, C, then F, the Neapolitan
a semitone above the tonic, and B7 with a flat ninth, a bar each; Em and C again; then through the build
the bass climbs a semitone every two beats, F, F sharp, G, G sharp and A (F, F#m7b5, G, E/G# and Am), to
Bsus4 letting down to B7b9 into the drop on Em; on the end line C, Am and B7b9, then Em, F and B7b9, and
Em on the last hit. The riff, on a driven saw lead in the middle of the range, grinds the flat second
against the tonic: E, G and F held, then E, D and down to B; E, G and A, then G, F and E. The answer goes
over F and B7b9 to the tritone and the flat ninth, and through the build a line rises a semitone every two
beats from F to B, held through the stop; the drop brings the riff back doubled an octave down.

What makes it gritty: a bass of detuned saws driven into a soft clip and crushed a little (`grit_bass`),
in eighths from the first look and sixteenths from the looks every beat; a punchy kick whose body is
driven (`punch_kick`); a snare with noise in its wires, driven and crushed (`grit_snare`); hats in eighths,
then sixteenths, then sixteenths with open hats on the off-beats as the cuts quicken; a driven supersaw
pad held low in the range for weight in the low mids, and a pluck in sixteenths kept dark. The build
screws a Shepard tone tighter under a riser and a snare roll doubling into the stop, where the rhythm stops
and a breath is drawn in while the drop's chord swells up through it; the drop is a trailer's low brass,
a deep kick, the punch kick and a dark crash, with air rising as the picture pulls back.

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


# Each chord: the bass's root, climbing a semitone at a time through the build; and the pad's voicing,
# held between E3 and F4 for weight in the low mids, its voices moving by step: the Neapolitan F's A
# against the tonic's G, B7's flat ninth (C) and its D sharp, the half-diminished F sharp's C.
VOICINGS = {
    "Em": (40, [52, 55, 59, 64]),
    "C": (36, [52, 55, 60, 64]),
    "F": (41, [53, 57, 60, 65]),
    "B7b9": (47, [51, 54, 57, 60]),
    "F#m7b5": (42, [52, 54, 57, 60]),
    "G": (43, [50, 55, 59, 62]),
    "E/G#": (44, [52, 56, 59, 64]),
    "Am": (45, [52, 57, 60, 64]),
    "Bsus4": (47, [52, 54, 59, 64]),
}
CHORDS = sheet["chords"]


def chord(beat):
    return VOICINGS[[name for name, first, _ in CHORDS if first <= beat][-1]]


# The riff and its answer, [beat, note, beats] from where each starts; the line rising through the build;
# and the closing phrase, through D sharp to E on the last hit.
RIFF = [(0, 64, 0.5), (0.5, 67, 0.5), (1, 65, 1.0), (2, 64, 0.5), (2.5, 62, 0.5), (3, 59, 1.0),
        (4, 64, 0.5), (4.5, 67, 0.5), (5, 69, 1.0), (6, 67, 0.5), (6.5, 65, 0.5), (7, 64, 1.0)]
ANSWER = [(0, 65, 0.5), (0.5, 69, 0.5), (1, 72, 1.0), (2, 71, 0.5), (2.5, 69, 0.5), (3, 65, 1.0),
          (4, 63, 0.5), (4.5, 66, 0.5), (5, 69, 1.0), (6, 72, 1.0), (7, 71, 1.0)]
RISE = [(0, 65, 2), (2, 66, 2), (4, 67, 2), (6, 68, 2), (8, 69, 2), (10, 71, 2)]
CLOSE = [(0, 64, 0.5), (0.5, 67, 0.5), (1, 65, 1.0), (2, 64, 0.5), (2.5, 62, 0.5), (3, 63, 1.0), (4, 64, 4.0)]


def placed(start, phrase):
    return [(start + beat, note, beats) for beat, note, beats in phrase]


TUNE = (placed(FIRST, RIFF) + placed(PAIRS, ANSWER) + placed(EVERY, RIFF) + placed(HALVES, RISE) + placed(DROP, RIFF)
        + placed(END, CLOSE))

# How fully the arrangement plays from each cue: held back under the hook, growing with each quickening of
# the cuts, full on the drop and as the end card arrives.
SWELL = [(0, 0.7), (FIRST, 0.8), (PAIRS, 0.84), (EVERY, 0.86), (HALVES, 0.88), (32, 0.92), (36, 1.0), (DROP, 1.25),
         (END_LINE, 1.1), (END, 1.15), (LAST, 1.0)]


def swell(beat):
    return [level for first, level in SWELL if first <= beat][-1]


# The pluck's notes for each sixteenth of a half bar: three steps up from the lowest, from the next and
# from the next again.
CLIMB = (0, 1, 2, 1, 2, 3, 2, 3)


def score():
    s.reset(112)
    length = LENGTH + 4
    room = s.reverb(1.8, 0.4, 0.015)
    drums, low, pads, arps, lead, shutters, fx = (s.Bus(length) for _ in range(7))
    kicks = []

    # The first frame lands as a deep hit under the hook, the driven bass holding E through a closed
    # filter and a low drone swelling in.
    drums.add(at(0), s.deep_kick(0.9), gain=0.55, wet=0.1)
    drums.add(at(0), s.punch_kick(0.9), gain=0.35, wet=0.05)
    kicks.append(0.0)
    fx.add(at(0), s.boom(1.6, 0.8), gain=0.18, wet=0.25)
    held = s.lowpass(s.grit_bass(40, 0.9, at(FIRST) - 0.05, bright=0.2, grit=0.8), 700)
    low.add(at(0), held * np.clip(np.arange(len(held)) / s.SR / 0.8, 0, 1), gain=0.5, wet=0.05)
    pads.add(at(0), s.drone([40, 47, 52], at(FIRST), cutoff=600, release=0.6, attack=1.2), gain=0.26, wet=0.3)

    # The pad on each chord: a supersaw low in the range, driven a little, opening through the build; the
    # last chord rings out.
    for name, first, beats in CHORDS:
        _, voicing = VOICINGS[name]
        final = first == LAST
        cutoff = 2600 if first >= DROP else opening(first, 0, STOP, 900, 2200)
        seconds = (BEATS - LAST) * BEAT if final else beats * BEAT
        pad = s.supersaw(voicing, seconds, voices=7, spread=16, cutoff=cutoff, attack=0.9 if first == 0 else 0.02,
                         release=1.8 if final else 0.15)
        pad = s.drive(pad, 1.8, tone=3200)
        if final:
            pad = dying(pad, 3.0)
        pads.add(at(first), pad, gain=0.15 * swell(first), wet=0.3)

    # The pluck in sixteenths, climbing each half bar an octave above the pad, kept dark: muffled under the
    # hook and opening only a little as the cuts quicken.
    for i, beat in enumerate(playing(0, LAST, 0.25)):
        note = chord(beat)[1][CLIMB[round(beat * 4) % 8]] + 12
        bright = 0.1 + 0.12 * beat / FIRST if beat < FIRST else opening(beat, FIRST, STOP, 0.25, 0.5) if beat < DROP else 0.5
        tone = s.lowpass(s.pluck(note, 0.85, 0.14, bright=bright), 2600)
        level = 0.1 * swell(beat) * (0.5 + 0.5 * min(1, beat / FIRST))
        arps.add(at(beat), tone, gain=level, pan_to=(-0.3, 0.3)[i % 2], wet=0.2)

    # The driven bass: octaves in eighths from the first look, sixteenths from the looks every beat, the
    # grit rising with the build; the last root rings out.
    for beat in playing(FIRST, LAST, 0.25):
        sixteenth = round(beat * 4) % 2
        if sixteenth and (beat < EVERY or beat >= END):
            continue
        root = chord(beat)[0]
        octave = 12 if round(beat * 4) % 4 == 2 else 0
        grit = opening(beat, FIRST, STOP, 0.5, 1.0) if beat < DROP else 1.0
        bright = opening(beat, FIRST, STOP, 0.35, 0.7) if beat < DROP else 0.75
        velocity = (0.95, 0.6, 0.8, 0.6)[round(beat * 4) % 4]
        low.add(at(beat), s.grit_bass(root + octave, velocity, 0.13 if sixteenth else 0.2, bright=bright, grit=grit),
                gain=0.34 * swell(beat), wet=0.02)
    low.add(at(LAST), dying(s.grit_bass(52, 0.9, 3.5, bright=0.3, grit=0.7), 1.4), gain=0.32, wet=0.12)

    # The beat: a kick through a wall under the hook; the punch kick on 1 and 3 with a push on the and of 4
    # from the first look, four on the floor from the looks every beat, with a pickup on the last sixteenth
    # of each bar through the run of half beats; the gritty snare on 2 and 4 from the looks every two beats;
    # hats on the off-beats from the first look, in eighths from the looks every two beats, sixteenths from the looks every beat, and open hats on the off-beats from
    # the run of half beats; a snare roll doubling into the stop.
    for beat in range(1, FIRST):
        drums.add(at(beat), s.lowpass(s.punch_kick(0.9), 260), gain=0.45, wet=0.02)
        kicks.append(at(beat))
    for beat in playing(FIRST, LAST, 0.25):
        on = beat % 1 == 0 and (beat >= EVERY or beat % 4 in (0, 2)) or beat < EVERY and beat % 4 == 3.5
        pickup = HALVES <= beat < STOP and beat % 4 == 3.75
        if on or pickup:
            drums.add(at(beat), s.punch_kick(0.95 if on else 0.6), gain=0.6 * swell(beat) ** 0.5, wet=0.02)
            kicks.append(at(beat))
    for beat in playing(PAIRS, LAST, 1):
        if beat % 2 == 1 and not 36 <= beat < DROP:
            drums.add(at(beat), s.grit_snare(0.9, tone=195, grit=0.6 + 0.4 * min(1, beat / DROP)),
                      gain=0.36 * swell(beat) ** 0.5, pan_to=0.05, wet=0.18)
    for beat in playing(FIRST, LAST, 0.25):
        sixteenth = round(beat * 4) % 2
        if sixteenth and beat < EVERY or beat < PAIRS and round(beat * 4) % 4 != 2:
            continue
        offbeat = round(beat * 4) % 4 == 2
        opened = offbeat and HALVES <= beat
        velocity = (0.85 if opened else 0.7) if offbeat else (0.45 if not sixteenth else 0.35)
        drums.add(at(beat), s.lowpass(s.drive(s.hat(velocity, open=opened), 1.5), 9000), gain=0.04 * swell(beat), pan_to=0.3 - 0.6 * sixteenth,
                  wet=0.04)
    for first, last, step in ((32, 36, 0.5), (36, 38, 0.25), (38, STOP, 0.125)):
        for beat in np.arange(first, last - 1e-9, step):
            p = (beat - 32) / (STOP - 32)
            drums.add(at(beat), s.grit_snare(0.3 + 0.6 * p, tone=180 + 80 * p, length=0.12, grit=0.5 + 0.5 * p),
                      gain=0.17, pan_to=-0.2 + 0.4 * p, wet=0.18)

    # A camera's shutter on every look, a little harder as the cuts quicken.
    for i, beat in enumerate(LOOKS):
        p = i / (len(LOOKS) - 1)
        shutters.add(at(beat), s.shutter(0.75 + 0.25 * p), gain=0.26 - 0.1 * p, pan_to=(-0.12, 0.12)[i % 2], wet=0.1)

    # The riff on a driven saw lead, with an echo a dotted eighth later that stops before the drop and the
    # last hit; from the drop doubled an octave down.
    for beat, note, beats in TUNE:
        final = beat >= LAST
        tone = s.saw_lead(note, beats * BEAT * 0.92, 0.9, cutoff=2600 if beat >= DROP else 2100, detune=9,
                          vibrato=0.1 if beats >= 1 else 0.0)
        tone = s.drive(tone, 2.5, tone=4200, asym=0.1)
        if final:
            tone = dying(tone, 1.6)
        level = 0.38 * swell(beat) ** 0.5
        lead.add(at(beat), tone, gain=level, wet=0.22)
        stop = DROP if beat < DROP else LAST if beat < LAST else BEATS
        echo = cut(s.lowpass(tone.mean(axis=1), 1500), (stop - beat - 0.75) * BEAT)
        lead.add(at(beat + 0.75), echo, gain=level * 0.25, pan_to=-0.45, wet=0.4)
        if DROP <= beat < LAST:
            low_tone = s.drive(s.saw_lead(note - 12, beats * BEAT * 0.9, 0.8, cutoff=1600, detune=11), 3.0, tone=3000)
            lead.add(at(beat), low_tone, gain=level * 0.5, wet=0.15)

    # The build: a Shepard tone screwing tighter under a riser, then the stop: a breath drawn in, and the
    # drop's chord swelling up into it.
    span = int(round((at(STOP) - at(HALVES)) * s.SR))
    p = np.arange(span) / span
    fx.add(at(HALVES), s.shepard(0.15 + 1.4 * p**2, 0.25 + 0.75 * p), gain=0.1, wet=0.3)
    fx.add(at(HALVES), s.riser(at(DROP) - at(HALVES), 200, 5000, curve=2.4), gain=0.06, wet=0.3)
    fx.add(at(STOP), s.inhale(at(DROP) - at(STOP)), gain=0.12, wet=0.1)
    hit = s.drive(s.supersaw([n - 12 for n in VOICINGS["Em"][1]] + VOICINGS["Em"][1], 1.6, cutoff=2400, attack=0.01,
                             release=0.6), 2.0)
    fx.add(at(STOP), s.swell_into(hit, at(DROP) - at(STOP), room), gain=0.22, wet=0.0)

    # The drop: a trailer's low brass on E, a deep kick and the punch kick, the chord struck, a dark crash,
    # and air rising as the picture pulls back; the icons coming up across the sheet tick in a muffled run
    # up the chord.
    low.add(at(DROP), s.braam([40, 47, 52], 2.6, 1.0), gain=0.36, wet=0.25)
    drums.add(at(DROP), s.deep_kick(1.0), gain=0.5, wet=0.06)
    drums.add(at(DROP), s.punch_kick(1.0), gain=0.5, wet=0.03)
    kicks.append(at(DROP))
    fx.add(at(DROP), s.boom(2.2, 1.0), gain=0.2, wet=0.25)
    pads.add(at(DROP), hit, gain=0.16, wet=0.25)
    drums.add(at(DROP), s.lowpass(s.crash(0.9, 2.6, decay=1.1), 4500), gain=0.2, wet=0.3)
    fx.add(at(DROP), s.whoosh(at(cue["sheet"]) - at(DROP), 250, 1800), gain=0.12, pan_to=-0.1, wet=0.25)
    run = [52, 55, 59, 64, 67, 71, 76, 79, 83, 88, 91]
    for i, note in enumerate(run):
        tone = s.lowpass(s.pluck(note, 0.6, 0.12, bright=0.4), 2400)
        fx.add(at(DROP + 1) + i * 1.5 / sheet["fps"], tone, gain=0.07, pan_to=0.4 - 0.08 * i, wet=0.3)

    # The end line and the end card each on a dark crash; the last hit under the end card: the low brass,
    # a deep kick, a boom and a crash, the last chord ringing and the pluck's last chord rising after it.
    drums.add(at(END_LINE), s.lowpass(s.crash(0.6, 2.0, decay=0.9), 4500), gain=0.1, wet=0.3)
    drums.add(at(END), s.lowpass(s.crash(0.8, 2.4, decay=1.0), 4500), gain=0.14, wet=0.3)
    low.add(at(LAST), dying(s.braam([40, 47, 52], 3.4, 0.9), 1.6), gain=0.3, wet=0.3)
    drums.add(at(LAST), s.deep_kick(1.0), gain=0.5, wet=0.08)
    drums.add(at(LAST), s.punch_kick(0.9), gain=0.35, wet=0.03)
    kicks.append(at(LAST))
    fx.add(at(LAST), s.boom(2.4, 0.9), gain=0.18, wet=0.25)
    drums.add(at(LAST), s.lowpass(s.crash(0.8, 3.0, decay=1.4), 4500), gain=0.15, wet=0.35)
    for i, (note, pan) in enumerate(zip(VOICINGS["Em"][1], (-0.3, -0.1, 0.1, 0.3))):
        arps.add(at(LAST + i / 4), s.lowpass(s.pluck(note + 12, 0.7, 0.3, bright=0.4), 2600), gain=0.1, pan_to=pan, wet=0.45)

    pump = s.sidechain(length, kicks, depth=0.55, release=0.16)
    low.duck(1 - 0.45 * (1 - pump))
    pads.duck(1 - 0.45 * (1 - pump))
    arps.duck(1 - 0.25 * (1 - pump))
    trim(drums, 50)
    trim(low, 60)
    trim(pads, 90)
    trim(fx, 60)
    trim(shutters, 120)
    return [drums, low, pads, arps, lead, shutters, fx], room


def main():
    buses, room = score()
    mix = s.master(buses, seconds=LENGTH, target=-14.0, ceiling=-1.4, room=room, wet=0.45, presence=1.0, fade=at(BEATS) - at(FADE))
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
