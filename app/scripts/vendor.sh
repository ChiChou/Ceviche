#!/bin/bash
# Builds the third-party codecs in Vendor/Package.swift, optimized, as static libraries for macOS on Apple silicon (and,
# with CEVICHE_IOS=1, for iOS and the iOS Simulator), and packs each into an xcframework in Vendor/Frameworks (CWebP,
# CJXL), which app/Package.swift links into
# CevicheKit. Nothing is embedded in the app: the codecs are part of CevicheKit's binary, and the linker drops what it
# doesn't call. Debug and release app builds share them; they are rebuilt only when the vendor package or this script
# changes.
set -euo pipefail
APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$APP_ROOT/Vendor"
OUT="$VENDOR/Frameworks"
SCRATCH="$APP_ROOT/.build/vendor"
source "$APP_ROOT/scripts/config.sh"
# Package.resolved does not exist until the first build resolves the package. Turning CEVICHE_IOS on or off rebuilds.
stamp() { { cat "$VENDOR/Package.swift" "$0" $([[ -f "$VENDOR/Package.resolved" ]] && echo "$VENDOR/Package.resolved"); echo "ios=$CEVICHE_IOS"; } | shasum | cut -d' ' -f1; }
[[ -f "$OUT/.stamp" && "$(cat "$OUT/.stamp")" == "$(stamp)" ]] && exit 0
# triple:sdk for each slice; the minimum systems match app/Package.swift. The iOS slices add about 40 s.
SLICES=("arm64-apple-macosx15.0:macosx")
[[ "$CEVICHE_IOS" == 0 ]] || SLICES+=("arm64-apple-ios26.0:iphoneos" "arm64-apple-ios26.0-simulator:iphonesimulator")
BIN_DIRS=()
for slice in "${SLICES[@]}"; do
    triple="${slice%%:*}" sdk="$(xcrun --sdk "${slice##*:}" --show-sdk-path)"
    args=(--package-path "$VENDOR" --scratch-path "$SCRATCH" --configuration release --triple "$triple" --sdk "$sdk")
    swift build "${args[@]}"
    BIN_DIRS+=("$(swift build "${args[@]}" --show-bin-path)")
done
CHECKOUTS="$SCRATCH/checkouts"
rm -rf "$OUT"; mkdir -p "$OUT"
# xcframework NAME FOLDER HEADER...: the headers go in Headers/FOLDER, where the codecs' own includes (<jxl/types.h>)
# find them, and the module map in Headers/NAME, so the two xcframeworks' headers never land on the same path.
xcframework() {
    local name="$1" folder="$2"; shift 2
    local headers="$SCRATCH/headers/$name" header bin args=()
    rm -rf "$headers"; mkdir -p "$headers/$folder" "$headers/$name"
    cp -L "$@" "$headers/$folder/"
    { printf 'module %s {\n' "$name"
      for header in "$@"; do printf '    header "../%s/%s"\n' "$folder" "$(basename "$header")"; done
      printf '    export *\n}\n'; } > "$headers/$name/module.modulemap"
    for bin in "${BIN_DIRS[@]}"; do args+=(-library "$bin/lib$name.a" -headers "$headers"); done
    xcodebuild -create-xcframework "${args[@]}" -output "$OUT/$name.xcframework" >/dev/null
}
xcframework CWebP webp "$CHECKOUTS"/libwebp-Xcode/include/webp/*.h
xcframework CJXL jxl "$CHECKOUTS"/libjxl-Xcode/include/jxl/*.h
# Every global symbol the codecs define, which a release link of CevicheKit keeps out of its exports
# (app/Package.swift), so that dead stripping can drop the codec code the app never calls.
for bin in "${BIN_DIRS[@]}"; do nm -gU -j "$bin/libCWebP.a" "$bin/libCJXL.a"; done | grep -v -e ':$' -e '^$' | sort -u > "$OUT/codec-symbols.txt"
stamp > "$OUT/.stamp"
