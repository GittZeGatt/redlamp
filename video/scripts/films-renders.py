#!/usr/bin/env python3
"""Renders the film looks reel's photos: every one of Redlamp's 36 film looks, each on its photo, with the
`redlamp` CLI, cropped to 9:16 before it develops so the grain is at the reel's own scale.

    video/scripts/films-renders.py             the looks and the hook's plain photo, into public/films/
    video/scripts/films-renders.py --frames    each photo whole, with its 9:16 crop outlined, for framing
    video/scripts/films-renders.py --sheet     the looks as a contact sheet, for the review notes

The photos and their crops are in src/films/photos.json and the looks, in the order the reel shows them,
in src/films/looks.json; the plan, with each photo's source and licence, is plans/2026-10-11-film-looks-reel.md
in the private redlamp-social repository. The owner's raws are in its photos/ folder; the CC0 photos are
fetched from Wikimedia Commons into its work/reels/films/photos/ when they're missing. A render is made
again only when its recipe changes. The CLI is build/cli/redlamp in this checkout, or REDLAMP_CLI.
"""

import argparse
import json
import os
import subprocess
import urllib.request
from pathlib import Path

from PIL import Image, ImageDraw

VIDEO = Path(__file__).resolve().parents[1]
REPO = VIDEO.parent
CLI = Path(os.environ.get("REDLAMP_CLI", REPO / "build/cli/redlamp"))
SOCIAL = Path(os.environ.get("REDLAMP_SOCIAL", Path.home() / "src/redlamp-social"))
WORK = SOCIAL / "work/reels/films"
OUT = VIDEO / "public/films"
W, H = 1080, 1920
PLAIN = {"id": "redlamp/base/color", "version": 1, "name": "Redlamp Color", "amount": 100}


def load(name):
    return json.loads((VIDEO / "src/films" / name).read_text())


def source(photo):
    """The photo's file: an owner's raw in the social repository, or a CC0 photo fetched from Commons."""
    if "file" in photo:
        return Path(photo["file"]).expanduser()
    path = WORK / "photos" / f"{photo['id']}.jpg"
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        request = urllib.request.Request(photo["url"], headers={"User-Agent": "RedlampPromo/1.0 (https://redlamp.app)"})
        path.write_bytes(urllib.request.urlopen(request, timeout=120).read())
    return path


def oriented_size(photo):
    """The photo's width and height as its orientation shows it, from a small render."""
    preview = WORK / "frames" / f"{photo['id']}-whole.jpg"
    if not preview.exists():
        render(source(photo), recipe(photo, PLAIN, {}, crop=False), preview, 1600)
    with Image.open(preview) as im:
        return im.size


def crop_rect(photo):
    """The 9:16 crop, from its centre and its width as shares of the photo, kept inside the frame."""
    width, height = oriented_size(photo)
    cx, cy, share = photo["crop"]
    w = share
    h = share * width * H / W / height
    if h > 1:
        w, h = w / h, 1.0
    left = min(max(cx - w / 2, 0), 1 - w)
    top = min(max(cy - h / 2, 0), 1 - h)
    return {"left": round(left, 5), "top": round(top, 5), "right": round(left + w, 5), "bottom": round(top + h, 5)}


def stock(slug, cache={}):
    """A Film Stocks recipe from the CLI's catalogue: its Base Look, process version and settings."""
    if slug not in cache:
        out = subprocess.run([str(CLI), "recipe", "show", f"stock/{slug}"], check=True, capture_output=True, text=True)
        cache[slug] = json.loads(out.stdout)
    return cache[slug]


def recipe(photo, base_look, settings, crop=True, process=None):
    """The photo's own exposure and tone, with a look's Base Look and its settings (grain, halation)."""
    values = dict(settings)
    values.update(photo.get("values", {}))
    out = {"version": 1, "treatment": "color", "whiteBalance": "asShot", "baseLook": base_look, "values": values}
    if process is not None:
        out["processVersion"] = process
    if crop:
        out["crop"] = crop_rect(photo)
    return out


def render(raw, recipe, out, size=H):
    """Renders `raw` with `recipe` to `out`, unless the recipe beside it is the same as last time."""
    out.parent.mkdir(parents=True, exist_ok=True)
    recipe_path, key_path = out.with_suffix(".json"), out.with_suffix(".key")
    key = json.dumps({"source": str(raw), "size": size, "recipe": recipe}, sort_keys=True)
    if out.exists() and key_path.exists() and key_path.read_text() == key:
        return out
    recipe_path.write_text(json.dumps(recipe, indent=1, sort_keys=True) + "\n")
    subprocess.run([str(CLI), "render", str(raw), "-o", str(out), "--size", str(size), "--recipe", str(recipe_path)],
                   check=True, capture_output=True)
    key_path.write_text(key)
    return out


def frames(photos):
    """Each photo whole, with its 9:16 crop outlined, on one sheet."""
    tiles = []
    for photo in photos:
        whole = WORK / "frames" / f"{photo['id']}-whole.jpg"
        oriented_size(photo)
        im = Image.open(whole).convert("RGB")
        im.thumbnail((480, 480))
        c = crop_rect(photo)
        draw = ImageDraw.Draw(im)
        box = [c["left"] * im.width, c["top"] * im.height, c["right"] * im.width - 1, c["bottom"] * im.height - 1]
        draw.rectangle(box, outline=(255, 220, 0), width=3)
        draw.text((6, 6), photo["id"], fill=(255, 220, 0))
        tiles.append(im)
    sheet(tiles, WORK / "frames.jpg", 480, 480)


def sheet(tiles, path, w, h, cols=6):
    rows = (len(tiles) + cols - 1) // cols
    out = Image.new("RGB", (cols * w, rows * h), (10, 7, 7))
    for i, tile in enumerate(tiles):
        out.paste(tile, ((i % cols) * w + (w - tile.width) // 2, (i // cols) * h + (h - tile.height) // 2))
    path.parent.mkdir(parents=True, exist_ok=True)
    out.save(path, quality=88)
    print(path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--frames", action="store_true")
    parser.add_argument("--sheet", action="store_true")
    args = parser.parse_args()
    photos = {photo["id"]: photo for photo in load("photos.json")["photos"]}
    looks = load("looks.json")["looks"]
    if args.frames:
        return frames(list(photos.values()))
    hook = photos[looks[0]["photo"]]
    render(source(hook), recipe(hook, PLAIN, {}), OUT / "plain" / f"{hook['id']}.jpg")
    for i, look in enumerate(looks):
        film = stock(look["slug"])
        photo = photos[look["photo"]]
        render(source(photo), recipe(photo, film["baseLook"], film.get("settings", {}).get("values", {}),
                                     process=film.get("processVersion")), OUT / "looks" / f"{look['slug']}.jpg")
        print(f"{i + 1:2d} {look['slug']} on {photo['id']}")
    if args.sheet:
        tiles = [Image.open(OUT / "looks" / f"{look['slug']}.jpg").resize((270, 480), Image.LANCZOS) for look in looks]
        sheet(tiles, WORK / "contact.jpg", 270, 480)


if __name__ == "__main__":
    main()
