# Building

Runs on macOS 15 or later on Apple silicon; it is developed and tested on macOS 27. Features that depend on newer system frameworks are checked at run time rather than compiled out: Object selection needs the Vision segmentation of macOS 27 and is disabled before that, the export format list follows the encoders ImageIO offers on the running system, and before macOS 26 the HDR headroom of rendered images is measured from their pixels instead of carried by Core Image. Building needs Xcode 27 (the macOS 27 SDK) or the matching Swift command-line tools, whatever the deployment target, because those newer APIs are referenced behind availability checks.

The app bundle carries only the small face models listed in `models/models.sh` (`MODEL_BUNDLED`: FaceMesh, PeopleParts and SFace): the build compiles them from `models/build` into `CevicheKit.framework/Resources/Models`, where the app, the index service and the MCP helper all find them. A build without them only warns and the app offers them as downloads; `make snapshot` and the Release workflow set `CEVICHE_REQUIRE_BUNDLED_MODELS=1` and fetch them first with `models/fetch-models.sh --prebuilt FaceMesh PeopleParts SFace`. Users download the other models in **Ceviche › Settings… › Models**, from the model set pinned in `app/Sources/CevicheCore/Resources/ModelSet.json` (a GitHub release such as `models-v1`; every file is verified against the SHA-256 recorded there) into `~/Library/Application Support/Ceviche/Models`, or add them from files (**From File…**, which also works offline); a missing model disables only its feature. That is the community build; the App Store build (`CEVICHE_DISTRIBUTION=appstore`) does not download from GitHub and, until it gets Apple-hosted assets, only adds models from files. For development, `make models` converts the models into `models/build` (needs `uv` and network access; `ML_PYTHON` can instead point to an environment with `models/requirements.txt` installed) and `make models-prebuilt` downloads the pinned set there without Python. The build compiles them into `models/build/compiled`, and a debug build records that folder in its Info.plist (`CevicheDevelopmentModels`) so `make dev` sees them without copying; a release build knows only its built-in models and the user's library. To test the app as users run it, `make models-install` compiles the models in `models/build` into that library, each in its own folder with its license and the same record the Models window writes, and `make models-uninstall` removes them. Tests find models through `CEVICHE_MODELS`, usually `models/build/compiled`, and skip without them.

```sh
make            # release build into app/dist/Ceviche.app
make run        # build and open it
make dev        # debug build (seconds, not minutes, after an edit), then relaunch the app
make xcode      # write Platforms/macOS/Config/Local.xcconfig from build.config and open app/Ceviche.xcodeproj
make snapshot   # test build for internal testers: app/dist/snapshots/Ceviche-<version>-<build>-<commit>.zip
make test       # the test suite: synthetic inputs and local photos, a couple of minutes
make test-slow  # also GPU-vs-CPU comparisons, Core ML models and full-size RAW exports
make help       # every target and variable
```

`make` wraps the scripts in `app/scripts`, which can also be run directly.

The app is built by `app/Ceviche.xcodeproj` (Xcode 16+ synchronized folders: adding a file to a target's folder needs
no project change), whose Mac targets are the launcher (`app/Platforms/macOS/Launcher`), the index service and
`ceviche-mcp`. The app's code and everything it links stay in `app/Package.swift`, a local package the project links
as its dynamic `CevicheKit` product (`Contents/Frameworks/CevicheKit.framework`) and that `swift test` builds on its
own. `build.sh` takes `release` (the default) or `debug` and does what `xcodebuild` cannot: it writes the build
settings, builds the codec frameworks (`vendor.sh`; the package needs them before Xcode can resolve it), runs
`xcodebuild` into `app/.build/xcode`, and copies the app to `app/dist/Ceviche.app`. A release build is stripped and
keeps its symbols in `app/dist/dSYMs` for symbolicating crash logs; a debug build keeps them for lldb. Everything else
is in the project: `app/Platforms/macOS/Config/*.xcconfig` for the settings, and two script phases (`app/scripts/xcode-phase.sh`) that check
the settings, string tables and licence notices first, then add the presets, licences, `d.json` (the edit schema,
from `ceviche-mcp --schema`) and the compiled development models, and move the package resource bundles into
CevicheKit, where every executable's `Bundle.module` finds them. To open a photo at launch:

```sh
open app/dist/Ceviche.app --args "/path/to/photo.ARW"
```

`make xcode` opens the project with the same settings as `make` (`app/Platforms/macOS/Config/Local.xcconfig`, git-ignored, written from
`build.config`; run it again after changing that file). The Xcode window builds into its own DerivedData, so it does
not disturb `make dev`.

Build settings come from the environment, then `build.config` at the repository root (copy `build.config.example`;
git-ignored), then the defaults; no personal value is committed. They become the `CEVICHE_*` inputs of
`app/Platforms/macOS/Config/Ceviche.xcconfig`:

| Variable | |
|---|---|
| `CEVICHE_DISTRIBUTION` | `community` (default: macOS 15, no store) or `appstore` (macOS 26, Ceviche Pro, needs `CEVICHE_STORE_PRODUCTS` and the sandbox) |
| `CEVICHE_SANDBOX` | `1` or `0`; on by default only for `appstore`. Off, the app keeps only its USB and Photos entitlements and the helpers are signed without any |
| `CEVICHE_IOS` | `1` or `0` (default): also build the export codecs for iOS and the iOS Simulator. Once built the iOS slices are kept |
| `CEVICHE_ICLOUD` | `1` or `0` (default): iCloud catalogs and iCloud Drive; `1` needs `CEVICHE_TEAM_ID` |
| `CEVICHE_SIGN_IDENTITY` | a certificate name or SHA-1 hash; a Developer ID also gets the hardened runtime and a secure timestamp |
| `CEVICHE_PROVISIONING_PROFILE` | an installed profile's name or UUID, for iCloud with `CEVICHE_SIGN_IDENTITY` |

Signing follows from them: with `CEVICHE_SIGN_IDENTITY`, that identity; with iCloud on and no identity, Xcode signs
for the team automatically (it registers the App ID, the iCloud container and a development profile on the first
build, and needs the Apple Developer account signed in to Xcode); otherwise ad hoc, without the iCloud keys.

With the sandbox on, the app's sandbox grants user-selected read/write access and persistent app-scoped bookmarks,
outgoing network connections (downloads, maps and iCloud), incoming connections (the optional loopback MCP server),
USB camera access, Photos library access and printing. It requests no blanket filesystem exceptions. A mounted card or
network share still needs a folder selection; USB and network entitlements do not grant filesystem access. The Folders
sidebar uses an Open panel for each new root, and remembers the grant for later launches. Catalogs and imported
references also retain their grants. App data lives in the sandbox container; use Open Catalog to reopen an existing
catalog from a build that ran outside the sandbox. Command-line paths alone cannot grant sandbox access: select those
locations in the app first.

The MCP stdio helper has its own sandbox with outgoing network access only. The XPC index service has its own
sandbox with file and bookmark access; each batch receives ordinary bookmarks carrying the app's current file
grants, including access to catalogs in the app container. Neither executable inherits an unrestricted sandbox.
The entitlements are in `app/Platforms/macOS/Entitlements`, one app file for each combination of sandbox and iCloud.

`make snapshot` packs a zip for internal testers: the app (built without iCloud, build number = commit count; signed with the team's Developer ID and notarized when `CEVICHE_NOTARY_PROFILE` is set in `build.config`), and read-me files in the app's five languages (templates in `app/scripts/snapshot`). It is always a community build with the face models built in, so testers download the rest of the pinned model set from Ceviche › Settings… › Models. `make snapshot MODELS=1` (or `snapshot-local MODELS=1`) also packs that set for offline testers as `Ceviche-<tag>.zip`, a Models folder laid out as the app installs each release archive, built from the archives cached in `models/cache/prebuilt` while the app builds and kept for later snapshots of the same tag. It builds in its own DerivedData, so it does not disturb `make dev`.

The Looks tab's **Built-in** presets ship in the app: the build copies `presets/` into `Contents/Resources/Presets`. Ceviche's own packs (Black & White, Color) are kept in git; the open-source packs are downloaded there at a pinned commit by `presets/fetch-presets.sh` (`make presets`, which the build runs when they are missing). Built-in presets are read-only.

The welcome screen's photos come from `welcome/`: the photos (or short `.mp4`/`.mov` clips, played muted on a loop; `app/scripts/welcome-video.sh` encodes one) and `photos.csv`, with the header
`file,title,author,link` and one row per photo; `author` and `link` may be empty, and a link (https) makes the
author's name a link. `app/scripts/welcome-photos.py` fails the build when a photo has no row or a row no photo, then copies
both into `Contents/Resources/Welcome` with the credits as `photos.json`. One photo is picked at random each launch;
without `welcome/` the screen shows no photo.

## Continuous integration and releases

Three GitHub Actions workflows in `.github/workflows` run on GitHub's `xcode-27` macOS image with the same scripts as above:

- **CI** (`ci.yml`): a debug build and `make test`, then a launch of the built app on macOS 15. Automatic runs on pushes and pull requests are paused to save Actions credits, so it runs only by hand (Actions › CI › Run workflow); until they return, run `make test` locally before merging.
- **Release** (`release.yml`): for a `v*` tag whose version matches `CFBundleShortVersionString`, a release build zipped with its dSYMs and checksums, attached to a draft GitHub release to finish by hand (notes, the samples archive). Run manually it only uploads the same files as a workflow artifact.
- **Models** (`models.yml`): run by hand with a tag such as `models-v2`, converts every model with `models/fetch-models.sh`, packages them with `models/package-models.sh` (one uncompressed Apple Archive per model, `<Name>.aar` with the model and its `LICENSE`, and for the models in `MODEL_INT8` a `<Name>-INT8.aar` with the INT8 copy that `models/quantize_int8.py` writes, plus `SHA256SUMS` and the `ModelSet.json` manifest, which lists the INT8 archives under `int8`; the app unpacks them with the AppleArchive framework) and publishes them as a model-set release, then opens a pull request that pins the manifest in the app. Model sets are versioned apart from the app and never overwritten; an app build downloads only the set it pins, so a new set reaches users through that one-file change, made only when a model changes. `make models-pin TAG=models-vN` pins by hand.

## App icon and wordmark

The tracked `app/Platforms/macOS/Resources/AppIcon.icns` is the application's icon. After changing the shared
bowl source in `docs/design/identity-system`, run `swift app/scripts/identity.swift` to export the Mac PNG and
outlined Nunito wordmarks, then `bash app/scripts/app-icon.sh` to rebuild the `.icns`. The latter uses `uv` for
its pinned compression tools. The [identity notes](../design/identity-system/README.md) describe the sources,
platform framing and font licence. Normal builds consume the tracked exports and do not regenerate the artwork.

## Export encoders

WebP and JPEG XL build through SwiftPM from pinned source dependencies in `app/Vendor/Package.swift`.
`app/scripts/vendor.sh`, which `build.sh` and `test.sh` run first (`make vendor` before opening the project in Xcode), compiles them once with optimization, as
static libraries for macOS on Apple silicon, into `app/Vendor/Frameworks` (git-ignored) as `CWebP.xcframework` and
`CJXL.xcframework`. `CEVICHE_IOS=1` also builds iOS and iOS Simulator slices, for iOS builds of the package; `app/Package.swift` links them on iOS when the slices are there, read from disk because Xcode caches
the evaluated manifest. On the Mac they are linked into `CevicheKit.framework`, so nothing else is embedded, the linker drops the
code the app never calls, and debug app builds neither recompile the codecs nor run them unoptimized. They are rebuilt
only when `app/Vendor/Package.swift`, its `Package.resolved` or `vendor.sh` changes.

The encoders and their dependencies use permissive open-source licenses.
See [encoder license and distribution notes](../../app/licenses/ENCODERS.md). The bundle includes
native dependency notices; the encoders' exact revisions are pinned in `app/Vendor/Package.resolved`, which the
release's source archive carries.
