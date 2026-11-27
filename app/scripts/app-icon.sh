#!/bin/bash
# Export the preview PNG and legacy .icns from the same Icon Composer source Xcode builds.
set -euo pipefail
APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICON_SOURCE="$APP_ROOT/Platforms/macOS/Resources/AppIcon.icon"
ICON_RESOURCES="$APP_ROOT/Platforms/macOS/Resources"
ICON_DEVELOPER_DIR="$(xcode-select -p)"
ICON_TOOL="$ICON_DEVELOPER_DIR/../Applications/Icon Composer.app/Contents/Executables/ictool"
[[ -x "$ICON_TOOL" ]] || { echo "app-icon.sh needs Xcode with Icon Composer" >&2; exit 1; }
ICON_TEMP="$(mktemp -d)"
trap 'rm -rf "$ICON_TEMP"' EXIT

xcrun actool --compile "$ICON_TEMP" --platform macosx --minimum-deployment-target 15.0 \
    --app-icon AppIcon --output-partial-info-plist "$ICON_TEMP/Info.plist" --target-device mac \
    --output-format human-readable-text "$ICON_SOURCE"
"$ICON_TOOL" "$ICON_SOURCE" --export-image --output-file "$ICON_TEMP/AppIcon.png" \
    --platform macOS --rendition Default --width 1024 --height 1024 --scale 1
# These exports are tracked for previews and distribution tools, but excluded from the app's
# Copy Bundle Resources: Xcode compiles AppIcon.icon and supplies Assets.car and its own fallback.
cp "$ICON_TEMP/AppIcon.icns" "$ICON_RESOURCES/AppIcon.icns"
cp "$ICON_TEMP/AppIcon.png" "$ICON_RESOURCES/AppIcon.png"
