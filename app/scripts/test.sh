#!/bin/bash
set -euo pipefail
APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$APP_ROOT/scripts/config.sh"
python3 "$APP_ROOT/scripts/localization.py"
"$APP_ROOT/scripts/vendor.sh"
swift test --package-path "$APP_ROOT" --cache-path "$APP_ROOT/.build/swiftpm-cache" ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} "$@"
