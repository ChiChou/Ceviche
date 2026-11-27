# Testing

```sh
make test        # the default tier
make test-slow   # with the slow tier (CEVICHE_SLOW_TESTS=1)
```

The default tier runs every feature on small synthetic inputs and, on a developer's Mac, on a small corpus of real photos. The slow tier adds what is expensive and changes rarely: the CPU reference paths of night sky, focus stacking and HDR merging checked against the GPU, Core ML models on full-size RAWs, and full-size exports in every format; run it before a release or after touching those engines. The image engines are tested by properties that hold whatever the picture looks like (the GPU agrees with the CPU, a known shift or rotation is recovered, a synthetic star stays a point, sizes and orientations come out right, edits survive saving and reopening); how a result looks is judged by eye, with the review tools below.

Real photos are local only and never committed. Tests ask `TestSamples` for photos by role (a landscape RAW, a burst, a RAW with another editor’s XMP sidecar…); each role is a folder under `samples/tests/` in the git-ignored `samples/` folder at the repository root (a worktree uses its main checkout's, or `CEVICHE_SAMPLES` points elsewhere), and the test takes whatever is in it. The git-ignored `presets/` folder holds third-party develop presets and camera profiles for the preset parser (`CEVICHE_PRESETS` points elsewhere). A test whose photo is missing skips; CI sets `CEVICHE_SAMPLES=off` and runs on synthetic inputs only.

The `ReviewTools` target holds tools that write images for a person to look at rather than asserting much (the defringe parameter sweep and comparisons, and the night-sky runs over a real sequence); `make test` skips it, and each needs its own environment variable, named in its file. UI snapshots in `CevicheMacTests` likewise write PNGs only with `CEVICHE_UI_SNAPSHOTS=1`.

Metal integration tests report **skipped** if the execution environment cannot access a GPU; run outside a restricted process sandbox for full verification.

For a repeatable UI snapshot, use a debug build (captures only Ceviche's own content view):

```sh
make debug
CEVICHE_SNAPSHOT_PATH=/tmp/ceviche-editor.png \
  app/dist/Ceviche.app/Contents/MacOS/Ceviche "/path/to/photo.ARW"
```

```sh
CEVICHE_TEST_LOCAL_VISION=1 CEVICHE_UI_SNAPSHOTS=1 ./app/scripts/test.sh
```

Panel snapshots are written to `/private/tmp/` with the prefix `ceviche-`. The test captures Crop, Retouch, Light & Color, Detail, Masks, Info and the export dialog. Set `CEVICHE_LOOKS_ROOT` to a library containing profiles or LUTs to also capture the applied looks under `ceviche-looks-`. Vision asset downloads may be needed on the first run. Normal test runs skip these opt-in checks.

## Meteor Shower review

For a Meteor Shower background comparison, run `NightSkySampleTests/testMeteorBackgroundMatching` with
`CEVICHE_NIGHT_SKY_SAMPLES` naming the source folder and `CEVICHE_NIGHT_SKY_OUTPUT` a separate local output folder.
`CEVICHE_NIGHT_SKY_BASE` optionally picks a base filename. It writes the base, the former blend and the corrected
preview, and saves analysis locally for repeat runs. `NightSkyTests/testMeteorRestorationDoesNotCopyBrighterSkyInsideItsFootprint`
checks a changing coloured sky against preview, CPU and Metal output on synthetic photos.
`testMeteorBackgroundPreservesWideTrails` checks that sky matching preserves the core and wings for measured widths
of 2–24 analysis pixels. `NightSkySampleTests/testMeteorWidthSweep`, with `CEVICHE_METEOR_WIDTH_REVIEW` set to a local
output folder, writes synthetic trails and a detection report across Gaussian widths; it does not establish real
fireball detection accuracy.

## Defringe review

Two `ReviewTools` tests write comparison images for a RAW with fringing:

```sh
CEVICHE_DEFRINGE_RAW=/path/to/photo.ARW CEVICHE_DEFRINGE_REVIEW_DIR=/tmp/defringe-sweep \
  app/scripts/test.sh --filter DefringeParameterSweepTests
CEVICHE_DEFRINGE_REVIEW_DIR=/tmp/defringe app/scripts/test.sh --filter DefringeVisualTests
```

The sweep compares the shipping correction with experimental edge-mask variants (`probe-*`), which exist only in the
test. `CEVICHE_DEFRINGE_VARIANTS` picks variants by name; `CEVICHE_DEFRINGE_FULL` exports one at full resolution as a
16-bit PNG.

## Latent images and generated jobs

`CatalogPendingOutputTests` covers immediate reservation, abort versus publication, and replacement with a completed
asset using the reserved ID, per-output batch abort, and interruption recovery. `NightSkyTests.testLatentImage*` covers filing a package into the catalog, that file and folder imports skip packages, version/source errors, package
trash deletion, index exclusion, damaged results, and restoring all three Night Sky workflows from saved analysis.
`NightSkyEditorTests` exercises autosave and catalog reopening, including video options. The restoration test checks
that detections and masks come back exactly, that previews decoded again stay within 3% of the originals, and that
editing does not change the stored results; it requires Metal.

## Development merge on a real catalog

`DevelopmentMergeTests/testRealDevelopmentsMergeCleanly` opens a catalog read-only (`CEVICHE_MERGE_CATALOG` set to its
folder) and checks, for every development, that a merge against an unchanged base gives the other side back, that
either side merging gives the same bytes, and that the merge of two unrelated developments still decodes.

## Blemish portrait review

`BlemishPortraitTests` passes local JPEGs through Vision, the converted blemish detector, source selection and the Heal renderer. Set `CEVICHE_MODELS` to the compiled models directory, `CEVICHE_BLEMISH_PORTRAITS` to an input directory and `CEVICHE_BLEMISH_REVIEW` to a separate local output directory, then run `swift test --package-path app --filter BlemishPortraitTests`. `CEVICHE_FACE_REGIONS="name=x,y,w,h;…"` (normalized, y up, file names without extension) replaces face detection with a manual Face region for those photos. The output holds the healed JPEG, the stroke coordinates and a Cheek width −75% rendering for each portrait.

Detection catches discrete spots and stronger freckles but leaves broad redness and faint freckles, can take decorations for blemishes, and misses raised moles. Partial faces and tight profile crops need a manual Face region; a region that is too tight finds little until it is widened.

## Tonal spot review

Run `app/scripts/test.sh --filter TonalSpotReviewTests` with `CEVICHE_SPOT_RAW`, an existing local output folder in `CEVICHE_SPOT_REVIEW`, normalized top-left coordinates in `CEVICHE_SPOT_X` and `CEVICHE_SPOT_Y`, and radius as a fraction of the short side in `CEVICHE_SPOT_RADIUS`. The review reports signed EV and writes matching before and after crops.
