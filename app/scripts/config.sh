# Build settings shared by build.sh, snapshot.sh and test.sh; source it, do not run it.
#
# Values come from the environment first, then from build.config at the repository root (git-ignored; see
# build.config.example), then from the defaults below. write_xcconfig turns them into the CEVICHE_* inputs of
# Platforms/macOS/Config/Ceviche.xcconfig.
REPO_ROOT="$(cd "$APP_ROOT/.." && pwd)"
# Keep the module caches inside the package so builds and tests share them and `make clean` removes them.
export CLANG_MODULE_CACHE_PATH="$APP_ROOT/.build/cache" SWIFTPM_MODULECACHE_OVERRIDE="$APP_ROOT/.build/cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
CONFIG_FILE="${CEVICHE_CONFIG:-$REPO_ROOT/build.config}"
if [[ -f "$CONFIG_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        [[ "$line" =~ ^[[:space:]]*(CEVICHE_[A-Z_]+)[[:space:]]*=[[:space:]]*(.*)$ ]] || { printf '%s: cannot read line: %s\n' "$CONFIG_FILE" "$line" >&2; exit 2; }
        key="${BASH_REMATCH[1]}" value="${BASH_REMATCH[2]}"
        value="${value%"${value##*[![:space:]]}"}"
        if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then value="${BASH_REMATCH[1]}"; fi
        # The environment wins over the file.
        if [[ -z "${!key:-}" ]]; then export "$key=$value"; fi
    done < "$CONFIG_FILE"
fi
config_error() { printf '%s\n' "$*" >&2; exit 2; }
CEVICHE_TEAM_ID="${CEVICHE_TEAM_ID:-}"
[[ -z "$CEVICHE_TEAM_ID" || "$CEVICHE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || config_error "CEVICHE_TEAM_ID is not a 10-character Team ID: $CEVICHE_TEAM_ID"
CEVICHE_BUNDLE_ID="${CEVICHE_BUNDLE_ID:-me.chichou.ceviche}"
[[ "$CEVICHE_BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || config_error "CEVICHE_BUNDLE_ID is not a bundle identifier: $CEVICHE_BUNDLE_ID"
CEVICHE_ICLOUD_CONTAINER="${CEVICHE_ICLOUD_CONTAINER:-iCloud.$CEVICHE_BUNDLE_ID}"
[[ "$CEVICHE_ICLOUD_CONTAINER" == iCloud.* ]] || config_error "CEVICHE_ICLOUD_CONTAINER must start with iCloud.: $CEVICHE_ICLOUD_CONTAINER"
CEVICHE_SIGN_IDENTITY="${CEVICHE_SIGN_IDENTITY:-}"
CEVICHE_PROVISIONING_PROFILE="${CEVICHE_PROVISIONING_PROFILE:-}"
# iCloud catalogs and iCloud Drive: 1 or 0 (auto, the old default, is 0). With 1 and no CEVICHE_SIGN_IDENTITY, Xcode
# signs automatically for CEVICHE_TEAM_ID and registers the App ID, the container and a development profile.
CEVICHE_ICLOUD="${CEVICHE_ICLOUD:-0}"
case "$CEVICHE_ICLOUD" in
    auto) CEVICHE_ICLOUD=0 ;;
    1|0) ;;
    *) config_error "CEVICHE_ICLOUD must be 1 or 0, not $CEVICHE_ICLOUD." ;;
esac
CEVICHE_LOCAL_STORAGE="${CEVICHE_LOCAL_STORAGE:-folders}"
case "$CEVICHE_LOCAL_STORAGE" in
    folders|database) ;;
    *) config_error "CEVICHE_LOCAL_STORAGE must be folders or database, not $CEVICHE_LOCAL_STORAGE." ;;
esac
# Which build: community (the default; open source, macOS 15, no store, models downloaded from GitHub) or appstore (Ceviche
# Pro, models delivered by the App Store, macOS 26).
CEVICHE_DISTRIBUTION="${CEVICHE_DISTRIBUTION:-community}"
# Ceviche Pro App Store product IDs, comma-separated; the App Store build only.
CEVICHE_STORE_PRODUCTS="${CEVICHE_STORE_PRODUCTS:-}"
case "$CEVICHE_DISTRIBUTION" in
    community) CEVICHE_STORE_PRODUCTS="" ;;
    appstore) [[ -n "$CEVICHE_STORE_PRODUCTS" ]] || config_error "The App Store build needs CEVICHE_STORE_PRODUCTS." ;;
    *) config_error "CEVICHE_DISTRIBUTION must be community or appstore, not $CEVICHE_DISTRIBUTION." ;;
esac
[[ -z "$CEVICHE_STORE_PRODUCTS" || "$CEVICHE_STORE_PRODUCTS" =~ ^[A-Za-z0-9._-]+([[:space:]]*,[[:space:]]*[A-Za-z0-9._-]+)*$ ]] || config_error "CEVICHE_STORE_PRODUCTS must be product IDs separated by commas: $CEVICHE_STORE_PRODUCTS"
# App Sandbox, 1 or 0: on by default only for the App Store build, which cannot ship without it. The community build
# runs unsandboxed, so command-line paths, MCP paths and sidecars beside referenced originals keep working; set
# CEVICHE_SANDBOX=1 to try the sandbox in a community build.
if [[ -z "${CEVICHE_SANDBOX:-}" ]]; then [[ "$CEVICHE_DISTRIBUTION" == appstore ]] && CEVICHE_SANDBOX=1 || CEVICHE_SANDBOX=0; fi
case "$CEVICHE_SANDBOX" in
    1|0) ;;
    *) config_error "CEVICHE_SANDBOX must be 1 or 0, not $CEVICHE_SANDBOX." ;;
esac
[[ "$CEVICHE_DISTRIBUTION" != appstore || "$CEVICHE_SANDBOX" == 1 ]] || config_error "The App Store build needs CEVICHE_SANDBOX=1."
# iOS and iPadOS, 1 or 0 (the default): the codecs also get iOS and iOS Simulator slices (scripts/vendor.sh), and
# app/Package.swift links them there. Off, iOS builds of the package have no WebP or JPEG XL export.
export CEVICHE_IOS="${CEVICHE_IOS:-0}"
case "$CEVICHE_IOS" in
    1|0) ;;
    *) config_error "CEVICHE_IOS must be 1 or 0, not $CEVICHE_IOS." ;;
esac

# How the bundle is signed: with CEVICHE_SIGN_IDENTITY (a certificate name or SHA-1 hash) when given; by Xcode for the
# team when iCloud is on; otherwise ad hoc. Only a Developer ID build is notarized, so only it gets the hardened runtime
# and pays for the timestamp server.
if [[ -n "$CEVICHE_SIGN_IDENTITY" ]]; then
    CEVICHE_SIGNING=manual
    [[ "$CEVICHE_ICLOUD" == 0 || -n "$CEVICHE_PROVISIONING_PROFILE" ]] || config_error "iCloud with CEVICHE_SIGN_IDENTITY needs CEVICHE_PROVISIONING_PROFILE (an installed profile's name or UUID), or leave the identity unset for Xcode to sign."
elif [[ "$CEVICHE_ICLOUD" == 1 ]]; then
    CEVICHE_SIGNING=automatic
    [[ -n "$CEVICHE_TEAM_ID" ]] || config_error "CEVICHE_ICLOUD=1 needs CEVICHE_TEAM_ID (see build.config.example)."
else
    CEVICHE_SIGNING=adhoc
fi
CEVICHE_HARDENED_RUNTIME=NO
if [[ "$CEVICHE_SIGNING" == manual ]] && security find-identity -v -p codesigning | grep -F -- "$CEVICHE_SIGN_IDENTITY" | grep -q '"Developer ID Application:'; then
    CEVICHE_HARDENED_RUNTIME=YES
fi

# The CEVICHE_* inputs of Platforms/macOS/Config/Ceviche.xcconfig, written to the path given.
write_xcconfig() {
    yes_no() { [[ "$1" == 1 ]] && echo YES || echo NO; }
    {
        printf '// Written by app/scripts/config.sh from build.config and the environment; edits are overwritten.\n'
        printf 'CEVICHE_BUNDLE_ID = %s\n' "$CEVICHE_BUNDLE_ID"
        printf 'CEVICHE_ICLOUD_CONTAINER = %s\n' "$CEVICHE_ICLOUD_CONTAINER"
        printf 'CEVICHE_DISTRIBUTION = %s\n' "$CEVICHE_DISTRIBUTION"
        printf 'CEVICHE_SANDBOX = %s\n' "$(yes_no "$CEVICHE_SANDBOX")"
        printf 'CEVICHE_ICLOUD = %s\n' "$(yes_no "$CEVICHE_ICLOUD")"
        printf 'CEVICHE_STORE_PRODUCTS = %s\n' "$CEVICHE_STORE_PRODUCTS"
        printf 'CEVICHE_LOCAL_STORAGE = %s\n' "$CEVICHE_LOCAL_STORAGE"
        printf 'CEVICHE_SIGNING = %s\n' "$CEVICHE_SIGNING"
        printf 'CEVICHE_SIGN_IDENTITY = %s\n' "$CEVICHE_SIGN_IDENTITY"
        printf 'CEVICHE_PROVISIONING_PROFILE = %s\n' "$CEVICHE_PROVISIONING_PROFILE"
        printf 'CEVICHE_HARDENED_RUNTIME = %s\n' "$CEVICHE_HARDENED_RUNTIME"
        printf 'DEVELOPMENT_TEAM = %s\n' "$CEVICHE_TEAM_ID"
        [[ -z "${CEVICHE_BUILD_NUMBER:-}" ]] || printf 'CURRENT_PROJECT_VERSION = %s\n' "$CEVICHE_BUILD_NUMBER"
    } > "$1.new"
    # Unchanged settings leave the file alone, so Xcode keeps its incremental build.
    if cmp -s "$1.new" "$1"; then rm "$1.new"; else mv "$1.new" "$1"; fi
}
