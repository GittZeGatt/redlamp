"""
E11's track (Command palette): a dark, driving synth track in G minor at 100 BPM, 8 bars and 19.2 seconds
on the series' cue sheet, src/features/cues.json, which scripts/features-score.py plays under the episode
with its own sounds. The opener's held D major chord is G minor's dominant, so the lead-in is the dominant
waiting to resolve: a crushed pluck on D and A, over a drone on D and A, and on the first hit the bass
comes in on G under them and the pads bring in B flat.

The owner found the first track, in G minor's bright Dorian colour on a hard-sync lead and a ticking step
sequencer, horrid, and asked for it darker, grittier and more energetic, as the film looks reel's is
(11 October 2026). So the harmony is G minor's darkest: Gm9 under the hook, then the bass falls G, E flat,
C and F under Ebmaj7#11, Cm9 and Fm9, every chord rubbing a semitone inside it (A against B flat, D
against E flat, G against A flat), and through the build Abmaj7#11, the Neapolitan a semitone above the
tonic, leaps a tritone to D7(b9) into the drop on Gm(add9); on the end line Abmaj7#11 to D7(b9) again,
and Gm(add9) on the last hit. The pads sit between E flat 3 and E flat 4, for weight in the low mids. The
riff, on a driven saw lead in the low middle, is two bars: G, B flat flicked up and back to G, down through
F and D to E flat and D; then G, B flat and up to C, and down through B flat, G and F to E flat. The answer
plays the first bar again over Fm9 and turns over the Neapolitan, G, A flat, C and back, then down to A and
F sharp, held through the stop, which rises to G on the drop; the head is the riff's first bar; the
closing phrase is the head over A flat, then F sharp and A over D7(b9), and G on the last hit.

What makes it gritty, with the voices the film looks reel brought into synth.py: everything with a pitch
goes through a waveshaper (`drive`), and the bass and the pluck through a bit crusher too (`crush`). The bass is two detuned saws, driven and crushed, in sixteenths
from the first frame, accented in 3 + 3 + 2 with the octave on the last accent, muffled under the hook and
opening through the build; a punchy kick whose body is driven (`punch_kick`), muffled as if through a
wall under the hook, in half time with a snare on 3 through the first two steps, and four on the floor
with the snare on 2 and 4 and ghost notes from the third; a snare with noise in its wires, driven and
crushed (`grit_snare`); driven hats with their top taken off, in eighths, then sixteenths from the second
step, and open hats on the offbeats from the third; a driven supersaw pad held low; a crushed pluck in
sixteenths through the chord; a gritty snare roll doubling into the stop. On the drop the punch kick,
the deep kick and a trailer's low brass on G land together, with the chord struck and a dark crash, then
the chord in driven stabs on the and of 2 and 4. On the drop the series' sting, glass struck on G, D and A.
"""

import importlib.util
from pathlib import Path

import numpy as np

import synth as s


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


theme = load(Path(__file__).resolve().parents[2] / "features-theme.py", "features_theme")
at, swell, opening, cue = theme.at, theme.swell, theme.opening, theme.cue
S1, S2, S3, S4, DROP, STOP, LAST = theme.S1, theme.S2, theme.S3, theme.S4, theme.DROP, theme.STOP, theme.LAST

# The chords as the cue sheet lists E01's: a name, its first beat and how many beats it lasts.
CHORDS = [("Gm9", 0, 4), ("Ebmaj7#11", 4, 4), ("Cm9", 8, 4), ("Fm9", 12, 4), ("Abmaj7#11", 16, 2), ("D7(b9)", 18, 2),
          ("Gm(add9)", 20, 4), ("Abmaj7#11", 24, 2), ("D7(b9)", 26, 2), ("Gm(add9)", 28, 4)]

# Each chord: the bass's root; the pads' voicing, rootless and low, its voices moving by step and each
# with a semitone rubbing inside it; and the pluck's four notes an octave above.
VOICINGS = {
    "Gm9": (43, [53, 57, 58, 62]),
    "Ebmaj7#11": (39, [55, 57, 58, 62]),
    "Cm9": (48, [55, 58, 62, 63]),
    "Fm9": (41, [55, 56, 60, 63]),
    "Abmaj7#11": (44, [55, 60, 62, 63]),
    "D7(b9)": (50, [54, 57, 60, 63]),
    "Gm(add9)": (43, [55, 57, 58, 62]),
}


def chord(beat):
    root, voicing = VOICINGS[theme.chord_at(beat, CHORDS)]
    return root, voicing, [n + 12 for n in voicing]


# The riff, [beat, note, beats] from where it starts: G, B flat flicked up and back to G, F, D, E flat and
# D; then G, B flat, C, B flat, G, F and E flat. The answer turns over the Neapolitan and holds F sharp
# through the stop; the head is the first bar; the closing phrase ends on G on the last hit.
MOTIF = [(0, 67, 0.5), (0.5, 70, 0.25), (0.75, 67, 0.75), (1.5, 65, 0.5), (2, 62, 0.75), (2.75, 63, 0.75), (3.5, 62, 0.5),
         (4, 67, 0.5), (4.5, 70, 0.25), (4.75, 72, 0.75), (5.5, 70, 0.5), (6, 67, 0.75), (6.75, 65, 0.75), (7.5, 63, 0.5)]
ANSWER = MOTIF[:7] + [(4, 67, 0.5), (4.5, 68, 0.25), (4.75, 72, 0.75), (5.5, 68, 0.5), (6, 69, 0.5), (6.5, 66, 1.5)]
HEAD = MOTIF[:7]
CLOSE = [(0, 67, 0.5), (0.5, 68, 0.25), (0.75, 67, 0.75), (1.5, 63, 0.5), (2, 66, 0.75), (2.75, 69, 0.75), (3.5, 66, 0.5),
         (4, 67, 4.0)]
TUNE = (theme.placed(S1, MOTIF) + theme.placed(S3, ANSWER) + theme.placed(DROP, HEAD)
        + theme.placed(cue["endLine"], CLOSE))

# The pluck's levels for a note and, in the lead-in, its echo, which the lead-in grows to.
ARP, ECHO = 0.12, 0.04


# ---------------------------------------------------------------- grit


def snare(velocity=1.0, tone=195.0, length=0.13, grit=1.0):
    """The gritty snare, its fizz above 8 kHz taken off and cut off within a sixteenth, so the key coming up
    after it is heard."""
    x = s.lowpass(s.grit_snare(velocity, tone=tone, length=length, grit=grit), 8000)
    return x * np.clip((length - s.times(length)) / 0.02, 0, 1)


def bass(note, velocity, bright, grit, length=0.14):
    """The driven bass, with the crusher's aliasing above 5 kHz taken off, so it growls without hissing."""
    return s.lowpass(s.grit_bass(note, velocity, length, bright=bright, grit=grit), 5000)


def dirty_hat(velocity=1.0, open=False):
    """A hat driven and with its top taken off, so it ticks without shimmering."""
    return s.lowpass(s.drive(s.hat(1.0, open=open), 2.0), 8500) * velocity


def grain(note, bright, velocity=0.8):
    """The pluck: dark, half of it crushed to six bits, so its tail breaks up."""
    x = s.pluck(note, velocity, 0.16, bright=bright)
    return s.lowpass(0.5 * x + 0.5 * s.crush(x, 6, 9000), 2800)


def pad(notes, seconds, cutoff, attack=0.06, release=0.25):
    """The pads: a supersaw held low, driven a little."""
    saws = s.supersaw(notes, seconds, voices=5, spread=14, cutoff=cutoff, attack=attack, release=release)
    return s.drive(saws, 1.8, tone=2600)


def stab(notes, seconds=0.2):
    """The pads' chord struck short and driven harder, dying away."""
    saws = s.supersaw(notes, seconds, voices=5, spread=16, cutoff=2400, attack=0.003, release=0.08)
    return theme.dying(s.drive(saws, 3.0, tone=3000), seconds * 0.6)


def cut(x, seconds):
    """`x` stopped after `seconds`, with a short fade."""
    out = x[: max(0, int(round(seconds * s.SR)))].copy()
    fade = min(len(out), int(0.03 * s.SR))
    out[len(out) - fade:] *= np.linspace(1, 0, fade)[:, None] if out.ndim == 2 else np.linspace(1, 0, fade)
    return out


def synthwave(sounds=theme.ui):
    theme.start(211)
    room = s.reverb(1.7, 0.4, 0.015)
    drums, low, pads, arps, lead, fx, bed = (s.Bus(theme.LENGTH) for _ in range(7))
    kicks = []

    # The lead-in, on D and A, the notes the held D major chord and Gm9 share, on the pluck's own crushed
    # voice, over a drone on D and A; on the hit the bass comes in on G and the pads bring in B flat, and
    # the drone gives way to them over the first bar.
    theme.lead_in((arps, drums, bed, fx), kicks, room, [57, 62, 69, 74], [38, 45, 50], ARP * swell(0), ECHO * swell(0),
                  tone=lambda note, grown: grain(note, 0.1 + 0.3 * grown))
    bed.duck(np.interp(np.arange(len(bed.dry)) / s.SR, [at(0), at(S1), at(S1 + 1)], [1.0, 0.7, 0.0]))

    # The first frame lands as a hard hit; the pads swell in low, opening through the build, and the last
    # chord rings out.
    drums.add(at(0), s.deep_kick(0.85), gain=0.55, wet=0.1)
    drums.add(at(0), s.punch_kick(0.9), gain=0.35, wet=0.04)
    fx.add(at(0), s.boom(1.4, 0.7), gain=0.2, wet=0.3)
    for name, first, length in CHORDS:
        _, voicing = VOICINGS[name]
        last = first == LAST
        cutoff = 2400 if first >= DROP else opening(first, 0, S4, 1000, 2000)
        tone = pad(voicing, 2.8 if last else length * theme.BEAT, cutoff, attack=0.5 if first == 0 else 0.06,
                   release=1.6 if last else 0.2)
        pads.add(at(first), theme.dying(tone, 1.3) if last else tone, gain=0.2 * swell(first), wet=0.35)

    # The pluck: sixteenths through the chord an octave above the pads, dark, opening a little through the
    # build; on the last hit its chord rolls up from G and rings.
    for i, beat in enumerate(theme.playing(0, LAST, 0.25)):
        note = chord(beat)[2][(0, 1, 2, 3, 2, 1, 3, 2)[i % 8]]
        bright = 0.4 if beat < S1 else opening(beat, S1, STOP, 0.42, 0.6) if beat < DROP else 0.6
        arps.add(at(beat), grain(note, bright, 0.95 if i % 4 == 0 else 0.75), gain=ARP * swell(beat),
                 pan_to=(-0.3, 0.3)[i % 2], wet=0.2)
    for i, note in enumerate(chord(LAST)[2]):
        ring = theme.dying(s.lowpass(s.pluck(note, 0.8, 2.0, bright=0.35), 2400), 0.8)
        arps.add(at(LAST + i * 0.25), ring, gain=ARP * 0.9, pan_to=-0.3 + 0.2 * i, wet=0.45)

    # The bass in sixteenths from the first frame, accented 3 + 3 + 2 with the octave on the last accent,
    # muffled under the hook and opening and dirtier through the build; the last root dies away.
    for beat in theme.playing(0, LAST, 0.25):
        sixteenth = round(beat * 4) % 8
        root = chord(beat)[0] + (12 if sixteenth == 6 else 0)
        accent = sixteenth in (0, 3, 6)
        if beat < S1:
            bright, grit = 0.06 + 0.06 * beat / S1, 0.5
        elif beat < DROP:
            bright, grit = opening(beat, S1, STOP, 0.22, 0.55), opening(beat, S1, STOP, 0.6, 1.0)
        else:
            bright, grit = 0.6, 1.0
        velocity = 0.95 if accent else 0.55
        low.add(at(beat), bass(root, velocity, bright * (1.0 if accent else 0.7), grit),
                gain=0.42 * swell(beat), wet=0.02)
    low.add(at(LAST), theme.dying(bass(43, 0.9, 0.3, 0.7, length=3.0), 0.9), gain=0.42, wet=0.1)

    # The beat: the punch kick on every beat, muffled as if through a wall, under the hook; half time
    # through the first two steps, a kick on 1 and the and of 3 and the snare on 3; from the third, four
    # on the floor with the snare on 2 and 4 and a ghost note a sixteenth before 4; and from the drop a
    # pickup into every other bar.
    for beat in range(1, S1):
        drums.add(at(beat), s.lowpass(s.punch_kick(0.9), 240), gain=0.5, wet=0.02)
        kicks.append(at(beat))
    for beat in theme.playing(S1, LAST, 0.25):
        b = beat % 4
        if beat < S3:
            on = b in (0, 2.5)
        else:
            on = b % 1 == 0 or (beat >= DROP and b == 3.75 and int(beat // 4) % 2 == 0)
        if on and beat != DROP:
            drums.add(at(beat), s.punch_kick(0.95 if b % 1 == 0 else 0.7), gain=0.6 * swell(beat) ** 0.5, wet=0.02)
            kicks.append(at(beat))
    for beat in theme.playing(S1, LAST, 1):
        b = beat % 4
        if S4 + 2 <= beat < DROP:
            continue
        if beat < S3 and b == 2 or beat >= S3 and b in (1, 3):
            grit = 0.6 if beat < S3 else 0.8 if beat < DROP else 1.0
            drums.add(at(beat), snare(0.9, grit=grit), gain=0.36 * swell(beat) ** 0.5, pan_to=0.05, wet=0.12)
    for beat in [b for b in theme.playing(S3, LAST, 1) if b % 4 == 3 and not S4 + 2 <= b < DROP]:
        drums.add(at(beat - 0.25), snare(0.35, tone=210, length=0.1, grit=0.6), gain=0.2, pan_to=-0.1, wet=0.12)
    # The hats: eighths from the first step, sixteenths from the second, and open hats on the offbeats from
    # the third.
    for beat in theme.playing(S1, LAST, 0.25):
        sixteenth = round(beat * 4) % 4
        if beat < S2 and sixteenth % 2:
            continue
        drums.add(at(beat), dirty_hat((0.5, 0.4, 0.9, 0.45)[sixteenth]), gain=0.09 * swell(beat),
                  pan_to=0.3 if sixteenth % 2 == 0 else 0.15, wet=0.04)
    for beat in theme.playing(S3 + 0.5, LAST, 1):
        drums.add(at(beat), dirty_hat(0.8, open=True), gain=0.055 * swell(beat), pan_to=-0.25, wet=0.1)
    # A gritty snare roll, sixteenths then thirty-seconds, rising into the stop.
    for first, last, step in ((S4 + 2, S4 + 3, 0.25), (S4 + 3, STOP, 0.125)):
        for beat in np.arange(first, last - 1e-9, step):
            p = (beat - S4 - 2) / (STOP - S4 - 2)
            drums.add(at(beat), snare(0.4 + 0.55 * p, tone=180 + 80 * p, length=0.12, grit=0.5 + 0.5 * p),
                      gain=0.24, pan_to=-0.2 + 0.4 * p, wet=0.18)

    # The riff on a driven saw lead, with an echo a dotted eighth later that stops on the drop and the last
    # hit so the F sharp rises to G cleanly; the head on the drop doubled an octave down.
    for beat, note, beats in TUNE:
        last = beat >= LAST
        saws = s.saw_lead(note, beats * theme.BEAT * 0.92, 0.9, cutoff=2400 if beat >= DROP else 2000, detune=9,
                          vibrato=0.12 if beats >= 1 else 0.0)
        tone = s.drive(saws, 2.4, tone=3400, asym=0.1)
        if last:
            tone = theme.dying(tone, 1.0)
        level = 0.5 * swell(beat) ** 0.5
        lead.add(at(beat), tone, gain=level, wet=0.25)
        stop = DROP if beat < DROP else LAST if beat < LAST else theme.BEATS
        echo = cut(s.lowpass(tone, 1600), (stop - beat - 0.75) * theme.BEAT)
        lead.add(at(beat + 0.75), echo, gain=level * 0.25, wet=0.45)
        if DROP <= beat < cue["endLine"]:
            doubled = s.drive(s.saw_lead(note - 12, beats * theme.BEAT * 0.9, 0.8, cutoff=1800, detune=12), 3.0, tone=2600)
            lead.add(at(beat), doubled, gain=level * 0.45, wet=0.2)

    # The build: a riser, and the hit's own reverb swelling up into the drop.
    hit = stab(chord(DROP)[2], 1.2)
    fx.add(at(S4), s.riser(at(DROP) - at(S4), 300, 6000, curve=2.2), gain=0.08, wet=0.35)
    fx.add(at(STOP), s.swell_into(hit, at(DROP) - at(STOP), room), gain=0.22, wet=0.0)

    # The drop lands heavily: the punch kick and the deep kick together, a trailer's low brass on G, the
    # chord struck and a dark crash; then the chord in driven stabs on the and of 2 and 4, a crash on the
    # call to action, and the last hit, with the chord left to die away.
    brass = s.drive(s.braam([31, 43, 50, 55, 58], 2.4, 1.0), 1.6, tone=3000)
    for beat, weight in ((DROP, 1.0), (LAST, 0.85)):
        drums.add(at(beat), s.deep_kick(1.0), gain=0.6, wet=0.08)
        drums.add(at(beat), s.punch_kick(1.0), gain=0.5, wet=0.03)
        kicks.append(at(beat))
        fx.add(at(beat), s.boom(2.2, 1.0), gain=0.22 * weight, wet=0.3)
        low.add(at(beat), theme.dying(brass, 1.2) if beat == LAST else brass, gain=0.4 * weight, wet=0.3)
        drums.add(at(beat), s.lowpass(s.crash(0.9, 3.0, decay=1.3), 5500), gain=0.2 * weight, wet=0.35)
    pads.add(at(DROP), hit, gain=0.24, wet=0.3)
    for beat in [b for b in theme.playing(DROP, LAST, 0.5) if b % 4 in (1.5, 3.5)]:
        pads.add(at(beat), stab(chord(beat)[1]), gain=0.24, wet=0.25)
    drums.add(at(cue["cta"]), s.lowpass(s.crash(0.7, 2.0, decay=0.9), 5500), gain=0.14, wet=0.35)

    theme.develop(fx, room, 79)
    sounds(fx)

    pump = s.sidechain(theme.LENGTH, kicks, depth=0.55, release=0.15)
    low.duck(1 - 0.6 * (1 - pump))
    pads.duck(1 - 0.45 * (1 - pump))
    arps.duck(1 - 0.3 * (1 - pump))
    theme.trim(drums, 50)
    theme.trim(low, 55)
    theme.trim(fx, 45)
    theme.trim(bed, 45)
    return [drums, low, pads, arps, lead, fx, bed], dict(room=room, wet=0.45, presence=3.0)


ARRANGEMENTS = {"synthwave": synthwave}
