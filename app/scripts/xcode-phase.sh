#!/bin/bash
# The Ceviche target's script phases in Ceviche.xcodeproj; Xcode runs them with the build settings in the environment.
#   check     before compiling: the build settings make sense, string tables and licence notices are complete.
#   assemble  after the helpers are embedded: what the bundle needs beyond the targets' own products.
#   assemble_ios  the same for the iPad and iPhone app, which needs far less.
set -euo pipefail
APP_ROOT="$SRCROOT"
REPO_ROOT="$(cd "$APP_ROOT/.." && pwd)"
APP="$TARGET_BUILD_DIR/$WRAPPER_NAME"
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

check() {
    case "$CEVICHE_DISTRIBUTION" in community|appstore) ;; *) fail "CEVICHE_DISTRIBUTION must be community or appstore, not $CEVICHE_DISTRIBUTION." ;; esac
    case "$CEVICHE_SANDBOX" in YES|NO) ;; *) fail "CEVICHE_SANDBOX must be YES or NO, not $CEVICHE_SANDBOX." ;; esac
    case "$CEVICHE_ICLOUD" in YES|NO) ;; *) fail "CEVICHE_ICLOUD must be YES or NO, not $CEVICHE_ICLOUD." ;; esac
    case "$CEVICHE_SIGNING" in adhoc|automatic|manual) ;; *) fail "CEVICHE_SIGNING must be adhoc, automatic or manual, not $CEVICHE_SIGNING." ;; esac
    case "$CEVICHE_LOCAL_STORAGE" in folders|database) ;; *) fail "CEVICHE_LOCAL_STORAGE must be folders or database, not $CEVICHE_LOCAL_STORAGE." ;; esac
    if [[ "$CEVICHE_DISTRIBUTION" == appstore ]]; then
        [[ "$CEVICHE_SANDBOX" == YES ]] || fail "The App Store build needs the App Sandbox (CEVICHE_SANDBOX=1)."
        [[ -n "${CEVICHE_STORE_PRODUCTS:-}" ]] || fail "The App Store build needs CEVICHE_STORE_PRODUCTS."
    else
        [[ -z "${CEVICHE_STORE_PRODUCTS:-}" ]] || fail "CEVICHE_STORE_PRODUCTS is for the App Store build only."
    fi
    [[ "$CEVICHE_ICLOUD_CONTAINER" == iCloud.* ]] || fail "CEVICHE_ICLOUD_CONTAINER must start with iCloud.: $CEVICHE_ICLOUD_CONTAINER"
    [[ "$CEVICHE_SIGNING" != manual || -n "${CEVICHE_SIGN_IDENTITY:-}" ]] || fail "Manual signing needs CEVICHE_SIGN_IDENTITY."
    python3 "$APP_ROOT/scripts/localization.py"
    python3 -I "$APP_ROOT/scripts/credits.py"
}

# Whatever models/fetch-models.sh (make models, or make models-prebuilt) produced is compiled into models/build/compiled,
# which a debug build records in its Info.plist (CevicheDevelopmentModels) and make snapshot packs for testers. The
# models in models.sh MODEL_BUNDLED are also copied with their licences into CevicheKit.framework (Resources/Models),
# where every executable that loads it finds them; users download the rest in Settings › Models. A bundled model that
# is missing is only a warning, and the app offers it as a download, unless CEVICHE_REQUIRE_BUNDLED_MODELS is 1, as it
# is for snapshots and releases.
bundle_models() { # destination [platform]
    local models="$REPO_ROOT/models" model name compiled platform="${2:-macos}"
    # A compiled model is for one platform: the Mac's are in compiled, the iOS app's in compiled-ios.
    local store="$models/build/compiled" options=()
    [[ "$platform" == macos ]] || { store="$models/build/compiled-$platform"; options=(--platform "$platform" --deployment-target "$IPHONEOS_DEPLOYMENT_TARGET"); }
    source "$models/models.sh"
    mkdir -p "$store"
    for model in "$models"/build/*.mlpackage "$models"/build/*.mlmodel; do
        [[ -e "$model" && "$model" != *-INT8.* ]] || continue
        name="$(basename "${model%.*}")"
        # Only the Mac build compiles every model, for debug builds to find; the others compile what they bundle.
        [[ "$platform" == macos || " ${MODEL_BUNDLED[*]} " == *" $name "* ]] || continue
        compiled="$store/$name.mlmodelc"
        if [[ ! -d "$compiled" || "$model" -nt "$compiled" ]]; then
            rm -rf "${compiled:?}"; xcrun coremlcompiler compile "$model" "$store" ${options[@]+"${options[@]}"} >/dev/null
        fi
    done
    rm -rf "${1:?}"
    for name in "${MODEL_BUNDLED[@]}"; do
        compiled="$store/$name.mlmodelc"
        if [[ ! -d "$compiled" ]]; then
            [[ "${CEVICHE_REQUIRE_BUNDLED_MODELS:-0}" != 1 ]] || fail "$name is not in models/build; run make models-prebuilt (or make models) first."
            printf 'warning: %s is not in models/build, so the app will offer it as a download; run make models-prebuilt (or make models) to bundle it.\n' "$name"
            continue
        fi
        mkdir -p "$1/$name"
        rsync -a --delete "$compiled/" "$1/$name/$name.mlmodelc/"
        cp "$models/licenses/$(model_license "$name")" "$1/$name/LICENSE"
    done
}

assemble() {
    local resources="$APP/Contents/Resources" info="$APP/Contents/Info.plist"
    # Xcode expands build settings in Info.plist values, not keys: the iCloud Drive folder's settings, keyed by this
    # build's container.
    local drive
    drive="$(plutil -extract NSUbiquitousContainers json -o - "$info" | python3 -I -c 'import json, sys; print(json.dumps(next(iter(json.load(sys.stdin).values()))))')"
    plutil -replace NSUbiquitousContainers -json "{\"$CEVICHE_ICLOUD_CONTAINER\": $drive}" "$info"
    # CevicheKit.framework carries the package resource bundles, where the generated Bundle.module accessors find them
    # beside the framework's binary whichever executable loaded it (the app, the helper or the index service). Xcode
    # copies them into the app's Resources too; the phase lists those copies as inputs so that it runs after them.
    local kit="$APP/Contents/Frameworks/CevicheKit.framework" key bundle
    # Only this build's bundles: one left from a renamed or removed target would otherwise stay in an incremental build.
    rm -rf "$kit"/Versions/A/Resources/*.bundle
    for bundle in "$BUILT_PRODUCTS_DIR"/*.bundle; do
        rsync -a --delete "$bundle" "$kit/Versions/A/Resources/"
        rm -rf "$resources/$(basename "$bundle")"
    done
    plutil -replace CFBundleIdentifier -string "$PRODUCT_BUNDLE_IDENTIFIER.kit" "$kit/Versions/A/Resources/Info.plist"
    for key in CFBundleShortVersionString CFBundleVersion; do
        plutil -replace "$key" -string "$(plutil -extract "$key" raw "$info")" "$kit/Versions/A/Resources/Info.plist"
    done
    # Xcode strips the targets it installs, not package products; the framework keeps the symbols the executables link
    # against, and its dSYM has the rest.
    if [[ "${DEPLOYMENT_POSTPROCESSING:-NO}" == YES && "${STRIP_INSTALLED_PRODUCT:-NO}" == YES ]]; then strip -x "$kit/Versions/A/CevicheKit"; fi
    # Xcode also copies the resource bundles and the codec frameworks into the index service, which links CevicheKit
    # too; it loads them from the app instead.
    local service="$APP/Contents/XPCServices/CevicheIndexService.xpc" helper="$APP/Contents/Helpers/ceviche-mcp"
    rm -rf "$service/Contents/Frameworks" "$service"/Contents/Resources/*.bundle
    # A debug build also records the build folder as an rpath, where CevicheKit has no resource bundles; the bundle
    # loads its frameworks only from Contents/Frameworks.
    local binary path
    for binary in "$APP/Contents/MacOS/$EXECUTABLE_NAME" "$helper" "$service/Contents/MacOS/CevicheIndexService" "$kit/Versions/A/CevicheKit"; do
        for path in $(otool -l "$binary" | awk '$1 == "cmd" { rpath = $2 == "LC_RPATH" } rpath && $1 == "path" { print $2 }' | grep '^/' | grep -v '^/usr/lib/' || true); do
            install_name_tool -delete_rpath "$path" "$binary" 2>/dev/null
        done
    done
    bundle_models "$kit/Versions/A/Resources/Models"
    # What changed is signed again: the helpers with their own entitlements; the app itself is signed after this phase.
    local runtime=()
    [[ "$ENABLE_HARDENED_RUNTIME" != YES ]] || runtime=(--options runtime)
    sign() { codesign --force ${runtime[@]+"${runtime[@]}"} ${OTHER_CODE_SIGN_FLAGS:-} --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$@" 2>/dev/null; }
    sign "$kit"
    if [[ "$CEVICHE_SANDBOX" == YES ]]; then
        sign --entitlements "$APP_ROOT/Platforms/macOS/Entitlements/CevicheMCP.entitlements" "$helper"
        sign --entitlements "$APP_ROOT/Platforms/macOS/Entitlements/CevicheIndexService.entitlements" "$service"
    else
        sign "$helper"; sign "$service"
    fi
    # The Looks tab's built-in presets: Ceviche's own from presets/, and the open-source packs fetch-presets.sh
    # downloads there (pinned, once), laid out as one level of category folders whatever pack they came from.
    # Each pack's LICENSE goes with it; the Looks tab lists only the presets.
    "$REPO_ROOT/presets/fetch-presets.sh" >/dev/null
    python3 -I "$REPO_ROOT/presets/bundle-presets.py" "$REPO_ROOT/presets" "$resources/Presets" >/dev/null
    cp "$REPO_ROOT/LICENSE" "$resources/LICENSE"
    # The welcome screen's photos with their credits, from welcome/.
    python3 -I "$APP_ROOT/scripts/welcome-photos.py" "$REPO_ROOT/welcome" "$resources/Welcome"
    # The encoders' licences and notices; third-party licences ship in
    # Ceviche_CevicheMac.bundle with credits.json (scripts/credits.py), which the Licenses window reads.
    "$APP_ROOT/scripts/vendor-sources.sh"
    rm -rf "$resources/EncoderLicenses"
    python3 "$APP_ROOT/scripts/encoder-notices.py" "$resources/EncoderLicenses"
    # The edit schema the MCP clients read, from the helper itself: a copy signed without its sandbox entitlements,
    # which stop a helper started on its own.
    local schema="$DERIVED_FILE_DIR/schema-ceviche-mcp"
    mkdir -p "$DERIVED_FILE_DIR"; cp "$BUILT_PRODUCTS_DIR/ceviche-mcp" "$schema"
    codesign --force --sign - "$schema" 2>/dev/null
    DYLD_FRAMEWORK_PATH="$BUILT_PRODUCTS_DIR/PackageFrameworks:$BUILT_PRODUCTS_DIR" "$schema" --schema > "$resources/d.json"
}

# The iPad and iPhone app is one flat bundle: the package's resource bundles are already at its top, where
# `Bundle.module` and the model lookup (`BundledModel.builtInDirectory`) find them.
assemble_ios() {
    bundle_models "$APP/Models" ios
    # The Looks tool's built-in presets, as in the Mac app: Ceviche's own and the open-source packs, each pack's
    # LICENSE beside its folders (`LookLibrary.builtInPresets`).
    "$REPO_ROOT/presets/fetch-presets.sh" >/dev/null
    python3 -I "$REPO_ROOT/presets/bundle-presets.py" "$REPO_ROOT/presets" "$APP/Presets" >/dev/null
    cp "$REPO_ROOT/LICENSE" "$APP/LICENSE"
    # The version and the open-source notices are in the system's Settings, under Ceviche, not in the app.
    python3 -I "$APP_ROOT/scripts/ios-settings.py" "$APP_ROOT/Sources/CevicheMac/Resources/OpenSourceLicenses" "$APP/Settings.bundle" \
        "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist" 2>/dev/null || echo "${MARKETING_VERSION:-}")"
}

"$1"
