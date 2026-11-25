# Roadmap

Work still to do. Each item is sized to land on its own branch from `main`; items in the same group share code, so land
the first one before branching the next.

Shared conventions for every tool:

- Merges write a linear DNG beside the sources, like HDR and Focus Stack, so the result is developed like any RAW.
- Entry point is the Library's Create section (multi-photo panel, context menu, Photo menu).
- Short labels; the users are experienced photographers.
- Keep the workflow consistent: select sources, open a large preview, adjust only the relevant controls, and return generated results beside their sources. Analysis and batch-edit tools keep their changes reviewable and undoable.
- Test with local photos, a separate bundle id and a scratch catalog (see `AGENTS.md`).

## 1. Before the first release

| | What | Notes |
|---|---|---|
| 1c | **Blank RAW decodes** | Apple's RAW decoder fails silently on some files: a DNG past about 19968 pixels on a side comes out fully transparent, and a multi-shot Hasselblad FFF comes out solid black (every RGB exactly 0), with no error either way. The limit may differ by chip and macOS version, so don't hard-code it. Check the preview or thumbnail the open already renders: if its maximum alpha or maximum RGB is 0, report "macOS couldn’t develop this RAW file (W × H)" in the failure alert instead of showing the empty picture. A real RAW never does this (even a lens-cap frame keeps noise above black). This is one pass over a small bitmap, with no extra decode: a separate low-scale render still decodes the whole file (3–7 s on a 100 MP file). Run the same check on a merge output's thumbnail before it joins the catalog. |

## 2. Agent interface

| | What | Notes |
|---|---|---|
| 2a | **`ceviche` command** | One executable in `Contents/Helpers` replacing the app's argv flags and `ceviche-mcp`: `ceviche <group> <command> [--json]` and `ceviche mcp`, both generated from the MCP tool table so they cannot drift. A client of the running app (launched hidden when needed), which stays the only catalog writer. Community build only. |
| 2c | **App Store build** | Sandboxed: no CLI, MCP over HTTP, imports always copy, MCP paths limited to Allowed Folders kept as bookmarks. Open: catalogs from the Developer ID build that reference originals, and features that reference by nature (Folders tab, Edit In, merges saved beside the originals). |

## 6. Shared app layer

| | What | Notes |
|---|---|---|
| 6a | **CevicheUI** | A module between CevicheCore and the two apps for the state they could share: the Mac's `CatalogModel`, `EditorModel`, `DevelopmentStore`, `ActivityCenter` and the touch app's `LibraryModel`, `DevelopModel`, `MergeModel`, which today do the same work twice. On the Mac only 7 of 187 files could move as they are: the models reference view types (`SecondaryWindow`, `FileAccess`, `Eyedropper`, `ImageViewport`, dialogs) and use `NSImage`, `NSScreen`, `NSSound`, `NSAlert`. Cut those edges (callbacks or protocols the shell provides, a `PlatformImage` alias), move the files, mark what the shells use `package`, and have `CevicheMobile` take the shared models in place of its own. Check with an iOS build. |
| 6b | **Split CevicheCore** | Imaging (pixel pipeline, merges; optimized in debug) and catalog (database, sync, indexing, MCP; unoptimized in debug) as parallel modules, to shorten the cold build. Looks, Analysis and Rendering reference Catalog types and Catalog references them back; cut that first. |

## 4. Creative filters, the rest

Tools › Creative Filters… is in the app: a stack of filters (Glow, Diffusion, Bloom, Bokeh, Polarizer, AI Noise Reduction, Pro Contrast, Tonal Contrast, Detail Extractor, Bleach Bypass, Cross Processing, Darken / Lighten Center, Fog, Reflector, Light Leak, Dust & Scratches, Border, Output Sharpening) applied to the developed photo on the way out. It is an export: the files go to a chosen folder through the Export dialog and the catalog's export job with the full `ExportSettings` (format, size, profile, watermark, metadata), and the photo's development is untouched; each output leaves a latent image per photo holding the stack, which reopens the window. The window lists recipes (built-in and saved, as thumbnails of the photo) and the filters by group, each with a checkbox, down the left; beside them the filters that are on as a chain in the order they apply (drag to reorder, Delete to remove) over the picked filter's settings; Single / Split / Side by Side compare on the canvas, with handles on the picture for Darken / Lighten Center and Bokeh. Border has six styles drawn in code (`BorderRenderer`) and 22 pictured ones (`BorderAsset`: film scans, frames, paper edges); Dust & Scratches lays one of eight `FilmTexture`s over the picture. The pictures are keyed to transparency by `app/scripts/border-key.swift` and are 1536 × 1024: larger originals, and slicing so a border keeps its proportions on any shape of photo, are still to do. Export… opens the Export dialog on the filtered photo. `CreativeFilter` and `FilterRenderer` in CevicheCore. These are what it still lacks.

| | What | Notes |
|---|---|---|
| 4a | **Masks and blend modes per filter** | Each row has Amount only. A mask from the photo's masks or a quick brush (control points), and a blend mode. |
| 4b | **A 1:1 inset in the preview** | Output Sharpening is left out of the preview, and Diffusion's core is sub-pixel at fit: both need the file's own pixels (`prepareExportDetail`). |
| 4c | **A sun handle for the Polarizer** | Sun Direction and Sun Height are sliders. Add a draggable sun handle on the preview, with a horizon and pixel-to-direction mapping from focal length. Sun azimuth needs about ±30° accuracy; elevation can be rough. Do not infer the sun from the brightest sky. |
| 4d | **Bloom and mist** | Diffusion has Types fitted to real soft-focus and diffuser filters. Still to do: feed Bloom light from before the decode's highlight compression (clipped sources underestimate the halo), and a mist type once a RAW pair shot with and without a black mist filter, with point lights, is measured. |
| 4e | **Reach** | The Export menu and MCP, drag to reorder the rows, a progress ring on the AI row, the stack written into the file's metadata as a record. |

Open questions: whether Darkroom film printing should also move here as a filter, now that the dialog is the output step.

## 5. Print

| | Tool | What it does | Notes |
|---|---|---|---|
| 5a | **Print Proof, the rest** | Save print-specific adjustments, and view at actual size. | The soft proof is in the app (`PrintProfile`, Tools › Print Proof, ⌘Y, in Develop): a view of the photo while it is edited, with profile, intent, paper simulation, colour and shadow warnings. Left: proof adjustments kept apart from the master development; actual size from a per-display ruler check, not EDID; a lighter surround, since paper white is L* 93–95; complement output sharpening. Keep colour-gamut and shadow warnings separate, and validate with real printer/paper profiles. |

## 7. Models

| | What | Notes |
|---|---|---|
| 7a | **The camera's focus frame** | Draw where the camera focused on the photo, in Develop and the culling tools, as photographers check it by eye. Sony writes it in its maker note (tag 0x2027 FocusLocation: sensor size and point; AF points around 0x2020), on the A7 R III and A7 V alike; `CameraRaw/TIFFReader` already walks the Sony maker note for Pixel Shift. Map the point through orientation and crop. Don't judge sharpness or call "focused off the face" from it: on 652 RAWs the softest focus areas were clouds and skin, and points off every face were not misses. Other makers need their own readers (Canon AFInfo, Nikon AFInfo2, Fujifilm FocusPixel). |

## 8. Night Sky

| | What | Notes |
|---|---|---|
| 8a | **Calibration frames** | Support dark, flat and bias frames. First test dark-frame correction on a real night sequence for hot pixels that survive RAW decoding. |
| 8b | **Show Radiant** | In Composite Meteor Shower, show the likely radiant in a review-only overlay when enough selected meteor paths converge on the aligned sky. |

## 9. iPad and iPhone

The touch app (`CevicheMobile`, docs/development/ios.md) has the library with People and the Map, Develop with masks and retouch, culling,
the merges, Convert Negative, Merge Best Faces, Timelapse, Creative Filters, Wide-Angle Faces, Match Series, ID Photo and export with a watermark. These are what it still lacks from the Mac app, each to be measured on a device before it is offered there.

| | What | Notes |
|---|---|---|
| 9a | **Portrait, and the rest of Retouch** | Retouch has its brushes and dust spots. Left: Object (tap to remove), Distraction Removal and Find People, Visualize Spots and Dodge/Burn checked by touch. Portrait lacks Remove Spots, Touch Up's tap-a-part, the face's handles on the photo and the section switches; Find blemishes has no screen yet; its model is not listed in Models until it does. |
| 9b | **Check Faces, the rest** | Check Faces, Tidy RAW + JPEG Pairs and Duplicates are there, and Check Faces has run on an iPad with real faces. Left: its faces numbered on the photo as on the Mac, a series of the same people checked on a device, and its peak measured. |
| 9c | **Models** | The sidebar's Models downloads the pinned set's models, or adds them from a file, and Sky, Depth and Scene masks, AI fill and the two model filters turn on with them. Their features are measured on an iPad (all under 1.3 GB). Left: AI Noise Reduction's full-size export, whose gate in `MobileFeatures` is an estimate, downloads that continue in the background, and Background Assets for the App Store build. |
| 9d | **The tools' on-photo handles, and the trail video's speed** | Dragging a negative's frame corners and the filters' on-photo handles. Wide-Angle Faces has found a person and corrected a photo on an iPad; its and Match Series' memory gates are still estimates. A Star Trails video takes about 3.6 s a frame on an iPad: timed on a Mac, half of a frame is composing it (a RAW developed and added each time) and the rest is writing it to a DNG and developing that file again for the encoder. The file is now packed fast rather than small (0.7 s to 0.4 s a frame there); rendering the composed frame straight into the encoder's buffer would save the rest of that half. ID Photo is there for one photo at a time; left: its batches, moving the crown and chin markers by hand, editing templates (those made on a Mac are not carried over), keeping its white balance on the photo, and its memory gate, an estimate. Chart Profile and Print Proof stay the Mac's, with Merge Pixel Shift: a chart is profiled at a desk, and the touch app does not print. |
| 9e | **Catalogs** | One app, one catalog, for now: the touch app keeps its own local catalog with copied originals and does not open a `.cevichecatalog` from Files or an external drive (built once and taken out, 2026-11-24). Left for later, if wanted: iCloud catalogs (the entitlements and container are the Mac's) and sharing a catalog with a Mac. |
| 9f | **Jobs in the background** | A merge pauses when the app leaves the screen and carries on when it is back: every GPU pass waits while the app is off screen (`GPUForeground`), since iOS refuses GPU work from the background. Seen on an iPad during a Star Trails analysis; other merges and the video writers not tried. (Composite Meteor Shower's list and outlines of what was found have run there on 303 photos: 46 meteors.) Left: running on in the background as a continued-processing task (`BackgroundJobs`), which needs a device that gives those the GPU, and an M1 iPad Pro does not. |

## Order

1c is independent and uses the failure alert. 6a and 6b are independent; the touch app's items (9a–9d) are independent of each other and don't wait for 6a. 5a is independent and can run in parallel with anything. 7a is independent. The filter items (4a–4e) are independent of each other.
