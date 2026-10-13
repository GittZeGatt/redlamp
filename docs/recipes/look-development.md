# Look development

How recipes are made, checked and shipped. The format is in [recipe-format.md](recipe-format.md), camera cards in [camera-card-mapping.md](camera-card-mapping.md), the agent studio in [agent-studio.md](agent-studio.md), and measuring phone-app filters with the capture kit in [app-looks.md](app-looks.md).

## The look-development set

`research/look-dev/manifest.json` lists 40 CC0 raw files from raw.pixls.us across 40 camera bodies. They're tagged by scene: landscape, sky, foliage, water, autumn, snow, street, architecture, night, tungsten, low light, high dynamic range, animals, flowers, still life, and a color chart. `mise run lookdev` downloads them into `build/look-dev/` and checks every SHA-256. They are never committed.

**Gap:** raw.pixls.us holds test shots, so there are no portraits. Skin is covered by the lint chart's eight skin patches until own or commissioned CC0 portraits are added.

## The Recipe Lab

In the harness (`mise run harness`), under **Recipes → Recipe Lab**:

- **Gallery.** Every recipe, Base Look and imported LUT, rendered on the chosen look-dev image or the lint chart. It filters by kind, group, tag, lint status and search, and Lightroom's words work in the search: "preset", "profile", "LUT".
- **Compare.** Before and after, A and B side by side, A/B flicker, and one recipe across the whole set. Right-click a tile to make it B.
- **Inspect.** Metadata, the included settings and their values, the camera card, the Base Look's parameters and table statistics (strength, grey chroma, steepest slope, out-of-range entries), the lint results, and the file itself.
- **Create.** Start a new recipe, a new camera card, a duplicate, or an imported `.cube` or HaldCLUT. Pick a Base Look and the settings to include. **Edit in Develop** applies the draft to the harness editor's photo, where the real Develop panels change it, and **Capture from Develop** brings the chosen groups back. The draft previews and lints live, then saves to My Recipes or exports a `.redrecipe`.
- **Runs.** The agent studio's runs; see [agent-studio.md](agent-studio.md).

The Lab renders on its own engine, so it never disturbs the editor's photo. Its views live in `RedlampUI/Sources/Recipes/Lab/`, so the app and a future companion app can host them too.

## The CLI

```bash
redlamp recipe list [--query <text>]
redlamp recipe show <recipe>
redlamp recipe lint all                      # exit 1 if any recipe fails
redlamp recipe render <raw> --recipe <recipe> -o out.jpg [--amount 50]
redlamp recipe contact-sheet --lookdev --original --recipes group:Street -o sheet.jpg
redlamp recipe hald-identity -o identity.png
redlamp recipe import graded.png --name "My Look" --install
redlamp recipe import look.cube -o look.redrecipe
redlamp recipe export <recipe> -o look.redrecipe [--cube look.cube]
redlamp recipe fingerprint ref1.jpg ref2.jpg
redlamp recipe fit --references ref*.jpg [--lut] -o fitted.redrecipe
redlamp recipe build-pack                    # regenerate the bundled film-style Base Looks
redlamp recipe golden [--record]             # this GPU's set of golden renders
```

A `<recipe>` is a path, an id, a bundled slug (`street/gritty`) or a name.

## Making a look in any editor (HaldCLUT)

1. `redlamp recipe hald-identity -o identity.png` writes a 64-point identity table as a 512×512 sRGB image.
2. In any editor (Photoshop, Affinity, Resolve, Capture One), grade a photo, then apply exactly the same adjustments to `identity.png`. Keep it in sRGB, and don't resize, crop or sharpen it.
3. `redlamp recipe import graded.png --name "My Look" --install` turns it into a recipe with an embedded Base Look, converted into Redlamp's space so it renders as graded.

`.cube` files work the same way; they're assumed to be built for sRGB unless you pass `--space rec2020`.

## Measured Base Looks (the profiler)

Hand-designed looks are guesses; film simulations are precise, so the film slots are fitted to cameras' own renderings. Every modern Fujifilm raw file embeds the camera's full-size JPEG, rendered with the film simulation set at capture and named in its EXIF. With a neutral Redlamp render of the same raw, that is an exact before-and-after pair.

```bash
mise run profile-data                          # CC0 pairs from raw.pixls.us into build/profiler (1.4 GB)
redlamp recipe profile [--slots chrome,…] [--install]
```

`research/profiler/fujifilm-pairs.json` keeps one CC0 file per camera and film simulation, and only files whose other settings are neutral (Color, Highlight and Shadow tone 0, dynamic range 100%). For each slot, the profiler:

1. **Renders and extracts.** It renders the raw with Redlamp Color and pulls out the camera JPEG.
2. **Aligns.** It matches scale and offset by correlating luminance edges, because the camera corrects lens distortion and crops slightly.
3. **Samples** colors in flat areas away from edges, clipping and the corners (the camera corrects vignetting), capped per color cell so a big sky can't outvote everything else.
4. **Removes each camera's own exposure and color offset** against the average. Redlamp and each body scale raws slightly differently, by up to ±0.9 EV, and that isn't part of the look.
5. **Fits a smooth 25-point table** with the GPU's own tetrahedral interpolation. It chooses the smoothness by leaving whole scenes out, and takes the most accurate fit that passes the banding and monotonic-lightness lint checks.

Each fit ships as the slot's next Base Look version. Earlier versions stay bundled for the edits that pinned them; menus offer only the newest; the Lab lists every version. Recipes built on a re-measured slot are published as a new version too.

Results (ΔE to the camera JPEG, OKLab × 100, on scenes the fit never saw). The first measured versions used the CC0 pairs alone:

| Slot | Camera film simulation | Scenes | Redlamp Color | Hand-designed v1 | Measured v2 |
| --- | --- | --- | --- | --- | --- |
| `standard` | Provia | 28 | 7.83 | 7.57 | **2.73** |
| `vivid-slide` | Velvia | 10 | 4.45 | 5.51 | **3.39** |
| `chrome` | Classic Chrome | 4 | 6.19 | 6.24 | **3.43** (few scenes: provisional) |

Adding the review-site pairs (`review-pairs.json`, below) gave a larger and harder test set, so the numbers aren't comparable with the table above. On it, the previous version is mostly scored on photos it never saw:

| Slot | Photos (bodies) | Redlamp Color | Previous version | New version | Shipped |
| --- | --- | --- | --- | --- | --- |
| `standard` | 120 (50) | 5.38 | v2 4.21 | **v3 3.26** | yes |
| `chrome` | 18 (5) | 5.72 | v2 5.52 | **v3 4.61** | yes |
| `soft-slide` | 5 (3) | 12.84 | v1 12.77 | **v2 4.57** | yes, provisional |
| `vivid-slide` | 13 (12) | 4.09 | v2 2.84 (seen 10 of 13) | v3 3.19 | no: not shown better |
| `cinema` | 4 (1) | 4.76 | v1 2.69 | v2 0.88 | no: four night scenes only |

The Soft Slide numbers include a large brightness difference between Redlamp and the camera on these bodies (TON-14). The other slots still need data: Eterna has only night scenes; Classic Negative, Nostalgic Negative, Pro Neg and Reala Ace none; Acros none; and the only Monochrome files were toned (Monochromatic Color), which the fetcher now rejects. Twenty to forty varied scenes per simulation, from any Fujifilm body re-rendered in camera or in X RAW Studio, are enough; add them to the manifest and rerun `profile`. The approach isn't Fujifilm-specific: any camera that embeds its own full-size rendering can be profiled the same way.

**Legal check still open:** closely matching a camera maker's rendering is a grey area. The looks keep Redlamp's own slot names.

### More data

Surveyed 2026-09-30 ([TON-20](../research/research-tracker.md#4-color-tone-and-detail)):

- **Review sites publish raw files.** Photography Blog's sample pages link 2,899 Fujifilm RAFs from 48 bodies (X-Pro1 to GFX100RF), each carrying the camera's JPEG. Reviewers shoot the default: 2,860 are Provia, and the rest are 17 Classic Chrome, 6 Astia, 4 Velvia, 4 Eterna (night only), 9 toned Monochrome and one Monochrome + Red. `research/profiler/fetch_review_pairs.py` surveys them (the first 512 KB of each file), selects neutral files (two Provia per body, up to eight of anything else) into `review-pairs.json`, and downloads them into `build/profiler/review/`; `redlamp recipe profile` reads both manifests. The files are copyrighted: they're used as references only, never shipped or committed ([DEC-17](../research/research-tracker.md#1-decisions-and-legal-questions)). Fetchers are slow (about one request a second), resumable, and stop at the first refusal: a faster first survey got us blocked for a while. Imaging Resource, DPReview and ePhotozine refuse automated requests outright.
- **Simulation-to-simulation pairs.** Film-simulation bracketing, and blog posts showing one frame in every simulation, give JPEG pairs with no raw. A simulation can be fitted relative to one already measured (Provia): measured Provia, then the Provia-to-X table. Web-sized, already-clipped JPEGs make these weaker than raw pairs.
- **Recipe cards.** Sites such as filmsimrecipes.com and Fuji X Weekly list settings cards that the `fujifilm-card` dialect imports directly ([DEC-18](../research/research-tracker.md#1-decisions-and-legal-questions)).
- **A camera.** One Fujifilm body for a few days: 30–40 varied raws, each re-rendered in camera through every simulation, is still the cleanest set.

### Fujifilm's published LUTs

Fujifilm publishes 3D LUTs that render F-Log, F-Log2 and F-Log2 C footage in its film simulations, on [its LUT page](https://www.fujifilm-x.com/global/support/download/lut/). Each body's pack holds ETERNA, ETERNA Bleach Bypass and WDR. The GFX ETERNA 55 pack (version 1.10, April 2026) holds F-Log2 and F-Log2 C LUTs, at 33 and 65 points, for PROVIA, Velvia, ASTIA, Classic Chrome, Classic Neg, Reala Ace, PRO Neg Std, ETERNA, Bleach Bypass and ACROS. No pack covers Nostalgic Neg, PRO Neg Hi, Monochrome with a filter, or Sepia.

Fujifilm's terms allow downloads for personal, noncommercial use and forbid modifying them without permission. Users download the LUTs and import them ([TON-43](../research/research-tracker.md#4-color-tone-and-detail)); Redlamp never bundles or re-hosts them, and never fits a look to them ([DEC-73](../research/research-tracker.md#1-decisions-and-legal-questions)).

Probed on 12 October, with the files read in memory and a ColorChecker chart rendered through them and through Redlamp's measured stills looks, middle grey matched:

- **They name themselves.** Comment lines read `#FUJIFILM Corporation`, `#Gamma:F-Log2 to PROVIA` and `#Gamut:F-Gamut to ITU-R BT.709`. 18% grey encodes to 0.391 in F-Log2. Fujifilm's own F-Log2-to-BT.709 conversion passes grey unchanged but isn't a plain matrix, so F-Gamut's primaries come from the data sheet.
- **They render as the X-Trans V bodies do.** The GFX ETERNA 55's ETERNA and Bleach Bypass LUTs match the X100VI's and the X-T5's, which are the same files: within 0.3 L* on a grey scale and a mean ΔE of 0.6–0.7 on the chart. They differ only for extreme colours outside BT.709.
- **They're video renderings.** Shadows and midtones sit within about 3 L* of the measured stills Provia; highlights are softer, reaching white 5.6 to 6.1 stops above middle grey (two stops up, PROVIA reads L* 81 against the stills look's 87).
- **Colour.** Mean ΔE (OKLab × 100) to the measured stills looks: PROVIA 2.1, Classic Chrome 3.5, Velvia 3.0–3.5, ASTIA 4.6–5.3. Against their own PROVIA, the LUTs make Classic Chrome 0.77 as chromatic and Velvia 1.12; the measured looks make them 0.96 and 1.00, which suggests the measured looks miss part of each simulation's character. TON-45 checks it on real photos.
- **Brightness.** Redlamp Color renders scene middle grey at L* 64 and the LUTs at 46–49, and camera-log import adds no offset, so an imported LUT renders about a stop darker without TON-43's exposure offset. Decoding their output as sRGB matched the stills looks as well as Rec.709 at 2.4 gamma, or better.

#### On real photos (TON-45)

`redlamp recipe profile --evaluate <looks>` renders each pair with each look as the app does and scores it against the camera's JPEG on the same flat points: OKLab ΔE × 100 (mean and 90th percentile) and CIEDE2000 (mean and 95th percentile), as rendered and with each photo's exposure matched to the camera's midtones, by processor generation. Given one of Fujifilm's LUTs, it scores the import's every output decoding and exposure offset. Run on 13 October with the GFX ETERNA 55 pack's 65-point F-Log2 LUTs; exposure matched, OKLab:

| Slot | Photos | Fujifilm's LUT (sRGB, +0.9 stops) | Bundled look | Redlamp Color |
| --- | --- | --- | --- | --- |
| `standard` (PROVIA) | 120 | 2.12 | 1.78 (measured on these photos) | 2.41 |
| `vivid-slide` (Velvia) | 13 | 2.28 | 2.40 (measured on most of them) | 3.10 |
| `soft-slide` (ASTIA) | 5 | 2.52 (2.01 at +1.3) | 2.35 (measured on these) | 4.86 |
| `chrome` (Classic Chrome) | 18 | 2.57 | 2.46 (measured on these) | 3.47 |
| `cinema` (ETERNA) | 4 (night) | 0.77 | 2.06 (hand-designed) | 3.84 |

- **The import's defaults.** sRGB decoding beat Rec.709's 2.4 gamma for every simulation, and with +0.9 stops the median photo needed +0.01 EV more for PROVIA, −0.15 for Velvia and +0.11 for Classic Chrome (ASTIA's five photos, from bodies whose brightness differs from Redlamp's, wanted +0.77). Both stay as the import's defaults.
- **How close.** Fujifilm's LUTs are closer to the cameras' JPEGs than Redlamp Color for every simulation, and within about 0.3 of Redlamp's measured looks scored on the photos they were fitted to; for Velvia and ETERNA they're closer. As rendered, before any exposure matching, PROVIA's LUT is the closest of all (3.51, against 3.89 for Redlamp Color and 4.40 for the bundled look).

#### What the fits leave (TON-45)

`redlamp recipe profile --diagnose` fits each slot's table to every photo and reports what's left:

- **The camera adapts to the scene.** For PROVIA (120 photos), the fit leaves a mean ΔE of 1.79, and the camera's colour for the same input colour spreads by a median 2.39 from photo to photo: 95% of samples sit in colour cells that spread more than the fit's error. 88% of what's left is lightness (70–96% for the other slots). It's tone that changes with the scene, which no single table can follow, scene-referred or not (TON-46).
- **Generation, light and ISO hardly matter.** Tables fitted to X-Processor 4 and 5 photos alone differ by 0.81, to daylight and warm light (an as-shot white balance below 4,200 K) by 0.87, and to ISO 800 and below and above by 0.82, all under half the fit's error and about what any two halves of the photos give. Pooling them is right.
- **Raw exposure bias.** Every RAF carries one (tag 0x9650): −0.72 EV on most X-Trans bodies, 0 on the Bayer X-A, X-T100 and X-T200, −0.49 to −1.10 on GFX bodies. It correlates with each body's exposure offset against Redlamp (r = −0.52, slope −0.47 EV per EV), but taking it out narrows the spread between bodies only from 0.235 to 0.201 EV, so it isn't applied.
- **No new CC0 pairs.** raw.pixls.us, rescanned on 13 October, has 152 Fujifilm files, 144 of them CC0, and the same 43 neutral pairs as on 30 September.

## Lint

Five deterministic checks, run on a synthetic chart through the real pipeline. Each compares the recipe's render with a neutral render, with vignette and grain removed:

| Check | Measures | Warn / fail |
| --- | --- | --- |
| `neutral-axis` | Chroma added to the grey ramp | 0.025 / 0.05 |
| `skin-hue` | Hue shift of eight skin patches, weighted by their chroma | 10° / 20° |
| `monotonic-luminance` | Largest lightness drop as the ramp brightens | 0.004 / 0.012 |
| `banding` | Abrupt contrast changes along smooth gradients (plateaus and jumps) | 2.5 / 4.5 |
| `clipping` | Colors newly clipped to pure black or white | 3% / 10% |

A recipe that deliberately fails a check (a toned black and white, a warm cross-process look) lists it in `lintWaivers`. Lint is a guardrail against broken looks, not a judge of taste. No bundled recipe fails.

## Shipping a recipe

1. Add it to `packages/RedlampRecipes/Sources/StarterPack.swift` with an original name. Never use a photographer's, brand's or film stock's name.
2. `redlamp recipe lint all` must not fail.
3. `redlamp recipe golden --record` records its golden render in the set of the GPU it runs on: `tests/golden/recipes/process-<n>/` on the M1 Ultra, and on any other GPU a folder within it named for that GPU, such as `apple-m4-max/` for the build Mac's. Two GPUs round a few values differently, so each keeps its own set. Existing golden renders are never overwritten, and the tests compare every bundled recipe against its own in the set of the GPU they run on. The build Mac records its own once a gate of the commit has run there (`scripts/build-mac.py gate`); from this Mac's Terminal, this line records what its set lacks, a new process version's whole set included, and copies it into this checkout, to commit with the recipe:

   ```bash
   ssh build-mac 'cd ~/src/build-mac/redlamp-push-gate && build/DerivedData/Build/Products/Debug/redlamp recipe golden --record | grep RECORDED >&2; tar -cf - tests/golden/recipes/process-*/apple-m4-max' | tar -C ~/src/darkroom -xf -
   ```
4. A published recipe never changes. To improve one, publish the same id with `version + 1` and record a golden render for the new version.

The bundled film-style Base Looks are `LookDesign`s in `StarterPackLooks.swift`, turned into 25-point tables by `redlamp recipe build-pack`. A test checks that the shipped tables still match their designs; a changed design must bump the look's version.
