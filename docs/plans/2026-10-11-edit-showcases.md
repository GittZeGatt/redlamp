# Edit showcases: the owner's raws, edited in Redlamp

Regular posts in the style photographers use to share their edits: a vibrant photo, a before and after, and the settings that made it. Each one takes one of the owner's raws and his edit, recreated in Redlamp, and shows either how the edit was built, panel by panel, or the raw in Redlamp's film looks, so people see how good a photo Redlamp gives and how simply. They run beside the feature videos (`2026-10-10-feature-videos.md`) and through the same social room (`.cursor/skills/redlamp-social/SKILL.md`), with the same copy rules: simple, direct words and a clear call to action.

## Two kinds

- **Edit flow:** a normal edit, shown the way it was made, panel by panel. The photo builds up one panel at a time, each step showing that panel's own values: Basic, then whichever of Tone Curve, Color Mixer, Color Grading, Masking (a mask and its local adjustments), Detail and Effects the edit uses, in the order the app shows them. No film look is needed; the point is how far Redlamp's ordinary panels take a raw. Most of the owner's own edits are this kind.
- **Film look:** one of Redlamp's film looks leads, with the edit's few other settings, and the same raw in three more looks, as in the first showcase.

A showcase is one kind or the other, chosen for the photo and the edit; a series alternates them.

## Formats

- **Carousel, film look** (Instagram, and TikTok as a photo post): six slides at 4:5, 1080 × 1350.
  1. **Cover:** the finished photo, full bleed, with one line: BEFORE AND AFTER / IN REDLAMP.
  2. **Before and after:** the photo split down the middle, the raw at Redlamp's default settings on the left and the edit on the right, each labelled.
  3. **The settings:** the finished photo, dimmed, under a panel drawn like Redlamp's Basic panel with the edit's own values (the Base Look or film look, Exposure, Contrast, Highlights, Shadows, Whites, Blacks, Temp, Tint, Vibrance, Saturation) and its tone curve.
  4. **Film looks:** the same raw in four of Redlamp's film looks, two by two, each named.
  5. **One look, full size:** the film look that suits the photo best.
  6. **Call to action:** the lamp mark, DOWNLOAD FREE / REDLAMP.APP, and FREE RAW PHOTO EDITOR FOR MAC.
- **Carousel, edit flow:** the cover; the before and after; then one slide for each panel the edit uses, in order, each showing the photo with the edit so far (that panel included) under the panel drawn with its values: Basic, Tone Curve, Color Mixer, Color Grading, Masking (the mask in its red overlay beside its local adjustments), Detail, Effects; then the finished photo; then the call to action. Up to ten slides, so an edit of more than six panels shows the smaller ones together.
- **Reel** (Instagram and TikTok, 9:16, 10 to 15 s). For an edit flow, the photo builds up panel by panel on the beat, each panel's values appearing as an overlay as its step lands, then the before and after as a wipe. For a film look, the reel is the before and after as a wipe on the beat, the settings appearing as overlays one beat at a time (the values, then the curve), the film looks cut on the bar, and the same call to action. It is built in the promo studio from the same renders and values, with a catchy track of its own.

Every picture in the photo is Redlamp's own render of the raw, made with the `redlamp` CLI. The overlays are drawn from the edit's own values, so what the slide says is what made the picture.

## How an edit is recreated

1. The owner shares a raw he owns and his finished edit: the exported JPEG, and his settings if he has them (a Lightroom `.xmp` sidecar imports into Redlamp as a preset, with a report of what came across, as the README describes).
2. Redlamp renders the raw at its defaults, which is the before.
3. The edit is rebuilt in Redlamp: his settings where they import, then crop, tone and colour adjusted with `redlamp render --set …` until Redlamp's render matches his JPEG as closely as it can, measured as the mean colour difference (ΔE in CIELAB) between the two. The values are kept as a Redlamp recipe beside the raw, so the edit can be opened in the app.
4. For an edit flow, the edit is split into its panels in the app's order, and the raw is rendered after each panel, so every step's picture is Redlamp's render of the edit up to that panel. For a film look, the same raw, with the same crop and exposure, is rendered in film looks, and the best four are chosen.
5. A raw without an edit from the owner gets one made in Redlamp, of either kind, which the owner approves before it's posted.

The ΔE is for us, to know how close the recreation is. The slides only show the settings.

## Looks to promote

One film look leads each post, chosen for the photo, so the series works through Redlamp's catalogue: Portra 400, Portra 160, Ektar 100, Gold 200, CineStill 800T, CineStill 50D, Velvia 50, Provia 100F, Kodachrome 64, Tri-X 400, HP5 Plus and the Vision3 cinema looks. Their names appear as the app shows them, with the README's trademark line in the caption, once the owner confirms film stock names may appear on screen.

## Cadence

One showcase a week, on Sundays at 18:00 London time, starting once the first is approved, so the account posts three times a week with the feature videos' Tuesdays and Fridays.

## Captions

One sentence on the photo and the look, the settings as a short list people can copy, then the standard lines from `docs/social/posts.json` (what Redlamp is, the download with "link in bio", the requirements and "It's in early development"), the trademark line, and three to five hashtags.

## What's needed from the owner

- Raws he owns, each with his finished JPEG, and his settings where he has them, in `~/src/redlamp-social/photos/`.
- His word on film stock names on screen (the open "names" item in the room).

## Files

- `video/scripts/showcase.py`: renders a showcase from a raw and its recipe with the CLI, and lays out the carousel's slides.
- `~/src/redlamp-social/showcases/<id>/`: the package the owner posts from, with only what's posted: `slide-1.jpg` to `slide-6.jpg`, `caption.txt`, `alt.txt` (a line per slide) and `post.txt`.
- `~/src/redlamp-social/work/showcases/<id>/`: the showcase's `showcase.json`, its recipe, the CLI's renders and the contact sheet.
- The posts themselves join `docs/social/posts.json` once the room handles carousels.
