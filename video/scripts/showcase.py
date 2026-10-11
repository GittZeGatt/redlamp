#!/usr/bin/env python3
"""Lays out an edit showcase: an Instagram carousel from one raw and its Redlamp recipe.

Every picture on the slides is Redlamp's own render of the raw, made here with the `redlamp` CLI, and
the panels are drawn from the recipe's values, so what a slide says is what made the picture. The plan
is plans/2026-10-11-edit-showcases.md in the private redlamp-social repository. There are two kinds:
a film look (the default), six slides with the raw in four of Redlamp's film looks, and an edit flow,
the edit shown panel by panel.

    video/scripts/showcase.py ~/src/redlamp-social/work/showcases/s01

The CLI is build/cli/redlamp in this checkout, or REDLAMP_CLI. The folder holds `showcase.json`; a
film look's:

    {"raw": "~/src/redlamp-social/photos/DSC02372.ARW",
     "recipe": "recipe.json",              the edit (a sidecar's edit.json, or a bare recipe)
     "looks": ["portra-400", ...],         the four film looks, by their Film Stocks slug
     "best": "portra-400",                 the look shown full size
     "frameTop": 0.1,                      where the 4:5 frame sits in the 2:3 photo, 0 top to 1 bottom
     "gridFrame": [0.5, 0.05, 0.8],        the film looks' frame: centre x, top, width (shares of the photo)
     "caption": "One sentence on the photo and its look.",
     "trademarks": "Kodak, Portra ... are trademarks of their owners. Redlamp isn't affiliated with them.",
     "hashtags": ["#rawediting", ...],
     "alt": ["Slide 1's alt text.", ...],
     "post": "Where and when it goes out, for post.txt."}

An edit flow's has "kind": "flow" and no looks: the cover, the before and after, one slide per step,
each the raw rendered with the edit up to and including that step's panels under those panels drawn
with their values, then the finished photo and the call to action, at most ten slides:

    {"kind": "flow", "raw": ..., "recipe": "recipe.json", "frameTop": 0.3,
     "steps": [["basic"], ["toneCurve"], ["mixer", "grading"]],   optional: by default one step per
                                           panel the edit uses, in the app's order (FLOW_PANELS)
     "remove": {"args": ["--remove-brush", "0.33,0.28,0.33,0.70,0.018", "--generative", "7"],
                "rows": [["Spots", "1 brush stroke"], ["Fill", "Generative"]],   Remove, with the CLI
                "caption": "the microphone stand, with generative fill"},
     "masks": [{"kind": "subject", "name": "Subject", "invert": false, "bitmap": "mask.png",
                "adjustments": {"local.exposure": 0.4}}],          AI masks, added with --mask, or
                                           --mask-bitmap from a `redlamp mask` PNG; the Masking
                                           step shows the recipe's own masks (gradients) first
     "panelAt": {"toneCurve": "top"},      where a step's panels sit, bottom by default
     "stepFrameTop": 0.5,                  the step slides' frameTop, when the panels need the photo higher
     "caption": ..., "hashtags": [...], "alt": [...], "post": ...}

The folder is the showcase's work folder, ~/src/redlamp-social/work/showcases/<id>/: it keeps `renders/`
(the CLI's renders and the recipes that made them) and `contact.jpg`. The package the owner posts from,
~/src/redlamp-social/showcases/<id>/, gets `slide-1.jpg` onwards at 1080 x 1350, `caption.txt`, and
`alt.txt` and `post.txt` when the spec has them. `--layout-only` reuses the renders.
"""

import argparse
import json
import math
import os
import subprocess
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

REPO = Path(__file__).resolve().parents[2]
CLI = Path(os.environ.get("REDLAMP_CLI", REPO / "build/cli/redlamp"))
FONT = REPO / "video/public/fonts/InterVariable.woff2"
ICON = REPO / "docs/brand/images/app-icon.png"

W, H = 1080, 1350
MARGIN = 64
RENDER_EDGE = 2048

PAPER = (243, 238, 232)
WALL = (10, 7, 7)

# Redlamp's neutral greys on dark (PaletteTokens.standard in RedlampDesign), as white over the panel.
PANEL = (29, 29, 29)
LABEL = 0.72
SECONDARY = 0.45
VALUE = 0.9
DIVIDER = 0.07
TRACK = 0.16
TRACK_FILL = 0.55
THUMB = (235, 235, 235)

BASIC = [
    ("wb.temperature", "Temp"), ("wb.tint", "Tint"),
    ("basic.exposure", "Exposure"), ("basic.contrast", "Contrast"),
    ("basic.highlights", "Highlights"), ("basic.shadows", "Shadows"),
    ("basic.whites", "Whites"), ("basic.blacks", "Blacks"),
    ("basic.vibrance", "Vibrance"), ("basic.saturation", "Saturation"),
]
CURVE = [("toneCurve.highlights", "Highlights"), ("toneCurve.lights", "Lights"),
         ("toneCurve.darks", "Darks"), ("toneCurve.shadows", "Shadows")]
RANGES = {"wb.temperature": (2000, 50000), "wb.tint": (-150, 150), "basic.exposure": (-5, 5)}
BANDS = ["red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"]


# Rendering


def read_recipe(path):
    data = json.loads(Path(path).read_text())
    return data["recipe"] if "recipe" in data else data


def stock(slug):
    """A Film Stocks recipe from the CLI's catalogue: its name, Base Look and settings."""
    out = subprocess.run([str(CLI), "recipe", "show", f"stock/{slug}"], check=True, capture_output=True, text=True)
    return json.loads(out.stdout)


def look_recipe(edit, film):
    """The edit's crop and exposure, with the film look's Base Look and its own settings (grain, halation)."""
    values = dict(film.get("settings", {}).get("values", {}))
    for key in ("basic.exposure",):
        if key in edit["values"]:
            values[key] = edit["values"][key]
    recipe = {key: edit[key] for key in ("version", "processVersion", "crop", "orientation") if key in edit}
    recipe.update(treatment="color", whiteBalance="asShot", baseLook=film["baseLook"], values=values)
    return recipe


def before_recipe(edit):
    recipe = {key: edit[key] for key in ("version", "processVersion", "crop", "orientation") if key in edit}
    recipe.update(treatment="color", whiteBalance="asShot",
                  baseLook={"id": "redlamp/base/color", "version": 1, "name": "Redlamp Color", "amount": 100},
                  values={})
    return recipe


def render(raw, recipe, out, extra=()):
    recipe_path = out.with_suffix(".json")
    recipe_path.write_text(json.dumps(recipe, indent=1, sort_keys=True) + "\n")
    subprocess.run([str(CLI), "render", str(raw), "-o", str(out), "--size", str(RENDER_EDGE),
                    "--recipe", str(recipe_path), *extra], check=True, capture_output=True)
    return out


# Drawing


def font(size, weight=500):
    f = ImageFont.truetype(str(FONT), size)
    f.set_variation_by_axes([min(32, max(14, size * 0.75)), weight])
    return f


def text_width(text, f, tracking=0.0):
    if not tracking:
        return f.getlength(text)
    return sum(f.getlength(c) for c in text) + tracking * f.size * (len(text) - 1)


def draw_text(draw, xy, text, f, fill, tracking=0.0, anchor="ls"):
    """Text on its baseline; `anchor` is l, m or r for where x is, with tracking in ems."""
    x, y = xy
    width = text_width(text, f, tracking)
    x -= {"l": 0, "m": width / 2, "r": width}[anchor[0]]
    if not tracking:
        draw.text((x, y), text, font=f, fill=fill, anchor="ls")
        return
    for c in text:
        draw.text((x, y), c, font=f, fill=fill, anchor="ls")
        x += f.getlength(c) + tracking * f.size


def frame(photo, top, size=(W, H)):
    """The photo scaled to the slide's width, with a 4:5 window `top` of the way down the rest."""
    scale = size[0] / photo.width
    scaled = photo.resize((size[0], round(photo.height * scale)), Image.LANCZOS)
    y = round((scaled.height - size[1]) * top)
    return scaled.crop((0, y, size[0], y + size[1]))


def window(photo, cx, top, width, size):
    """A window of the photo, its width a share of the photo's, at the slide's aspect."""
    w = photo.width * width
    h = w * size[1] / size[0]
    x0 = min(max(photo.width * cx - w / 2, 0), photo.width - w)
    y0 = min(photo.height * top, photo.height - h)
    return photo.resize(size, Image.LANCZOS, box=(x0, y0, x0 + w, y0 + h))


def shade(img, top=0, bottom=0, strength=0.55):
    """Darkens the top and bottom edges smoothly, under type."""
    a = np.asarray(img, np.float32)
    y = np.arange(img.height, dtype=np.float32)[:, None]
    k = np.zeros_like(y)
    if top:
        k = np.maximum(k, np.clip(1 - y / top, 0, 1) ** 1.6)
    if bottom:
        k = np.maximum(k, np.clip(1 - (img.height - y) / bottom, 0, 1) ** 1.6)
    a *= (1 - strength * k)[..., None]
    return Image.fromarray(a.clip(0, 255).astype(np.uint8))


def white(alpha):
    return (255, 255, 255, round(255 * alpha))


def formatted(key, value):
    if key == "wb.temperature":
        return f"{int(round(value / 50) * 50)}"
    if key in ("basic.exposure", "local.exposure"):
        return f"+{value:.2f}" if value >= 0.005 else f"{value:.2f}"
    v = int(round(value))
    return f"+{v}" if v > 0 else f"{v}"


def position(key, value):
    lo, hi = RANGES.get(key, (-100, 100))
    if key == "wb.temperature":
        mired_lo, mired_hi = 1e6 / hi, 1e6 / lo
        return 1 - (1e6 / value - mired_lo) / (mired_hi - mired_lo)
    return (value - lo) / (hi - lo)


def parametric(x, values):
    """ToneCurveMath.parametric: the four region sliders shift the curve within their regions."""
    s1 = values.get("toneCurve.split.shadows", 25) / 100
    s2 = values.get("toneCurve.split.midtones", 50) / 100
    s3 = values.get("toneCurve.split.highlights", 75) / 100
    regions = [(values.get("toneCurve.shadows", 0), 0, s1, 0.12), (values.get("toneCurve.darks", 0), s1, s2, 0.16),
               (values.get("toneCurve.lights", 0), s2, s3, 0.16), (values.get("toneCurve.highlights", 0), s3, 1, 0.12)]
    shift = np.zeros_like(x)
    for amount, lower, upper, strength in regions:
        if amount == 0:
            continue
        distance = np.abs(x - (lower + upper) / 2) / max(upper - lower, 0.05)
        weight = np.where(distance < 1, np.cos(np.minimum(distance, 1) * math.pi / 2) ** 2, 0)
        shift += amount / 100 * strength * weight

    def smoothstep(e0, e1, v):
        t = np.clip((v - e0) / (e1 - e0), 0, 1)
        return t * t * (3 - 2 * t)

    return np.clip(x + shift * smoothstep(0, 0.06, x) * smoothstep(1, 0.94, x), 0, 1)


def other_sections(values):
    """The edit's Color Mixer and Color Grading values, as (title, [(label, value)]) for the panel."""
    mixer = []
    for band in BANDS:
        for channel, name in (("hue", "Hue"), ("saturation", "Saturation"), ("luminance", "Luminance")):
            value = values.get(f"mixer.{channel}.{band}", 0)
            if round(value):
                mixer.append((f"{band.title()} {name}", formatted("", value)))
    grading = []
    for region in ("shadows", "midtones", "highlights", "global"):
        if not round(values.get(f"grading.{region}.saturation", 0)) and not round(values.get(f"grading.{region}.luminance", 0)):
            continue
        grading.append((f"{region.title()} Hue", f"{round(values.get(f'grading.{region}.hue', 0))}°"))
        grading.append((f"{region.title()} Saturation", f"{round(values.get(f'grading.{region}.saturation', 0))}"))
        if round(values.get(f"grading.{region}.luminance", 0)):
            grading.append((f"{region.title()} Luminance", formatted("", values[f"grading.{region}.luminance"])))
    if grading:
        if round(values.get("grading.blending", 50)) != 50:
            grading.append(("Blending", f"{round(values['grading.blending'])}"))
        if round(values.get("grading.balance", 0)):
            grading.append(("Balance", formatted("", values["grading.balance"])))
    return [(title, rows) for title, rows in (("Color Mixer", mixer), ("Color Grading", grading)) if rows]


def settings_panel(recipe):
    """The edit's panels (Basic, Tone Curve, and Color Mixer and Color Grading where it uses them), as
    Redlamp draws them in its neutral greys. Returns the panel and its rounded mask."""
    values = recipe["values"]
    defaults = {"wb.temperature": values.get("wb.temperature", 5500)}
    pw, pad = 840, 42
    row, head, line = 46, 64, 40
    others = other_sections(values)
    curve = 200 if others else 220
    column = (pw - 2 * pad - 72) // 2
    curve_block = head + curve + 12 + len(CURVE) * line
    other_block = sum(head + line * len(rows) for _, rows in others)
    lower = max(curve_block, other_block) if others else head + curve
    ph = head + 58 + row * len(BASIC) + 26 + lower + pad - 8
    panel = Image.new("RGB", (pw, ph), PANEL)
    d = ImageDraw.Draw(panel, "RGBA")
    f_head, f_label, f_value = font(29, 600), font(28, 450), font(28, 560)
    f_small, f_small_value = font(26, 450), font(26, 560)

    y = 0
    draw_text(d, (pad, y + 46), "Basic", f_head, white(VALUE))
    y += head
    draw_text(d, (pad, y + 32), "Base Look", f_label, white(LABEL))
    draw_text(d, (pw - pad, y + 32), recipe["baseLook"]["name"], f_value, white(VALUE), anchor="rs")
    y += 58
    track_x0, track_x1 = pad + 200, pw - pad - 116
    for key, label in BASIC:
        value = values.get(key, defaults.get(key, 0))
        cy = y + row / 2
        draw_text(d, (pad, cy + 10), label, f_label, white(LABEL))
        draw_text(d, (pw - pad, cy + 10), formatted(key, value), f_value, white(VALUE), anchor="rs")
        d.rounded_rectangle((track_x0, cy - 2, track_x1, cy + 2), radius=2, fill=white(TRACK))
        px = track_x0 + (track_x1 - track_x0) * position(key, value)
        if key != "wb.temperature":
            zero = track_x0 + (track_x1 - track_x0) * position(key, 0)
            d.line((zero, cy - 7, zero, cy + 7), fill=white(SECONDARY), width=2)
            if abs(px - zero) > 1:
                d.rounded_rectangle((min(px, zero), cy - 2, max(px, zero), cy + 2), radius=2, fill=white(TRACK_FILL))
        d.ellipse((px - 10, cy - 10, px + 10, cy + 10), fill=THUMB, outline=(0, 0, 0, 90), width=1)
        y += row

    y += 26
    d.line((pad, y - 13, pw - pad, y - 13), fill=white(DIVIDER), width=2)
    draw_text(d, (pad, y + 46), "Tone Curve", f_head, white(VALUE))
    gx0, gy0 = pad, y + head
    gx1, gy1 = gx0 + curve, gy0 + curve
    d.rectangle((gx0, gy0, gx1, gy1), fill=(0, 0, 0, 70))
    for i in (1, 2, 3):
        gx = gx0 + curve * i / 4
        gy = gy0 + curve * i / 4
        d.line((gx, gy0, gx, gy1), fill=white(DIVIDER), width=1)
        d.line((gx0, gy, gx1, gy), fill=white(DIVIDER), width=1)
    d.line((gx0, gy1, gx1, gy0), fill=white(TRACK), width=1)
    xs = np.linspace(0, 1, 241)
    ys = parametric(xs, values)
    if recipe.get("pointCurve"):
        pts = sorted(recipe["pointCurve"], key=lambda p: p["x"])
        ys = np.interp(ys, [p["x"] for p in pts], [p["y"] for p in pts])
    d.line([(gx0 + curve * x, gy1 - curve * v) for x, v in zip(xs, ys)], fill=white(VALUE), width=4, joint="curve")

    if others:
        for i, (key, label) in enumerate(CURVE):
            yy = gy1 + 12 + line * i + 30
            draw_text(d, (pad, yy), label, f_small, white(LABEL))
            draw_text(d, (pad + column, yy), formatted(key, values.get(key, 0)), f_small_value, white(VALUE), anchor="rs")
        x0 = pw - pad - column
        yy = y
        for title, rows in others:
            draw_text(d, (x0, yy + 46), title, f_head, white(VALUE))
            yy += head
            for label, text in rows:
                draw_text(d, (x0, yy + 30), label, f_small, white(LABEL))
                draw_text(d, (pw - pad, yy + 30), text, f_small_value, white(VALUE), anchor="rs")
                yy += line
    else:
        lx, step = gx1 + 40, curve / len(CURVE)
        for i, (key, label) in enumerate(CURVE):
            cy = gy0 + step * (i + 0.5)
            draw_text(d, (lx, cy + 10), label, f_label, white(LABEL))
            draw_text(d, (pw - pad, cy + 10), formatted(key, values.get(key, 0)), f_value, white(VALUE), anchor="rs")

    mask = Image.new("L", panel.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, pw - 1, ph - 1), radius=22, fill=255)
    return panel, mask


def label_pill(img, xy, text, f, tracking=0.12, anchor="l"):
    """A small caps label on a dark, quiet pill."""
    d = ImageDraw.Draw(img, "RGBA")
    tw = text_width(text, f, tracking)
    padx, h = 20, round(f.size * 1.9)
    x, y = xy
    x0 = x if anchor == "l" else x - tw - 2 * padx
    d.rounded_rectangle((x0, y, x0 + tw + 2 * padx, y + h), radius=h // 2, fill=(12, 12, 12, 150))
    draw_text(d, (x0 + padx, y + h / 2 + f.size * 0.36), text, f, PAPER + (240,), tracking)


# Slides


def cover(after, spec):
    img = shade(frame(after, spec["frameTop"]), top=480, strength=0.5)
    d = ImageDraw.Draw(img, "RGBA")
    draw_text(d, (MARGIN, MARGIN + 58), "BEFORE AND AFTER", font(62, 700), PAPER, tracking=0.02)
    draw_text(d, (MARGIN, MARGIN + 112), "IN REDLAMP", font(30, 600), PAPER + (215,), tracking=0.2)
    return img


def before_after(before, after, spec):
    b, a = frame(before, spec["frameTop"]), frame(after, spec["frameTop"])
    img = b.copy()
    img.paste(a.crop((W // 2, 0, W, H)), (W // 2, 0))
    img = shade(img, top=260, strength=0.35)
    d = ImageDraw.Draw(img, "RGBA")
    d.line((W // 2, 0, W // 2, H), fill=PAPER + (230,), width=3)
    f = font(28, 650)
    label_pill(img, (MARGIN - 16, MARGIN - 16), "BEFORE", f)
    label_pill(img, (W - MARGIN + 16, MARGIN - 16), "AFTER", f, anchor="r")
    return img


def settings(after, recipe, spec):
    img = frame(after, spec["frameTop"]).filter(ImageFilter.GaussianBlur(5))
    img = Image.fromarray((np.asarray(img, np.float32) * 0.45).astype(np.uint8)).convert("RGBA")
    panel, mask = settings_panel(recipe)
    shadow = Image.new("RGBA", img.size, (0, 0, 0, 0))
    x, y = (W - panel.width) // 2, (H - panel.height) // 2
    ImageDraw.Draw(shadow).rounded_rectangle((x, y + 10, x + panel.width, y + panel.height + 10), 24, fill=(0, 0, 0, 130))
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(24)))
    img = img.convert("RGB")
    img.paste(panel, (x, y), mask)
    return img


def looks_grid(looks, spec):
    gutter = 6
    cw, ch = (W - gutter) // 2, (H - gutter) // 2
    img = Image.new("RGB", (W, H), WALL)
    cx, top, width = spec["gridFrame"]
    f = font(29, 600)
    for i, (name, photo) in enumerate(looks):
        cell = shade(window(photo, cx, top, width, (cw, ch)), bottom=190, strength=0.55)
        d = ImageDraw.Draw(cell, "RGBA")
        draw_text(d, (34, ch - 34), name, f, PAPER, tracking=0.01)
        img.paste(cell, ((cw + gutter) * (i % 2), (ch + gutter) * (i // 2)))
    return img


def one_look(name, photo, spec):
    img = shade(frame(photo, spec["frameTop"]), top=480, strength=0.5)
    d = ImageDraw.Draw(img, "RGBA")
    draw_text(d, (MARGIN, MARGIN + 26), "FILM LOOK", font(28, 600), PAPER + (200,), tracking=0.2)
    draw_text(d, (MARGIN, MARGIN + 100), name, font(66, 650), PAPER, tracking=0.0)
    return img


def call_to_action():
    y, x = np.mgrid[0:H, 0:W].astype(np.float32)
    cy = 530
    r = np.hypot(x - W / 2, (y - cy) * 1.1) / 620
    glow = np.exp(-(r**2) * 2.2)[..., None]
    base = np.array([38, 28, 27], np.float32) * (1 - y[..., None] / H) + np.array(WALL, np.float32) * (y[..., None] / H)
    a = base + np.array([70, 18, 12], np.float32) * glow * 0.45
    img = Image.fromarray(a.clip(0, 255).astype(np.uint8)).convert("RGBA")
    icon = Image.open(ICON).convert("RGBA").resize((400, 400), Image.LANCZOS)
    img.alpha_composite(icon, ((W - 400) // 2, cy - 200))
    d = ImageDraw.Draw(img, "RGBA")
    draw_text(d, (W / 2, 870), "DOWNLOAD FREE", font(32, 600), PAPER + (200,), tracking=0.22, anchor="ms")
    draw_text(d, (W / 2, 970), "REDLAMP.APP", font(84, 700), PAPER, tracking=0.02, anchor="ms")
    draw_text(d, (W / 2, 1050), "FREE RAW PHOTO EDITOR FOR MAC", font(28, 550), PAPER + (150,), tracking=0.2, anchor="ms")
    return img.convert("RGB")


def contact(slides):
    tw, th, gap = 360, 450, 16
    cols = len(slides) if len(slides) <= 6 else math.ceil(len(slides) / 2)
    rows = math.ceil(len(slides) / cols)
    sheet = Image.new("RGB", (cols * (tw + gap) + gap, rows * (th + gap) + gap), (24, 22, 22))
    for i, s in enumerate(slides):
        sheet.paste(s.resize((tw, th), Image.LANCZOS), (gap + i % cols * (tw + gap), gap + i // cols * (th + gap)))
    return sheet


# Edit flows

# The panels an edit flow shows, in the order the app shows them, and the recipe values each owns.
FLOW_PANELS = [
    ("basic", "Basic", ("wb.", "basic.")),
    ("toneCurve", "Tone Curve", ("toneCurve.",)),
    ("mixer", "Color Mixer", ("mixer.",)),
    ("grading", "Color Grading", ("grading.",)),
    ("remove", "Remove", ()),
    ("masking", "Masking", ()),
    ("detail", "Detail", ("detail.",)),
    ("effects", "Effects", ("effects.",)),
]
PANEL_NAMES = {panel: name for panel, name, _ in FLOW_PANELS}
PRESENCE = [("basic.texture", "Texture"), ("basic.clarity", "Clarity"), ("basic.dehaze", "Dehaze")]
BAND_COLORS = {"red": (226, 72, 66), "orange": (236, 142, 52), "yellow": (232, 206, 64), "green": (92, 178, 84),
               "aqua": (64, 188, 190), "blue": (66, 116, 222), "purple": (146, 96, 214), "magenta": (214, 74, 172)}
EFFECTS = [("Vignette", [("effects.vignette.amount", "Amount"), ("effects.vignette.midpoint", "Midpoint"),
                         ("effects.vignette.roundness", "Roundness"), ("effects.vignette.feather", "Feather"),
                         ("effects.vignette.highlights", "Highlights")]),
           ("Grain", [("effects.grain.amount", "Amount"), ("effects.grain.size", "Size"),
                      ("effects.grain.roughness", "Roughness")])]
DETAIL = [("Sharpening", [("detail.sharpen.amount", "Amount"), ("detail.sharpen.radius", "Radius"),
                          ("detail.sharpen.detail", "Detail"), ("detail.sharpen.masking", "Masking")]),
          ("Noise Reduction", [("detail.noise.luminance", "Luminance"), ("detail.noise.luminanceDetail", "Detail"),
                               ("detail.noise.color", "Color")])]
LOCAL = [("local.temperature", "Temp"), ("local.tint", "Tint"), ("local.exposure", "Exposure"),
         ("local.contrast", "Contrast"), ("local.highlights", "Highlights"), ("local.shadows", "Shadows"),
         ("local.whites", "Whites"), ("local.blacks", "Blacks"), ("local.texture", "Texture"),
         ("local.clarity", "Clarity"), ("local.dehaze", "Dehaze"), ("local.saturation", "Saturation")]
FLOW_RANGES = {"effects.vignette.midpoint": (0, 100), "effects.vignette.feather": (0, 100),
               "effects.vignette.highlights": (0, 100), "effects.grain.amount": (0, 100),
               "effects.grain.size": (0, 100), "effects.grain.roughness": (0, 100),
               "detail.sharpen.amount": (0, 150), "detail.sharpen.radius": (0.5, 3), "detail.sharpen.detail": (0, 100),
               "detail.sharpen.masking": (0, 100), "detail.noise.luminance": (0, 100),
               "detail.noise.luminanceDetail": (0, 100), "detail.noise.color": (0, 100),
               "grading.blending": (0, 100), "local.exposure": (-4, 4)}
STEP_DEFAULTS = {"effects.vignette.midpoint": 50, "effects.vignette.feather": 50, "effects.grain.size": 25,
                 "effects.grain.roughness": 50, "detail.sharpen.radius": 1, "detail.sharpen.detail": 25,
                 "grading.blending": 50}


def grey(alpha):
    """White at `alpha` over the panel, as an opaque colour, so text and lines blend the same."""
    return tuple(round(c + (255 - c) * alpha) for c in PANEL)


def panel_of(key):
    for panel, _, prefixes in FLOW_PANELS:
        if key.startswith(prefixes):
            return panel
    raise SystemExit(f"{key} isn't in any panel an edit flow shows")


def flow_steps(edit, spec):
    """The steps, each a list of panels: the spec's, or one per panel the edit uses."""
    if spec.get("steps"):
        return spec["steps"]
    used = {panel_of(key) for key in edit["values"]}
    if edit.get("pointCurve"):
        used.add("toneCurve")
    if flow_masks(edit, spec):
        used.add("masking")
    if spec.get("remove"):
        used.add("remove")
    used.add("basic")
    return [[panel] for panel, _, _ in FLOW_PANELS if panel in used]


def step_recipe(edit, panels):
    """The edit with only the given panels' settings, on Redlamp's defaults (the crop stays)."""
    recipe = before_recipe(edit)
    if "basic" in panels:
        recipe.update({key: edit[key] for key in ("treatment", "whiteBalance", "baseLook") if key in edit})
    recipe["values"] = {key: value for key, value in edit["values"].items() if panel_of(key) in panels}
    if "toneCurve" in panels and edit.get("pointCurve"):
        recipe["pointCurve"] = edit["pointCurve"]
    if "masking" in panels and edit.get("masks"):
        recipe["masks"] = edit["masks"]
    return recipe


def flow_masks(edit, spec):
    """Every mask the edit shows: the recipe's own (gradients, brushes), then the spec's AI masks."""
    masks = [{"name": m.get("name", "Mask"), "adjustments": m.get("adjustments", {}), "invert": m.get("inverted"),
              "recipe": m} for m in edit.get("masks", [])]
    return masks + [{**m, "name": m.get("name", m["kind"].title())} for m in spec.get("masks", [])]


def coverage_job(edit, spec, panels, mask):
    """The recipe and CLI arguments that render one mask's coverage."""
    recipe = step_recipe(edit, panels)
    if "recipe" in mask:
        recipe["masks"] = [mask["recipe"]]
        return recipe, ["--coverage"]
    recipe.pop("masks", None)
    return recipe, mask_args([mask], 0)


def mask_args(masks, coverage_of=None):
    """The CLI arguments that add the spec's AI masks; with `coverage_of`, only that mask, as its coverage."""
    args = []
    for i, mask in enumerate(masks):
        if coverage_of is not None and i != coverage_of:
            continue
        if mask.get("bitmap"):
            args += ["--mask-bitmap", f"{mask['kind']}={Path(mask['bitmap']).expanduser()}"]
        else:
            args += ["--mask", mask["kind"]]
        for key, value in mask.get("adjustments", {}).items():
            args += ["--mask-set", f"{key}={value}"]
        if mask.get("invert"):
            args.append("--mask-invert")
    return args + (["--coverage"] if coverage_of is not None else [])


def step_args(spec, panels):
    """The CLI arguments for the steps' Remove spots and masks, which the recipe JSON doesn't carry."""
    args = list(spec["remove"]["args"]) if "remove" in panels else []
    return args + (mask_args(spec.get("masks", [])) if "masking" in panels else [])


def value_text(key, value):
    """A slider's value as the inspector shows it: signed when the slider has a centre, plain when it starts at 0."""
    if key != "wb.temperature" and FLOW_RANGES.get(key, RANGES.get(key, (-100, 100)))[0] >= 0:
        return f"{round(value, 1):g}"
    return formatted(key, value)


def slider(d, box, label, key, value, f_label, f_value, lo=None, hi=None, text=None):
    """One slider as the inspector draws it, compactly: its label and value above its track."""
    x0, y0, x1 = box
    if lo is None:
        lo, hi = FLOW_RANGES.get(key, RANGES.get(key, (-100, 100)))
    if text is None:
        text = value_text(key, value)
    draw_text(d, (x0, y0 + 28), label, f_label, grey(LABEL))
    draw_text(d, (x1, y0 + 28), text, f_value, grey(VALUE), anchor="rs")
    cy = y0 + 50
    d.rounded_rectangle((x0, cy - 2, x1, cy + 2), radius=2, fill=grey(TRACK))
    t = position(key, value) if key == "wb.temperature" else (value - lo) / (hi - lo)
    px = x0 + (x1 - x0) * min(max(t, 0), 1)
    if key != "wb.temperature":
        origin = STEP_DEFAULTS.get(key, min(max(0, lo), hi))
        zero = x0 + (x1 - x0) * (origin - lo) / (hi - lo)
        d.line((zero, cy - 7, zero, cy + 7), fill=grey(SECONDARY), width=2)
        if abs(px - zero) > 1:
            d.rounded_rectangle((min(px, zero), cy - 2, max(px, zero), cy + 2), radius=2, fill=grey(TRACK_FILL))
    d.ellipse((px - 9, cy - 9, px + 9, cy + 9), fill=THUMB, outline=(0, 0, 0, 90), width=1)


SLIDER_ROW = 70


def slider_grid(d, x0, x1, y, items, values, columns=2, gutter=56):
    """Sliders in columns, filled down each column; returns the height used."""
    f_label, f_value = font(26, 450), font(26, 560)
    per = math.ceil(len(items) / columns)
    width = (x1 - x0 - gutter * (columns - 1)) / columns
    for i, (key, label) in enumerate(items):
        cx = x0 + (width + gutter) * (i // per)
        value = values.get(key, STEP_DEFAULTS.get(key, 0))
        slider(d, (cx, y + SLIDER_ROW * (i % per), cx + width), label, key, value, f_label, f_value)
    return SLIDER_ROW * per


def card(pw, height):
    panel = Image.new("RGB", (pw, height), PANEL)
    return panel, ImageDraw.Draw(panel, "RGBA")


PAD, HEAD = 40, 62


def basic_card(recipe, pw):
    values = recipe["values"]
    items = BASIC[:8] + [item for item in PRESENCE if round(values.get(item[0], 0))] + BASIC[8:]
    defaults = {"wb.temperature": values.get("wb.temperature", 5500)}
    rows = math.ceil(len(items) / 2)
    panel, d = card(pw, HEAD + 50 + SLIDER_ROW * rows + PAD - 14)
    draw_text(d, (PAD, 46), "Basic", font(29, 600), grey(VALUE))
    draw_text(d, (PAD, HEAD + 30), "Base Look", font(26, 450), grey(LABEL))
    draw_text(d, (pw - PAD, HEAD + 30), recipe["baseLook"]["name"], font(26, 560), grey(VALUE), anchor="rs")
    slider_grid(d, PAD, pw - PAD, HEAD + 46, items, {**defaults, **values})
    return panel


def tone_curve_card(recipe, pw):
    values = recipe["values"]
    size = 270
    panel, d = card(pw, HEAD + size + PAD)
    draw_text(d, (PAD, 46), "Tone Curve", font(29, 600), grey(VALUE))
    gx0, gy0 = PAD, HEAD + 4
    gx1, gy1 = gx0 + size, gy0 + size
    d.rectangle((gx0, gy0, gx1, gy1), fill=(0, 0, 0, 70))
    for i in (1, 2, 3):
        d.line((gx0 + size * i / 4, gy0, gx0 + size * i / 4, gy1), fill=grey(DIVIDER), width=1)
        d.line((gx0, gy0 + size * i / 4, gx1, gy0 + size * i / 4), fill=grey(DIVIDER), width=1)
    d.line((gx0, gy1, gx1, gy0), fill=grey(TRACK), width=1)
    xs = np.linspace(0, 1, 241)
    ys = parametric(xs, values)
    points = sorted(recipe.get("pointCurve") or [], key=lambda p: p["x"])
    if points:
        ys = np.interp(ys, [p["x"] for p in points], [p["y"] for p in points])
    d.line([(gx0 + size * x, gy1 - size * v) for x, v in zip(xs, ys)], fill=grey(VALUE), width=4, joint="curve")
    for p in points:
        px, py = gx0 + size * p["x"], gy1 - size * p["y"]
        d.ellipse((px - 7, py - 7, px + 7, py + 7), fill=THUMB, outline=(0, 0, 0, 120), width=1)
    x0 = gx1 + 56
    slider_grid(d, x0, pw - PAD, gy0 - 6 + (size - SLIDER_ROW * 4) / 2, CURVE, values, columns=1)
    return panel


def mixer_card(recipe, pw):
    values = recipe["values"]
    channels = [(c, n) for c, n in (("hue", "Hue"), ("saturation", "Saturation"), ("luminance", "Luminance"))]
    line = 46
    panel, d = card(pw, HEAD + 40 + line * len(channels) + PAD - 10)
    draw_text(d, (PAD, 46), "Color Mixer", font(29, 600), grey(VALUE))
    f_label, f_value = font(26, 450), font(26, 560)
    x0 = PAD + 190
    col = (pw - PAD - x0) / len(BANDS)
    for i, band in enumerate(BANDS):
        cx, cy = x0 + col * (i + 0.5), HEAD + 18
        d.ellipse((cx - 11, cy - 11, cx + 11, cy + 11), fill=BAND_COLORS[band])
    for j, (channel, name) in enumerate(channels):
        y = HEAD + 40 + line * j + 32
        draw_text(d, (PAD, y), name, f_label, grey(LABEL))
        for i, band in enumerate(BANDS):
            value = round(values.get(f"mixer.{channel}.{band}", 0))
            text = formatted("", value)
            draw_text(d, (x0 + col * (i + 0.5), y), text, f_value, grey(VALUE if value else SECONDARY * 0.8), anchor="ms")
    return panel


def wheel(diameter, hue, saturation):
    """A grading wheel as the inspector draws it: hue round the rim, grey at the centre, and its puck."""
    r = diameter / 2
    y, x = np.mgrid[0:diameter, 0:diameter].astype(np.float32) + 0.5
    dx, dy = x - r, r - y
    angle = np.degrees(np.arctan2(dy, dx)) % 360
    dist = np.hypot(dx, dy) / r
    # HSV at saturation 0.75 and brightness 0.85, as RGBA.wheelHue draws the rim, dimmed for the slide.
    k = (np.array([5, 3, 1], np.float32) + (angle / 60)[..., None]) % 6
    rgb = 0.85 - 0.85 * 0.75 * np.clip(np.minimum(k, 4 - k), 0, 1)
    rgb = rgb * 0.62
    grey = 0.5 * 0.62
    mix = np.clip(dist, 0, 1)[..., None]
    rgb = grey * (1 - mix) + rgb * mix
    alpha = np.clip((1 - dist) * r + 0.5, 0, 1)
    img = Image.fromarray(np.dstack([rgb * 255, alpha * 255]).clip(0, 255).astype(np.uint8), "RGBA")
    d = ImageDraw.Draw(img, "RGBA")
    d.line((r - 6, r, r + 6, r), fill=(0, 0, 0, 110), width=2)
    d.line((r, r - 6, r, r + 6), fill=(0, 0, 0, 110), width=2)
    a = math.radians(hue)
    px, py = r + math.cos(a) * saturation / 100 * r, r - math.sin(a) * saturation / 100 * r
    k = (np.array([5, 3, 1]) + hue / 60) % 6
    puck = 0.95 - 0.95 * saturation / 100 * np.clip(np.minimum(k, 4 - k), 0, 1)
    d.ellipse((px - 12, py - 12, px + 12, py + 12), fill=(0, 0, 0, 90))
    d.ellipse((px - 10, py - 10, px + 10, py + 10), fill=tuple(int(c * 255) for c in puck), outline=(255, 255, 255), width=3)
    return img


def grading_card(recipe, pw):
    values = recipe["values"]
    regions = ["shadows", "midtones", "highlights"]
    if round(values.get("grading.global.saturation", 0)):
        regions.append("global")
    col = (pw - 2 * PAD) / len(regions)
    diameter = min(160, int(col - 40))
    lines = 2 + any(round(values.get(f"grading.{r}.luminance", 0)) for r in regions)
    panel, d = card(pw, HEAD + diameter + 22 + 36 * lines + 10 + SLIDER_ROW + PAD - 14)
    draw_text(d, (PAD, 46), "Color Grading", font(29, 600), grey(VALUE))
    f_name, f_small = font(26, 560), font(24, 450)
    for i, region in enumerate(regions):
        cx = PAD + col * (i + 0.5)
        hue, sat = values.get(f"grading.{region}.hue", 0), values.get(f"grading.{region}.saturation", 0)
        img = wheel(diameter, hue, sat)
        panel.paste(img, (round(cx - diameter / 2), HEAD + 6), img)
        y = HEAD + 6 + diameter + 40
        draw_text(d, (cx, y), region.title(), f_name, grey(VALUE), anchor="ms")
        draw_text(d, (cx, y + 36), f"Hue {round(hue) % 360}°  Sat {round(sat)}", f_small, grey(LABEL), anchor="ms")
        if lines == 3:
            lum = values.get(f"grading.{region}.luminance", 0)
            draw_text(d, (cx, y + 72), f"Luminance {formatted('', lum)}", f_small, grey(LABEL), anchor="ms")
    y = HEAD + 6 + diameter + 22 + 36 * lines + 10
    slider_grid(d, PAD, pw - PAD, y, [("grading.blending", "Blending"), ("grading.balance", "Balance")], values)
    return panel


def groups_card(title, groups, values, pw):
    used = [(name, items) for name, items in groups if any(round(values.get(k, STEP_DEFAULTS.get(k, 0)), 2)
                                                           != STEP_DEFAULTS.get(k, 0) for k, _ in items)]
    height = HEAD + sum(44 + SLIDER_ROW * math.ceil(len(items) / 2) for _, items in used) + PAD - 14
    panel, d = card(pw, height)
    draw_text(d, (PAD, 46), title, font(29, 600), grey(VALUE))
    y = HEAD
    for name, items in used:
        draw_text(d, (PAD, y + 30), name, font(26, 560), grey(SECONDARY + 0.2))
        y += 44 + slider_grid(d, PAD, pw - PAD, y + 40, items, values)
    return panel


def masking_card(mask, pw):
    adjustments = mask.get("adjustments", {})
    items = [(k, l) for k, l in LOCAL if k in adjustments]
    columns = 3 if len(items) > 4 else 2
    rows = math.ceil(len(items) / columns)
    panel, d = card(pw, HEAD + SLIDER_ROW * rows + PAD - 20)
    draw_text(d, (PAD, 46), "Masking", font(29, 600), grey(VALUE))
    name = mask["name"] + (" (inverted)" if mask.get("invert") else "")
    draw_text(d, (pw - PAD, 46), name, font(27, 560), grey(VALUE), anchor="rs")
    slider_grid(d, PAD, pw - PAD, HEAD - 4, items, adjustments, columns=columns, gutter=44)
    return panel


def remove_card(remove, pw):
    rows = remove["rows"]
    panel, d = card(pw, HEAD + 50 * len(rows) + PAD - 18)
    draw_text(d, (PAD, 46), "Remove", font(29, 600), grey(VALUE))
    for i, (label, text) in enumerate(rows):
        draw_text(d, (PAD, HEAD + 32 + 50 * i), label, font(26, 450), grey(LABEL))
        draw_text(d, (pw - PAD, HEAD + 32 + 50 * i), text, font(26, 560), grey(VALUE), anchor="rs")
    return panel


def panel_cards(panel, recipe, spec, pw):
    if panel == "basic":
        return [basic_card(recipe, pw)]
    if panel == "toneCurve":
        return [tone_curve_card(recipe, pw)]
    if panel == "mixer":
        return [mixer_card(recipe, pw)]
    if panel == "grading":
        return [grading_card(recipe, pw)]
    if panel == "remove":
        return [remove_card(spec["remove"], pw)]
    if panel == "masking":
        return [masking_card(mask, pw) for mask in flow_masks(recipe, spec)]
    if panel == "detail":
        return [groups_card("Detail", DETAIL, recipe["values"], pw)]
    return [groups_card("Effects", EFFECTS, recipe["values"], pw)]


def overlay(photo, coverage):
    """The mask's red overlay, as the app shows it, over the photo."""
    a = np.asarray(photo, np.float32)
    m = np.asarray(coverage.convert("L").resize(photo.size, Image.LANCZOS), np.float32)[..., None] / 255 * 0.5
    return Image.fromarray((a * (1 - m) + np.array([230, 30, 30], np.float32) * m).clip(0, 255).astype(np.uint8))


def paste_card(img, c, x, y):
    """A panel's card, its rounded corners clipped, composited onto an RGBA slide."""
    mask = Image.new("L", c.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, c.width - 1, c.height - 1), radius=22, fill=255)
    img.paste(c.convert("RGBA"), (x, y), mask)


def step_slide(photo, cards, number, count, spec, at="bottom"):
    img = frame(photo, spec.get("stepFrameTop", spec["frameTop"]))
    gap, edge = 16, 40
    total = sum(c.height for c in cards) + gap * (len(cards) - 1)
    if at == "bottom":
        img = shade(img, top=300, bottom=total + 240, strength=0.45).convert("RGBA")
        y = H - edge - total
    else:
        img = shade(img, top=total + 240, bottom=300, strength=0.45).convert("RGBA")
        y = edge
    shadow = Image.new("RGBA", img.size, (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    positions = []
    for c in cards:
        x = (W - c.width) // 2
        sd.rounded_rectangle((x, y + 8, x + c.width, y + c.height + 8), 24, fill=(0, 0, 0, 120))
        positions.append((x, y))
        y += c.height + gap
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(20)))
    for c, (x, yy) in zip(cards, positions):
        paste_card(img, c, x, yy)
    img = img.convert("RGB")
    label_y = MARGIN - 16 if at == "bottom" else H - MARGIN - 40
    label_pill(img, (MARGIN - 16, label_y), f"STEP {number} OF {count}", font(26, 650))
    return img


def masks_slide(overlays, names, cards, number, count, spec):
    """Several masks: each one's overlay side by side, over their cards."""
    img = Image.new("RGB", (W, H), WALL)
    gap, edge = 16, 40
    total = sum(c.height for c in cards) + gap * (len(cards) - 1)
    top = MARGIN + 60
    cw = (W - 2 * edge - gap * (len(overlays) - 1)) // len(overlays)
    ch = min(round(cw * 5 / 4), H - edge - total - 28 - top)
    cw_frame = round(ch * 4 / 5) if ch < round(cw * 5 / 4) else cw
    top += (H - edge - total - 28 - top - ch) // 2
    size = 26
    while size > 16 and max(text_width(n.upper(), font(size, 650), 0.12) for n in names) + 40 > cw_frame - 32:
        size -= 1
    f = font(size, 650)
    cx, frame_top, width = spec.get("maskFrame", [0.5, 0.0, 1.0])
    for k, (photo, name) in enumerate(zip(overlays, names)):
        cell = window(photo, cx, frame_top, width, (cw_frame, ch))
        x = edge + k * (cw + gap) + (cw - cw_frame) // 2
        mask = Image.new("L", cell.size, 0)
        ImageDraw.Draw(mask).rounded_rectangle((0, 0, cell.width - 1, cell.height - 1), radius=18, fill=255)
        img.paste(cell, (x, top), mask)
        label_pill(img, (x + 16, top + 16), name.upper(), f)
    y = H - edge - total
    img = img.convert("RGBA")
    for c in cards:
        paste_card(img, c, (W - c.width) // 2, y)
        y += c.height + gap
    img = img.convert("RGB")
    label_pill(img, (MARGIN - 16, MARGIN - 16), f"STEP {number} OF {count}", font(26, 650))
    return img


def flow_caption(edit, spec, steps):
    values = edit["values"]
    lines = [spec["caption"], "", "The settings, panel by panel:"]
    for panel in [p for step in steps for p in step]:
        name = PANEL_NAMES[panel]
        if panel == "basic":
            items = [f"Base Look {edit['baseLook']['name']}"]
            items += [f"{label} {formatted(key, values[key])}" for key, label in BASIC[:8] + PRESENCE + BASIC[8:]
                      if key in values and formatted(key, values[key]) not in ("0", "0.00")]
        elif panel == "toneCurve":
            items = [f"{label} {formatted(key, values[key])}" for key, label in CURVE if round(values.get(key, 0))]
            if edit.get("pointCurve"):
                items.append("Point Curve " + " ".join(f"({round(p['x'] * 255)}, {round(p['y'] * 255)})"
                                                     for p in edit["pointCurve"]))
        elif panel in ("mixer", "grading"):
            items = [f"{label} {text}" for title, rows in other_sections(values) if title == name for label, text in rows]
        elif panel == "remove":
            items = [spec["remove"]["caption"]]
        elif panel == "masking":
            for mask in flow_masks(edit, spec):
                adjust = mask.get("adjustments", {})
                items = [f"{label} {formatted(key, adjust[key])}" for key, label in LOCAL
                         if key in adjust]
                lines.append(f"Masking, {mask['name']}: " + ", ".join(items))
            continue
        else:
            groups = DETAIL if panel == "detail" else EFFECTS
            items = [f"{group} {label} {value_text(key, values[key])}" for group, keys in groups for key, label in keys
                     if key in values and round(values[key], 2) != STEP_DEFAULTS.get(key, 0)]
        lines.append(f"{name}: " + ", ".join(items))
    lines += ["", "Redlamp is a free raw photo editor for Mac, with Lightroom's layout and shortcuts.",
              "Download it at redlamp.app (link in bio).",
              "Needs an Apple Silicon Mac with macOS 26. It's in early development."]
    if spec.get("trademarks"):
        lines += ["", spec["trademarks"]]
    lines += ["", " ".join(spec["hashtags"])]
    return "\n".join(lines) + "\n"


def flow_slides(raw, edit, spec, renders, layout_only):
    steps = flow_steps(edit, spec)
    masks = flow_masks(edit, spec)
    if len(steps) + 4 > 10:
        raise SystemExit(f"{len(steps)} steps make more than ten slides; group the smaller panels in `steps`")
    jobs = {"before": (before_recipe(edit), [])}
    done = []
    for i, step in enumerate(steps, 1):
        done += step
        jobs[f"step-{i}"] = (step_recipe(edit, done), step_args(spec, done))
    jobs.update({f"mask-{j}": coverage_job(edit, spec, done, mask) for j, mask in enumerate(masks)})
    photos = {}
    for name, (recipe, extra) in jobs.items():
        out = renders / f"{name}.png"
        if not (layout_only and out.exists()):
            render(raw, recipe, out, extra)
            print(f"rendered {out.name}")
        photos[name] = Image.open(out).convert("RGB")
    after = photos[f"step-{len(steps)}"]
    slides = [cover(after, spec), before_after(photos["before"], after, spec)]
    pw = W - 2 * 40
    for i, step in enumerate(steps, 1):
        photo, cards = photos[f"step-{i}"], []
        for panel in step:
            cards += panel_cards(panel, edit, spec, pw)
        at = spec.get("panelAt", {}).get(step[0], "bottom")
        if "masking" in step and len(masks) > 1:
            overlays = [overlay(photo, photos[f"mask-{j}"]) for j in range(len(masks))]
            slides.append(masks_slide(overlays, [m["name"] for m in masks], cards, i,
                                      len(steps), spec))
            continue
        if "masking" in step:
            photo = overlay(photo, photos["mask-0"])
        slides.append(step_slide(photo, cards, i, len(steps), spec, at))
    slides += [frame(after, spec["frameTop"]), call_to_action()]
    return slides, flow_caption(edit, spec, steps)


# Caption


def caption(recipe, spec, best_name):
    values = recipe["values"]
    lines = [spec["caption"], "", "The settings:", f"Base Look: {recipe['baseLook']['name']}"]
    for key, label in BASIC:
        if key in values and formatted(key, values[key]) not in ("0", "0.00"):
            lines.append(f"{label} {formatted(key, values[key])}")
    curve = [f"{label} {formatted(key, values[key])}" for key, label in CURVE if round(values.get(key, 0))]
    if curve:
        lines.append("Tone Curve: " + ", ".join(curve))
    for title, rows in other_sections(values):
        lines.append(f"{title}: " + ", ".join(f"{label} {text}" for label, text in rows))
    lines.append(f"Film look on slide 5: {best_name}")
    lines += ["", "Redlamp is a free raw photo editor for Mac, with Lightroom's layout and shortcuts.",
              "Download it at redlamp.app (link in bio).",
              "Needs an Apple Silicon Mac with macOS 26. It's in early development.", "",
              spec["trademarks"], "", " ".join(spec["hashtags"])]
    return "\n".join(lines) + "\n"


# Only what's posted goes in a showcase's package, which the owner sends to his phone; the renders,
# recipes and contact sheet stay in its work folder.
SOCIAL = Path(os.environ.get("REDLAMP_SOCIAL", Path.home() / "src" / "redlamp-social")).expanduser()
PACKAGES = SOCIAL / "showcases"


def look_slides(raw, edit, spec, renders, layout_only):
    films = {slug: stock(slug) for slug in dict.fromkeys(spec["looks"] + [spec["best"]])}
    jobs = {"before": before_recipe(edit), "after": edit}
    jobs.update({f"look-{slug}": look_recipe(edit, film) for slug, film in films.items()})
    photos = {}
    for name, recipe in jobs.items():
        out = renders / f"{name}.png"
        if not (layout_only and out.exists()):
            render(raw, recipe, out)
            print(f"rendered {out.name}")
        photos[name] = Image.open(out).convert("RGB")

    looks = [(films[s]["baseLook"]["name"], photos[f"look-{s}"]) for s in spec["looks"]]
    best = films[spec["best"]]["baseLook"]["name"]
    slides = [
        cover(photos["after"], spec),
        before_after(photos["before"], photos["after"], spec),
        settings(photos["after"], edit, spec),
        looks_grid(looks, spec),
        one_look(best, photos[f"look-{spec['best']}"], spec),
        call_to_action(),
    ]
    return slides, caption(edit, spec, best)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("folder", type=Path)
    parser.add_argument("--layout-only", action="store_true", help="reuse the renders in renders/")
    args = parser.parse_args()
    folder = args.folder.expanduser().resolve()
    spec = json.loads((folder / "showcase.json").read_text())
    raw = Path(os.path.expanduser(spec["raw"]))
    edit = read_recipe(folder / spec["recipe"])
    renders = folder / "renders"
    renders.mkdir(exist_ok=True)

    make = flow_slides if spec.get("kind", "look") == "flow" else look_slides
    slides, text = make(raw, edit, spec, renders, args.layout_only)
    if spec.get("alt") and len(spec["alt"]) != len(slides):
        raise SystemExit(f"{len(slides)} slides but {len(spec['alt'])} alt texts")
    package = PACKAGES / folder.name
    package.mkdir(parents=True, exist_ok=True)
    for old in package.glob("slide-*.jpg"):
        old.unlink()
    for i, slide in enumerate(slides, 1):
        slide.save(package / f"slide-{i}.jpg", quality=95, subsampling=0)
    contact(slides).save(folder / "contact.jpg", quality=90)
    (package / "caption.txt").write_text(text)
    if spec.get("alt"):
        (package / "alt.txt").write_text("\n".join(f"Slide {i}: {text}" for i, text in enumerate(spec["alt"], 1)) + "\n")
    if spec.get("post"):
        (package / "post.txt").write_text(spec["post"].rstrip("\n") + "\n")
    print(f"wrote {len(slides)} slides, caption.txt, alt.txt and post.txt to {package}, and contact.jpg to {folder}")


if __name__ == "__main__":
    main()
