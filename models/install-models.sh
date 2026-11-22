#!/bin/bash
# Installs locally converted models into this user's model library, ~/Library/Application Support/Ceviche/Models,
# laid out as the app installs a release archive: <Name>/<Name>.mlmodelc, <Name>/LICENSE and the <Name>/<Name>.json record. For
# testing the app as users will run it (a release build knows only the library) without a published model set.
#   install-models.sh              install every model in models/build (run models/fetch-models.sh or make models first)
#   install-models.sh --uninstall  remove the models and their records from the library again
set -euo pipefail
ML="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ML/build"; COMPILED="$BUILD/compiled"
LIBRARY="${CEVICHE_MODEL_LIBRARY:-$HOME/Library/Application Support/Ceviche/Models}"
source "$ML/models.sh"

if [[ "${1:-}" == "--uninstall" ]]; then
    for name in "${MODEL_NAMES[@]}"; do
        key="${name%.*}"
        rm -rf "${LIBRARY:?}/${key:?}" "${LIBRARY:?}/${key:?}.mlmodelc" "${LIBRARY:?}/${key:?}.json"
    done
    printf 'Removed the models from %s\n' "$LIBRARY"
    exit 0
fi

mkdir -p "$COMPILED" "$LIBRARY"
installed=0
for name in "${MODEL_NAMES[@]}"; do
    key="${name%.*}"
    model="$BUILD/$name"
    [[ -e "$model" ]] || { printf 'Skipping %s: not in %s (run make models).\n' "$key" "$BUILD"; continue; }
    compiled="$COMPILED/$key.mlmodelc"
    if [[ ! -d "$compiled" || "$model" -nt "$compiled" ]]; then
        rm -rf "${compiled:?}"; xcrun coremlcompiler compile "$model" "$COMPILED" >/dev/null
    fi
    # A copy from before the per-model folders would hide nothing, but would linger.
    rm -rf "${LIBRARY:?}/${key:?}" "${LIBRARY:?}/${key:?}.mlmodelc" "${LIBRARY:?}/${key:?}.json"
    mkdir -p "$LIBRARY/$key"
    cp -R "$compiled" "$LIBRARY/$key/$key.mlmodelc"
    cp "$ML/licenses/$(model_license "$name")" "$LIBRARY/$key/LICENSE"
    # The record the app keeps for a model added from a file (ModelLibrary.Installed).
    bytes="$(du -sk "$LIBRARY/$key/$key.mlmodelc" | cut -f1)"
    printf '{\n  "bytes" : %s,\n  "installedAt" : "%s",\n  "sha256" : null,\n  "source" : "file",\n  "tag" : null\n}\n' \
        "$((bytes * 1024))" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$LIBRARY/$key/$key.json"
    printf 'Installed %s\n' "$key"
    installed=$((installed + 1))
done
printf '%d model(s) in %s. Relaunch Ceviche, or reopen its Models window, to see them.\n' "$installed" "$LIBRARY"
