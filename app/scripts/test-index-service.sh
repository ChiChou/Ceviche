#!/bin/bash
set -euo pipefail
APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVICE="$APP_ROOT/dist/Ceviche.app/Contents/XPCServices/CevicheIndexService.xpc"
if [[ ! -d "$SERVICE" ]]; then
    printf 'Build the app first with make build\n' >&2
    exit 1
fi
PROBE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ceviche-xpc-probe.XXXXXX")"
trap 'rm -rf "$PROBE_ROOT"' EXIT
PROBE="$PROBE_ROOT/IndexProbe.app"
mkdir -p "$PROBE/Contents/MacOS" "$PROBE/Contents/XPCServices"
cp -R "$SERVICE" "$PROBE/Contents/XPCServices/"
# The service loads CevicheKit and the vendor frameworks from the app around it.
ditto "$APP_ROOT/dist/Ceviche.app/Contents/Frameworks" "$PROBE/Contents/Frameworks"
cat > "$PROBE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>me.chichou.ceviche.index-probe</string>
<key>CFBundleExecutable</key><string>IndexProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
xcrun swiftc -module-cache-path "$APP_ROOT/.build/cache" "$APP_ROOT/Tests/Fixtures/IndexServiceProbe.swift" -o "$PROBE/Contents/MacOS/IndexProbe"
codesign --force --sign - "$PROBE"
CEVICHE_XPC_PROBE="$PROBE/Contents/MacOS/IndexProbe" "$APP_ROOT/scripts/test.sh" --filter CatalogIndexTests.testBundledXPCIndexesRealPhotoWhenRequested
