#!/bin/bash
# Builds app/dist/Ceviche.app with Ceviche.xcodeproj, doing first what xcodebuild cannot: the build settings from
# build.config (Platforms/macOS/Config/Local.xcconfig, which the Xcode window reads too), the static codec libraries the package links as
# binary targets (they must exist before Xcode resolves the package), and afterwards the dSYMs beside the app.
#
# CEVICHE_DIST, CEVICHE_DERIVED and CEVICHE_XCCONFIG let scripts/snapshot.sh build with other settings without
# touching the everyday build: CEVICHE_XCCONFIG is written there and passed with -xcconfig instead of Local.xcconfig.
set -euo pipefail
APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-release}"
case "$CONFIGURATION" in
    debug) XCODE_CONFIGURATION=Debug ;;
    release) XCODE_CONFIGURATION=Release ;;
    # Only the settings and the pinned dependencies, for the Xcode window (make xcode).
    --configure) XCODE_CONFIGURATION=Debug ;;
    *) printf 'Usage: %s [debug|release|--configure]\n' "$0" >&2; exit 2 ;;
esac
source "$APP_ROOT/scripts/config.sh"
"$APP_ROOT/scripts/vendor.sh"
XCODE=(-project "$APP_ROOT/Ceviche.xcodeproj" -scheme Ceviche -configuration "$XCODE_CONFIGURATION"
       -destination generic/platform=macOS -derivedDataPath "${CEVICHE_DERIVED:-$APP_ROOT/.build/xcode}"
       -clonedSourcePackagesDirPath "$APP_ROOT/.build/xcode-packages")
if [[ -n "${CEVICHE_XCCONFIG:-}" ]]; then
    write_xcconfig "$CEVICHE_XCCONFIG"; XCODE+=(-xcconfig "$CEVICHE_XCCONFIG")
else
    write_xcconfig "$APP_ROOT/Platforms/macOS/Config/Local.xcconfig"
fi
# Xcode registers the App ID, the iCloud container and a development profile when it signs for the team.
[[ "$CEVICHE_SIGNING" != automatic ]] || XCODE+=(-allowProvisioningUpdates)
# The same dependency versions the tests build with.
RESOLVED="$APP_ROOT/Ceviche.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$RESOLVED"; cp "$APP_ROOT/Package.resolved" "$RESOLVED/Package.resolved"
[[ "$CONFIGURATION" != --configure ]] || exit 0
DIST="${CEVICHE_DIST:-$APP_ROOT/dist}"
# Apple silicon only, as SwiftPM builds: the code does not build for Intel (Float16).
XCODE+=(ARCHS=arm64)
# Release code optimized for size, on the command line so it reaches the package targets too (the xcconfig only
# reaches the project's): the app layer and GRDB shrink by about 4.7 MB. The pixel code keeps -O, which Package.swift
# forces on CevicheCore, FilmPrint and CameraRaw.
[[ "$CONFIGURATION" != release ]] || XCODE+=(SWIFT_OPTIMIZATION_LEVEL=-Osize)
xcodebuild build "${XCODE[@]}" -quiet
PRODUCTS="$(xcodebuild "${XCODE[@]}" -showBuildSettings 2>/dev/null | awk '$1 == "BUILT_PRODUCTS_DIR" { print $3; exit }')"
# A copy, so a launched app never holds Xcode's product, and app/dist can be deleted on its own. A release build is
# stripped and keeps its symbols in dSYMs, for symbolicating crash logs; a debug build keeps them in place for lldb.
rm -rf "$DIST/Ceviche.app"; mkdir -p "$DIST"
ditto "$PRODUCTS/Ceviche.app" "$DIST/Ceviche.app"
if [[ "$CONFIGURATION" == release ]]; then
    rm -rf "$DIST/dSYMs"; mkdir -p "$DIST/dSYMs"
    find "$PRODUCTS" "$PRODUCTS/PackageFrameworks" -maxdepth 1 -name '*.dSYM' -exec cp -R {} "$DIST/dSYMs/" \;
fi
printf '\nBuilt %s (%s)\n' "$DIST/Ceviche.app" "$CEVICHE_SIGNING"
