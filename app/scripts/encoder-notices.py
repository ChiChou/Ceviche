#!/usr/bin/env python3
"""Collect notices from the exact source used by SwiftPM, including transitive dependencies."""
from pathlib import Path
import shutil
import sys

app = Path(__file__).resolve().parents[1]
output = Path(sys.argv[1])
output.mkdir(parents=True, exist_ok=True)
checkouts = app / '.build/vendor/checkouts'
native = {
    'libwebp': checkouts / 'libwebp-Xcode/libwebp',
    'libjxl': checkouts / 'libjxl-Xcode/libjxl',
    'Brotli': checkouts / 'libjxl-Xcode/libjxl/third_party/brotli',
    'Highway': checkouts / 'libjxl-Xcode/libjxl/third_party/highway',
    'Little-CMS': checkouts / 'libjxl-Xcode/libjxl/third_party/lcms',
}

def notices(root, destination):
    destination.mkdir(parents=True, exist_ok=True)
    found = False
    for path in root.iterdir():
        if path.is_file() and path.name.upper().startswith(('LICENSE', 'COPYING', 'NOTICE', 'PATENTS', 'AUTHORS')):
            target = destination / path.name
            if target.exists():
                target.unlink()
            target.write_bytes(path.read_bytes())
            if path.name.upper().startswith(('LICENSE', 'COPYING')):
                found = True
    if not found:
        raise RuntimeError(f'Missing license notice: {root}')

for name, root in native.items():
    notices(root, output / name)

shutil.copy2(app / 'licenses/ENCODERS.md', output / 'ENCODERS.md')
