"""
E12's track (Library): a dark, wide track in C minor at 100 BPM, 8 bars and 19.2 seconds on the series' cue
sheet, src/features/cues.json, which scripts/features-score.py plays under the episode with its own sounds.
Its first chord, Cm6/9, takes C minor's Dorian sixth, A, so it shares D and A with the opener's held D major
chord: the lead-in plays the arpeggio on D and A over a drone on the same two and a recorded hum on D, and on
the first hit the bass falls to C and the pads bring in E flat and G.

Where E11 falls to the Neapolitan and E03 lifts to the Dorian fourth, this one climbs to the relative major
and its fifth, then lets the bass down by semitones into the drop: Cm6/9 under the hook, then Ebmaj7#11 and
Bbmaj9, every chord keeping the Dorian A; then the bass steps down from B flat through A, A flat and G, under
Am7(b5), Abmaj7#11 and G7(b9), and falls a fifth to C on the drop, on Cm9; on the end line Abmaj7#11 to
G7(b9) again, and Cm9 on the last hit. The pads sit between D3 and D4, every voice moving by step.

The riff is two bars, each a long note dropping a fourth and back, then climbing: C, G and C, up through D to
E flat, held, and back to D; then the same a step lower from B flat, up to D. The answer plays the first bar
again over Am7(b5), then C, A flat and C over A flat, up to D and down onto B, held through the stop, which
rises to C on the drop; the head on the drop is the first bar; the closing phrase turns over A flat up to E
flat, falls through D, B and G and climbs back through B to C on the last hit.

darksynth, its one arrangement, layers recorded sounds into our own synthesis, after the music the owner
listens to: dronescapes, Luftrum's pads, Perturbator, electronic Depeche Mode and deep trance (11 October
2026). The samples are from Sonic Pi's pack (CC0), in the samples' folder outside the repository
(synth.SAMPLES). A cinematic boom's air rises into the first hit with a crash played backwards and its impact
lands on it, with an 808's boom tuned to C. A recorded drone pitched down to C holds under the hook and the
build, the hum on D fading out of the lead-in over it; a recorded pad plays the minor seventh chord inside
each chord that has one, and from the first step a synth choir sings every chord on "ah", the recorded choir
joining it on the A flat chords, the drop and the last hit and breathing in before the drop. The bass is a recorded trance bass over driven saws on the offbeats, deep trance's
pump against the kick, held under the hook. The kit is recorded: a heavy kick over a fat one, an electronic
snare's crack over a dry one in a long room, closed hats, an open hat on the offbeats once the full beat comes
in, and toms tuned to E flat, C and G falling into the stop and the last hit. The synths that remain are
driven and spread wide: a supersaw pad, an arpeggio in sixteenths whose top note pulses, a trance gate on the
supersaw's chord from the third step, and the riff on a brass and a pair of saws, doubled an octave down and,
from the drop, an octave up. On the drop the boom, the 808, an impact, a trailer's low brass on C, the chord
struck, the choir and a crash land together with the series' sting, glass struck on C, G and D; the boom comes
again, smaller, on the last hit.
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
CHORDS = [("Cm6/9", 0, 4), ("Ebmaj7#11", 4, 4), ("Bbmaj9", 8, 4), ("Am7(b5)", 12, 4), ("Abmaj7#11", 16, 2),
          ("G7(b9)", 18, 2), ("Cm9", 20, 4), ("Abmaj7#11", 24, 2), ("G7(b9)", 26, 2), ("Cm9", 28, 4)]

# Each chord: the bass's root, climbing to B flat and stepping down by semitones to G, then falling to C on the
# drop; and the pads' voicing, rootless between D3 and D4, its voices moving by step and keeping the colour
# notes: the Dorian A and the ninth over Cm, E flat's sharp eleventh, B flat's major seventh, A's flat fifth,
# A flat's major seventh against its root, and G's flat ninth over its third.
VOICINGS = {
    "Cm6/9": (36, [51, 55, 57, 62]),
    "Ebmaj7#11": (39, [50, 55, 57, 62]),
    "Bbmaj9": (46, [50, 53, 57, 60]),
    "Am7(b5)": (45, [51, 55, 57, 60]),
    "Abmaj7#11": (44, [50, 55, 56, 60]),
    "G7(b9)": (43, [50, 53, 56, 59]),
    "Cm9": (36, [51, 55, 58, 62]),
}


def chord(beat):
    root, voicing = VOICINGS[theme.chord_at(beat, CHORDS)]
    return root, voicing, [n + 12 for n in voicing]


# The riff, [beat, note, beats] from where it starts: C, G and C, D, E flat held and D; then B flat, F and
# B flat, C, D held and C. The answer turns over A flat and holds B through the stop; the head is the first
# bar; the closing phrase ends on C on the last hit.
MOTIF = [(0, 72, 0.75), (0.75, 67, 0.25), (1, 72, 0.5), (1.5, 74, 0.5), (2, 75, 1.5), (3.5, 74, 0.5),
         (4, 70, 0.75), (4.75, 65, 0.25), (5, 70, 0.5), (5.5, 72, 0.5), (6, 74, 1.5), (7.5, 72, 0.5)]
ANSWER = MOTIF[:6] + [(4, 72, 0.75), (4.75, 68, 0.25), (5, 72, 0.5), (5.5, 74, 0.5), (6, 71, 2.0)]
HEAD = MOTIF[:6]
CLOSE = [(0, 72, 0.75), (0.75, 68, 0.25), (1, 72, 0.5), (1.5, 75, 0.5), (2, 74, 0.5), (2.5, 71, 0.5), (3, 67, 0.5),
         (3.5, 71, 0.5), (4, 72, 4.0)]
TUNE = (theme.placed(S1, MOTIF) + theme.placed(S3, ANSWER) + theme.placed(DROP, HEAD)
        + theme.placed(cue["endLine"], CLOSE))

# The arpeggio's levels for a note and its echo, which the lead-in grows to.
ARP, ECHO = 0.24, 0.08
# Which of the chord's four notes each sixteenth of a half bar plays: the top note on every other one, the
# others climbing and falling under it.
PULSE = (0, 3, 1, 3, 2, 3, 1, 3)
# The trance gate on the supersaw's chord: which sixteenths of a bar sound.
GATE = (1, 0, 1, 1, 0, 1, 1, 0, 1, 0, 1, 1, 0, 1, 1, 0)

# ---------------------------------------------------------------- the recorded sounds
# Samples from Sonic Pi's pack (CC0) in the samples' folder (synth.SAMPLES).
PACK = "sonic-pi/"
# Where misc_cineboom's impact falls, after the air that swells up into it.
IMPACT = 1.66
# bd_boom, an 808's boom, sounds B flat 1 36 cents sharp; it's tuned to C.
BOOM_ROOT = 34.36
# loop_drone_g_97 holds G2 with its fifth and seventh; pitched down to C, it holds C with G and B flat.
DRONE_ROOT = 43
# ambi_haunted_hum hums D3 26 cents flat.
HUM_ROOT = 49.74
# tbd_pad_1 is G minor's seventh chord about G2 and G3. Under each chord it plays the minor seventh chord inside
# it: C minor's under Cm6/9 and Cm9 and over A flat, G minor's over E flat and D minor's over B flat. Am7(b5)
# and G7(b9) have none, so the pad leaves them to the synths.
LAYER = {"Cm6/9": 48, "Ebmaj7#11": 43, "Bbmaj9": 50, "Abmaj7#11": 48, "Cm9": 48}
# ambi_choir sings A flat major 45 cents sharp: at its own pitch over the A flat chords, and a fourth down, on E
# flat major, C minor's seventh, over the drop's and the last hit's C.
CHOIR = 68.45
# The toms: each one's sample, the note it was recorded at and the note it's tuned to (E flat, C and G, falling
# through C minor), and where it sits, from the right to the left.
TOMS = {"high": ("drum_tom_hi_hard", 50.58, 51, 0.35), "middle": ("drum_tom_mid_hard", 46.87, 48, 0.0),
        "low": ("drum_tom_lo_hard", 41.9, 43, -0.35)}


def mixed(*parts):
    """Sounds of any lengths, each with its gain, added together from the same start, stereo."""
    out = np.zeros((max(len(x) for x, _ in parts), 2))
    for x, gain in parts:
        out[: len(x)] += (s.pan(x, 0.0) if x.ndim == 1 else x) * gain
    return out


def wider(x, width):
    """A stereo sound with what differs between its ears `width` times as loud against what they share."""
    middle, side = (x[:, 0] + x[:, 1]) / 2, (x[:, 0] - x[:, 1]) / 2 * width
    return np.stack([middle + side, middle - side], axis=1)


def driven(x, amount=2.5, tone=3200):
    """A synth pushed through the waveshaper, its grit warm rather than fizzing."""
    return s.drive(x, amount, tone=tone, asym=0.1)


def cut(x, seconds):
    """`x` stopped after `seconds`, with a short fade."""
    out = x[: max(0, int(round(seconds * s.SR)))].copy()
    fade = min(len(out), int(0.03 * s.SR))
    out[len(out) - fade:] *= np.linspace(1, 0, fade)[:, None] if out.ndim == 2 else np.linspace(1, 0, fade)
    return out


def kick():
    """The kick: a heavy kick's beater over a fat kick's body, brought forward so it carries on a phone."""
    x = mixed((s.sample(PACK + "drum_heavy_kick.flac"), 0.7), (s.sample(PACK + "bd_fat.flac"), 0.6))
    return s.shelf(x, 2500, 4.0)


def snare():
    """The snare: an electronic snare's crack over a dry one, damped within a sixteenth, so a key coming up a
    sixteenth after it is heard; its room comes from the reverb."""
    return mixed((s.sample(PACK + "sn_zome.flac", seconds=0.15, release=0.07), 0.7),
                 (s.sample(PACK + "elec_snare.flac", seconds=0.15, release=0.07), 0.55))


def tom(which):
    """A tom, `high`, `middle` or `low`, tuned, mono for Bus.add to pan."""
    name, root, note, _ = TOMS[which]
    return s.sample(PACK + f"{name}.flac", note=note, root=root, seconds=0.6, release=0.2, mono=True)


def boom(seconds, rising=1.0):
    """The cinematic boom, from the air that swells up into its impact IMPACT seconds before it, that air
    `rising` times as loud; its low tail cut to `seconds` after the impact, and the rumble under 40 Hz a phone
    doesn't play taken out."""
    x = s.sample(PACK + "misc_cineboom.flac", seconds=IMPACT + seconds, attack=0.002, release=seconds * 0.7)
    gain = np.interp(np.arange(len(x)) / s.SR, [IMPACT - 0.01, IMPACT], [rising, 1.0])
    return s.highpass(x * gain[:, None], 40, order=3)


def eight08(seconds=1.4):
    """The 808's boom, tuned to C2."""
    return s.sample(PACK + "bd_boom.flac", note=36, root=BOOM_ROOT, seconds=seconds, release=seconds * 0.5)


def choir(note, seconds=None, reverse=False):
    """The recorded choir's "ah" on a major chord rooted on `note`, or backwards, breathing in."""
    return s.sample(PACK + "ambi_choir.flac", note=note, root=CHOIR, seconds=seconds, release=0.3, reverse=reverse)


# ---------------------------------------------------------------- the synths

def pluck(note, bright):
    """A note of the arpeggio: a saw plucked dark and driven, so it growls a little as it snaps shut."""
    return driven(s.pluck(note, 0.85, 0.18, bright=bright), 2.2, 3600)


def growing(note, grown):
    """A note of the arpeggio in the lead-in, darker as it starts."""
    return pluck(note, 0.1 + 0.3 * grown)


def pad(notes, seconds, cutoff, attack, release):
    """The supersaw pad, driven and spread wide."""
    saws = s.supersaw(notes, seconds, voices=6, spread=16, cutoff=cutoff, attack=attack, release=release)
    return wider(driven(saws, 1.8, 5000), 1.5)


def gated(notes, cutoff):
    """A sixteenth of the trance gate: the supersaw's chord, cut short, driven."""
    saws = s.supersaw(notes, 0.11, voices=5, spread=14, cutoff=cutoff, attack=0.004, release=0.03)
    return wider(driven(saws, 2.2, 5200), 1.4)


def lead(note, seconds, cutoff, vibrato):
    """The riff's voice: a poly-synth's brass blaring open over two detuned saws, driven and spread wide, its
    grit kept under 3 kHz so the keys and ticks on screen carry over it."""
    brassy = s.brass([note], seconds, 0.9, cutoff=cutoff, attack=0.03, release=0.15)
    saws = s.saw_lead(note, seconds, 0.9, cutoff=cutoff * 1.2, detune=9, vibrato=vibrato)
    return wider(s.highpass(driven(mixed((brassy, 0.8), (saws, 0.7)), 2.6, 2800), 150), 1.6)


def bass(root, velocity, bright):
    """A note of the offbeat bass: the recorded trance bass over driven saws, a sixteenth and a half long."""
    sampled = s.sample(PACK + "bass_trance_c.flac", note=root, root=36, seconds=0.2, release=0.05, mono=True)
    saws = s.grit_bass(root, velocity, 0.18, bright=bright, grit=0.7)
    return s.lowpass(mixed((driven(sampled, 2.0, 2600) * velocity, 0.6), (saws, 0.9)), 4500)


def darksynth(sounds=theme.ui):
    theme.start(127)
    room = s.reverb(3.0, 0.75, 0.025)
    drums, low, pads, layer, arps, gate, lead_, fx, bed, drone = (s.Bus(theme.LENGTH) for _ in range(10))
    kicks = []
    beat_kick, beat_snare = kick(), snare()
    closed = s.sample(PACK + "hat_gnu.flac", mono=True)
    opened = s.sample(PACK + "hat_metal.flac", seconds=0.25, release=0.15, mono=True)
    crash = s.sample(PACK + "drum_cymbal_hard.flac", release=0.4)

    # The lead-in, on D and A, the notes the held D major chord and Cm6/9 share, on the arpeggio's pluck, over a
    # drone on D and A and the recorded hum on D; the boom's air and a crash played backwards rise into the
    # first hit. The drone gives way to the bass as it comes in with the first step; the hum carries on over
    # the hook as Cm6/9's ninth and fades.
    theme.lead_in((arps, drums, bed, fx), kicks, room, [57, 62, 69, 74], [38, 45, 50], ARP * swell(0), ECHO * swell(0),
                  tone=growing)
    bed.duck(np.interp(np.arange(len(bed.dry)) / s.SR, [at(0), at(S1), at(S1 + 1)], [1.0, 1.0, 0.0]))
    hum = s.held(PACK + "ambi_haunted_hum.flac", at(S1) - at(-theme.LEAD_IN), note=50, root=HUM_ROOT, cross=0.6,
                 attack=theme.PRE * 0.8, release=1.5)
    drone.add(at(-theme.LEAD_IN), s.lowpass(hum, 3000), gain=0.28, wet=0.4)
    fx.add(at(0) - IMPACT, boom(2.2, rising=2.4), gain=0.3, wet=0.3)
    backwards = s.sample(PACK + "drum_cymbal_hard.flac", seconds=1.4, release=0.7, reverse=True)
    drums.add(at(0) - len(backwards) / s.SR, backwards, gain=0.3, wet=0.3)

    # The first frame lands as the kick, the deep kick and the 808 under the boom. The recorded drone comes in
    # on C under the hook and grows from the first step through the build, swelling on through the stop into
    # the drop.
    drums.add(at(0), beat_kick, gain=0.5, wet=0.1)
    drums.add(at(0), s.deep_kick(0.85), gain=0.34, wet=0.12)
    low.add(at(0), eight08(1.2), gain=0.22, wet=0.1)
    bedded = s.held(PACK + "loop_drone_g_97.flac", at(DROP) - at(0), note=36, root=DRONE_ROOT, cross=0.4, attack=0.3,
                    release=0.5)
    grow = np.interp(np.arange(len(bedded)) / s.SR, [0, at(S1) - at(0), at(DROP) - at(0)], [0.9, 0.85, 1.0])
    drone.add(at(0), bedded * grow[:, None], gain=0.6, wet=0.3)

    # The pads: the supersaw's, driven and wide, opening through the build; the recorded pad, the minor seventh
    # chord inside each chord; and the synth choir singing each chord, from the first step.
    for name, first, length in CHORDS:
        _, voicing = VOICINGS[name]
        last = first == LAST
        seconds = 2.8 if last else length * theme.BEAT
        cutoff = 2600 if first >= DROP else opening(first, 0, S4, 1000, 2200)
        tone = pad(voicing, seconds, cutoff, attack=0.5 if first == 0 else 0.1, release=1.6 if last else 0.25)
        pads.add(at(first), theme.dying(tone, 1.3) if last else tone, gain=0.18 * swell(first), wet=0.5)
        if name in LAYER:
            under = s.held(PACK + "tbd_pad_1.flac", seconds, note=LAYER[name], root=43, cross=0.3,
                           attack=0.4 if first == 0 else 0.08, release=1.6 if last else 0.25)
            under = s.highpass(theme.dying(under, 1.4) if last else under, 140)
            layer.add(at(first), under, gain=0.42 * swell(first), wet=0.45)
        if first >= S1:
            sung = s.choir([n + 12 for n in voicing[1:]], seconds, attack=0.35 if first == S1 else 0.12,
                           release=1.8 if last else 0.3)
            layer.add(at(first), theme.dying(sung, 1.4) if last else sung, gain=0.22 * swell(first), wet=0.55)

    # The arpeggio in sixteenths, its top note pulsing on every other one and the others moving under it, with
    # an echo a dotted eighth later between its notes; darker under the hook, it opens through the build.
    for i, beat in enumerate(theme.playing(0, LAST, 0.25)):
        note = chord(beat)[2][PULSE[round(beat * 4) % 8]]
        bright = 0.22 if beat < S1 else opening(beat, S1, STOP, 0.28, 0.62) if beat < DROP else 0.66
        tone = pluck(note, bright)
        arps.add(at(beat), tone, gain=ARP * swell(beat) * (1.0 if i % 2 == 0 else 0.8), pan_to=(-0.45, 0.45)[i % 2],
                 wet=0.3)
        arps.add(at(beat + 0.75), s.lowpass(tone, 2000), gain=ECHO * swell(beat), pan_to=(0.6, -0.6)[i % 2], wet=0.45)

    # The trance gate from the third step: the supersaw's chord on the gate's sixteenths, opening through the
    # build and full from the drop.
    for beat in theme.playing(S3, LAST, 0.25):
        if not GATE[round(beat * 4) % 16]:
            continue
        cutoff = opening(beat, S3, STOP, 1600, 3400) if beat < DROP else 3600
        gate.add(at(beat), gated(chord(beat)[2], cutoff), gain=0.2 * swell(beat), wet=0.3)

    # The bass: the root held under the hook, swelling in over the hit's first beat; then the offbeats from the
    # first step, opening through the build; the last root dies away.
    held = s.grit_bass(36, 0.8, at(S1) - at(0) - 0.05, bright=0.12, grit=0.5)
    held = held * np.clip(np.arange(len(held)) / s.SR / theme.BEAT, 0, 1)
    low.add(at(0), theme.dying(s.lowpass(held, 1800), 2.4), gain=0.32, wet=0.08)
    for beat in theme.playing(S1, LAST, 1):
        if STOP <= beat + 0.5 < DROP:
            continue
        bright = opening(beat, S1, STOP, 0.2, 0.55) if beat < DROP else 0.65
        low.add(at(beat + 0.5), bass(chord(beat)[0], 0.9, bright), gain=0.48 * swell(beat), wet=0.04)
    low.add(at(LAST), theme.dying(s.lowpass(s.grit_bass(36, 0.9, 3.0, bright=0.3, grit=0.6), 2200), 0.9), gain=0.4,
            wet=0.1)

    # The kit, recorded. The kick muffled as if through a wall under the hook; in half time through the first
    # two steps, a kick on 1 and the and of 2 and the snare in a long room on 3; from the third step four on the
    # floor with the snare on 2 and 4. Closed hats in eighths from the second step and in sixteenths from the
    # third, accented on the offbeats; an open hat on the offbeats from the third. Toms fall from E flat to G in
    # sixteenths, then thirty-seconds, into the stop, and into the last hit.
    for beat in range(1, S1):
        drums.add(at(beat), s.lowpass(beat_kick, 200), gain=0.55, wet=0.02)
        kicks.append(at(beat))
    for beat in theme.playing(S1, LAST, 0.5):
        if beat < S3 and beat % 4 not in (0, 1.5) or beat >= S3 and beat % 1:
            continue
        drums.add(at(beat), beat_kick, gain=0.52 * swell(beat) ** 0.5, wet=0.04)
        kicks.append(at(beat))
    for beat in theme.playing(S1, LAST, 1):
        if S4 + 2 <= beat < DROP:
            continue
        if beat < S3 and beat % 4 == 2 or beat >= S3 and beat % 2 == 1:
            drums.add(at(beat), beat_snare, gain=0.36 if beat < S3 else 0.4, wet=0.34)
    for beat in theme.playing(S2, S3, 0.5):
        drums.add(at(beat), closed, gain=(0.42 if beat % 1 else 0.26) * swell(beat), pan_to=0.3, wet=0.06)
    for beat in theme.playing(S3, LAST, 0.25):
        if S4 + 2 <= beat < DROP:
            continue
        accent = (0.45, 0.3, 1.0, 0.3)[round(beat * 4) % 4]
        drums.add(at(beat), closed, gain=0.34 * accent * swell(beat), pan_to=0.3, wet=0.06)
    for beat in theme.playing(S3 + 0.5, LAST, 1):
        if S4 + 2 <= beat < DROP:
            continue
        drums.add(at(beat), opened, gain=0.13 * swell(beat), pan_to=-0.3, wet=0.15)
    fill = [("high", 0.25), ("high", 0.25), ("middle", 0.25), ("middle", 0.25), ("low", 0.125), ("middle", 0.125),
            ("low", 0.125), ("low", 0.125)]
    beat = S4 + 2
    for i, (which, step) in enumerate(fill):
        drums.add(at(beat), tom(which), gain=0.36 + 0.03 * i, pan_to=TOMS[which][3], wet=0.3)
        beat += step
    for beat, which in zip(np.arange(LAST - 1, LAST, 0.25), ("high", "middle", "middle", "low")):
        drums.add(at(beat), tom(which), gain=0.34, pan_to=TOMS[which][3], wet=0.3)

    # The riff on the brass and the saws, with an echo a dotted eighth later that stops on the drop and the last
    # hit so the held note resolves; doubled an octave down throughout and, from the drop to the end line, an
    # octave up.
    for beat, note, beats in TUNE:
        last = beat >= LAST
        seconds = beats * theme.BEAT * 0.94
        cutoff = 2400 if beat >= DROP else 1900
        tone = lead(note, seconds, cutoff, 0.14 if beats >= 1 else 0.0)
        below = lead(note - 12, seconds, cutoff * 0.7, 0.0)
        if last:
            tone, below = theme.dying(tone, 1.0), theme.dying(below, 1.0)
        level = 0.27 * swell(beat) ** 0.5
        lead_.add(at(beat), tone, gain=level, wet=0.3)
        lead_.add(at(beat), below, gain=level * 0.45, wet=0.25)
        stop = DROP if beat < DROP else LAST if beat < LAST else theme.BEATS
        echo = cut(s.lowpass(tone.mean(axis=1), 1800), (stop - beat - 0.75) * theme.BEAT)
        lead_.add(at(beat + 0.75), echo, gain=level * 0.28, pan_to=-0.5, wet=0.5)
        if DROP <= beat < cue["endLine"]:
            lead_.add(at(beat), lead(note + 12, seconds, 3000, 0.1), gain=level * 0.26, wet=0.4)

    # The build: a crash as the full beat comes in, a riser through the fourth step, and into the drop the air
    # before the boom's impact, a crash played backwards, the choir breathing in the chord it sings on the drop
    # and the hit's own reverb, swelling up through the stop; the choir sings each A flat chord.
    drums.add(at(S3), crash, gain=0.1, wet=0.35)
    hit = pad([n + 12 for n in VOICINGS["Cm9"][1]], 1.2, 3600, attack=0.02, release=0.6)
    fx.add(at(S4), s.riser(at(DROP) - at(S4), 300, 7000, curve=2.2), gain=0.06, wet=0.35)
    fx.add(at(STOP), s.swell_into(hit, at(DROP) - at(STOP), room), gain=0.18, wet=0.0)
    fx.add(at(DROP) - IMPACT, boom(3.5), gain=0.34, wet=0.25)
    backwards = s.sample(PACK + "drum_cymbal_hard.flac", seconds=1.6, release=0.8, reverse=True)
    drums.add(at(DROP) - len(backwards) / s.SR, backwards, gain=0.16, wet=0.3)
    breath = choir(63, 1.2, reverse=True)
    layer.add(at(DROP) - len(breath) / s.SR, breath, gain=0.24, wet=0.5)
    for first in (S4, cue["endLine"]):
        layer.add(at(first), choir(68, 1.3), gain=0.16, wet=0.55)

    # The drop: the boom, the 808 and the deep kick under the beat's kick, an impact, a trailer's low brass on C,
    # the pad struck at full width, the choir on E flat over the C and a crash; a crash on the call to action;
    # and the last hit, with the boom again, smaller, and the arpeggio's last chord rising after it into the
    # room.
    brass = driven(s.braam([36, 43, 48, 51, 55], 2.6, 1.0), 1.6, 3000)
    for beat, weight in ((DROP, 1.0), (LAST, 0.8)):
        drums.add(at(beat), beat_kick, gain=0.55, wet=0.1)
        drums.add(at(beat), s.deep_kick(1.0), gain=0.55 * weight, wet=0.08)
        low.add(at(beat), eight08(2.2), gain=0.42 * weight, wet=0.1)
        low.add(at(beat), theme.dying(brass, 1.1) if beat == LAST else brass, gain=0.34 * weight, wet=0.3)
        kicks.append(at(beat))
        fx.add(at(beat), s.sample(PACK + "perc_impact2.flac", release=0.3), gain=0.18 * weight, wet=0.35)
        layer.add(at(beat), choir(63), gain=0.3 * weight, wet=0.5)
        drums.add(at(beat), crash, gain=0.2 * weight, wet=0.35)
    fx.add(at(LAST) - IMPACT, boom(3.4, rising=0.5), gain=0.24, wet=0.3)
    pads.add(at(DROP), hit, gain=0.2, wet=0.3)
    drums.add(at(cue["cta"]), crash, gain=0.13, wet=0.35)
    for i, (note, p) in enumerate(zip(VOICINGS["Cm9"][1], (-0.4, -0.15, 0.15, 0.4))):
        arps.add(at(LAST + i / 4), pluck(note + 12, 0.45), gain=ARP * 0.9, pan_to=p, wet=0.55)

    theme.develop(fx, room, 72)
    sounds(fx)

    pump = s.sidechain(theme.LENGTH, kicks, depth=0.55, release=0.17)
    low.duck(1 - 0.6 * (1 - pump))
    pads.duck(1 - 0.4 * (1 - pump))
    layer.duck(1 - 0.3 * (1 - pump))
    arps.duck(1 - 0.25 * (1 - pump))
    gate.duck(1 - 0.3 * (1 - pump))
    drone.duck(1 - 0.4 * (1 - pump))
    theme.trim(drums, 40)
    theme.trim(low, 45)
    theme.trim(fx, 45)
    theme.trim(bed, 45)
    theme.trim(drone, 50)
    return [drums, low, pads, layer, arps, gate, lead_, fx, bed, drone], dict(room=room, wet=0.55, presence=4.0)


ARRANGEMENTS = {"darksynth": darksynth}
