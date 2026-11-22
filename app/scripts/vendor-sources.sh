#!/bin/bash
# Checks out the codec sources the vendor frameworks are built from, where their licenses and notices are read.
# vendor.sh leaves them behind when it builds, but frameworks restored from a cache (as in CI) come without them;
# resolving fetches them without building anything.
set -euo pipefail
APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECKOUTS="$APP_ROOT/.build/vendor/checkouts"
[[ -d "$CHECKOUTS/libwebp-Xcode/libwebp" && -d "$CHECKOUTS/libjxl-Xcode/libjxl" ]] && exit 0
export CLANG_MODULE_CACHE_PATH="$APP_ROOT/.build/cache" SWIFTPM_MODULECACHE_OVERRIDE="$APP_ROOT/.build/cache"
swift package resolve --package-path "$APP_ROOT/Vendor" --scratch-path "$APP_ROOT/.build/vendor"
