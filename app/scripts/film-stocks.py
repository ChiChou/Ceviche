#!/usr/bin/env python3
"""Packs film stock definitions into app/Sources/FilmPrint/Resources/Stocks.

The stocks are Fotufilm's profiles (CC BY-SA 4.0, MUAStudio Inc.; github.com/DhaliwalX/fotufilm-engine,
Sources/FotufilmCore/Stocks). Each `<id>.json` given is written as `<id>.json.lzfse`: the same JSON without its
whitespace and without the records the film print does not read, LZFSE-compressed, about a tenth of its size.
Numbers are kept as written. Run it to take stocks from a newer revision of the profiles:

    python3 -I app/scripts/film-stocks.py path/to/Stocks

and note the revision in the credits (OpenSourceLicenses/credits/fotufilm).
"""
import json
import pathlib
import subprocess
import sys
import tempfile

# Records of a stock definition that only other parts of Fotufilm's engine read.
UNREAD = ("layeredTransport", "edgePrinting", "crystalGrainPopulation", "sheetNotches")
OUT = pathlib.Path(__file__).resolve().parent.parent / "Sources/FilmPrint/Resources/Stocks"


def members(text):
    """The top-level members of a JSON object as (key, text of the value), each exactly as written."""
    found, depth, start, key, quoted, i = [], 0, None, None, False, 0
    while i < len(text):
        ch = text[i]
        if quoted:
            if ch == "\\":
                i += 1
            elif ch == '"':
                quoted = False
                if depth == 1 and key is None:
                    key = json.loads(text[start:i + 1])
                    start = None
        elif ch == '"':
            quoted = True
            if depth == 1 and key is None:
                start = i
        elif ch in "{[":
            depth += 1
        elif ch in "}]":
            depth -= 1
            if depth == 0 and key is not None:
                found.append((key, text[start:i]))
        elif ch == ":" and depth == 1 and start is None:
            start = i + 1
        elif ch == "," and depth == 1:
            found.append((key, text[start:i]))
            key, start = None, None
        i += 1
    return found


def compact(text):
    """JSON text without the whitespace between its tokens."""
    out, quoted, i = [], False, 0
    while i < len(text):
        ch = text[i]
        if quoted:
            out.append(ch)
            if ch == "\\":
                i += 1
                out.append(text[i])
            elif ch == '"':
                quoted = False
        elif ch == '"':
            quoted = True
            out.append(ch)
        elif ch not in " \t\r\n":
            out.append(ch)
        i += 1
    return "".join(out)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    sources = sorted(pathlib.Path(sys.argv[1]).glob("*.json"))
    if not sources:
        sys.exit("No stock definitions in " + sys.argv[1])
    OUT.mkdir(parents=True, exist_ok=True)
    for stale in list(OUT.glob("*.json.lzfse")) + list(OUT.glob("*.json")):
        stale.unlink()
    for source in sources:
        text = source.read_text()
        whole = json.loads(text)
        kept = [(key, value) for key, value in members(text) if key not in UNREAD]
        packed = "{" + ",".join(json.dumps(key) + ":" + compact(value) for key, value in kept) + "}"
        if json.loads(packed) != {key: value for key, value in whole.items() if key not in UNREAD}:
            sys.exit("Could not repack " + source.name)
        with tempfile.NamedTemporaryFile("w", suffix=".json") as plain:
            plain.write(packed)
            plain.flush()
            subprocess.run(["compression_tool", "-encode", "-a", "lzfse", "-i", plain.name, "-o", str(OUT / (source.name + ".lzfse"))], check=True)
    print("Packed %d stocks into %s" % (len(sources), OUT))


if __name__ == "__main__":
    main()
