"""
E12, Library, in the series' look (boards/e01.py): Redlamp's library with a Lightroom Classic catalog
brought into it, searched and flown through from the keyboard, with no pointer anywhere. The library is
drawn as a dashboard: the left panel's Folders, Collections and Keywords, and beside it the count, the
filter bar and a grid of thumbnails, over the selected photo's histogram and level and a bottom panel
that holds the import, then its report, then the keyboard.

A copy of the catalog peels off it, under a card that says it's read and never changed, and lands in the
import; the report counts what came across in the catalog's own numbers, and as each count lands its
stars, pick flags and colour labels come up on the thumbnails and its collections and keywords fill the
left panel. SNOW, one of its keywords, is typed into the filter bar a letter a beat, and the count and
the grid narrow with each letter beside the search's time. A held right arrow runs the selection through
the results, E shows them in the loupe and D in Develop, each step a photo. The result is the library as
it was before the catalog, then with it.

The thumbnails are drawn scenes and the owner's photos (in ~/src/redlamp-social/photos), reduced to the
library's own colours. The wording is the app's: All Photographs, the filter bar's count ("7,902 of
1,000,000"), No catalog chosen, and the report's fields (LightroomReport); G, E and D are Lightroom's
keys for the grid, the loupe and Develop (README, Keyboard shortcuts). The catalog's numbers stand in for
a catalog of the owner's size; the library's million and the search's 0.2 ms are the tracker's (LIB-05,
LIB-06).
"""

import math
from functools import cache
from typing import NamedTuple

import numpy as np
from PIL import Image

from features import world as w

EPISODE = w.episode("e12")
FEATURE = "LIBRARY"
PHOTO = ("NO PHOTO OF ITS OWN: THE LIBRARY'S THUMBNAILS ARE DRAWN SCENES AND THIRTEEN OF THE OWNER'S PHOTOS, REDUCED "
         "TO THE LIBRARY'S OWN COLOURS. THE CATALOG'S COUNTS STAND IN FOR A CATALOG OF THE OWNER'S SIZE; A MILLION "
         "PHOTOS AND 0.2 MS ARE THE TRACKER'S (LIB-05, LIB-06)")
CUE = w.CUE

# Bars 1 to 5: the library over the series' histogram, level and bottom panel.
LEFT = w.Rect(4, 106, 64, 128)
GRID = w.Rect(70, 106, 142, 128)
HIST = w.Rect(4, 236, 208, 12)
BOTTOM = w.Rect(4, 250, 178, 38)
LEVEL = w.Rect(190, 252, 18, 34)
# Develop: the series' photo panel across the top of the stage.
DEVELOP = w.Rect(4, 106, 208, 128)
# Bar 6: the library fills the stage.
RESULT_LEFT = w.Rect(4, 106, 64, 182)
RESULT_GRID = w.Rect(70, 106, 142, 182)
# Words keep left of the apps' side buttons, which cover the stage's right edge.
READ_RIGHT = 202
# A thumbnail's frame, and the step from one cell to the next, its stars under it.
FRAME, PITCH = (20, 13), (22, 18)
THUMB = (FRAME[0] - 2, FRAME[1] - 2)
COLUMNS = 6
KEYCAP = 22
TITLE = w.wrapped(EPISODE["title"].upper())


# ---------------------------------------------------------------- the scenes

def lin(h):
    """A colour in linear light, from its hex."""
    v = np.array([int(h[i:i + 2], 16) for i in (1, 3, 5)]) / 255
    return np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4)


def encode(v):
    v = np.clip(v, 0, 1)
    return Image.fromarray(np.rint(np.where(v <= 0.0031308, v * 12.92, 1.055 * v ** (1 / 2.4) - 0.055) * 255)
                           .astype(np.uint8))


def plane(width, height):
    x = (np.arange(width) + 0.5) / width
    y = (np.arange(height) + 0.5) / height
    X, Y = np.meshgrid(x, y)
    return x, X, Y, width / height


def sky(Y, stops, bottom):
    t = np.clip(Y / bottom, 0, 1)
    cols = np.array([lin(c) for _, c in stops])
    return np.stack([np.interp(t, [s for s, _ in stops], cols[:, k]) for k in range(3)], axis=-1)


def hills(x, rng, base, amp):
    """A soft skyline's height at each x, as a share of the height from the top."""
    out = np.full_like(x, base)
    for f, a in ((1.3, 1.0), (3.1, 0.5), (7.3, 0.2)):
        out -= amp * a * np.sin(2 * np.pi * f * x + rng.uniform(0, 2 * np.pi))
    return out


def mountains(img, X, Y, aspect, rng, base, rise, n, lit, shade):
    """A range of `n` peaks standing on `base`, up to `rise` above it, each a cone whose left face is lit and
    whose right face is in shade, the split running down and to the right from its summit."""
    peaks = [(rng.uniform(-0.05, 1.05), base - rise * rng.uniform(0.45, 1.0), rng.uniform(0.18, 0.34)) for _ in range(n)]
    tops = np.stack([py + np.abs(X - px) * (base - py) / hw for px, py, hw in peaks])
    k = tops.argmin(0)
    inside = (Y > tops.min(0)) & (Y < base + 0.02)
    px, py = np.array([p[0] for p in peaks])[k], np.array([p[1] for p in peaks])[k]
    sunny = X < px + (Y - py) * 0.5 / aspect + 0.012 * np.sin(Y * 60)
    img[inside] = np.where(sunny[..., None], lit, shade)[inside]


def pine(img, X, Y, aspect, tx, foot, tall, green, snow):
    """A pine of three tiers, each a little narrower than the one under it, snow along the top of each."""
    for tier in range(3):
        top = foot - tall + tall * 0.28 * tier
        bottom = top + tall * 0.45
        half = (Y - top) / (bottom - top) * tall * (0.22 + 0.04 * tier) / aspect
        body = (np.abs(X - tx) < half) & (Y > top) & (Y < bottom)
        img[body] = green
        img[body & (Y < top + (bottom - top) * 0.35) & (np.abs(X - tx) > half * 0.25)] = snow
    img[(np.abs(X - tx) < tall * 0.03 / aspect) & (Y >= foot - tall * 0.08) & (Y < foot)] = lin("#3a2a20")


def peaks(width, height, seed):
    """Snow-covered mountains under a clear sky, or at dusk, with pines in the snow below them."""
    rng = np.random.default_rng(seed)
    x, X, Y, aspect = plane(width, height)
    dusk = seed % 3 == 1
    img = sky(Y, [(0, "#25256a"), (0.55, "#9a67b0"), (1, "#f6b388")] if dusk else
              [(0, "#1c58b8"), (0.6, "#5d9fe4"), (1, "#c8e6f9")], 0.62)
    lit, shade = (lin("#ffe6d2"), lin("#8a7fb8")) if dusk else (lin("#f7fbff"), lin("#8fb2dc"))
    far = img[-1, 0].copy()
    mountains(img, X, Y, aspect, rng, 0.62, 0.42, 4, lit * 0.65 + far * 0.35, shade * 0.65 + far * 0.35)
    mountains(img, X, Y, aspect, rng, 0.8, 0.32, 3, lit, shade)
    img[Y > 0.8 + 0.015 * np.sin(x * 11)[None, :]] = lin("#eef5ff")
    for _ in range(rng.integers(2, 6)):
        pine(img, X, Y, aspect, rng.uniform(0, 1), rng.uniform(0.92, 1.02), rng.uniform(0.14, 0.24), lin("#1d3b33"),
             lin("#eef5ff"))
    return img


def forest(width, height, seed):
    """Pines in deep snow under a clear or a grey sky."""
    rng = np.random.default_rng(seed)
    x, X, Y, aspect = plane(width, height)
    img = sky(Y, [(0, "#3f7fd0"), (1, "#d5e9f8")] if seed % 2 == 0 else [(0, "#8ea4c2"), (1, "#e6edf6")], 0.55)
    img[Y > hills(x, rng, 0.56, 0.03)[None, :]] = lin("#f1f6fc")
    trees = sorted(((rng.uniform(-0.05, 1.05), rng.uniform(0.62, 1.05), rng.uniform(0.3, 0.55)) for _ in range(8)),
                   key=lambda t: t[1])
    for tx, foot, tall in trees:
        pine(img, X, Y, aspect, tx, foot, tall, lin("#1e4a3c") * (0.55 + 0.45 * foot), lin("#eaf2f9"))
    return img


def village(width, height, seed):
    """Houses in the snow at dusk, their windows lit, under mountains."""
    rng = np.random.default_rng(seed)
    x, X, Y, aspect = plane(width, height)
    img = sky(Y, [(0, "#1f1d55"), (0.6, "#683f8a"), (1, "#f2a46e")], 0.5)
    mountains(img, X, Y, aspect, rng, 0.55, 0.25, 3, lin("#f3dccf"), lin("#7b6ea4"))
    img[Y > hills(x, rng, 0.6, 0.04)[None, :]] = lin("#e3e9f6")
    for _ in range(4):
        hx, hw, base = rng.uniform(0.08, 0.92), rng.uniform(0.09, 0.14), rng.uniform(0.78, 0.92)
        hh, rise = hw * 0.9 * aspect, hw * 0.55 * aspect
        img[(np.abs(X - hx) < hw / 2) & (Y > base - hh) & (Y < base)] = lin("#4a3442")
        roof = (np.abs(X - hx) < (hw / 2 + 0.01) * (Y - (base - hh - rise)) / rise) & (Y > base - hh - rise) & (Y <= base - hh)
        img[roof] = lin("#f4f7ff")
        img[(np.abs(X - hx) < hw * 0.16) & (np.abs(Y - (base - hh * 0.5)) < hh * 0.18)] = lin("#ffcf5a")
    pine(img, X, Y, aspect, rng.uniform(0, 1), 0.98, 0.3, lin("#1d3b33"), lin("#eef5ff"))
    return img


def night(width, height, seed):
    """Snowy hills under the moon and the stars."""
    rng = np.random.default_rng(seed)
    x, X, Y, aspect = plane(width, height)
    img = sky(Y, [(0, "#060a22"), (1, "#2a457f")], 0.7)
    for _ in range(width * height // 120):
        img[rng.integers(0, int(height * 0.45)), rng.integers(0, width)] = lin("#f3f4f9")
    mx, my = rng.uniform(0.6, 0.85), rng.uniform(0.15, 0.28)
    img[np.hypot((X - mx) * aspect, Y - my) < 0.07] = lin("#f6f1d8")
    mountains(img, X, Y, aspect, rng, 0.7, 0.35, 4, lin("#c5d4ee"), lin("#5a6f9e"))
    for base, amp, col in ((0.78, 0.04, "#9fb4dc"), (0.9, 0.03, "#d9e4f6")):
        img[Y > hills(x, rng, base, amp)[None, :]] = lin(col)
    for _ in range(3):
        pine(img, X, Y, aspect, rng.uniform(0, 1), rng.uniform(0.95, 1.05), rng.uniform(0.2, 0.3), lin("#0f2230"),
             lin("#b8c8e6"))
    return img


def frozen(width, height, seed):
    """Snowy mountains over a frozen lake that mirrors them."""
    rng = np.random.default_rng(seed)
    x, X, Y, aspect = plane(width, height)
    img = sky(Y, [(0, "#2b6cc6"), (1, "#d2e8f8")], 0.58)
    mountains(img, X, Y, aspect, rng, 0.6, 0.4, 4, lin("#f6faff"), lin("#8aa7d0"))
    ice = Y >= 0.6
    rows = np.clip(((1.2 - Y) * height).astype(int), 0, height - 1)
    cols = np.broadcast_to(np.arange(width), (height, width))
    img[ice] = img[rows[ice], cols[ice]] * 0.6 + lin("#c6ecf4") * 0.4
    return img


def beach(width, height, seed):
    rng = np.random.default_rng(seed)
    x, X, Y, aspect = plane(width, height)
    horizon = rng.uniform(0.42, 0.52)
    img = sky(Y, [(0, "#1e78d8"), (1, "#a8dcf5")], horizon)
    shore = 0.72 + 0.04 * np.sin(x * 9 + seed)[None, :]
    sea = (Y > horizon) & (Y < shore)
    depth = ((Y - horizon) * 2)[sea][:, None]
    img[sea] = lin("#0b6fb2") * (1 - depth) + lin("#33c6d6") * depth
    img[Y >= shore] = lin("#f2d08a")
    img[np.abs(Y - shore) < 0.025] = lin("#ffffff")
    return img


def meadow(width, height, seed):
    rng = np.random.default_rng(seed)
    x, X, Y, aspect = plane(width, height)
    img = sky(Y, [(0, "#2a7de0"), (1, "#bfe2fa")], 0.6)
    for base, amp, col in ((0.56, 0.05, "#4f9a3a"), (0.7, 0.06, "#79c043"), (0.88, 0.04, "#a2d64c")):
        img[Y > hills(x, rng, base, amp)[None, :]] = lin(col)
    tx = rng.uniform(0.2, 0.8)
    img[np.hypot((X - tx) * aspect, Y - 0.5) < 0.13] = lin("#2f6b2a")
    img[(np.abs(X - tx) * aspect < 0.02) & (Y > 0.55) & (Y < 0.72)] = lin("#5a3b22")
    return img


def dunes(width, height, seed):
    rng = np.random.default_rng(seed)
    x, X, Y, aspect = plane(width, height)
    img = sky(Y, [(0, "#3d8fd6"), (1, "#f4e2b8")], 0.5)
    mountains(img, X, Y, aspect, rng, 0.75, 0.3, 3, lin("#f6ac52"), lin("#b8602a"))
    mountains(img, X, Y, aspect, rng, 1.0, 0.3, 2, lin("#f7b862"), lin("#c06a30"))
    return img


def city(width, height, seed):
    rng = np.random.default_rng(seed)
    x, X, Y, aspect = plane(width, height)
    img = sky(Y, [(0, "#0b1030"), (1, "#4a3474")], 0.8)
    edges = np.sort(rng.uniform(0, 1, 7))
    for a, b in zip(np.concatenate([[0], edges]), np.concatenate([edges, [1]])):
        block = (X >= a) & (X < b) & (Y > rng.uniform(0.25, 0.65))
        img[block] = lin("#181c38")
        img[block & ((X * 23 + a * 7) % 1 < 0.45) & ((Y * 14) % 1 < 0.45) & (rng.random(block.shape) < 0.6)] = lin("#ffd06a")
    return img


def autumn(width, height, seed):
    rng = np.random.default_rng(seed)
    x, X, Y, aspect = plane(width, height)
    img = sky(Y, [(0, "#7fb6e8"), (1, "#f2e6c8")], 0.4)
    for _ in range(12):
        tx, ty, r = rng.uniform(0, 1), rng.uniform(0.2, 0.62), rng.uniform(0.12, 0.2)
        img[np.hypot((X - tx) * aspect, Y - ty) < r] = lin(["#f08a24", "#f7b733", "#d9661e", "#e8a02c"][rng.integers(4)])
    img[Y > 0.76] = lin("#6f4a26")
    img[(np.abs(X - 0.5) < (Y - 0.76) * 0.9) & (Y > 0.76)] = lin("#d9b67a")
    return img


def lavender(width, height, seed):
    rng = np.random.default_rng(seed)
    x, X, Y, aspect = plane(width, height)
    img = sky(Y, [(0, "#f2a27a"), (1, "#f7d9a8")], 0.5)
    ground = Y > 0.5
    rows = ((X - rng.uniform(0.3, 0.7)) / np.maximum(Y - 0.5, 1e-3) * 0.5) % 1 < 0.55
    img[ground] = np.where(rows[ground][:, None], lin("#8a4fc0"), lin("#3d5a2a"))
    return img


def aurora(width, height, seed):
    rng = np.random.default_rng(seed)
    x, X, Y, aspect = plane(width, height)
    img = sky(Y, [(0, "#050a1c"), (1, "#0f2a3a")], 0.7)
    img += np.exp(-((Y - (0.32 + 0.08 * np.sin(X * 6 + rng.uniform(0, 6)))) / 0.08) ** 2)[..., None] * lin("#39e09a") * 0.9
    img[Y > hills(x, rng, 0.72, 0.04)[None, :]] = lin("#0a1420")
    return img


SCENES = {"peaks": peaks, "forest": forest, "village": village, "night": night, "frozen": frozen, "beach": beach,
          "meadow": meadow, "dunes": dunes, "city": city, "autumn": autumn, "lavender": lavender, "aurora": aurora,
          "dusk": lambda width, height, seed: w.dusk(width, height)}
# The owner's photos in the library, and where each one's landscape crop is centred, as a share of its height.
OWN = {"DSC02372.jpg": 0.33, "IMG_3557.jpg": 0.36, "DSC03201 (2).jpg": 0.6, "DSC00983.jpg": 0.36, "DSC00973.jpg": 0.32,
       "DSC03230 (2).jpg": 0.45, "DSC04319.jpg": 0.42, "DSC02005.jpg": 0.4, "DSC01584 (2).jpg": 0.45,
       "DSC03301 (2).jpg": 0.42, "DSC01300.jpg": 0.5, "DSC03213.jpg": 0.45, "DSC01898.jpg": 0.55}


class Shot(NamedTuple):
    """A photo in the library: a drawn scene and its seed, or one of the owner's photos; its name; and the
    catalog's rating, pick and colour label for it."""
    source: str
    seed: int
    name: str
    rating: int = 0
    pick: bool = False
    label: str | None = None


def shoots(runs, first, seed):
    """Photos in capture order, from runs of (scene or photo, frames), named on from DSC0`first`, each given the
    catalog's marks as a photographer's catalog has them: about half rated, a quarter picked, a third labelled."""
    rng = np.random.default_rng(seed)
    out = []
    for source, frames in runs:
        for _ in range(frames):
            rating = int(rng.choice(6, p=[0.4, 0.05, 0.1, 0.2, 0.15, 0.1]))
            label = [None, "yellow", "green", "blue", "purple"][rng.choice(5, p=[0.68, 0.08, 0.08, 0.08, 0.08])]
            out.append(Shot(source, len(out) + seed, f"DSC0{first + len(out)}.ARW", rating, bool(rng.random() < 0.25),
                            label))
    return out


# The library's first page, in capture order: a few frames from each shoot, the owner's photos among them.
LIBRARY = shoots([("beach", 3), ("DSC02372.jpg", 1), ("meadow", 2), ("IMG_3557.jpg", 1), ("city", 3),
                  ("DSC03201 (2).jpg", 1), ("dusk", 1), ("autumn", 2), ("DSC00983.jpg", 1), ("DSC00973.jpg", 1),
                  ("peaks", 2), ("DSC03230 (2).jpg", 1), ("lavender", 2), ("DSC04319.jpg", 1), ("dunes", 2),
                  ("aurora", 2), ("DSC02005.jpg", 1), ("DSC01584 (2).jpg", 1), ("forest", 1), ("DSC03301 (2).jpg", 1),
                  ("beach", 2), ("DSC01300.jpg", 1), ("meadow", 1), ("DSC03213.jpg", 1), ("DSC01898.jpg", 1),
                  ("village", 2), ("city", 2), ("autumn", 2), ("lavender", 1), ("dunes", 1), ("aurora", 1),
                  ("beach", 1), ("meadow", 2)], 1204, 12)
# The photo selected in the library, and the catalog's marks it gets.
LIBRARY[0] = LIBRARY[0]._replace(rating=4, pick=True, label="green")
# The photos SNOW finds, in capture order.
RESULTS = shoots([("peaks", 3), ("forest", 2), ("village", 2), ("night", 2), ("frozen", 2), ("peaks", 2), ("forest", 3),
                  ("village", 2), ("night", 2), ("peaks", 2), ("frozen", 2), ("forest", 2), ("village", 2),
                  ("night", 2), ("peaks", 2)], 7412, 41)
# What each letter typed finds: the first page of its results and how many there are. Under three letters
# the text is matched against folders, cameras, lenses, creators and places, so S still finds most of the
# library; SNO finds the snorkelling photos too, and SNOW only snow.
SNORKEL = shoots([("beach", 3)], 9030, 77)
FOUND = {
    "": (LIBRARY, 1_000_000),
    "S": ([shot for i, shot in enumerate(LIBRARY) if i % 3 != 1], 612_431),
    "SN": ([RESULTS[i // 5 * 3 + (0, 0, 1, 2, 0)[i % 5]] if i % 5 in (0, 2, 3) else LIBRARY[i] for i in range(30)], 41_836),
    "SNO": ([SNORKEL[i // 9] if i % 9 == 4 else RESULTS[i - i // 9 - (i % 9 > 4)] for i in range(30)], 8_407),
    "SNOW": (RESULTS, 7_902),
}

FOLDERS = [("2022", 231_408), ("2023", 247_915), ("2024", 262_377), ("2025", 258_300)]
COLLECTIONS = ["BEST OF 2024", "FAMILY", "PORTFOLIO", "PRINTS", "WEDDINGS"]
KEYWORDS = [("BIRDS", 3_120), ("FOOD", 4_870), ("PEOPLE", 9_486), ("SNOW", 7_902), ("STREET", 21_530),
            ("SUNSET", 5_214), ("TRAVEL", 18_215)]
# The report: what came across, in the catalog's own numbers.
REPORT = [("RATINGS", 48_215), ("PICKS", 12_904), ("LABELS", 6_377), ("KEYWORDS", 1_248), ("COLLECTIONS", 86)]
CATALOG = "CATALOG.LRCAT"


@cache
def drawn(source, seed, size):
    """A scene or one of the owner's photos at `size`, drawn larger and reduced, as the eye saw it."""
    if source in SCENES:
        up = 3 if size[0] < 60 else 2
        return encode(SCENES[source](size[0] * up, size[1] * up, seed)).resize(size, Image.BOX)
    img = Image.open(w.SOCIAL / "photos" / source).convert("RGB")
    iw, ih = img.size
    ch = round(iw * size[1] / size[0])
    top = int(np.clip(OWN[source] * ih - ch / 2, 0, ih - ch))
    return img.crop((0, top, iw, top + ch)).resize(size, Image.BOX)


LOUPE = w.Rect(GRID.x + 4, GRID.y + 33, GRID.w - 8, 89)
PICTURE = (DEVELOP.w - 8, DEVELOP.h - 16)
HISTOGRAM = (60, 40)


@cache
def palette():
    """The library's own colours: every picture the video shows, reduced by median cut, the drawn scenes to 40
    colours and the owner's photos to 24 of their own, so his streets and skin keep their warm tones."""
    shots = sorted({shot for shots_, _ in FOUND.values() for shot in shots_}, key=lambda s: (s.source, s.seed))
    scenes = [drawn(s.source, s.seed, THUMB) for s in shots if s.source in SCENES]
    scenes += [drawn(s.source, s.seed, (100, 56)) for s in RESULTS[:16]]
    own = [drawn(name, 0, (60, 36)) for name in OWN]

    def cut(images, colors):
        sheet = Image.new("RGB", (sum(i.width for i in images), max(i.height for i in images)))
        x = 0
        for i in images:
            sheet.paste(i, (x, 0))
            x += i.width
        flat = sheet.quantize(colors=colors, method=Image.Quantize.MEDIANCUT).getpalette()[: colors * 3]
        return [tuple(flat[i:i + 3]) for i in range(0, len(flat), 3)]

    return list(dict.fromkeys(cut(scenes, 40) + cut(own, 24)))


@cache
def picture(shot, size):
    """A photo at `size` as pixel art in the library's colours, dithered a little once it's large."""
    return w.lock(drawn(shot.source, shot.seed, size), palette(), dither=0.0 if size[0] < 40 else 0.3).convert("RGB")


# ---------------------------------------------------------------- the keys

class Key(NamedTuple):
    """A key in the keyboard panel: its legend, what it shows (a label beside it) and each (down, up) of its
    presses."""
    legend: str
    label: str | None
    presses: tuple


TAP = 0.25


def tap(legend, beat, label=None):
    return Key(legend, label, ((beat, beat + TAP),))


s1, s2, s3, s4 = (CUE[f"step{i}"] for i in range(1, 5))
STOP = CUE["result"] - 0.5
# The catalog's card comes up with the words, a copy leaves it a beat later and lands on the next.
LEAVES, LANDS = s1 + 1, s1 + 2
# Each count of the report lands half a beat after the one before, the first half a beat into the bar.
COUNTED = [s2 + 0.5 * (k + 1) for k in range(len(REPORT))]
RATED, PICKED, LABELLED, KEYWORDED, COLLECTED = COUNTED
# SNOW is typed a letter a beat from the fourth bar's first beat. The right arrow goes down on the fifth bar's
# first beat and steps the selection every sixteenth until it comes up at the stop; E shows the loupe a beat
# in and D Develop a beat later.
TYPED = [tap(letter, s3 + i) for i, letter in enumerate("SNOW")]
RIGHT = Key("→", None, ((s4, STOP),))
LOUPE_KEY, DEVELOP_KEY = tap("E", s4 + 1, "LOUPE"), tap("D", s4 + 2, "DEVELOP")
STEPS = [float(b) for b in np.arange(s4, STOP, 0.25)]
BARS = [(s3, TYPED), (s4, [RIGHT, LOUPE_KEY, DEVELOP_KEY])]
CAPTIONS = [(s1, ["BRING YOUR", "LIGHTROOM CATALOG"]), (s2, ["RATINGS, KEYWORDS", "AND COLLECTIONS"]),
            (s3, ["SEARCH A MILLION", "PHOTOS IN 0.2 MS"]), (s4, ["HOLD AN ARROW KEY", "NO BLANK FRAMES"]),
            (CUE["result"], ["YOUR LIBRARY"]), (CUE["flip"], ["YOUR LIBRARY", "WITH YOUR CATALOG"])]
APPEAR = 6 / w.PER_BEAT


def down(key, b):
    return any(d <= b < u for d, u in key.presses)


def shown(key, b):
    return b >= key.presses[0][0]


def query_at(b):
    return "".join(k.legend for k in TYPED if shown(k, b))


def selected_at(b):
    """The result selected at beat b: the first, then one on for each step of the held arrow."""
    return sum(1 for step in STEPS if step <= b)


def marks_at(b):
    """The catalog's marks shown on the thumbnails at beat b, each from its count's landing."""
    return {mark for mark, at in (("stars", RATED), ("flags", PICKED), ("labels", LABELLED)) if b >= at}


# ---------------------------------------------------------------- the grid

STAR = [".#.", "###", ".#."]
FLAG = ["##.", "###", "##.", "#.."]
MAGNIFIER = [".###...", "#...#..", "#...#..", "#...#..", ".###...", "....#..", ".....#."]


def cell(c, x, y, shot, marks, selected):
    """A thumbnail in its frame, the frame in the photo's label colour once labels have come across, a pick's
    flag at its corner and its stars under it; the selected one ringed in the system accent."""
    if selected:
        c.box(x - 1, y - 1, FRAME[0] + 2, FRAME[1] + 2, "sky")
    c.box(x, y, *FRAME, shot.label if "labels" in marks and shot.label else "white" if selected else "line")
    c.img.paste(picture(shot, THUMB), (x + 1, y + 1))
    if "flags" in marks and shot.pick:
        c.sprite(x + 2, y + 2, FLAG, {"#": "white"}, outline="shadow")
    if "stars" in marks:
        for i in range(shot.rating):
            c.sprite(x + i * 4, y + FRAME[1] + 1, STAR, {"#": "gold"})


def thumbnails(c, r, shots, marks, selected=None, rows=5):
    """The grid: `rows` rows of the shots in capture order under the count and the filter bar."""
    x0 = r.x + (r.w - (COLUMNS * PITCH[0] - 2)) // 2
    y0 = r.y + 33
    for i, shot in enumerate(shots[: rows * COLUMNS]):
        cell(c, x0 + (i % COLUMNS) * PITCH[0], y0 + (i // COLUMNS) * PITCH[1], shot, marks, i == selected)


def count(c, r, query, view):
    """The photos the filter finds, as the filter bar counts them: all of them, or so many of the million; and
    the view at the right."""
    found, total = FOUND[query][1], FOUND[""][1]
    x = r.x + 4
    x += c.text(x, r.y + 4, f"{found:,}", "white", font="large") + 4
    c.text(x, r.y + 6, f"OF {total:,}" if query else "PHOTOS", "dim" if query else "sky")
    c.text(READ_RIGHT, r.y + 6, view, "dim", align="right")


def filter_bar(c, r, query, b, focused):
    """The filter bar: the magnifier, what's typed in the large font with the caret on for the first half of
    each beat, or the source it searches."""
    c.rect(*r, "shadow")
    c.box(*r, "sky" if focused else "line")
    c.sprite(r.x + 3, r.y + 3, MAGNIFIER, {"#": "sky" if focused else "dim"})
    if query:
        caret = r.x + 13 + c.text(r.x + 13, r.y + 3, query, "white", font="large") + 2
    else:
        c.text(r.x + 14, r.y + 4, "SEARCH ALL PHOTOGRAPHS", "dim")
        caret = r.x + 13
    if focused and b % 1 < 0.5:
        c.vline(caret, r.y + 2, 9, "sky")


def library(c, r, b, *, query, marks, selected=None, focused=False, rows=5, view="GRID"):
    """The grid panel: the count, the filter bar and the grid."""
    p = c.panel(*r)
    count(c, r, query, view)
    filter_bar(c, w.Rect(p.x, r.y + 15, p.w, 13), query, b, focused)
    thumbnails(c, r, FOUND[query][0], marks, selected, rows)


# ---------------------------------------------------------------- the left panel

def section(c, x, y, wd, title, colour):
    c.text(x, y, title, colour)
    c.hline(x, y + 7, wd, "line")
    return y + 10


def sources(c, r, b, *, collections, keywords, query="", rows=(3, 4), arrived=(-1.0, -1.0)):
    """The left panel: Folders with their counts; the catalog's collections and keywords, the first `rows` of
    each, once they've come across, developing in from the beats in `arrived`; the keywords the query matches
    lit."""
    p = c.panel(*r)
    y = section(c, p.x, p.y, p.w, "FOLDERS", "orange")
    for name, n in FOLDERS:
        c.rect(p.x, y + 1, 3, 3, "orange")
        c.text(p.x + 6, y, name, "text")
        c.text(p.x2, y, f"{n:,}", "dim", align="right")
        y += 8
    y = section(c, p.x, y + 2, p.w, "COLLECTIONS", "violet")

    def listed(c, y=y):
        for name in COLLECTIONS[: rows[0]]:
            c.rect(p.x, y + 1, 3, 3, "violet")
            c.text(p.x + 6, y, name, "text")
            y += 8

    if collections:
        w.appear(c, w.between(b, arrived[0], arrived[0] + APPEAR), listed)
    y = section(c, p.x, y + rows[0] * 8 + 2, p.w, "KEYWORDS", "cyan")

    def tagged(c, y=y):
        for name, n in KEYWORDS[: rows[1]]:
            lit = bool(query) and query in name
            if lit:
                c.rect(p.x - 2, y - 2, p.w + 4, 9, "line")
            c.rect(p.x, y + 1, 3, 3, "cyan")
            c.text(p.x + 6, y, name, "white" if lit else "text")
            c.text(p.x2, y, f"{n:,}", "text" if lit else "dim", align="right")
            y += 8

    if keywords:
        w.appear(c, w.between(b, arrived[1], arrived[1] + APPEAR), tagged)


# ---------------------------------------------------------------- the catalog

# A catalog file: a page with its corner folded and a band across it, and the lock that says it's only read.
LRCAT = ["ooooooo...", "owwwwwfo..", "owwwwwffo.", "owwwwwoooo", "owwwwwwwwo", "oggggggggo", "oggggggggo",
         "oggggggggo", "owwwwwwwwo", "owwwwwwwwo", "owwwwwwwwo", "owwwwwwwwo", "oooooooooo"]
LRCAT_COLOURS = {"o": "muted", "w": "text", "f": "dim", "g": "gold"}
LOCK = [".###.", "#...#", "#####", "##.##", "#####"]
CARD = w.Rect(GRID.x + 30, GRID.y + 40, 82, 34)
SLOT = w.Rect(BOTTOM.x + 5, BOTTOM.y + 13, 14, 19)


def catalog_card(c, r):
    """The catalog, read and never changed: the file with its lock."""
    c.sprite(r.x, r.y + 1, LRCAT, LRCAT_COLOURS)
    c.sprite(r.x + 7, r.y + 10, LOCK, {"#": "gold"}, outline="shadow")
    c.text(r.x + 17, r.y + 1, "READ,", "white", font="large")
    c.text(r.x + 17, r.y + 11, "NEVER CHANGED", "text")


def card_file():
    """Where the file sits in the catalog's card."""
    return CARD.x + 4, CARD.y + 13


def importing(c, b):
    """Bars 1 and 2's bottom panel, the import: an empty slot until the catalog's copy lands in it."""
    p = c.panel(*BOTTOM, "IMPORT", color="lime")
    if b < LANDS:
        for x0, y0, length, vertical in ((SLOT.x, SLOT.y, SLOT.w, False), (SLOT.x, SLOT.y2 - 1, SLOT.w, False),
                                         (SLOT.x, SLOT.y, SLOT.h, True), (SLOT.x2 - 1, SLOT.y, SLOT.h, True)):
            c.dashes(x0, y0, length, "line", vertical=vertical)
        c.text(SLOT.x2 + 6, p.y + 7, "NO CATALOG CHOSEN", "dim")
    else:
        c.sprite(SLOT.x + 2, SLOT.y + 3, LRCAT, LRCAT_COLOURS)
        c.text(SLOT.x2 + 6, p.y + 6, CATALOG, "white", font="large")
        if b < LANDS + 0.5:
            c.sparkles(SLOT.x - 2, SLOT.y - 2, SLOT.w + 4, SLOT.h + 4, 6, ["lime.light", "white"], seed=int(b * w.PER_BEAT))


def flying(c, b):
    """The catalog's copy on its way from the card to the import's slot, from the beat it leaves to the beat it
    lands, in an arc."""
    if not LEAVES <= b < LANDS:
        return
    t = w.ease(w.between(b, LEAVES, LANDS))
    (x0, y0), (x1, y1) = card_file(), (SLOT.x + 2, SLOT.y + 3)
    x = round(x0 + (x1 - x0) * t)
    y = round(y0 + (y1 - y0) * t - 18 * math.sin(math.pi * t))
    c.sprite(x, y, LRCAT, LRCAT_COLOURS, outline="shadow")


# The report's rows: their marks, in the colours the grid and the left panel give them.
LABELS = ["yellow", "green", "blue", "purple"]


def mark(c, x, y, field):
    if field == "RATINGS":
        c.sprite(x, y + 1, STAR, {"#": "gold"})
    elif field == "PICKS":
        c.sprite(x, y, FLAG, {"#": "white"})
    elif field == "LABELS":
        for i, colour in enumerate(LABELS):
            c.rect(x + i * 2, y + 1, 2, 3, colour)
    else:
        c.rect(x, y + 1, 3, 3, "cyan" if field == "KEYWORDS" else "violet")


def report(c, b):
    """Bar 3's bottom panel: the report, each count rolling up to the catalog's figure over the half beat before
    it lands, in two columns."""
    p = c.panel(*BOTTOM, "REPORT", color="lime", right=CATALOG, right_color="dim")
    columns = [(p.x, p.x + 78), (p.x + 88, p.x2)]
    for i, ((field, n), at) in enumerate(zip(REPORT, COUNTED)):
        x0, x1 = columns[i // 3]
        y = p.y + 1 + (i % 3) * 7
        mark(c, x0, y, field)
        c.text(x0 + 10, y, field, "text" if b >= at else "dim")
        shown_ = round(n * w.ease(w.between(b, at - 0.5, at)))
        c.text(x1, y, f"{shown_:,}", "white" if b >= at else "dim", align="right")


# ---------------------------------------------------------------- the keyboard

def keycap_xs(bar):
    """Where each of a bar's keycaps is, with its label beside it, centred in the keyboard panel."""
    widths = [KEYCAP + (4 + w.FONTS["small"].measure(k.label) if k.label else 0) for k in bar]
    x = BOTTOM.x + (BOTTOM.w - (sum(widths) + 8 * (len(bar) - 1))) // 2
    out = []
    for wd in widths:
        out.append(x)
        x += wd + 8
    return out


def keyboard(c, b):
    """Bars 4 and 5's bottom panel: the bar's keys as they come, each sunk and ringed while it's held, with
    what it shows beside it."""
    p = c.panel(*BOTTOM, "KEYBOARD", color="blue")
    bar = [keys for start, keys in BARS if b >= start][-1]
    y = p.y + (p.h - KEYCAP) // 2
    for key, x in zip(bar, keycap_xs(bar)):
        if not shown(key, b):
            continue
        if down(key, b):
            c.box(x - 2, y - 2, KEYCAP + 4, KEYCAP + 4, "blue.light")
        w.keycap(c, x, y, key.legend, pressed=down(key, b), size=KEYCAP, scale=2)
        if key.label:
            c.text(x + KEYCAP + 4, y + 9, key.label, "white" if down(key, b) else "text")


def search_card(c, r):
    """The search's time: a keystroke's search of the million."""
    c.text(r.cx, r.y + 2, "0.2 MS", "white", font="large", scale=2, align="center")


SEARCH_CARD = w.Rect(GRID.x + 6, GRID.y + 86, 76, 36)


# ---------------------------------------------------------------- the dashboard

def level(c, img):
    c.seg_column(*LEVEL, min(1.0, float(np.asarray(img).mean()) / 255 * 1.3), "gold", seg=2, gap=1)


def dashboard(c, b):
    """Bars 1 to 5: the library or, from D, Develop; the selected photo's histogram and level; and the bottom
    panel's import, report or keyboard."""
    w.header(c, FEATURE)
    query = query_at(b)
    shots = FOUND[query][0]
    chosen = selected_at(b) if b >= s4 else 0
    if b >= DEVELOP_KEY.presses[0][0]:
        img = picture(shots[chosen], PICTURE)
        w.photo_panel(c, DEVELOP, img, b, shots[chosen].name, right="DEVELOP", right_color="sky", horizon=None)
    else:
        sources(c, LEFT, b, collections=b >= COLLECTED, keywords=b >= KEYWORDED, query=query,
                arrived=(COLLECTED, KEYWORDED))
        if b >= LOUPE_KEY.presses[0][0]:
            img = picture(shots[chosen], (LOUPE.w, LOUPE.h))
            p = c.panel(*GRID)
            count(c, GRID, query, "LOUPE")
            filter_bar(c, w.Rect(p.x, GRID.y + 15, p.w, 13), query, b, False)
            c.img.paste(img, (LOUPE.x, LOUPE.y))
        else:
            img = picture(shots[chosen], HISTOGRAM)
            library(c, GRID, b, query=query, marks=marks_at(b), selected=chosen, focused=s3 <= b < s4)
        if s1 <= b < s2:
            w.appear(c, w.between(b, s1, s1 + APPEAR),
                     lambda c: w.card(c, CARD.x, CARD.y, "CATALOG", "gold", catalog_card, w=CARD.w, h=CARD.h))
            if b < s1 + 0.5:
                c.sparkles(CARD.x - 2, CARD.y - 2, CARD.w + 4, CARD.h + 4, 8, ["gold.light", "white"],
                           seed=int(b * w.PER_BEAT))
        if s3 <= b < s4:
            w.appear(c, w.between(b, s3, s3 + APPEAR),
                     lambda c: w.card(c, SEARCH_CARD.x, SEARCH_CARD.y, "SEARCH", "cyan", search_card,
                                      w=SEARCH_CARD.w, h=SEARCH_CARD.h))
    w.histogram(c, img, HIST)
    level(c, img)
    if b < s2:
        importing(c, b)
    elif b < s3:
        report(c, b)
    else:
        keyboard(c, b)
    flying(c, b)
    caption(c, b)
    return []


def whole(c, catalog):
    """The library filling the stage: as it was before the catalog, or with its marks, collections and
    keywords."""
    w.header(c, FEATURE)
    sources(c, RESULT_LEFT, 0, collections=catalog, keywords=catalog, rows=(len(COLLECTIONS), len(KEYWORDS)))
    library(c, RESULT_GRID, 0, query="", marks={"stars", "flags", "labels"} if catalog else set(), rows=8)


def result(c, b):
    """Bar 6: the library as it was before the catalog, then with it on the flip."""
    if b < CUE["flip"]:
        whole(c, False)
        caption(c, b)
        return []
    before = w.canvas()
    whole(before, False)
    caption(before, CUE["flip"] - 0.01)
    whole(c, True)
    caption(c, b)
    w.develop(c, before.img, w.between(b, CUE["flip"], CUE["flip"] + 8 / w.PER_BEAT))
    if b < CUE["flip"] + 1:
        c.sparkles(RESULT_GRID.x, RESULT_GRID.y, RESULT_GRID.w, RESULT_GRID.h, 26, ["gold.light", "white", "sky.light"],
                   seed=int(b * w.PER_BEAT))
    return []


def end_card(c, b):
    """Bars 7 and 8: the lamp comes on with the end line, the call to action from its cue, then the fade."""
    light = math.ceil(6 * w.ease(w.between(b, CUE["endLine"], CUE["endLine"] + 1))) / 6
    w.cta_card(c, EPISODE["endLine"], cta=b >= CUE["cta"], light=light)
    w.fade(c, w.between(b, CUE["fade"], CUE["end"]))
    return []


def caption_at(b):
    """The caption at beat b: the title held from the opener, then each step's words."""
    lines = TITLE
    for start, words in CAPTIONS:
        if b >= start:
            lines = words
    return lines


def caption(c, b):
    """The caption at beat b. YOUR LIBRARY stands on the first row, where it stays when WITH YOUR CATALOG joins it
    on the flip."""
    w.caption(c, caption_at(b), rows=w.CAPTION_ROWS[2] if CUE["result"] <= b < CUE["flip"] else None)


def frame(c, b, hook="a"):
    """The picture at beat b, drawn on c; the hook is the opener's. All pixel art, so no overlays."""
    if b < CUE["result"]:
        return dashboard(c, b)
    if b < CUE["endLine"]:
        return result(c, b)
    return end_card(c, b)


# ---------------------------------------------------------------- its sounds

def pan(x):
    return round((x / w.W - 0.5) * 0.8, 2)


def sounds():
    """Each sound on screen, (beat, kind, pan): the catalog's copy landing in the import, a tick as each count
    of the report lands, every key down and up, panned with its keycap, a soft step each time the held arrow
    moves the selection on, and a tick on the flip."""
    out = [(LANDS, "lands", pan(SLOT.cx))]
    for k, at in enumerate(COUNTED):
        out.append((at, "tick", pan(BOTTOM.x + 50 + 88 * (k // 3))))
    for _, bar in BARS:
        for key, x in zip(bar, keycap_xs(bar)):
            for d, u in key.presses:
                out += [(d, "key", pan(x + KEYCAP // 2)), (u, "key up", pan(x + KEYCAP // 2))]
    out += [(step, "step", pan(GRID.cx)) for step in STEPS]
    out.append((CUE["flip"], "flip", 0.0))
    return sorted(out)


# ---------------------------------------------------------------- the storyboard

def at(b):
    return lambda c: frame(c, b)


PANELS = [
    w.Panel(1, 0.0, at(1.5), " / ".join(TITLE),
            "A boom and an 808 on the first frame, and C minor over a drone on C, the arpeggio pulsing over a kick "
            "muffled as if through a wall. The library: 1,000,000 photos with no stars, flags or labels, the folders "
            "over an empty Collections, and the import waiting."),
    w.Panel(2, 2.4, at(s1 + 2.6), " / ".join(CAPTIONS[0][1]),
            "The riff, the offbeat bass and a half-time beat come in; the catalog's card comes up with the words, a "
            "copy leaves it a beat later and lands in the import on the bar's third beat with a soft drop."),
    w.Panel(3, 4.8, at(s2 + 3.2), " / ".join(CAPTIONS[1][1]),
            "A tick as each count of the report lands, half a beat apart; stars, flags and labels come up on the "
            "thumbnails with theirs, and the keywords and collections fill the left panel."),
    w.Panel(4, 7.2, at(s3 + 3.5), " / ".join(CAPTIONS[2][1]),
            "The full beat and the trance gate come in; a key down and up for S, N, O and W a beat apart, and the "
            "count and the grid narrow with each."),
    w.Panel(5, 9.6, at(s4 + 2.6), " / ".join(CAPTIONS[3][1]),
            "A key for → held from the bar's first beat to the stop, a soft step every sixteenth, and a key for E and "
            "D on the next two beats; toms fall from E flat to G into the stop, and the riff's B holds through it."),
    w.Panel(6, 12.0, at(CUE["flip"] + 0.6), "YOUR LIBRARY, then YOUR LIBRARY / WITH YOUR CATALOG at 13.2 s",
            "The drop on C: the boom, the 808, a trailer's low brass, the choir and the sting; a tick and a burst of "
            "sparkles as the catalog's marks come up on the flip."),
    w.Panel(7, 14.4, at(CUE["cta"] + 0.5), " / ".join(EPISODE["endLine"]) + ", then " + " / ".join(w.END_CARD),
            "The closing phrase over A flat and G7(b9), rising through B to C on the last hit."),
    w.Panel(8, 16.8, at(CUE["fade"] + 1), " / ".join(w.END_CARD), "The last chord dies away as the picture fades."),
]
