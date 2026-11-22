# Architecture

- `app/Platforms/macOS`: everything specific to the Mac app's targets in `Ceviche.xcodeproj`: the sources of the launcher (`Launcher`), the index service (`IndexService`) and `ceviche-mcp` (`MCP`), their Info.plists, entitlements, xcconfigs and the app icon. A future iPad app goes in `Platforms/iOS`. They link this package's `CevicheKit` product (the app's code, CevicheCore and everything they link) as one dynamic library instead of each carrying a static copy, shipped as `Contents/Frameworks/CevicheKit.framework` with the resource bundles inside, where every executable's `Bundle.module` finds them. Tests use `app/Package.swift` alone.
- `app/Sources/CevicheMac`: the Mac app's code (SwiftUI and AppKit), built as a library. `App` (entry point, welcome, settings, secondary window), `Components` (the palette and the shared controls: buttons, form controls, sliders, the full-window tool chrome, the zoom canvas), `Catalog` (library model, grid, sidebar, activity center), `Import` (card, camera and Photos import), `Culling` (burst picker, flawed photos, RAW + JPEG pairs), `Editor` (develop model, canvas, tool panels), `Tools` (the full-window tools: merges, stacks, night sky, timelapse, negatives, ID photo, filters, chart profiles, each with its `CatalogModel` entry point), `Export` (dialog, sessions, batch export, watermarks, Edit In) and `MCP` (the local MCP endpoint's controller). SwiftUI views with AppKit panels, grouped undo/redo, debounced rendering and autosave.
- `app/Sources/CevicheCore`: the library the app, the index service and `ceviche-mcp` share. `Catalog` (GRDB store, importer, history, previews, iCloud sync), `Indexing` (background tagging), `Originals` (locators and storage providers), `Rendering` (the Core Image pipeline), `Adjustments` (the serializable edit model), `Masks`, `Looks` (presets, DCP profiles, LUTs), `Analysis` (bundled models, dust, upright), `Export`, `XMP`, `MCP`, `Panorama`, `HDRMerge`, `Metadata` and `Localization`.
- `app/Sources/CevicheCore/Rendering/RawRenderer.swift`: an actor owns `CIRAWFilter`, a reusable `CIContext(mtlDevice:)`, and document writes. The URL RAW initializer handles the Sony samples correctly even when byte-based ImageIO inspection labels the container TIFF. RAW white balance and exposure are applied by the decoder before downstream tone/color/detail processing. RAW lens correction is enabled when supported. Info reports the current decoder’s per-image capability as Enabled or Unavailable. RAW decoding support does not guarantee lens correction for every camera/lens combination; rendered files receive no additional optical correction. Lensfun integration is deferred.
- The Library's grid and wall (`LibraryGrid`) know every row's height before showing it: grid tiles are a 4:3 photo plus fixed chrome (`CatalogTile.height`), wall rows come from `WallLayout`. `RowStack` places the rows and `RowPlacement` builds only those near the visible part, never asking rows for size or spacing, so a scrollbar jump anywhere in a large library costs the same as a small scroll. The built rows cover about a screen past each edge and move only when the scroll nears their edge; the per-frame scroll position goes to an `@Observable` (`GridScroll`) that only the pinned date reads. Each row is an `Equatable` `LibraryRow` and its cells hold the models without observing them, so scrolling and unrelated catalog changes redraw no tiles. Photos past the loaded pages get room below the loaded rows (exact for an even grid, else the loaded photos' average height), so the scrollbar holds still as pages load; scrolling into that room loads through the photos estimated to be there. Keyboard moves scroll the selection into view by its computed row (`ScrollPosition`), since its row may not exist yet.
- What the renderer would otherwise read from the original on every open is recorded at import: `ImageInfo.defaults` (as-shot white balance and Apple's noise reduction from `RawRenderer.cameraDefaults`, and whether the photo opens in HDR, marked by `defaultsFromImport`) and the `asset.hdr` column. Catalog callers pass `asset.hdr` to `RawRenderer.open`, and paste, reset and `CatalogImporter.developmentDefaults` use the recorded defaults without the file; photos imported before then still read it. Stored developments and `infoData` leave out every value equal to `Adjustments()`'s (`Adjustments.sparseKey`; decoding restores them; `colorNoiseReduction` is always written since its missing value means unset), about a sixth of the full JSON. Integer RGB TIFFs and PNGs are decoded once, on the first render, into four-channel memory (`RawRenderer.decodedBitmap`): left to Core Image, every render re-reads and converts the file.
- The processing graph uses a linear extended-sRGB 32-bit float working space. Interactive previews are limited to 2200 pixels on the long edge. JPEG thumbnails (400 pixels) reuse that rendered preview. Export rebuilds the same graph at full resolution. RGB histogram binning uses the small thumbnail on CPU; image processing uses Metal. The scopes (`Scopes`) are measured on CPU from the same thumbnail (the HDR preview for HDR levels), only while one is showing, one measurement at a time. The zone map (`ZoneMap`) is measured the same way from the preview itself while Zones is on.
- A generation counter prevents stale renders replacing newer edits. Blocking decode, render, and database work stay off the main actor. Only preview images are transferred back to SwiftUI.
- `app/Sources/CevicheCore/Adjustments/ToneCurve.swift`: ordered, nonuniform anchors with shape-preserving cubic interpolation shared by the graph and a cached 64³ GPU color cube. Curves persist explicit x/y points.
- `Adjustments/PixelAdjustments.swift` and `Rendering/PixelRenderer.swift`: shared serializable pixel controls and processing for global development and local masks. Each mask retains its own curve/HSL caches; selection coverage is cached independently of adjustment values.
- Defringe detects edges in sRGB-encoded light and expands their coverage by two pixels at the render scale. Its eyedropper samples a 3×3 patch at source resolution in linear extended sRGB, at the input of the selected global or masked Defringe pass.
- `Adjustments/FilmAdjustments.swift` and `Rendering/FilmRenderer.swift`: serializable film controls, cached RGB/color cubes, deterministic grain, and detail shaping. Curves run parametric → master → channel. Calibration precedes basic tone/color; B&W mixing precedes split toning; grain follows detail/vignette and precedes local masks. Calibration adjusts decoded RGB; it does not replace Apple camera decoding.
- `Adjustments/SelectiveColor.swift`: smooth circular hue masks drive HSL changes through a cached GPU color cube. Neutral pixels and unrelated hue ranges are preserved. Section bypasses substitute as-shot defaults only in the processing graph, leaving stored slider values intact. Legacy vignetting uses Core Image’s radial vignette effect; new post-crop vignetting runs after geometry with signed amount and highlight protection.
- `Masks/Masks.swift`, `Rendering/MaskRenderer.swift` and `Rendering/RawRenderer+Selection.swift`: serializable mask recipes, cached coverage, compositing, and local Vision selection. Brush refinements share one grayscale raster to bound memory.
- `Export/ExportSettings.swift` and `Export/RawRenderer+Export.swift`: RGB profiles, encoder capability checks, metadata selection, and atomic depth-verified export.

- `app/Sources/CameraRaw`: sensor data straight from RAW files, for what Apple's decoder doesn't expose: a TIFF and maker-note reader, Sony's uncompressed ARW, Pentax PEF (its Huffman coding) and DNG (lossless JPEG) with the four exposures of Pixel Shift Resolution, the Fujifilm RAF tags that place each Pixel Shift shot, and the six interleaved exposures of a Hasselblad multi-shot FFF (its predictor-11 coding). It decodes no pictures: development stays with `CIRAWFilter`.
- `CevicheCore/PixelShift`: `PixelShiftSelection` sorts a selection by its files' headers. Sony and Pentax sets are merged on their CFA samples on the GPU (`PixelShiftEngine`), Pentax at the movement its mechanism makes, with the colour fitted to Apple's development of the first exposure; a Pentax PEF has no crop tags, so `PentaxRAW.activeArea` holds the picture Apple develops for each model. Fujifilm sets (`PixelShiftFusion`) are developed by Core Image in linear light, without lens correction, and interleaved on the doubled grid at the offsets each RAF records. A Hasselblad six-shot (`PixelShiftMultiShot`) is merged by a Metal kernel on the doubled grid, measured colours where an exposure sampled the point and a distance-weighted average elsewhere, through the file's own colour matrix; it matches the prototype the photographer checked exactly. Apple's decoder develops a DNG only up to `PanoramaDNGWriter.developableSide` (19968) pixels on a side and returns a transparent picture past it, so larger merges skip the DNG and write a TIFF or JPEG straight from the raster (`runMergeJob(writesExport:)`). Only models checked against a real set are accepted.

Camera support is supplied by the installed macOS RAW codecs; an unsupported RAW is reported rather than silently substituting an embedded JPEG. GPU access is required. There is no software-rendering fallback.

Apple API references: [CIRAWFilter](https://developer.apple.com/documentation/coreimage/cirawfilter), [CIContext](https://developer.apple.com/documentation/coreimage/cicontext).

## Import and background analysis

Import runs in three tiers. The import loop reads only the header and the XMP sidecar and takes the camera's embedded
preview as the thumbnail, so each photo opens once inserted; `importing` (and the batch-action lock it drives) ends
with the loop. Photos whose sidecar changes their look are then queued for a developed thumbnail at background
priority (`ThumbnailReactor`), when their original is on this Mac's own disk; on a network share or another volume
the grid asks for the photos it shows instead (`developOnScreen`), so a migrated library is not read in full at once. Heavy work runs in the index service (`CatalogIndexWorker`, the `analysisJob` queue):
one decode per photo for Vision labels, face boxes, landmark fit, eye openness and capture quality, written in one
transaction to `asset.suggestedTags`, `assetFace` (one row per face, top-left normalized bounds) and `asset.faceCount`,
which always equals the photo's rows (nil: not analysed). Photos with a face at least 3 % wide also get 256-pixel
tiles cut from the original by `FaceCrops`, kept in the `faceTile` table of `previews.sqlite` for the Faces wall.
Face boxes sync with the suggested tags (`SyncedAnalysis.faceBoxes`); tiles do not, and a photo analysed on another
Mac shows its face cut from the library thumbnail. Background indexing also saves a feature print for Show Similar Photos and Duplicates. Culling computes its own report and burst-comparison print on demand.
People runs in the app, not the index service (`CatalogPeopleGrouper`, `PeopleIndex`): Vision finds five points on
each wall tile, `FaceEmbedding` aligns the face to OpenCV's 112-pixel template and SFace gives 128 numbers, kept on the
face's row (`assetFace.embedding`, Float16, with its revision), about 15 ms a face. `PeopleGrouping` then places faces
nobody holds into people (`person`, `assetFace.personID`) by cosine similarity to each person's mean, at 0.5 and a 0.05
lead, never two faces of one photo in one person. Existing people keep their faces; faces moved by hand are `pinned`
and never moved again. Analysing a photo again carries each face's person to the new face in the same place
(`CatalogStore.setFaces`). People are not synced yet.

The Library has three levels. Map and Faces have an overview (`CatalogModel.collectionOverview`: Map, People, or the
Faces wall without the People model) above their photos; a pin (`CatalogFilter.mapArea`) or a person
(`CatalogFilter.personID`) narrows the collection, and its photos show in the wall or the grid (`showPhotos`); Compare
and Detail show the open photo. `showingOverview` picks the overview over the photos, `goUp` and ⌘↑ return to it.

## Generated outputs and latent images

`CatalogPendingOutput` holds device-local jobs separately from `CatalogAsset`, so pending outputs never enter photo
selection, deletion, export, or indexing. The shared merge runner covers panorama/HDR panorama, HDR, focus stack,
photo stack, pixel shift, and Night Sky; AI Denoise and Convert Negative reserve one output per source. Each pending output reserves the
finished asset ID and shows as a progress row above the grid or the wall (`PendingOutputBar`), never as a cell. Abort cancels the worker, while publication wins once finalization begins. Files render in a local
job directory, then copy beside a writable local source or into catalog originals. Prepared adjustments and thumbnails
precede `insertCompletedOutput`; errors and cancellation clean up unpublished files. Local journals under
Application Support/Ceviche/Jobs record interrupted work for cleanup and reporting when its catalog opens. Jobs do
not sync or automatically resume.

Night Sky analysis assumes a fixed camera: the ground holds still in the frame while the sky turns, which is what lets
stars be told from ground lights and the sky's rotation be traced. One sky mask, found in the anchor photo's frame,
serves every photo; all other masks derive from it and the sky corrections. A camera moved for effect belongs in
Timelapse, and a tracking mount needs no alignment, so plain stacking covers it. Supporting a tracking mount whose
ground turns on purpose would add a ground transform per photo, the inverse of the sky's rotation, not a mask per photo.

A latent image is a concept of Ceviche's own, named for film's latent image: exposed but invisible until developed.
It is saved tool work, everything one output picture is made from except pixels: references to the catalog's source
photos, the tool's settings and hand choices, and what analysis found. Outputs (Merge, Render Video) develop it into
ordinary photos or videos and leave it in place, so the next version starts where the last one ended. It is a catalog
asset of kind “Latent Image” whose original is a `.cevichelatent` package with `manifest.json`, a 320-pixel `thumbnail.jpg`, a 2560-pixel `preview.jpg` for Develop
(`LatentImage.pictures`), and an immutable analysis directory
named by UUID. The manifest holds bundle/type/analysis versions, the Night Sky tool discriminator, serialized settings,
ordered `{assetID, filename, size, modified}` source references and their catalog ID, full dimensions, and the sky
corrections used for alignment. An optional presentation payload retains Star Trails’ output mode and video settings,
including crop, trails, glow and meteor timing. The analysis directory holds `results.plist`, a few MB: what analysis
found and nothing it can derive. That is frame metadata, gains, the sky finder's mask (Float32, LZFSE), the sky
corrections the stars were aligned with, alignments, detected lines, star statistics and hot pixels. The other masks
are shaped from the found one on opening. No preview pixels are stored: RAW decoding is most of the analysis time, so a
disk copy of the previews would save little beyond it. Reopening decodes each photo straight at preview size (about a
third faster than decoding at analysis size and shrinking), so a reopen takes about 60% of a fresh analysis. Analysis
reads the photos as shot, so later development in the catalog never changes the stored detections.

A Creative Filters latent image (type `creativeFilters`) has exactly one source, the `CreativeFilterStack` as its
settings, no analysis (an empty `analysisID`) and the photo's developed size; the alignment fields go unused. It holds
no development: opening and exporting apply the photo's current one, so its thumbnail shows the development of when it
was last saved. Export and Print from a window opened on photos save one per photo in the background
(`CatalogModel.keepFilterLatents`); a window opened on a latent image saves its stack into it a second after a change
and when it closes. Its source stamps are recorded but not checked: nothing is derived from the file.

Tools without analysis save through `CatalogModel.storeLatent`. ID Photo keeps none: it stays open after its exports
and prints, so its layouts are still there for the next one. Develop's sequence (`browsingAssets`) includes latent images:
opening one sets `CatalogModel.latentShown` and closes the editor's document, and `LatentDetailView` shows its
`preview.jpg` (the thumbnail for packages saved before it) with a button that opens its tool; the editing inspector
and Compare are off while it shows. `shownAssetID(editor:)` is what the filmstrip, arrow keys and Trash treat as open.

Creative Filters, and the three merges below, also file a latent image only when **Keep Latent Image** is ticked (`LatentCheckbox`,
with an ⓘ popover; in the Export dialog's Options through `ExportTarget.latentType`, which only Creative Filters sets,
and in the other tools' options; one UserDefaults key per type, `LatentPreference`, off by default); a window
opened from a latent image hides it and always keeps that one up to date. The merges save from Merge or Create Video
and update on Close: `timelapse`
(`TimelapseLatent`: the settings with the crop, and the asset IDs left out), `focusStack` (`FocusStackSettings`,
brush strokes included, which are in fractions of the alignment frame and so survive a fresh analysis) and `panorama`
(`PanoramaLatent`: options, HDR and Deghost, and `PanoramaSolved`). `PanoramaSolved` is what alignment fits, a few
numbers per photo: cameras with focal length and lens distortion, rotations, straightening, gains and white balance.
`PanoramaMerger.restore` takes it in place of `align`, decoding the preview copies but skipping features, matching and
the lens fit; an HDR panorama still merges its brackets first. Restoring checks the sources' stamps and aligns again
when one changed, keeping the options. Focus Stack and Timelapse measure again on opening.

With Keep Latent Image ticked (in the tools' shared options row; the key is the tool's type), the first successful
preview saves and imports an owned package; ticking it later saves at once, analysis included, and unticked nothing
is written. Subsequent previews atomically replace settings in
the manifest; **Align Again** creates a new analysis directory before publishing its manifest and removes the old one.
Source order and detection IDs remain stable across reopening. When **Align Again** finds other lines while some were
chosen by hand, the window asks whether to use them and clear those choices or keep the previous lines; keeping takes
the earlier results back from memory and only warps the existing preview copies again. Source file size/modification stamps are checked, and current catalog development
is applied to the composite preview; an output job freezes the development it uses before processing. Unknown types,
unsupported versions, damaged results and changed or missing sources produce errors. Packages exist only inside a
catalog: the tool files them into its originals (`CatalogImporter.prepareLatent`), and file and folder imports, the
Folders view, Show in Finder, Locate Original, Duplicate, Edit In and export all skip them. They are excluded from
photo indexing and follow catalog trash/backup handling. Source IDs refer to the catalog's own photos; cross-catalog
source remapping and analysis-version migration are not provided.
