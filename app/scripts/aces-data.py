#!/usr/bin/env python3
"""Bakes the ACES 2 output transform into app/Sources/CevicheCore/Resources/ACESOutput.zlib.

Needs OpenColorIO's command-line tools (`brew install opencolorio`) and nothing else; run with
`python3 -I app/scripts/aces-data.py`. The transform comes from OpenColorIO's built-in ACES studio config, so the
app needs no OpenColorIO at run time.

The file is raw DEFLATE of, in little-endian order:
- 9 float32: the matrix from linear Rec. 709 (D65) to ACEScg, row by row, as the config converts;
- 65^3 x 3 float16: Display P3 code values (sRGB curve) of the "ACES 2.0 - SDR 100 nits (P3 D65)" view over an
  ACEScct cube, red changing fastest.
"""
import os
import struct
import subprocess
import sys
import tempfile
import zlib

CONFIG = "ocio://studio-config-v5.0.0_aces-v2.1_ocio-v2.6"
DISPLAY, VIEW = "Display P3 - Display", "ACES 2.0 - SDR 100 nits (P3 D65)"
SIZE = 65
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Sources", "CevicheCore", "Resources", "ACESOutput.zlib")


def bake(args, size):
    with tempfile.TemporaryDirectory() as folder:
        path = os.path.join(folder, "out.cube")
        subprocess.run(["ociobakelut", "--iconfig", CONFIG, *args, "--format", "resolve_cube", "--cubesize", str(size), path],
                       check=True, capture_output=True)
        rows = []
        with open(path) as f:
            for line in f:
                parts = line.split()
                if len(parts) == 3:
                    try:
                        rows.append(tuple(float(p) for p in parts))
                    except ValueError:
                        pass
        if len(rows) != size ** 3:
            sys.exit(f"expected {size ** 3} rows, got {len(rows)}")
        return rows


def main():
    # A 2-point cube of a linear conversion holds the matrix: each primary's corner is its column.
    corners = bake(["--inputspace", "Linear Rec.709 (sRGB)", "--outputspace", "ACEScg"], 2)
    red, green, blue = corners[1], corners[2], corners[4]
    matrix = [red[0], green[0], blue[0], red[1], green[1], blue[1], red[2], green[2], blue[2]]
    table = bake(["--inputspace", "ACEScct", "--displayview", DISPLAY, VIEW], SIZE)
    data = struct.pack("<9f", *matrix) + b"".join(struct.pack("<3e", *row) for row in table)
    compressor = zlib.compressobj(9, zlib.DEFLATED, -15)
    with open(OUT, "wb") as f:
        f.write(compressor.compress(data) + compressor.flush())
    print("matrix", [round(v, 6) for v in matrix])
    print(f"wrote {os.path.relpath(OUT)} ({os.path.getsize(OUT)} bytes)")


if __name__ == "__main__":
    main()
