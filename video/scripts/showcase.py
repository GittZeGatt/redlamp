#!/usr/bin/env python3
"""Lays out an edit showcase: a six-slide Instagram carousel from one raw and its Redlamp recipe.

Every picture on the slides is Redlamp's own render of the raw, made here with the `redlamp` CLI, and
the settings slide is drawn from the recipe's values, so what a slide says is what made the picture.
The plan is plans/2026-10-11-edit-showcases.md in the private redlamp-social repository.

    video/scripts/showcase.py ~/src/redlamp-social/work/showcases/s01

The folder holds `showcase.json`:

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

The folder is the showcase's work folder, ~/src/redlamp-social/work/showcases/<id>/: it keeps `renders/`
(the CLI's renders and the recipes that made them) and `contact.jpg`. The package the owner posts from,
~/src/redlamp-social/showcases/<id>/, gets `slide-1.jpg` to `slide-6.jpg` at 1080 x 1350, `caption.txt`,
and `alt.txt` and `post.txt` when the spec has them. `--layout-only` reuses the renders.
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
CLI = REPO / "build/cli/redlamp"
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


def render(raw, recipe, out):
    recipe_path = out.with_suffix(".json")
    recipe_path.write_text(json.dumps(recipe, indent=1, sort_keys=True) + "\n")
    subprocess.run([str(CLI), "render", str(raw), "-o", str(out), "--size", str(RENDER_EDGE),
                    "--recipe", str(recipe_path)], check=True, capture_output=True)
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
    if key == "basic.exposure":
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
    sheet = Image.new("RGB", (len(slides) * (tw + gap) + gap, th + 2 * gap), (24, 22, 22))
    for i, s in enumerate(slides):
        sheet.paste(s.resize((tw, th), Image.LANCZOS), (gap + i * (tw + gap), gap))
    return sheet


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


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("folder", type=Path)
    parser.add_argument("--layout-only", action="store_true", help="reuse the renders in renders/")
    args = parser.parse_args()
    folder = args.folder.expanduser()
    spec = json.loads((folder / "showcase.json").read_text())
    raw = Path(os.path.expanduser(spec["raw"]))
    edit = read_recipe(folder / spec["recipe"])
    renders = folder / "renders"
    renders.mkdir(exist_ok=True)

    films = {slug: stock(slug) for slug in dict.fromkeys(spec["looks"] + [spec["best"]])}
    jobs = {"before": before_recipe(edit), "after": edit}
    jobs.update({f"look-{slug}": look_recipe(edit, film) for slug, film in films.items()})
    photos = {}
    for name, recipe in jobs.items():
        out = renders / f"{name}.png"
        if not (args.layout_only and out.exists()):
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
    package = PACKAGES / folder.name
    package.mkdir(parents=True, exist_ok=True)
    for i, slide in enumerate(slides, 1):
        slide.save(package / f"slide-{i}.jpg", quality=95, subsampling=0)
    contact(slides).save(folder / "contact.jpg", quality=90)
    (package / "caption.txt").write_text(caption(edit, spec, best))
    if spec.get("alt"):
        (package / "alt.txt").write_text("\n".join(f"Slide {i}: {text}" for i, text in enumerate(spec["alt"], 1)) + "\n")
    if spec.get("post"):
        (package / "post.txt").write_text(spec["post"].rstrip("\n") + "\n")
    print(f"wrote {len(slides)} slides, caption.txt, alt.txt and post.txt to {package}, and contact.jpg to {folder}")


if __name__ == "__main__":
    main()
