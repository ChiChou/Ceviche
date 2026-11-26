#!/usr/bin/env python3
"""Extract app-owned localization keys and validate native string tables.

Run --extract after adding L10n.tr literals, display enums, or slider keys. This
updates only English and Source.json; translations must be reviewed separately.
No network or third-party dependencies are used.

With no options it covers this package: CevicheCore and CevicheMac, into CevicheCore's tables. An app built on the
package elsewhere keeps its own table (`L10n.addTable`) and runs this with --root, --sources, --resources, --source-json,
--plists and --shared (the core's resources folder), so its table holds only the keys the core's lacks.
"""
import argparse
import collections
import json
import pathlib
import plistlib
import re
import sys

APP = pathlib.Path(__file__).resolve().parents[1]
LOCALES = ("en", "zh-Hans", "zh-Hant", "it", "es")
# Between a context and its English (`L10n.contextKey`).
CONTEXT_SEPARATOR = "|"

def strings(s,start=0,end=None):
    i=start; end=len(s) if end is None else end
    while i<end:
        if s.startswith('//',i):
            j=s.find('\n',i); i=end if j<0 else j+1
        elif s.startswith('/*',i):
            depth=1;i+=2
            while i<end and depth:
                if s.startswith('/*',i):depth+=1;i+=2
                elif s.startswith('*/',i):depth-=1;i+=2
                else:i+=1
        elif s[i]=='"' or (s[i]=='#' and s[i+1:i+2]=='"'):
            a=i;raw=s[i]=='#';i+=raw
            multi=s.startswith('"""',i);quote='"""' if multi else '"';close=quote+('#' if raw else '')
            i+=len(quote); parts=[];lit=i
            while i<end:
                if s.startswith(close,i):
                    parts.append(('text',s[lit:i]));i+=len(close);break
                esc='\\#' if raw else '\\'
                if s.startswith(esc+'(',i):
                    parts.append(('text',s[lit:i]));i+=len(esc)+1;b=i;depth=1
                    while i<end and depth:
                        if s[i]=='"':
                            nested=next(strings(s,i),None)
                            if nested:i=nested['end'];continue
                        if s[i]=='(':depth+=1
                        if s[i]==')':depth-=1
                        i+=1
                    parts.append(('expr',s[b:i-1]));lit=i
                elif s.startswith(esc,i):i+=len(esc)+1
                else:i+=1
            yield dict(start=a,end=i,parts=parts,raw=raw,multi=multi,literal=s[a:i])
        else:i+=1

def walk_strings(source, offset=0):
    for token in strings(source):
        yield dict(token, start=token["start"] + offset, end=token["end"] + offset)
        for kind, expression in token["parts"]:
            if kind == "expr":
                position = source.find(expression, token["start"], token["end"])
                yield from walk_strings(expression, offset + position)


def decoded(text):
    # Swift literals used by this app share these escapes with JSON.
    return json.loads('"' + text + '"')


def message_key(parts):
    interpolated = any(kind == "expr" for kind, _ in parts)
    result = ""
    position = 0
    for kind, value in parts:
        if kind == "text":
            value = decoded(value)
            result += value.replace("%", "%%") if interpolated else value
        else:
            position += 1
            result += f"%{position}$@"
    return result


def inventory(root, folders, shared, synthetic):
    entries = {}
    for folder in folders:
        for path in sorted((root / folder).rglob("*.swift")):
            if path.name == "Localization.swift":
                continue
            source = path.read_text()
            if re.search(r"(?:forKey:|systemName:|systemImage:|identifier:|appendingPathComponent\()\s*L10n\.", source):
                raise ValueError(f"Localized non-display identifier in {path}")
            for token in walk_strings(source):
                before = source[max(0, token["start"] - 100):token["start"]]
                line = source[source.rfind("\n", 0, token["start"]) + 1:source.find("\n", token["end"])]
                direct = before.endswith(("L10n.tr(", "L10n.key("))
                slider = re.search(r"(?:adjustment|rangeAdjustment|selectiveSlider)\($", before)
                slider = slider or re.search(r"(?:AdjustmentSlider|AdjustmentRangeSlider)\(title:\s*$", before)
                display_enum = "var localizedTitle: String" in source and re.search(r"\bcase\s+", line) and re.search(r"=\s*$", before)
                if not (direct or slider or display_enum) or token["multi"] or token["raw"]:
                    continue
                english = message_key(token["parts"])
                if not english:
                    continue
                # L10n.tr("Landscape", context: "orientation"): its own key, so each meaning has its own translation.
                meaning = re.match(r'\s*,\s*context:\s*"([^"\\]+)"', source[token["end"]:]) if direct else None
                if CONTEXT_SEPARATOR in english or (meaning and CONTEXT_SEPARATOR in meaning.group(1)):
                    raise ValueError(f"{CONTEXT_SEPARATOR!r} is reserved for contexts: {english} in {path}")
                key = f"{meaning.group(1)}{CONTEXT_SEPARATOR}{english}" if meaning else english
                where = f"{path.relative_to(root)}:{source.count(chr(10), 0, token['start']) + 1}"
                entry = entries.setdefault(key, {"key": key, "english": english, "source": token["literal"], "context": where, "uses": []})
                if meaning:
                    entry["meaning"] = meaning.group(1)
                entry["uses"].append(where)
    # These names are also XMP field suffixes. Translate at the UI boundary only.
    for name in ("Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta", "Cyan") if synthetic else ():
        entries.setdefault(name, {"key": name, "english": name, "source": name, "context": "SelectiveColor.names (display only; XMP identifiers stay in English)", "uses": []})
    for key in shared:
        entries.pop(key, None)
    for entry in entries.values():
        # Every place a key shows, so a translator sees when one word serves two purposes.
        uses = entry.pop("uses")
        if len(uses) > 1:
            entry["uses"] = uses
    return dict(sorted(entries.items()))


def read_table(path):
    result = {}
    literal = r'"((?:[^"\\]|\\.)*)"'
    for line in path.read_text().splitlines():
        match = re.fullmatch(r"\s*" + literal + r"\s*=\s*" + literal + r";\s*", line)
        if not match:
            if line.strip() and not line.strip().startswith("/*"):
                raise ValueError(f"Invalid strings line in {path}: {line}")
            continue
        key, value = map(decoded, match.groups())
        if key in result:
            raise ValueError(f"Duplicate key in {path}: {key}")
        result[key] = value
    return result


def write_table(path, entries):
    path.parent.mkdir(parents=True, exist_ok=True)
    quote = lambda text: json.dumps(text, ensure_ascii=False)
    path.write_text("/* Ceviche localization. See docs/development/localization.md. */\n" + "".join(f"{quote(key)} = {quote(value)};\n" for key, value in sorted(entries.items())))


def placeholders(value):
    return collections.Counter(re.findall(r"%(?:[1-9][0-9]*\$)?@|%%", value))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--extract", action="store_true")
    parser.add_argument("--root", type=pathlib.Path, default=APP, help="the folder the other paths are in")
    parser.add_argument("--sources", nargs="+", default=["Sources/CevicheMac", "Sources/CevicheCore"])
    parser.add_argument("--resources", default="Sources/CevicheCore/Resources")
    parser.add_argument("--source-json", default="Localization/Source.json")
    parser.add_argument("--plists", nargs="*", default=["Platforms/macOS/Info.plist", "Platforms/macOS/IndexService-Info.plist"])
    parser.add_argument("--shared", type=pathlib.Path, help="another resources folder whose keys this table leaves out")
    args = parser.parse_args()
    root = args.root.resolve()
    resources = root / args.resources
    shared = read_table(args.shared / "en.lproj/Localizable.strings").keys() if args.shared else ()
    entries = inventory(root, args.sources, shared, synthetic=not args.shared)
    if args.extract:
        source = [{name: value for name, value in entry.items() if name != "english"} for entry in entries.values()]
        (root / args.source_json).parent.mkdir(parents=True, exist_ok=True)
        (root / args.source_json).write_text(json.dumps(source, ensure_ascii=False, indent=2) + "\n")
        write_table(resources / "en.lproj/Localizable.strings", {key: entry["english"] for key, entry in entries.items()})
    failures = []
    for name in args.plists:
        info = plistlib.loads((root / name).read_bytes())
        if set(info.get("CFBundleLocalizations", [])) != set(LOCALES):
            failures.append(f"{name}: declared languages differ from shipped tables")
    for locale in LOCALES:
        path = resources / f"{locale}.lproj/Localizable.strings"
        if not path.exists():
            failures.append(f"Missing {path}")
            continue
        table = read_table(path)
        if table.keys() != entries.keys():
            failures.append(f"{locale}: {len(entries.keys() - table.keys())} missing, {len(table.keys() - entries.keys())} stale keys")
        for key, value in table.items():
            if not value or placeholders(key) != placeholders(value):
                failures.append(f"{locale}: invalid placeholders/empty translation: {key}")
            # A bare percent in a formatted message can crash String(format:).
            if "%1$@" in key and "%" in re.sub(r"%[1-9][0-9]*\$@|%%", "", value):
                failures.append(f"{locale}: unescaped percent: {key}")
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print(f"Validated {len(entries)} keys in {len(LOCALES)} languages.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
