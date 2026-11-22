#!/usr/bin/env python3
"""Lays out the built-in presets for the app bundle as one level of category folders.

presets/ holds Ceviche's own packs (a folder of presets each, kept in git) and the open-source packs fetch-presets.sh
downloads (a folder of category folders each). In the app every category is a folder directly under Presets, whatever
pack it came from, so the Looks panel lists them one level deep: a pack's "Black-White" joins Ceviche's
"Black & White", and "Color-Negative" reads "Color Negative". Each downloaded pack's LICENSE ships beside the folders
as "<pack> LICENSE"; the panel lists only presets.

Usage: bundle-presets.py <presets dir> <destination>   (the destination is replaced)
"""
import shutil
import sys
from pathlib import Path

PRESET_EXTENSIONS = {".xmp"}
# Category names that mean the same thing across packs.
SAME_AS = {"black white": "Black & White", "black and white": "Black & White", "b&w": "Black & White"}


def category(name: str) -> str:
    spaced = name.replace("-", " ").replace("_", " ").strip()
    return SAME_AS.get(spaced.lower(), spaced)


def presets_in(folder: Path) -> list[Path]:
    return sorted(p for p in folder.iterdir() if p.is_file() and p.suffix.lower() in PRESET_EXTENSIONS)


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    source, destination = Path(sys.argv[1]), Path(sys.argv[2])
    layout: dict[str, list[Path]] = {}
    for pack in sorted(p for p in source.iterdir() if p.is_dir() and not p.name.startswith(".")):
        # A pack of presets is one category; a pack of folders is one category per folder.
        if presets_in(pack):
            layout.setdefault(category(pack.name), []).extend(presets_in(pack))
        for folder in sorted(p for p in pack.iterdir() if p.is_dir() and not p.name.startswith(".")):
            if presets_in(folder):
                layout.setdefault(category(folder.name), []).extend(presets_in(folder))
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)
    count = 0
    for name, files in layout.items():
        folder = destination / name
        folder.mkdir()
        for file in files:
            target = folder / file.name
            if target.exists():
                print(f"bundle-presets: {name}/{file.name} comes from two packs", file=sys.stderr)
                return 1
            shutil.copy2(file, target)
            count += 1
    for license in sorted(source.glob("*/LICENSE")):
        shutil.copy2(license, destination / f"{license.parent.name} LICENSE")
    print(f"bundle-presets: {count} presets in {len(layout)} folders")
    return 0


if __name__ == "__main__":
    sys.exit(main())
