#!/bin/bash
# Rebuild the macOS icon from the 1024px PNG master.
# iconutil stores 16 and 32 px as ARGB and the other sizes as PNGs it encodes loosely; those PNG elements are swapped
# for 256-colour PNGs (libimagequant, dithered; no visible difference at 100 %) recompressed with oxipng, both run
# through uv as models/ does: 2.3 MB becomes 0.5 MB. Neither tool ships with the app.
set -euo pipefail
APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICON_TEMP="$(mktemp -d)"
trap 'rm -rf "$ICON_TEMP"' EXIT
ICONSET="$ICON_TEMP/AppIcon.iconset"
ICNS="$APP_ROOT/Platforms/macOS/Resources/AppIcon.icns"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$APP_ROOT/Platforms/macOS/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" "$APP_ROOT/Platforms/macOS/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$ICNS"
command -v uv >/dev/null || { echo "app-icon.sh needs uv (https://docs.astral.sh/uv/) to run libimagequant and oxipng" >&2; exit 1; }
uv run --quiet --no-project --with pyoxipng==9.1.1 --with imagequant==1.1.6 --with pillow==13.0.0 python -I - "$ICONSET" "$ICNS" <<'EOF'
import os, struct, sys
import imagequant, oxipng
from PIL import Image
iconset, icns = sys.argv[1:3]
# The iconset file behind each PNG element iconutil writes; other elements (ARGB, info) are kept as they are.
FILES = {b"ic11": "icon_16x16@2x.png", b"ic12": "icon_32x32@2x.png", b"ic07": "icon_128x128.png", b"ic13": "icon_128x128@2x.png",
         b"ic08": "icon_256x256.png", b"ic14": "icon_256x256@2x.png", b"ic09": "icon_512x512.png", b"ic10": "icon_512x512@2x.png"}
data, body, i = open(icns, "rb").read(), b"", 8
while i < len(data):
    kind, length = data[i:i + 4], struct.unpack(">I", data[i + 4:i + 8])[0]
    payload = data[i + 8:i + length]
    if kind in FILES and payload.startswith(b"\x89PNG"):
        path = os.path.join(iconset, FILES[kind])
        imagequant.quantize_pil_image(Image.open(path).convert("RGBA"), dithering_level=1.0, max_colors=256,
                                      min_quality=80, max_quality=100).save(path)
        oxipng.optimize(path, level=6, strip=oxipng.StripChunks.safe())
        payload = open(path, "rb").read()
    body += kind + struct.pack(">I", len(payload) + 8) + payload
    i += length
with open(icns, "wb") as f:
    f.write(b"icns" + struct.pack(">I", len(body) + 8) + body)
print(f"{icns}: {len(data) / 1e6:.2f} MB -> {(len(body) + 8) / 1e6:.2f} MB")
EOF
