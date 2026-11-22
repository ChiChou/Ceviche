#!/bin/bash
# Release companion: exact source and dependencies for all bundled encoders.
set -euo pipefail
APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGING="$(mktemp -d "$APP_ROOT/.build/encoder-sources.XXXXXX")"
trap 'rm -rf "$STAGING" "$STAGING.tar.gz"' EXIT
"$APP_ROOT/scripts/vendor-sources.sh"
for codec in libwebp-Xcode libjxl-Xcode; do
    mkdir -p "$STAGING/$codec"
    rsync -a --exclude=.git "$APP_ROOT/.build/vendor/checkouts/$codec/" "$STAGING/$codec/"
done
python3 "$APP_ROOT/scripts/encoder-notices.py" "$STAGING/Notices"
cp "$APP_ROOT/Vendor/Package.swift" "$APP_ROOT/Vendor/Package.resolved" "$APP_ROOT/licenses/ENCODERS.md" "$STAGING/"
cat > "$STAGING/BUILD.txt" <<'BUILD'
Native libraries: libwebp-Xcode and libjxl-Xcode are Swift packages with all submodules included.
Package.swift and Package.resolved here are Ceviche's app/Vendor package, which pins them; app/scripts/vendor.sh in
Ceviche's accompanying source builds them into the frameworks the application bundles.
BUILD
mkdir -p "$APP_ROOT/dist"
tar -czf "$STAGING.tar.gz" -C "$STAGING" .
mv -f "$STAGING.tar.gz" "$APP_ROOT/dist/encoder-corresponding-source.tar.gz"
