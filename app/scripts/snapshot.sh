#!/bin/bash
# A snapshot for internal testers: one zip with the app, which carries its presets, and read-me files saying how to
# install it. Written to app/dist/snapshots/; the dSYMs are zipped beside it. The snapshot is a community build, which
# downloads the model set pinned in CevicheCore/Resources/ModelSet.json from its Models window.
#
# `--models` also packs that model set for testers without the download, as a second zip named by its tag
# (Ceviche-models-v1.zip), packed once per tag and kept for later snapshots. Its Models folder holds each model as the
# app installs it from the release archive with From File…: <Name>/<Name>.mlmodelc, the archive's LICENSE and the
# <Name>.json record of the pinned tag and checksum, so the app takes them for the pinned set. It is packed while the
# app builds, from the release archives cached in models/cache/prebuilt/<tag>.
#
# The app is built without iCloud, so it runs on Macs outside the provisioning profile. It is signed with this Mac's
# Developer ID Application identity (or CEVICHE_SIGN_IDENTITY), and notarized and stapled when CEVICHE_NOTARY_PROFILE
# names a notarytool keychain profile (xcrun notarytool store-credentials). Without a Developer ID it is signed with
# the development identity or ad hoc and not notarized, and the read-me files then tell testers to clear the quarantine
# with `xattr -rc`.
#
# `snapshot.sh --local` (make snapshot-local) skips notarization, for testing on this Mac: nothing goes to Apple, and
# the read-me files keep the xattr note.
#
# A dirty working tree is built too, marked -dirty in the name.
set -euo pipefail
LOCAL=0; WITH_MODELS=0
for arg in "$@"; do
    case "$arg" in
        --local) LOCAL=1 ;;
        --models) WITH_MODELS=1 ;;
        *) printf 'Usage: %s [--local] [--models]\n' "$0" >&2; exit 2 ;;
    esac
done
APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/.." && pwd)"
TEMPLATES="$APP_ROOT/scripts/snapshot"

version="$(plutil -extract CFBundleShortVersionString raw "$APP_ROOT/Platforms/macOS/Info.plist")"
build="$(git -C "$REPO_ROOT" rev-list --count HEAD)"
commit="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
dirty=""; [[ -z "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no)" ]] || dirty="-dirty"
NAME="Ceviche-$version-$build-$commit$dirty"
# One run per checkout: each starts by clearing the staging folder another run would be packing.
mkdir -p "$APP_ROOT/.build"
LOCK="$APP_ROOT/.build/snapshot.lock"
shlock -f "$LOCK" -p $$ || { printf 'Another make snapshot is running in this checkout (PID %s).\n' "$(cat "$LOCK")" >&2; exit 1; }
MODELS_PID=""
trap 'rm -f "$LOCK"; [[ -z "$MODELS_PID" ]] || kill "$MODELS_PID" 2>/dev/null || true' EXIT
OUT="$APP_ROOT/dist/snapshots"
STAGE="$APP_ROOT/.build/snapshot-stage"
# Team, signing identity and notary profile: the environment, then build.config. Always the community build, whatever
# build.config says: only it downloads the models.
export CEVICHE_DISTRIBUTION=community
source "$APP_ROOT/scripts/config.sh"
if [[ -z "${CEVICHE_SIGN_IDENTITY:-}" ]]; then
    CEVICHE_SIGN_IDENTITY="$(security find-identity -v -p codesigning | grep '"Developer ID Application:' \
        | grep -F "(${CEVICHE_TEAM_ID:-})" | awk '{print $2}' | head -1 || true)"
fi
export CEVICHE_SIGN_IDENTITY
NOTARY="${CEVICHE_NOTARY_PROFILE:-}"
[[ $LOCAL == 0 ]] || NOTARY=""
if [[ -n "$NOTARY" ]]; then
    [[ -n "$CEVICHE_SIGN_IDENTITY" ]] || { printf 'Notarization needs a Developer ID Application identity.\n' >&2; exit 1; }
    xcrun notarytool history --keychain-profile "$NOTARY" >/dev/null \
        || { printf 'No notary profile %s: run xcrun notarytool store-credentials %s\n' "$NOTARY" "$NOTARY" >&2; exit 1; }
fi
[[ -z "$dirty" ]] || printf 'warning: uncommitted changes; the snapshot is named %s\n' "$NAME" >&2

# Its own scratch and output folders: the flags differ from an everyday build (no iCloud), and a copy of the app that
# has been launched cannot be rebuilt in place.
rm -rf "$STAGE"; mkdir -p "$STAGE/$NAME" "$OUT"

MANIFEST="$APP_ROOT/Sources/CevicheCore/Resources/ModelSet.json"
manifest() { python3 -I -c 'import json, sys; m = json.load(open(sys.argv[1])); print(eval(sys.argv[2], {"m": m}) or "")' "$MANIFEST" "$1"; }
TAG="$(manifest 'm.get("tag")')"
MODELS_ZIP="$OUT/Ceviche-$TAG.zip"
# Downloads each pinned archive (or takes it from the cache), unpacks and compiles it as the app does, and zips the
# Models folder. Runs beside the app build; its output goes to a log shown only when it fails.
pack_models() {
    local repo base cache work key file sha bytes source
    repo="$(manifest 'm["repository"]')"; base="https://github.com/$repo/releases/download/$TAG"
    cache="$REPO_ROOT/models/cache/prebuilt/$TAG"; work="$STAGE/models"
    mkdir -p "$cache" "$work/Ceviche-$TAG/Models"
    for key in $(manifest '" ".join(sorted(m["models"]))'); do
        file="$(manifest "m['models']['$key']['file']")"; sha="$(manifest "m['models']['$key']['sha256']")"
        bytes="$(manifest "m['models']['$key']['bytes']")"
        if [[ ! -f "$cache/$file" || "$(shasum -a 256 "$cache/$file" | cut -d' ' -f1)" != "$sha" ]]; then
            curl -fsSL --retry 3 -o "$cache/$file.partial" "$base/$file"
            [[ "$(shasum -a 256 "$cache/$file.partial" | cut -d' ' -f1)" == "$sha" ]] || { printf 'Checksum mismatch for %s\n' "$file"; return 1; }
            mv "$cache/$file.partial" "$cache/$file"
        fi
        rm -rf "$work/unpacked"; mkdir -p "$work/unpacked"
        aa extract -i "$cache/$file" -d "$work/unpacked"
        source="$(find "$work/unpacked/$key" -maxdepth 1 \( -name "$key.mlpackage" -o -name "$key.mlmodel" \) | head -1)"
        [[ -n "$source" && -f "$work/unpacked/$key/LICENSE" ]] || { printf '%s does not hold %s/%s.ml* and its LICENSE\n' "$file" "$key" "$key"; return 1; }
        local folder="$work/Ceviche-$TAG/Models/$key"
        mkdir -p "$folder"
        xcrun coremlcompiler compile "$source" "$folder" >/dev/null
        cp "$work/unpacked/$key/LICENSE" "$folder/LICENSE"
        # The record From File… writes for a pinned archive (ModelLibrary.Installed).
        printf '{\n  "bytes" : %s,\n  "installedAt" : "%s",\n  "sha256" : "%s",\n  "source" : "file",\n  "tag" : "%s"\n}\n' \
            "$bytes" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$sha" "$TAG" > "$folder/$key.json"
        printf 'Packed %s\n' "$key"
    done
    rm -rf "$work/unpacked"
    ditto -c -k --norsrc --keepParent "$work/Ceviche-$TAG" "$MODELS_ZIP.partial"
    mv "$MODELS_ZIP.partial" "$MODELS_ZIP"
    (cd "$OUT" && shasum -a 256 "$(basename "$MODELS_ZIP")" > "$(basename "$MODELS_ZIP").sha256")
}
models_packed=no
if [[ $WITH_MODELS == 1 ]]; then
    [[ -n "$TAG" ]] || { printf '%s pins no model set.\n' "$MANIFEST" >&2; exit 1; }
    if [[ -f "$MODELS_ZIP" ]]; then
        models_packed=kept
    else
        pack_models > "$STAGE/models.log" 2>&1 &
        MODELS_PID=$!
    fi
fi
# The built-in models: the ones in models/build (a local make models), else the pinned set's.
source "$REPO_ROOT/models/models.sh"
absent=()
for key in "${MODEL_BUNDLED[@]}"; do compgen -G "$REPO_ROOT/models/build/$key.ml*" >/dev/null || absent+=("$key"); done
[[ ${#absent[@]} == 0 ]] || "$REPO_ROOT/models/fetch-models.sh" --prebuilt "${absent[@]}"
CEVICHE_REQUIRE_BUNDLED_MODELS=1 CEVICHE_ICLOUD=0 CEVICHE_BUILD_NUMBER="$build" CEVICHE_DERIVED="$APP_ROOT/.build/snapshot" CEVICHE_DIST="$STAGE/build" \
    CEVICHE_XCCONFIG="$APP_ROOT/.build/snapshot.xcconfig" "$APP_ROOT/scripts/build.sh" release
IMAGE="$STAGE/$NAME"
notarized=no
if [[ -n "$NOTARY" ]]; then
    printf '\nNotarizing…\n'
    ditto -c -k --keepParent "$STAGE/build/Ceviche.app" "$STAGE/notarize.zip"
    result="$(xcrun notarytool submit "$STAGE/notarize.zip" --keychain-profile "$NOTARY" --wait --output-format json)"
    read -r status submission < <(python3 -I -c 'import json, sys; r = json.loads(sys.argv[1]); print(r.get("status"), r.get("id"))' "$result")
    if [[ "$status" != Accepted ]]; then
        printf 'Notarization %s (%s):\n' "$status" "$submission" >&2
        xcrun notarytool log "$submission" --keychain-profile "$NOTARY" >&2 || true
        exit 1
    fi
    xcrun stapler staple -q "$STAGE/build/Ceviche.app"
    spctl --assess --type execute "$STAGE/build/Ceviche.app"
    notarized=yes
fi
ditto "$STAGE/build/Ceviche.app" "$IMAGE/Ceviche.app"

# The quarantine paragraph only for an app that is not notarized, the offline models paragraph only beside a models zip.
block() { # name keep(1|0)
    if [[ $2 == 1 ]]; then printf '/^\\[\\[\\/*%s\\]\\]$/d' "$1"; else printf '/^\\[\\[%s\\]\\]$/,/^\\[\\[\\/%s\\]\\]$/d' "$1" "$1"; fi
}
for readme in "$TEMPLATES"/readme/*.txt; do
    sed -e "s/{{VERSION}}/$version ($build, $commit$dirty)/" -e "s/{{MODELS}}/$(basename "$MODELS_ZIP")/" \
        -e "$(block unnotarized "$([[ $notarized == yes ]] && echo 0 || echo 1)")" -e "$(block models "$WITH_MODELS")" \
        "$readme" > "$IMAGE/$(basename "$readme")"
done

if [[ -n "$MODELS_PID" ]]; then
    printf '\nWaiting for the models…\n'
    if ! wait "$MODELS_PID"; then MODELS_PID=""; cat "$STAGE/models.log" >&2; printf 'Packing the models failed.\n' >&2; exit 1; fi
    MODELS_PID=""; models_packed=yes
fi

# One folder, named as the zip, so it unpacks in one piece.
rm -f "$OUT/$NAME.zip"
ditto -c -k --sequesterRsrc --keepParent "$IMAGE" "$OUT/$NAME.zip"
rm -f "$OUT/$NAME-dSYMs.zip"
ditto -c -k --norsrc --keepParent "$STAGE/build/dSYMs" "$OUT/$NAME-dSYMs.zip"
(cd "$OUT" && shasum -a 256 "$NAME.zip" > "$NAME.zip.sha256")
signer="$(codesign -dvv "$IMAGE/Ceviche.app" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
presets="$(find "$IMAGE/Ceviche.app/Contents/Resources/Presets" -name '*.xmp' 2>/dev/null | wc -l | tr -d ' ')"
rm -rf "$STAGE"
printf '\n%s (%s)\n  signed: %s\n  notarized: %s\n  model set: %s\n  built-in presets: %d\n' \
    "$OUT/$NAME.zip" "$(du -h "$OUT/$NAME.zip" | cut -f1)" "${signer:-ad hoc}" "$notarized" "$TAG" "$presets"
case "$models_packed" in
    yes) printf '%s (%s)\n' "$MODELS_ZIP" "$(du -h "$MODELS_ZIP" | cut -f1)" ;;
    kept) printf '%s (%s, packed by an earlier snapshot)\n' "$MODELS_ZIP" "$(du -h "$MODELS_ZIP" | cut -f1)" ;;
esac
[[ -n "$signer" ]] || printf 'Ad hoc: testers grant photo access again after each update. Set CEVICHE_SIGN_IDENTITY in build.config to keep it.\n'
