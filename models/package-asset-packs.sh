#!/bin/bash
# Makes the App Store build's model asset packs from a model-set release in models/dist (models/package-models.sh): one
# on-demand Apple-hosted pack per archive, named after the set's tag and the archive (<tag>.<Name> for FP16,
# <tag>.<Name>-INT8), holding that archive as the release has it. The tag is in the name because a pack is not tied to
# a build: a new version of a pack reaches every installed build, so each set's archives get packs of their own, so the app verifies it against the same pinned SHA-256 and installs it the same way
# (CevicheCore's ModelAssetPacks). The packs land in models/asset-packs, ready to upload to App Store Connect; they
# must belong to the model set the Store build pins (app/Sources/CevicheCore/Resources/ModelSet.json).
# Usage: package-asset-packs.sh <tag>   (the tag the Store build pins, such as models-v1)
set -euo pipefail
ML="$(cd "$(dirname "$0")" && pwd)"
TAG="${1:?usage: package-asset-packs.sh <tag>}"
DIST="$ML/dist"; OUT="$ML/asset-packs"
compgen -G "$DIST/*.aar" >/dev/null || { printf 'No archives in %s; run models/package-models.sh <tag> first.\n' "$DIST" >&2; exit 1; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ceviche-packs.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
rm -rf "${OUT:?}"; mkdir -p "$OUT"
for archive in "$DIST"/*.aar; do
    file="$(basename "$archive")"; id="$TAG.${file%.aar}"
    # On demand: the app asks for a model when a feature needs it, never at install.
    cat > "$WORK/$id.json" <<MANIFEST
{
    "assetPackID": "$id",
    "downloadPolicy": { "onDemand": {} },
    "fileSelectors": [ { "file": "$file" } ],
    "platforms": [ "iOS" ]
}
MANIFEST
    # The file selector is resolved against the working directory.
    (cd "$DIST" && xcrun ba-package package "$WORK/$id.json" --output-path "$OUT/$id.aar" --quiet)
    printf '%s\n' "$id"
done
