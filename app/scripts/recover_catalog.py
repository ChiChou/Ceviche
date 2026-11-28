#!/usr/bin/env python3
"""Gets each photo's edits and metadata out of a Ceviche catalog the app won't open, as XMP sidecars.

usage: recover_catalog.py <catalog> <output folder> [--beside-originals] [--salvage] [--resources <folder>]...

For a catalog that is damaged, or that a newer or older version of Ceviche refuses. The catalog is only read: its
database is copied to a temporary folder first, and a copy SQLite reports damaged is rebuilt with `sqlite3 .recover`.
Only the photo, development, mask and resource tables are read, by column name; search, face and place tables and
foreign keys are ignored.

Each XMP carries Ceviche's recipe (the whole development, masks inline, with rating, label, flag, keywords, title,
caption and a location set in Ceviche), which Import and Import XMP read back. Files go below <output folder> in the
originals' folder layout, Files/<original path> or Catalog/<path in the catalog>, with recovery.csv listing every
photo. Quit Ceviche first.

  --beside-originals   also write IMG.xmp beside each original that has no sidecar yet, so importing the originals
                       again brings their edits (never on a drive you mean to keep untouched)
  --salvage            rebuild with `sqlite3 .recover` even when the database checks out
  --resources <folder> another folder to look in for LUTs and profiles the edits use

Python 3.9 or later, standard library only; `sqlite3` (in macOS) for damaged databases.
"""
import base64
import csv
import glob
import hashlib
import json
import os
import shutil
import sqlite3
import struct
import subprocess
import sys
import tempfile
import urllib.parse
from xml.sax.saxutils import quoteattr

NATIVE = "https://chichou.me/ceviche/ns/edit/1.0/"
# `XMPNativeRecipe.version` the app reads.
RECIPE_VERSION = 5
# `XMPPacket.portableDigest` of a packet with no crs, xmp, dc, exif or xmpDM fields: the recipe is trusted as it is.
PORTABLE_DIGEST = hashlib.sha256(b'{"arrays":{},"scalars":{},"structures":[]}').hexdigest()
BLOB = "@blob:"
MAX_XMP = 32 * 1024 * 1024
SQLITE = "/usr/bin/sqlite3" if os.path.exists("/usr/bin/sqlite3") else (shutil.which("sqlite3") or "sqlite3")
# The photo table's stored columns as of the 2026-11-22 schema, for a catalog whose schema can't be read. Columns are
# only ever added after these, so a newer catalog's rows start the same way.
ASSET_COLUMNS = """id importPath origin sourcePath isCopy fileSize filename kind captureDay captureTime title caption
    keywords suggestedTags review rating latitude longitude placeCountry placeRegion placeCity placeSource locationSource
    cameraMake cameraModel lensMake lensModel artist focalLength focalLength35mm fNumber exposureTime iso exposureBias
    flashFired fileExtension width height aspect stackID trashedAt archivedAt label importedAt importBatchID updatedAt
    developmentUpdatedAt originalUpdatedAt lastEditedAt analysisVersion analysisOrigin analyzedAt faceCount hdr
    thumbnailKey thumbnailRenderKey renderKey xmpWarnings bookmark infoData""".split()
REVIEW = {"unreviewed", "accepted", "rejected"}
LABELS = {"red", "yellow", "green", "blue", "purple"}


def fail(message):
    sys.stderr.write("recover_catalog: %s\n" % message)
    sys.exit(1)


def quick_check(path):
    try:
        with sqlite3.connect(path) as db:
            return db.execute("PRAGMA quick_check(1)").fetchone()[0] == "ok"
    except sqlite3.DatabaseError:
        return False


def table_names(db):
    return {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}


def column_names(db, table, stored_only=False):
    rows = db.execute("SELECT name, hidden FROM pragma_table_xinfo(?)", (table,)).fetchall()
    return [name for name, hidden in rows if not (stored_only and hidden == 2)]


def salvage(damaged, rebuilt):
    """Every row SQLite can still find, gathered into salvaged* tables. `.recover` misplaces the columns of a table
    with generated columns, so the photo table is first declared as its stored columns alone, without constraints or
    triggers. Rows on pages no longer linked to their table come out in lost_and_found and are matched by shape."""
    try:
        with sqlite3.connect(damaged) as db:
            columns = column_names(db, "asset", stored_only=True)
    except sqlite3.DatabaseError:
        columns = []
    columns = columns or ASSET_COLUMNS
    quoted = ", ".join('"%s"' % c for c in columns)
    # Fails when the schema page itself is damaged; then every row is in lost_and_found anyway.
    definition = ("CREATE TABLE asset(%s)" % quoted).replace("'", "''")
    subprocess.run([SQLITE, damaged, ".dbconfig defensive off", "PRAGMA writable_schema = ON",
                    "UPDATE sqlite_schema SET sql = '%s' WHERE type = 'table' AND name = 'asset'" % definition,
                    "DELETE FROM sqlite_schema WHERE type = 'trigger' OR (type = 'index' AND tbl_name = 'asset')"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    dump = subprocess.Popen([SQLITE, damaged, ".recover --ignore-freelist"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    load = subprocess.Popen([SQLITE, rebuilt], stdin=dump.stdout, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    dump.stdout.close()
    errors = dump.stderr.read()
    dump.wait(); load.wait()
    if not os.path.exists(rebuilt):
        fail("SQLite could not salvage the catalog. " + errors.decode(errors="replace"))
    with sqlite3.connect(rebuilt) as db:
        gather(db, columns)


def gather(db, columns):
    def uuid(x):
        return "(typeof(%s) = 'text' AND length(%s) = 36 AND substr(%s, 9, 1) = '-' AND substr(%s, 24, 1) = '-')" % (x, x, x, x)
    tables = table_names(db)
    quoted = ['"%s"' % c for c in columns]
    db.execute("CREATE TABLE salvagedAsset(%s, UNIQUE(id))" % ", ".join(quoted))
    db.execute("CREATE TABLE salvagedDevelopment(assetID, adjustmentsData, xmpData, UNIQUE(assetID))")
    db.execute("CREATE TABLE salvagedBlob(id, assetID, data, UNIQUE(id))")
    db.execute("CREATE TABLE salvagedResource(digest, path, data, UNIQUE(digest))")
    if "asset" in tables:
        have = set(column_names(db, "asset"))
        shared = ", ".join(q for c, q in zip(columns, quoted) if c in have)
        db.execute("INSERT OR IGNORE INTO salvagedAsset(%s) SELECT %s FROM asset WHERE id IS NOT NULL" % (shared, shared))
    for table, target, listed in [("assetDevelopment", "salvagedDevelopment", "assetID, adjustmentsData, xmpData"),
                                  ("blob", "salvagedBlob", "id, assetID, data"), ("resource", "salvagedResource", "digest, path, data")]:
        if table in tables:
            db.execute("INSERT OR IGNORE INTO %s(%s) SELECT %s FROM %s" % (target, listed, listed, table))
    if "lost_and_found" in tables:
        lost = set(column_names(db, "lost_and_found"))
        origin, filename = columns.index("origin"), columns.index("filename")
        # A row written before a later column was added stores fewer fields.
        for count in range(max(origin, filename) + 1, len(columns) + 1):
            if count < len(columns) - 16 or "c%d" % (count - 1) not in lost:
                continue
            values = ", ".join("c%d" % i for i in range(count))
            db.execute("INSERT OR IGNORE INTO salvagedAsset(%s) SELECT %s FROM lost_and_found WHERE nfield = %d AND %s "
                       "AND typeof(c%d) = 'text' AND typeof(c%d) = 'text'"
                       % (", ".join(quoted[:count]), values, count, uuid("c0"), origin, filename))
        if "c2" in lost:
            db.execute("INSERT OR IGNORE INTO salvagedDevelopment SELECT c0, c1, c2 FROM lost_and_found WHERE nfield = 3 AND %s "
                       "AND (c1 IS NULL OR (typeof(c1) = 'blob' AND hex(substr(c1, 1, 1)) = '7B')) "
                       "AND (c2 IS NULL OR typeof(c2) = 'blob') AND NOT (c1 IS NULL AND c2 IS NULL)" % uuid("c0"))
            db.execute("INSERT OR IGNORE INTO salvagedBlob SELECT c0, c1, c2 FROM lost_and_found WHERE nfield = 3 AND %s AND %s "
                       "AND typeof(c2) = 'blob'" % (uuid("c0"), uuid("c1")))
            db.execute("INSERT OR IGNORE INTO salvagedResource SELECT c0, c1, c2 FROM lost_and_found WHERE nfield = 3 "
                       "AND typeof(c0) = 'text' AND length(c0) = 64 AND typeof(c1) = 'text' AND typeof(c2) = 'blob'")
    db.commit()


class Catalog:
    """Reads by column name, so a catalog from another schema works as long as the columns it has mean the same."""

    def __init__(self, path, salvaged, resource_folders):
        self.db = sqlite3.connect(path)
        self.db.row_factory = sqlite3.Row
        names = ("salvagedAsset", "salvagedDevelopment", "salvagedBlob", "salvagedResource") if salvaged \
            else ("asset", "assetDevelopment", "blob", "resource")
        self.asset, self.development, self.blob_table, self.resource_table = names
        found = table_names(self.db)
        if self.asset not in found:
            fail("the catalog has no photo table left")
        self.columns = set(column_names(self.db, self.asset))
        self.has = {name: name in found for name in names}
        self.resource_folders = resource_folders

    def ids(self):
        order = "captureDay, id" if "captureDay" in self.columns else "id"
        return [r[0] for r in self.db.execute("SELECT id FROM %s WHERE id IS NOT NULL ORDER BY %s" % (self.asset, order))]

    def row(self, asset_id):
        return self.db.execute("SELECT * FROM %s WHERE id = ?" % self.asset, (asset_id,)).fetchone()

    def stored_development(self, asset_id):
        if not self.has[self.development]:
            return None, None
        row = self.db.execute("SELECT adjustmentsData, xmpData FROM %s WHERE assetID = ?" % self.development, (asset_id,)).fetchone()
        return (row[0], row[1]) if row else (None, None)

    def blob(self, blob_id):
        if self.has[self.blob_table]:
            row = self.db.execute("SELECT data FROM %s WHERE id = ?" % self.blob_table, (blob_id,)).fetchone()
            if row and row[0] is not None:
                return bytes(row[0])
        return None

    def resource(self, reference):
        digest, path = reference.get("digest", ""), reference.get("path", "")
        if self.has[self.resource_table]:
            row = self.db.execute("SELECT data FROM %s WHERE digest = ?" % self.resource_table, (digest,)).fetchone()
            if row and row[0] is not None:
                return bytes(row[0])
        for folder in self.resource_folders:
            for candidate in [os.path.join(folder, path), os.path.join(folder, os.path.basename(path))]:
                if os.path.isfile(candidate):
                    data = open(candidate, "rb").read()
                    if hashlib.sha256(data).hexdigest() == digest:
                        return data
        return None


def cube_samples(data):
    """A standard 3D .cube over 0…1 as `CreativeLUT` stores it (16-bit RGB); None for 1D tables or other domains,
    which only the app converts."""
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        text = data.decode("latin-1")
    size, values = None, []
    for line in text.splitlines():
        parts = line.strip().split()
        if not parts or parts[0].startswith("#"):
            continue
        key = parts[0].upper()
        if key == "LUT_3D_SIZE":
            size = int(parts[1])
        elif key in ("LUT_1D_SIZE", "DOMAIN_MIN", "DOMAIN_MAX", "LUT_3D_INPUT_RANGE", "LUT_1D_INPUT_RANGE"):
            if key.startswith("DOMAIN") and [float(p) for p in parts[1:]] == ([0.0] * 3 if key == "DOMAIN_MIN" else [1.0] * 3):
                continue
            return None
        elif len(parts) == 3 and not parts[0][0].isalpha():
            values += [float(p) for p in parts]
    if not size or len(values) != size ** 3 * 3:
        return None
    return size, b"".join(struct.pack("<H", int(round(min(1.0, max(0.0, v)) * 65535))) for v in values)


def recipe_settings(stored, catalog, notes, xmp_folder, stem):
    """The stored development as the recipe's development: mask rasters inline, LUTs and profiles read back from
    their files. A part whose data is gone is left out and named in `notes`."""
    tree = json.loads(stored)
    missing = []

    def inline(value):
        if isinstance(value, str) and value.startswith(BLOB):
            data = catalog.blob(value[len(BLOB):])
            if data is None:
                missing.append(value)
                return value
            return base64.b64encode(data).decode()
        if isinstance(value, list):
            return [inline(v) for v in value]
        if isinstance(value, dict):
            return {k: inline(v) for k, v in value.items()}
        return value

    def refers_to_missing(value):
        if isinstance(value, str):
            return value in missing
        if isinstance(value, list):
            return any(refers_to_missing(v) for v in value)
        if isinstance(value, dict):
            return any(refers_to_missing(v) for v in value.values())
        return False

    tree = inline(tree)
    for key in sorted(tree):
        value = tree[key]
        if not refers_to_missing(value):
            continue
        if isinstance(value, list):
            tree[key] = [item for item in value if not refers_to_missing(item)]
            notes.append("left out (mask data missing): %s, %d item(s)" % (key, len(value) - len(tree[key])))
        else:
            del tree[key]
            notes.append("left out (mask data missing): %s" % key)

    lut = tree.get("lut")
    if isinstance(lut, dict) and "resource" in lut:
        reference = lut.pop("resource")
        data = catalog.resource(reference)
        name = os.path.basename(reference.get("path", "")) or lut.get("name", "LUT")
        lut.setdefault("space", "sRGB")
        lut["source"] = reference
        if data is not None and data.startswith(b"\x89PNG"):
            lut["haldPNG"] = base64.b64encode(data).decode()
        elif data is not None and cube_samples(data):
            lut["dimension"], samples = cube_samples(data)
            lut["samples"] = base64.b64encode(samples).decode()
        else:
            del tree["lut"]
            if data is not None:
                with open(os.path.join(xmp_folder, stem + "." + name), "wb") as f:
                    f.write(data)
                notes.append("LUT %s left out: apply the copy beside the XMP" % name)
            else:
                notes.append("LUT %s left out: its file is missing" % name)

    profile = tree.get("cameraProfile")
    if isinstance(profile, dict) and "resource" in profile:
        reference = profile.pop("resource")
        data = catalog.resource(reference)
        try:
            separated = json.loads(data) if data is not None else None
        except ValueError:
            separated = None
        if isinstance(separated, dict):
            separated.update({"amount": profile.get("amount", 1), "enabled": profile.get("enabled", True), "source": reference})
            tree["cameraProfile"] = separated
        else:
            del tree["cameraProfile"]
            notes.append("camera profile %s left out: its file is missing" % profile.get("name", ""))

    color = tree.get("colorProfile")
    if isinstance(color, dict) and "resource" in color:
        reference = color.pop("resource")
        data = catalog.resource(reference)
        if data is not None:
            color["iccData"] = base64.b64encode(data).decode()
            color["source"] = reference
        else:
            del tree["colorProfile"]
            notes.append("color profile %s left out: its file is missing" % color.get("name", ""))
    return tree


def without_fills(settings):
    """AI fills are pixels, megabytes each: left out only when the XMP would pass 32 MB; a stroke without one falls
    back to patch Remove, as in the app's own XMP."""
    for item in settings.get("retouch", []) or []:
        if isinstance(item, dict):
            item.pop("fill", None)
    return settings


def packet(recipe, source_xmp):
    attributes = [("ceviche:Recipe", base64.b64encode(json.dumps(recipe, sort_keys=True, separators=(",", ":")).encode()).decode()),
                  ("ceviche:PortableDigest", PORTABLE_DIGEST)]
    if source_xmp:
        attributes.append(("ceviche:SourcePacket", base64.b64encode(bytes(source_xmp)).decode()))
    body = "".join("\n            %s=%s" % (name, quoteattr(value)) for name, value in attributes)
    return ('<?xml version="1.0" encoding="UTF-8"?>\n<x:xmpmeta xmlns:x="adobe:ns:meta/">\n'
            '    <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n'
            '        <rdf:Description rdf:about="" xmlns:ceviche="%s"%s/>\n    </rdf:RDF>\n</x:xmpmeta>\n' % (NATIVE, body)).encode()


def metadata_packet(metadata, source_xmp):
    """Metadata alone, in the standard fields Ceviche and other editors read; no recipe, so the photo keeps its own
    development defaults."""
    from xml.sax.saxutils import escape
    attributes = [("xmp:Rating", str(metadata["rating"])),
                  ("xmpDM:pick", {"accepted": "1", "rejected": "-1"}.get(metadata["review"], "0"))]
    if metadata.get("label"):
        attributes.append(("xmp:Label", metadata["label"].capitalize()))
    if source_xmp:
        attributes.append(("ceviche:SourcePacket", base64.b64encode(bytes(source_xmp)).decode()))
    elements = []
    for name, value in [("dc:title", metadata["title"]), ("dc:description", metadata["caption"])]:
        if value:
            elements.append('<%s><rdf:Alt><rdf:li xml:lang="x-default">%s</rdf:li></rdf:Alt></%s>' % (name, escape(value), name))
    keywords = [k.strip() for k in metadata["keywords"].split(",") if k.strip()]
    if keywords:
        elements.append("<dc:subject><rdf:Bag>%s</rdf:Bag></dc:subject>" % "".join("<rdf:li>%s</rdf:li>" % escape(k) for k in keywords))
    body = "".join("\n            %s=%s" % (name, quoteattr(value)) for name, value in attributes)
    children = "".join("\n            " + e for e in elements)
    return ('<?xml version="1.0" encoding="UTF-8"?>\n<x:xmpmeta xmlns:x="adobe:ns:meta/">\n'
            '    <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n'
            '        <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:dc="http://purl.org/dc/elements/1.1/"'
            ' xmlns:xmpDM="http://ns.adobe.com/xmp/1.0/DynamicMedia/" xmlns:ceviche="%s"%s>%s\n        </rdf:Description>\n'
            '    </rdf:RDF>\n</x:xmpmeta>\n' % (NATIVE, body, children)).encode()


def original_path(row, columns, root, originals_root):
    def text(name):
        return row[name] if name in columns and isinstance(row[name], str) else None
    origin, source = text("origin") or "", text("sourcePath") or ""
    parsed = urllib.parse.urlsplit(origin)
    path = urllib.parse.unquote(parsed.path)
    if parsed.scheme == "file" and path:
        return "file", path
    if parsed.scheme == "catalog" and len(path) > 1:
        relative = path.lstrip("/")
        shared = os.path.join(originals_root, relative)
        return "catalog:" + relative, shared if os.path.exists(shared) or originals_root == root else os.path.join(root, relative)
    if parsed.scheme == "smb" and len(path) > 1:
        # Builds before 2026-11-27 recorded shares as smb://host/share/path; Finder mounts them at /Volumes/share.
        return "file", "/Volumes" + path
    return "file", source or origin


def metadata_of(row, columns):
    def get(name, kind=None):
        value = row[name] if name in columns else None
        return value if kind is None or isinstance(value, kind) else None
    rating = get("rating", int) or 0
    metadata = {"title": get("title", str) or "", "caption": get("caption", str) or "", "keywords": get("keywords", str) or "",
                "rating": min(5, max(0, rating)), "review": get("review", str) if get("review", str) in REVIEW else "unreviewed",
                "captureDay": get("captureDay", str) or ""}
    if get("label", str) in LABELS:
        metadata["label"] = get("label", str)
    latitude, longitude = get("latitude", (int, float)), get("longitude", (int, float))
    if latitude is not None and longitude is not None and -90 <= latitude <= 90 and -180 <= longitude <= 180:
        metadata["latitude"], metadata["longitude"] = float(latitude), float(longitude)
        if get("locationSource", str):
            metadata["locationSource"] = get("locationSource", str)
    if len(metadata["captureDay"]) != 10:
        metadata["captureDay"] = ""
    return metadata


def set_in_ceviche(metadata):
    return bool(metadata["rating"] or metadata.get("label") or metadata["review"] != "unreviewed" or metadata["title"]
                or metadata["caption"] or metadata["keywords"] or metadata.get("locationSource"))


def has_sidecar(original):
    folder, name = os.path.dirname(original), os.path.basename(original)
    stem = os.path.splitext(name)[0]
    try:
        listing = {n.lower() for n in os.listdir(folder)}
    except OSError:
        return True
    return (stem + ".xmp").lower() in listing or (name + ".xmp").lower() in listing


def recover(catalog_path, output, beside=False, force_salvage=False, resource_folders=()):
    database = catalog_path if catalog_path.endswith(".sqlite") else os.path.join(catalog_path, "catalog.sqlite")
    root = os.path.dirname(os.path.abspath(database))
    if not os.path.isfile(database):
        fail("no catalog.sqlite at " + catalog_path)
    if os.path.exists(output) and os.listdir(output):
        fail(output + " is not empty")
    originals_root = root
    try:
        manifest = json.load(open(os.path.join(root, "catalog.json")))
        # An iCloud catalog keeps its copied originals outside the package.
        if isinstance(manifest.get("originals"), str):
            originals_root = manifest["originals"]
    except (OSError, ValueError):
        pass
    folders = [os.path.expanduser("~/Library/Application Support/Ceviche"),
               os.path.expanduser("~/Library/Mobile Documents/iCloud~me~chichou~ceviche/Documents")] + list(resource_folders)

    work = tempfile.mkdtemp(prefix="ceviche-recover-")
    try:
        # The copy is opened writable so a WAL left by a crash is replayed into it, never into the catalog.
        copy = os.path.join(work, "catalog.sqlite")
        for suffix in ["", "-wal", "-shm"]:
            if os.path.exists(database + suffix):
                shutil.copyfile(database + suffix, copy + suffix)
        salvaged = force_salvage or not quick_check(copy)
        path = copy
        if salvaged:
            path = os.path.join(work, "recovered.sqlite")
            salvage(copy, path)
        catalog = Catalog(path, salvaged, [f for f in folders if os.path.isdir(f)])
        ids = catalog.ids()
        if not ids:
            fail("no photos could be read from the catalog")
        os.makedirs(output, exist_ok=True)
        entries, written = [], set()
        for index, asset_id in enumerate(ids):
            entries.append(recover_one(asset_id, catalog, root, originals_root, output, beside, written))
            if index % 50 == 0 or index + 1 == len(ids):
                sys.stderr.write("\r%d/%d" % (index + 1, len(ids)))
        sys.stderr.write("\n")
    finally:
        shutil.rmtree(work, ignore_errors=True)
    with open(os.path.join(output, "recovery.csv"), "w", newline="") as f:
        out = csv.writer(f)
        out.writerow(["id", "filename", "status", "original", "xmp", "beside original", "notes"])
        for e in entries:
            out.writerow([e["id"], e["filename"], e["status"], e["original"], e.get("xmp", ""), e.get("beside", ""), "; ".join(e["notes"])])
    return salvaged, entries


def recover_one(asset_id, catalog, root, originals_root, output, beside, written):
    entry = {"id": asset_id, "filename": "", "original": "", "status": "failed", "notes": []}
    try:
        row = catalog.row(asset_id)
        if row is None:
            entry["notes"].append("photo record unreadable")
            return entry
        columns = catalog.columns
        kind, original = original_path(row, columns, root, originals_root)
        filename = row["filename"] if "filename" in columns and isinstance(row["filename"], str) else os.path.basename(original)
        entry.update(filename=filename, original=original)
        if "trashedAt" in columns and row["trashedAt"] is not None:
            entry["notes"].append("in Trash")
        copy = "isCopy" in columns and row["isCopy"] == 1
        if copy:
            entry["notes"].append("copy")
        metadata = metadata_of(row, columns)
        stored, source_xmp = catalog.stored_development(asset_id)

        if kind.startswith("catalog:"):
            folder = os.path.join(output, "Catalog", os.path.dirname(kind[len("catalog:"):]))
        else:
            folder = os.path.join(output, "Files", os.path.dirname(original).lstrip("/"))
        stem = os.path.splitext(filename)[0]
        settings = None
        if stored is not None:
            try:
                os.makedirs(folder, exist_ok=True)
                settings = recipe_settings(bytes(stored), catalog, entry["notes"], folder, stem)
                entry["status"] = "partial" if any(n.startswith(("left out", "LUT", "camera", "color")) for n in entry["notes"]) else "edits"
            except (ValueError, UnicodeDecodeError) as error:
                entry["status"] = "unreadable"
                entry["notes"].append("edits unreadable: %s" % error)
        if settings is None:
            if not set_in_ceviche(metadata) and not source_xmp:
                entry["status"] = "nothing" if entry["status"] != "unreadable" else "unreadable"
                return entry
            if entry["status"] != "unreadable":
                entry["status"] = "metadata"

        if settings is None:
            data = metadata_packet(metadata, source_xmp)
            if len(data) > MAX_XMP:
                data = metadata_packet(metadata, None); entry["notes"].append("source XMP left out")
        else:
            recipe = {"version": RECIPE_VERSION, "adjustments": settings, "metadata": metadata}
            data = packet(recipe, source_xmp)
            if len(data) > MAX_XMP:
                recipe["adjustments"] = without_fills(settings)
                data = packet(recipe, source_xmp); entry["notes"].append("AI fills left out")
            if len(data) > MAX_XMP:
                data = packet(recipe, None); entry["notes"].append("source XMP left out")
        os.makedirs(folder, exist_ok=True)
        target = os.path.join(folder, stem + ".xmp")
        # Two photos of one original (a copy, two files with one stem): the second keeps its ID in the name.
        if target.lower() in written or os.path.exists(target):
            target = os.path.join(folder, "%s.%s.xmp" % (stem, asset_id[:8]))
        written.add(target.lower())
        with open(target, "xb") as f:
            f.write(data)
        entry["xmp"] = target
        if settings is None and stored is not None:
            with open(target[:-4] + ".development.json", "xb") as f:
                f.write(bytes(stored))
        if beside and not copy and os.path.isfile(original) and not has_sidecar(original):
            sidecar = os.path.splitext(original)[0] + ".xmp"
            try:
                with open(sidecar, "xb") as f:
                    f.write(data)
                entry["beside"] = sidecar
            except OSError as error:
                entry["notes"].append("not written beside the original: %s" % error.strerror)
    except Exception as error:  # One photo never stops the rest.
        entry["status"] = "failed"
        entry["notes"].append(str(error))
    return entry


def main(arguments):
    beside = force_salvage = False
    resource_folders, paths = [], []
    while arguments:
        argument = arguments.pop(0)
        if argument in ("-h", "--help"):
            print(__doc__.strip()); return 0
        if argument == "--beside-originals":
            beside = True
        elif argument == "--salvage":
            force_salvage = True
        elif argument == "--resources" and arguments:
            resource_folders.append(arguments.pop(0))
        elif argument.startswith("-"):
            sys.stderr.write("unknown option %s\n\n%s\n" % (argument, __doc__.strip())); return 64
        else:
            paths.append(argument)
    if len(paths) != 2:
        sys.stderr.write(__doc__.strip() + "\n"); return 64
    output = os.path.abspath(paths[1])
    salvaged, entries = recover(os.path.abspath(paths[0]), output, beside, force_salvage, resource_folders)
    if salvaged:
        print("The database was rebuilt from what SQLite could still read.")
    labels = [("edits", "edits recovered"), ("partial", "edits recovered with parts left out"),
              ("unreadable", "edits unreadable, kept as .development.json"), ("metadata", "metadata only"),
              ("nothing", "nothing to recover"), ("failed", "failed")]
    for status, label in labels:
        count = sum(1 for e in entries if e["status"] == status)
        if count:
            print("%d\t%s" % (count, label))
    if beside:
        print("%d\tsidecars written beside originals" % sum(1 for e in entries if e.get("beside")))
    print("See " + os.path.join(output, "recovery.csv"))
    return 1 if any(e["status"] == "failed" for e in entries) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
