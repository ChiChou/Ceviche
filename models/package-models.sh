#!/bin/bash
# Packages the converted models in models/build for a model-set release into models/dist: one uncompressed Apple
# Archive per model, <Name>.aar holding <Name>/<Name>.mlpackage (or .mlmodel) and <Name>/LICENSE; for the models in
# models.sh MODEL_INT8 also <Name>-INT8.aar, laid out the same with the INT8 copy (listed under "int8" in the
# manifest, so users can choose either); SHA256SUMS over them, and ModelSet.json, the manifest the app pins (copied to app/Sources/CevicheCore/Resources/ModelSet.json when the
# set is published). Each model is its own file so the app can fetch one at a time. The archives leave out owners,
# times and extended attributes, so the same models always give the same bytes. The app and fetch-models.sh
# --prebuilt download and verify exactly these files, so the set must be complete and every model must compile.
# Usage: package-models.sh <tag>   (models-v1, models-v2, ...). Run by .github/workflows/models.yml.
set -euo pipefail
TAG="${1:?usage: package-models.sh <tag>}"
[[ "$TAG" =~ ^models-v[0-9]+$ ]] || { printf '%s is not of the form models-v<number>.\n' "$TAG" >&2; exit 1; }
REPO="${CEVICHE_MODELS_REPO:-ChiChou/Ceviche}"
ML="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ML/build"; DIST="$ML/dist"
source "$ML/models.sh"
rm -rf "${DIST:?}"; mkdir -p "$DIST"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ceviche-models.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
pack() { # model file in models/build, name inside the archive (<Name>.mlpackage), license, archive name
    local key="${2%%.*}"
    [[ -e "$BUILD/$1" ]] || { printf 'Missing %s; run models/fetch-models.sh first.\n' "$BUILD/$1" >&2; exit 1; }
    [[ -f "$3" ]] || { printf 'Missing %s.\n' "$3" >&2; exit 1; }
    xcrun coremlcompiler compile "$BUILD/$1" "$WORK/compiled" >/dev/null || { printf '%s does not compile.\n' "$1" >&2; exit 1; }
    rm -rf "${WORK:?}/${key:?}"; mkdir -p "$WORK/$key"
    ditto --norsrc --noextattr "$BUILD/$1" "$WORK/$key/$2"
    cp "$3" "$WORK/$key/LICENSE"
    aa archive -a raw -d "$WORK" -subdir "$key" -exclude-field uid,gid,flg,ctm,mtm,btm,xat,acl -o "$DIST/$4"
    printf '%s\n' "$4"
}
for name in "${MODEL_NAMES[@]}"; do
    key="${name%%.*}"; license="$ML/licenses/$(model_license "$name")"
    pack "$name" "$name" "$license" "$key.aar"
    # The INT8 copy keeps the model's own name inside, so it installs in the same place.
    [[ " ${MODEL_INT8[*]} " != *" $key "* ]] || pack "$key-INT8.${name##*.}" "$name" "$license" "$key-INT8.aar"
done
(cd "$DIST" && shasum -a 256 *.aar > SHA256SUMS)
python3 -I - "$DIST" "$TAG" "$REPO" "${MODEL_NAMES[@]}" <<'MANIFEST'
import hashlib, json, os, sys
dist, tag, repo, names = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
keys = [name.split(".")[0] for name in names]
def asset(file):
    path = os.path.join(dist, file)
    with open(path, "rb") as f: digest = hashlib.sha256(f.read()).hexdigest()
    return {"file": file, "sha256": digest, "bytes": os.path.getsize(path)}
manifest = {"repository": repo, "tag": tag, "models": {key: asset(key + ".aar") for key in keys},
            "int8": {key: asset(key + "-INT8.aar") for key in keys if os.path.exists(os.path.join(dist, key + "-INT8.aar"))}}
with open(os.path.join(dist, "ModelSet.json"), "w") as f: json.dump(manifest, f, indent=2, sort_keys=True); f.write("\n")
MANIFEST
printf 'Model set %s packaged in %s\n' "$TAG" "$DIST"
