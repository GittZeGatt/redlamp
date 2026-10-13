# Lightroom edits: catalogs, XMP sidecars and versions: design

A photographer moving from Lightroom Classic brings years of edits: a catalog whose photos carry crops, masks, healing, lens and Upright corrections, profiles and white balance, with virtual copies beside them. This design brings those edits into Redlamp, converted once, without writing anything of Lightroom's. Tracker: EDT-23 ([#312](https://github.com/pdcgomes/redlamp/issues/312), a catalog's edits), EDT-12 ([#74](https://github.com/pdcgomes/redlamp/issues/74), XMP sidecars, which share its converter) and EDT-09 ([#71](https://github.com/pdcgomes/redlamp/issues/71), versions, which virtual copies become). It starts from LIB-29's catalog reader (`packages/RedlampLibrary/Sources/Migration/`) and EDT-11's preset converter (`packages/RedlampRecipes/Sources/LightroomPreset*.swift`).

**Status (2026-10-13):** planned. The owner made the decisions below the same day: measured sliders, versions as items of the library, Process 2003 and 2010 converted, and a Redlamp edit kept with Lightroom's beside it as a version. The test catalog waits until the owner has help with Lightroom work, so the work starts from published sources. Nothing is built.

## Where it starts

**LIB-29's reader** reads a copy of the `.lrcat` without writing it (opened immutable; a catalog with a `-wal` log read from a temporary copy; one Lightroom has open refused), matches photos by path, and writes ratings, flags, labels, fields, keywords and collections as the library's keyword and metadata batches, in parts of 10,000 photos with Stop and Undo Import. Of edits it only counts: `LightroomCatalog.edited` is the number of photos whose `Adobe_imageDevelopSettings` row has develop adjustments, and the report lists those photos and the virtual copies (`Adobe_images.masterImage`, `copyName`) as left behind. It doesn't read the settings themselves (`Adobe_imageDevelopSettings.text`), the photo's rotation (`Adobe_images.orientation`), snapshots or history. `LuaTable` already reads Lua table constructors as data, never running them; it was written for smart collections' rules, and develop settings are the same kind of text.

**EDT-11's converter** reads Camera Raw settings from XMP in both RDF forms (`CameraRawSettings`), maps Process 2012 and later global settings through `LightroomPresetMapping` with a mapped, approximated or ignored report, and maps the crop (`LightroomCrop.redlampCrop`) though recipes don't carry it. Three limits matter here: it refuses a photo's sidecar (`isPreset`), refuses process versions before 6.7, and keeps only the count of an array of structures (`.structures(Int)`), so masks and spots can't be read. It makes a `Recipe` of setting groups, not a photo's whole `EditRecipe`. What a preset leaves to each photo (lens, Transform, calibration, crop, masks, spots, profile) is what a photo's edit holds, so most of the new work is there.

**Redlamp's edit already has a place for most of Lightroom's develop module,** under the same names and ranges: crop with angle, rotate and flip (LNS-06); the Transform sliders and Upright, Guided included (LNS-05, LNS-08); lens profile corrections from the file or the user's LCP files, manual distortion and vignetting, Remove Chromatic Aberration and Defringe (LNS-01, LNS-02, LNS-04, LNS-09); the calibration sliders; masks with Lightroom's components (linear, radial, brush, luminance, colour and depth ranges, Subject, Sky, Background, People and their parts, Objects, Landscape; add, subtract, intersect and invert); curves and Point Color inside masks (MSK-20, TON-29); Remove, Heal and Clone spots (RM-01, RM-07); snapshots; and Base Looks named as Adobe's profiles are (Color, Vivid, Portrait, Landscape, Neutral, Monochrome).

**What it lacks becomes the report's "left out",** each with the row that would close it: red, green and blue curves in the global Tone Curve (TON-40, [#379](https://github.com/pdcgomes/redlamp/issues/379)), Lens Blur (OTH-03, [#138](https://github.com/pdcgomes/redlamp/issues/138)), red-eye (OTH-01, [#136](https://github.com/pdcgomes/redlamp/issues/136)), HDR editing (TON-42, [#381](https://github.com/pdcgomes/redlamp/issues/381)), grain inside masks, more than 16 masks or 64 components on one photo, and the pixels Generative Remove made. Lightroom's Intersect may combine masks differently from Redlamp's product (MSK-02, [#48](https://github.com/pdcgomes/redlamp/issues/48); DEC-08).

## One converter for three sources

Lightroom keeps a photo's develop settings in three forms, all with the same Camera Raw setting names: a Lua table in the catalog (`s = { Exposure2012 = 0.35, … }`), an XMP sidecar beside a raw (`IMG_1234.xmp`), and XMP inside a DNG, JPEG, TIFF or HEIC when Lightroom saved metadata to the file.

- **One settings model.** `CameraRawSettings` keeps nested structures and arrays of them (a mask's components, retouch areas, the profile, Upright's guides) instead of a count.
- **Two readers.** XMP, as today, extended to arrays of structures. Lua, from a `LuaTable`: its keys are the setting names, a curve's flat list of numbers becomes x, y pairs, and nested tables become structures.
- **Two conversions on one table.** Presets go on becoming recipes of setting groups, as [Lightroom presets](../recipes/lightroom-presets.md) documents. A photo's settings become a whole `EditRecipe` with the same per-setting report, through `LightroomPresetMapping` for every global setting, so a conversion fitted later (EDT-24) reaches presets, sidecars and catalogs at once.
- **What the conversion needs of the photo:** its pixel size as stored and the camera's orientation (for the crop, masks and spots, which Lightroom places in the stored pixels' 0 to 1 coordinates; to confirm for each kind), whether it is raw or rendered (for white balance), the photo's rotation in the catalog, and whether the file carries a lens correction. The library's index has the size and orientation; the rest is a metadata read, not a decode.
- **Where it lives:** in RedlampRecipes beside EDT-11's converter, with RedlampLibrary taking RedlampRecipes as a dependency in `Tuist/ProjectDescriptionHelpers/Module.swift`, so the catalog's plan converts while it reads. Neither reaches the engine or a UI. The alternative, composing the import in the app and the CLI above both modules, keeps the module graph but splits LIB-29's plan in two.
- **Learnt from files we make, never from Adobe's code** (DEC-51). Setting names are cross-checked against ExifTool's `crs` tag tables, as EDT-11's were. What they mean (coordinate spaces, units, which Lightroom version writes which form) is learnt from a test catalog and XMP files made in Lightroom Classic from fixture, CC0 and synthetic photos, and written down in a format note, `docs/research/notes/EDT-lightroom-develop-settings.md`. Tests use Lua and XMP written from that note.
- **Until the test catalog exists.** The owner can't make it yet (2026-10-13), so the work starts from what's published: ExifTool's tables for the names, Ellis's definition of the crop, and Redlamp's sliders, which follow Lightroom's ranges, defaults and directions. What only Lightroom-made files can settle is built and tested against the documented names, but the import leaves it out, reported as "not yet checked against Lightroom", until a test catalog or a real catalog settles it: where masks and spots sit, Upright's modes and solved transforms, panel switches, and the Process 2003 and 2010 conversion. Lightroom's rotation codes can come from any real catalog: the census pairs each photo's code with its file's EXIF orientation, which the library's index already holds.

## What each edit becomes

| Lightroom | Redlamp | Outcome |
| --- | --- | --- |
| Basic, Presence, Color Mixer, B&W mix, Color Grading, Detail, Effects, the parametric curve and the composite point curve | As EDT-11 maps them ([mapping](../recipes/lightroom-presets.md#mapping)). A photo's settings are complete, so every value is written | Mapped; the B&W mix approximated |
| Red, green and blue point curves | None until TON-40 | Left out when not straight |
| White balance on a raw: As Shot, the named presets, Custom | The same mode; Custom with `Temperature` and `Tint` | Mapped. The same numbers give the same neutral only where Redlamp's temperature and tint agree with Lightroom's for that camera: measured below |
| White balance Auto on a raw | Custom, with the temperature and tint Lightroom's Auto found, where the settings hold them | Approximated: Lightroom's result is kept, not measured again |
| White balance on a JPEG, TIFF or HEIC (`IncrementalTemperature`, `IncrementalTint`) | Red and Blue Shift, as EDT-11 converts them | Approximated |
| Treatment; the profile (`CameraProfile`, `Look` and its amount) | Treatment; the Base Look of the same name (Adobe Color to Color, and Vivid, Portrait, Landscape, Neutral, Monochrome) with its amount; Adobe Standard and the camera-matching profiles to the camera's embedded look where the file has one (TON-09), else the nearest by name; Fujifilm's simulations to Redlamp's film looks of that kind, or to the photographer's imported Fujifilm LUTs (TON-43 to TON-45); creative and third-party profiles to Color | Mapped by name, approximated otherwise. Adobe's profiles are never read or converted |
| Crop and angle | `crop` and `crop.angle`, through `LightroomCrop` | Mapped. Exact when both apps see the same frame: Lightroom's frame is checked against the catalog's own record of the photo's size |
| Rotate and flip (`Adobe_images.orientation`) | `orientation`, after the camera's own | Mapped, once the census settles Lightroom's codes from a real catalog |
| Lens profile corrections and their amounts | `lens.profile`, `lens.profileDistortion`, `lens.profileVignetting`: the correction the file carries, or the photographer's LCP files (LNS-04) | Mapped. Approximated when Lightroom used a profile Redlamp doesn't have; the report says where an LCP can come from |
| Manual distortion and vignetting, Remove Chromatic Aberration, Defringe | `lens.distortion`, `lens.vignetting`, `lens.vignettingMidpoint`, `lens.removeChromaticAberration`, `lens.defringe…` | Mapped, scales to check. Process 2010's manual `ChromaticAberrationR` and `ChromaticAberrationB` are left out |
| Transform sliders | `transform.vertical`, `.horizontal`, `.rotate`, `.aspect`, `.scale`, `.offsetX`, `.offsetY` | Mapped, scales to check |
| Upright, Guided | Redlamp's Guided Upright, solved from the same guides | Approximated, close to exact |
| Upright Auto, Level, Vertical, Full | Redlamp's Upright in the same mode, worked out again from the photo; or Lightroom's solved transform (`UprightTransform_*`), if the format note can say what it holds | Approximated |
| Calibration | `calibration.shadowsTint` and the red, green and blue hue and saturation | Mapped, scales to check |
| Panel switches, if the catalog keeps them | `panelsOff` (UX-30) | To learn from the test catalog |
| Point Color | `pointColor` swatches (TON-29), mapped as TON-34 plans for presets | Mapped or approximated |
| Masks and spots | [Masks](#masks), [Spots](#spots) | |
| Lens Blur, red-eye, HDR editing | None | Left out, with their rows |
| Snapshots | Snapshots, converted the same way | Mapped |
| History steps | None | Left out, counted |
| Virtual copies | Versions (EDT-09) | [Virtual copies as versions](#virtual-copies-as-versions-edt-09) |

### Masks

Lightroom 11 and later keep masks in `MaskGroupBasedCorrections`: each correction is a mask with its sliders, amount, name and visibility, and a list of components that add, subtract or intersect. Earlier versions kept one shape per correction (`GradientBasedCorrections`, `CircularGradientBasedCorrections`, `PaintBasedCorrections`), with range masks beside them. A long-used catalog holds both forms.

| Lightroom component | Redlamp component | Outcome |
| --- | --- | --- |
| Linear Gradient | `linear`, full at Lightroom's full point and none at its zero point | Mapped |
| Radial Gradient | `radial`: centre, radii, rotation, feather, inverted | Mapped; feather's falloff to check |
| Brush | `brush` strokes: each stroke's dabs as points, with its radius, feather, flow, density and erase | Mapped; Auto Mask as the test catalog shows it stored |
| Luminance Range | `luminanceRange` | Approximated: Lightroom's luminance against OKLab lightness |
| Color Range | `colorRange` | Approximated: Lightroom's sample areas and amount against Redlamp's samples and Refine |
| Depth Range | `depthRange` on the photo's embedded depth | Approximated |
| Select Subject, Select Sky, Background | `ai` Subject, Sky and Background | Approximated: Redlamp's model draws the shape |
| People and their parts | `ai` People with the same part, for the person Lightroom chose where it records which | Approximated |
| Objects | `ai` Objects, with Lightroom's box or brushed points as the prompts where they're stored | Approximated |
| Landscape | `ai` Landscape with the same class (Redlamp's classes are Lightroom's) | Approximated |

A mask's sliders map one for one where Redlamp has the slider: Temp, Tint, Exposure, Contrast, Highlights, Shadows, Whites, Blacks, Texture, Clarity, Dehaze, Hue, Saturation, Sharpness, Noise, Moiré, Defringe, the Color swatch, Curves (MSK-20) and Point Color. Grain inside a mask is left out. Process 2010's local sliders follow [the rules for earlier process versions](#process-versions-before-2012).

AI masks aren't read from Lightroom: its AI pixel data sits in stores beside the catalog in a form we don't read, and Redlamp keeps its own bitmaps with their provenance (MSK-09). Redlamp's models compute them again, in the background after the import, in an engine of their own as Settings Sync does, a photo that's opened first. Until then they cover nothing, and Develop says the photo's masks are being computed. An AI mask waiting for its bitmap is a small sidecar format change, made within the format's compatibility rules: a reader from before sees a missing bitmap, which covers nothing.

A photo with more than 16 masks or 64 components keeps the first ones in Lightroom's order, and the report names the rest.

### Spots

| Lightroom | Redlamp | Outcome |
| --- | --- | --- |
| Heal and Clone, circles and brushed (`RetouchAreas`) | `heal` and `clone`: centre, source, radius, feather, opacity and stroke | Mapped. An elliptical spot is approximated by a circle; the pixels are Redlamp's heal |
| Remove | `remove` | Approximated: Redlamp's content-aware fill |
| Generative Remove | `remove` | Approximated: Adobe's generated pixels aren't brought; Redlamp's fill takes their place, and Redlamp's own generative fill can redo it |
| Process 2003 and 2010 spots (`RetouchInfo`) | `heal` and `clone` circles | Mapped |

## Process versions before 2012

Process 2003 (Lightroom 1 and 2) and Process 2010 (Lightroom 3) have other Basic sliders: Exposure, Recovery, Fill Light, Blacks from 0 to 100, Brightness and Contrast, a Clarity of their own, a point curve that starts at Medium Contrast, other local sliders and, in Process 2003, other noise reduction. A raw at Process 2010's defaults already carries Brightness +50, Contrast +25 and Blacks 5, which Process 2012 folds into sliders at zero. Lightroom keeps a photo's process version until the photographer updates it, so a catalog begun before 2012 can hold thousands of such photos. The census (step 2) says how many.

What doesn't depend on the process version converts as it does for later photos: crop, rotation, spots, lens and Transform, white balance, the Color Mixer, split toning as Color Grading, sharpening, vignette and grain, and where masks are. The choice is about the tone sliders, the old point curve and the old local sliders:

- **A.** Carry the rest, leave those at Redlamp's defaults, and report them.
- **B (chosen).** A, and convert those as Lightroom's own Update to Current Process does. Test photos get a grid of Process 2003 and 2010 values and are updated in Lightroom; the catalog's history holds each photo's settings before and after, which give the mapping to fit. Reported as approximated: it lands where Lightroom's update would, which isn't exactly how the photo looked in Process 2010. A new row, EDT-31.
- **C.** Leave these photos' edits behind, as today.

The owner chose B (2026-10-13). Its fit needs the test catalog, so until then these photos come across as A describes, and the report says their tone waits on EDT-31. It lists them with Show Photos, so they can be reviewed first.

## Virtual copies as versions (EDT-09, LIB-48)

Versions are Lightroom's virtual copies (the owner, 2026-10-13): another edit of the same file, which the library shows as a photo of its own, with its own rating, flag, label, keywords, title, caption and collections. The file is shared, so moving, renaming or trashing it takes its versions along. The import makes each virtual copy a version of its photo, named as Lightroom named it ("Copy 1", or the name the photographer gave it), with its own metadata and snapshots.

- **The sidecar (EDT-09):** `versions`, a list beside `recipe` and `metadata`, each `{"id", "name", "created", "recipe", "metadata", "snapshots"}`. The file's own edit stays in `recipe`, so a Redlamp from before still shows the photo as it was, and keeps `versions` as an unknown key. The format document, the schema and `SidecarSchemaTests` follow.
- **Develop (EDT-09):** Create Version (⌘', Lightroom's key for Create Virtual Copy) makes a version of the photo or version open, named Copy 1, Copy 2 and so on; versions are renamed and removed from Develop and the library. Each version has its own edit, history sessions and snapshots, and the filmstrip shows each one.
- **The library (LIB-48):** each version is a row of the index beside its file's, with its own rating, flag, label, keywords and collections, so lists, filters, smart collections, search, the grid and selections treat it as a photo. It's stacked with its file's photo by default (LIB-28), and an attribute tells versions from originals, as Lightroom's Copy Status does. File operations, Library Health, duplicates and the XMP metadata sync act on the file and carry its versions along. An index rebuilt from the sidecars gets the versions back.
- **Copy, paste, Sync and export** act on the photos and versions selected. A `{version}` token in naming templates names a version's export.

This is the larger choice: every list and action of the library learns that a photo can be one of several on one file. LIB-48 carries that work, and EDT-23 brings virtual copies once both rows are built.

## Writing the edits

- **The report first.** LIB-29's report gains an Edits section before anything is written: the photos whose edits convert fully, with approximations, or with settings left out (each reason with its count and Show Photos); the photos by process version; virtual copies as versions; snapshots; AI masks to compute; and photos that already have a Redlamp edit.
- **One write per photo.** Edits go in the same parts as LIB-29's fields and are written with them, which also finishes LIB-29's "one sidecar write per photo". Undo Import takes them back with the rest. The photo open in the editor is changed by the editor, as Settings Sync does. A raw and its JPEG, which Lightroom kept as one photo, give the edit to the raw only.
- **Photos already edited in Redlamp** keep their edit (the owner, 2026-10-13). Lightroom's is added as a version named "Lightroom Classic", which takes the photo's metadata as a new virtual copy does in Lightroom.
- **Provenance.** Each converted edit records where it came from: the catalog or the XMP file, Lightroom's photo and its settings' digest, the date, and the settings approximated or left out, by name. Develop shows it on the photo ("From Lightroom Classic: 2 settings left out", with the list), and a later import can tell what changed since (EDT-32). It is a new key of the recipe, documented in the sidecar format.
- **Speed.** A photo's develop settings are a few kilobytes of Lua. Read and converted on every core, a report of 100,000 edited photos should stay within about twice LIB-29's 2.45 s; it is measured once built. AI masks are the slow part, and run in the background.
- **Nothing of Lightroom's is written:** not the catalog, its folders, the photos or Lightroom's XMP.

## XMP sidecars (EDT-12)

- **What:** a photo whose `.xmp` sidecar (written by Lightroom, Camera Raw or Bridge) or embedded XMP holds Camera Raw settings, and which has no Redlamp edit.
- **When (lean: both).** A library command, Convert Lightroom Edits…, over a folder or the selection, with the catalog import's report, batch and Undo. And opening such a photo, which opens with the converted edit and the provenance notice, saved as its first history step.
- **Once.** A converted photo isn't converted again when its `.xmp` changes. Convert Again replaces the edit, keeping Redlamp's as a snapshot. The XMP metadata sync (LIB-24) goes on as it does, and never writes Camera Raw settings.
- **Which wins:** for a photo in a catalog being imported, the catalog's settings. A newer `.xmp` beside it is noted in the report.

## How close the results need to look

"The same edit" means different things for different kinds of setting:

| Kind | What to expect | Measured by |
| --- | --- | --- |
| Geometry: crop, angle, rotation, flip, Transform sliders, lens distortion, Guided Upright, where masks and spots sit | Exact, within about a pixel at 24 MP | Marks on the test photos, in Lightroom's exports and Redlamp's renders |
| Global sliders | The same control at the same value. How far it moves the photo matches Lightroom only once EDT-24 fits it | The change each app's edit makes from its own default render, compared |
| White balance | The same neutral for the same temperature and tint, where the colour models agree | Grey patches of the test photos |
| Profile | Redlamp's look of the same name, not Adobe's | The whole-photo difference, recorded rather than targeted |
| AI masks | The same kind of mask; the shape is Redlamp's model's | Overlap with Lightroom's mask, exported as the bench's mask recipe does |
| Healing | The same places; the pixels are Redlamp's | Spot positions |
| Process 2003 and 2010 | Approximated (option B) | Against Lightroom's own update |

A conversion is measured by the change each app's edit makes from its own default render (ΔE2000 between the two changes, per chart patch or per pixel), which takes the difference between the profiles out; the whole-photo difference is recorded beside it. Three targets were weighed:

1. **Same settings.** Value for value, geometry exact, looks by name. No colour target; the measurement is recorded.
2. **Measured sliders (chosen).** 1, with EDT-24's fitted conversions and a CI check holding each to its recorded distance. Needs DEC-41.
3. **Looks like Lightroom.** 2, with a Base Look fitted to Adobe Color's renders of the charts, used for imported photos, and each imported photo compared with Lightroom's own preview of it from the catalog's previews, listing those that differ most for review. It would need a decision on measuring Adobe's profile output (as DEC-19 allowed for presets) and on reading the previews, which DEC-51 doesn't cover.

The owner chose 2 (2026-10-13). EDT-24's fits need Lightroom's renders of the synthetic charts and DEC-41, so imported edits start as 1 describes, and each fitted conversion reaches presets, sidecars and catalogs alike once EDT-24 lands.

## Decisions (2026-10-13, the owner)

1. **How close:** measured sliders (2 above), through EDT-24; geometry exact; profiles become Redlamp's looks of the same name.
2. **Versions:** items of the library now, each with its own rating, flag, label, keywords and collections, as Lightroom's virtual copies are; chosen over the edit-only first step this draft leaned to. EDT-09 and LIB-48.
3. **Process 2003 and 2010:** converted as Lightroom's Update to Current Process does (B above), EDT-31.
4. **Photos already edited in Redlamp:** keep their edit; Lightroom's is added as a version named "Lightroom Classic".
5. **The test catalog:** recorded for later, as the owner has no help for Lightroom work yet. What needs it waits, as [Until the test catalog exists](#one-converter-for-three-sources) describes.

Rows: EDT-31 (Process 2003 and 2010 tone conversion) and LIB-48 (versions in the library), accepted with these decisions; EDT-24 accepted as the way to measured sliders; EDT-32 (importing a catalog or sidecars again: photos changed in Lightroom since their import updated where Redlamp's edit is as imported, otherwise added as a version) proposed. Comparing imported photos with Lightroom's previews belonged to the third target and has no row.

## Steps

Each step has the ID its todo and the board's plan step use.

1. **`canvas`:** the workstream board, `ws-lightroom-edits`. Done when it shows this plan.
2. **`census`:** `redlamp library lightroom --census`: per process version, setting, mask component, spot kind, profile and Upright mode, the number of photos; virtual copies and snapshots counted; each rotation code in the catalog paired with its file's EXIF orientation; no names, paths or values, so it can be shared. Done when LIB-29's synthetic catalogs test it, and its output for the owner's catalog, and the photographer's if they share it, is recorded here.
3. **`test-catalog`** (later, when the owner has help): fixture, CC0 and synthetic photos in Lightroom Classic, one kind of edit each (every mask component, spot kind, Upright mode, white balance mode and common profile, rotations and flips, an angled crop on a turned photo), virtual copies and snapshots, Process 2003 and 2010 photos updated to current, and Lightroom's export of each, as a bench task. Done when the files are in the bench's Done folder and the format note describes every setting the converter reads.
4. **`settings-model`:** nested structures and arrays in `CameraRawSettings`, the Lua reader, and the catalog reader reading develop settings, rotation, virtual copies' settings and snapshots. Done when synthetic Lua and XMP of every structure read alike, and 100,000 photos' settings parse within the report's budget.
5. **`photo-converter`:** a photo's whole edit, masks and spots aside, sharing EDT-11's table. Done when a test pins each row of the mapping table, and the geometry is checked through `GeometryMap` for every camera and edit orientation, as the crop tests do.
6. **`masks-spots`:** masks and spots, built against the documented names and left out of imports until checked. Done when every component and spot kind converts in tests; they're brought once the test catalog's placements land within a pixel at 24 MP.
7. **`versions`** (EDT-09): the sidecar's versions, Develop, copy and paste, export, and a scenario. Done when a version survives saving, reopening, Sync and export, and the scenario covers it.
8. **`library-versions`** (LIB-48): versions as rows of the index with their own metadata; lists, filters, smart collections, search, stacks and selections; file operations, Health and the XMP sync carrying them along; a rebuilt index getting them back; a scenario. Done when the library scenarios pass with versions present and the index's timings at two million photos hold.
9. **`catalog-edits`** (EDT-23): the Edits section, one write per photo, Undo Import, photos already edited, provenance, virtual copies and snapshots, AI masks in the background, File › Import from Lightroom Classic… and `redlamp library lightroom`, the `library.lightroom-edits` scenario, measured at 100,000 photos.
10. **`xmp-sidecars`** (EDT-12): Convert Lightroom Edits…, conversion on opening, embedded XMP, Convert Again, and a scenario.
11. **`pre-2012`** (EDT-31): option B's conversion, fitted to the test catalog's updates.
12. **`closeness`:** the measurements above on the test catalog, recorded here and in the comparison's notes; EDT-24's fits once DEC-41 is decided and the charts are rendered.
13. **`docs`:** [Lightroom presets](../recipes/lightroom-presets.md) becomes the reference for presets, sidecars and catalogs; the sidecar format (versions, provenance, AI masks waiting for their bitmaps); the README's roadmap and known limitations; the comparison's rows; the tracker.

Steps 2, 4 and 7 start together, and step 8 follows 7's sidecar format. Step 5 follows 4; step 6 follows 5; step 9 follows 5, 7 and 8; step 10 follows 5; step 13 comes last. Step 3 is the owner's, recorded for later; steps 11 and 12, and bringing masks and spots in imports, wait on it.
