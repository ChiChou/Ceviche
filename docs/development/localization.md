# Localization

Ceviche includes English (`en`, the development language), Simplified Chinese
(`zh-Hans`), Traditional Chinese (`zh-Hant`), Italian (`it`), and Spanish (`es`).
Tables are keyed by language and script only, never by country. macOS chooses the
language from Language & Region, including an app-specific preferred language.
Quit and reopen Ceviche after changing that setting. The language chosen in
Ceviche's own Settings applies at once; dates then use that language through
`L10n.locale` (`date.localized(...)`, never bare `formatted()`), and the window
root sets SwiftUI's `\.locale` to match.

Each language has a single table with neutral photo-editing terminology; regional
variations are mostly word choice, not different functionality. Any regional
preference macOS reports (for example `zh-Hant-HK` or `es-AR`) resolves to the
matching language and script table. Language names shown in the app are the
language's own name and script, such as 简体中文 and 繁體中文, never a place.

Avoid wrong terms or ambiguity in the translation. For example, `合成` can be
use for image stacking, which is grammatically correct, however it implies
generative or artificial content rather than combining recorded image data.

`app/Sources/CevicheCore/Resources/*/Localizable.strings` are the shipped native tables.
The core resource bundle ships in CevicheKit.framework, which the app and the indexing
service share. SwiftUI, AppKit, accessibility text and background errors share
`L10n`; system panels and standard menu titles use macOS's own localizations.

An app built on the package in another project keeps its own keys in its own table and
adds it at launch with `L10n.addTable(.module)`; `L10n` reads the core's table first.
It runs `localization.py` with `--root`, `--sources`, `--resources`, `--source-json`,
`--plists` and `--shared` (the core's resources folder), so its table holds only the
keys the core's lacks.

## Editing strings

Use `L10n.tr("Export \(count) Photos…")` for app-owned prose. Its interpolation
stores numbered object placeholders, so translators can reorder values safely.
Use whole singular/plural messages instead of concatenating an English `s` or
translating isolated nouns. These languages need no additional plural forms
for the integer counts used here; Chinese translations can use identical forms.

When the same English means two things, give each use a context:
`L10n.tr("Landscape", context: "orientation")` and
`L10n.tr("Landscape", context: "exposure program")` are separate keys
(`orientation|Landscape`) with their own translations, and English shows the
text alone. Name the meaning, not the screen. `Source.json` lists every place a
key is used under `uses`; check it before reusing a short word, and add a context
if the new use means something else. `|` is reserved for contexts.

`L10n.key` is for app-owned display keys stored as strings, such as enum titles and
slider labels. Never pass user text, filenames, catalog names, or protocol fields.
Raw enum values, XMP fields, model labels, folder names and preferences remain
stable. Newly created default names and history descriptions use the active
language; previously saved names/descriptions remain as recorded.

After adding or changing text:

```sh
python3 app/scripts/localization.py --extract
# Translate the new keys in the four non-English tables.
python3 app/scripts/localization.py
```

The extraction script understands string interpolation, display enum values and
slider keys; it updates the English table and `Source.json`. Validation rejects
missing/stale keys, empty values, and incompatible formatting placeholders. Both
the build and test scripts run this validation.

Use `app/scripts/test.sh --filter LocalizationTests` for bundle coverage,
interpolation, fallback, count messages and serialization invariants. Optional
`LocalizationLayoutTests` render the app's welcome screen, Settings and inspector
when `CEVICHE_LOCALIZATION_SNAPSHOTS` names an output directory. Run each language
in a fresh test process using its `AppleLanguages` launch argument.
