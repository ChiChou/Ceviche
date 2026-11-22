#!/bin/bash
# Downloads the open-source preset packs into presets/, beside Ceviche's own (Black & White, Color), which are kept in
# git. The downloaded packs are git-ignored; each is pinned to a commit and checked against its SHA-256.
#   EmulsionPresets  github.com/peva3/EmulsionPresets, MIT: film emulation presets, .xmp only, with its LICENSE
set -euo pipefail
PRESETS="$(cd "$(dirname "$0")" && pwd)"
EMULSION_COMMIT=0cdb71c60603867a046bc92c63617feec7894dd1
EMULSION_SHA256=c0f77c53c336d4f00d0fc41c48c76a4ddb464193bd846de4b5cbea6d1d0ec5ba
TARGET="$PRESETS/EmulsionPresets"

if [[ "$(cat "$TARGET/.commit" 2>/dev/null)" == "$EMULSION_COMMIT" ]]; then
    printf 'EmulsionPresets %s already in %s\n' "${EMULSION_COMMIT:0:7}" "$TARGET"; exit 0
fi
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
curl -fsSL --retry 3 -o "$WORK/archive.tar.gz" "https://codeload.github.com/peva3/EmulsionPresets/tar.gz/$EMULSION_COMMIT"
actual="$(shasum -a 256 "$WORK/archive.tar.gz" | cut -d' ' -f1)"
[[ "$actual" == "$EMULSION_SHA256" ]] || { printf 'Checksum mismatch for EmulsionPresets\n  expected %s\n  actual   %s\n' "$EMULSION_SHA256" "$actual" >&2; exit 1; }
mkdir -p "$WORK/x"; tar -xzf "$WORK/archive.tar.gz" -C "$WORK/x"
SOURCE="$WORK/x/EmulsionPresets-$EMULSION_COMMIT"
rm -rf "$TARGET"; mkdir -p "$TARGET"
(cd "$SOURCE/Presets" && find . -type f -name '*.xmp' -print0 | xargs -0 -I{} ditto {} "$TARGET/{}")
cp "$SOURCE/LICENSE" "$TARGET/LICENSE"
printf '%s\n' "$EMULSION_COMMIT" > "$TARGET/.commit"
printf 'EmulsionPresets %s: %s presets in %s\n' "${EMULSION_COMMIT:0:7}" "$(find "$TARGET" -name '*.xmp' | wc -l | tr -d ' ')" "$TARGET"
