#!/usr/bin/env python3
"""Checks the welcome screen's photos and copies them into the app bundle.

    welcome-photos.py SOURCE DEST

SOURCE holds the photos (or short videos, which play muted on a loop) and photos.csv, which credits each one:

    file,title,author,link
    Warsaw.heic,Night at Warsaw,Jane Doe,https://example.com/jane

`author` and `link` may be empty; a link must be https and needs an author, whose name it makes a link. Every photo
needs a row and every row a photo, so none ships without its credit. DEST is replaced with the photos and photos.json,
which the app reads; a SOURCE that does not exist leaves DEST empty and the welcome screen shows no photo.
"""
import csv
import json
import shutil
import sys
from pathlib import Path

KINDS = {".jpg", ".jpeg", ".heic", ".png", ".mp4", ".mov"}
COLUMNS = ["file", "title", "author", "link"]


def fail(message: str) -> None:
    print(f"error: welcome photos: {message}", file=sys.stderr)
    sys.exit(1)


def main() -> None:
    if len(sys.argv) != 3:
        fail("usage: welcome-photos.py SOURCE DEST")
    source, dest = Path(sys.argv[1]), Path(sys.argv[2])
    if dest.exists():
        shutil.rmtree(dest)
    if not source.is_dir():
        return
    photos = {p.name for p in source.iterdir() if p.suffix.lower() in KINDS}
    manifest = source / "photos.csv"
    if not manifest.is_file():
        if photos:
            fail(f"{source} has photos but no photos.csv to credit them")
        return
    with manifest.open(newline="", encoding="utf-8-sig") as file:
        reader = csv.reader(file)
        if next(reader, None) != COLUMNS:
            fail(f"photos.csv must start with the header {','.join(COLUMNS)}")
        entries, listed = [], set()
        for row in reader:
            where = f"photos.csv line {reader.line_num}"
            if not any(cell.strip() for cell in row):
                continue
            if len(row) != len(COLUMNS):
                fail(f"{where} has {len(row)} columns, not {len(COLUMNS)}")
            name, title, author, link = (cell.strip() for cell in row)
            if not (name and title):
                fail(f"{where} needs file and title")
            if link and not author:
                fail(f"{where}: a link needs an author to link")
            if link and not link.startswith("https://"):
                fail(f"{where}: link must start with https://")
            if name not in photos:
                fail(f"{where}: {name} is not in {source}")
            if name in listed:
                fail(f"{where}: {name} is listed twice")
            listed.add(name)
            entry = {"file": name, "title": title}
            if author:
                entry["author"] = author
            if link:
                entry["link"] = link
            entries.append(entry)
    if uncredited := photos - listed:
        fail(f"no row in photos.csv for {', '.join(sorted(uncredited))}")
    dest.mkdir(parents=True)
    for name in sorted(listed):
        shutil.copy2(source / name, dest / name)
    (dest / "photos.json").write_text(json.dumps(entries, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
