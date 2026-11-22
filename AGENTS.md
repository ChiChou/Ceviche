This is a tool for experienced photographer, avoid verbose descriptive labels on the UI

- Commit only when asked; otherwise leave changes in the working tree.
- New strings: run `app/scripts/localization.py --extract`, then append es, it, zh-Hans and zh-Hant translations to the end of each table (don't re-sort them) and drop stale keys. A word with two meanings (Landscape the orientation, Landscape the scene mode) gets `L10n.tr("…", context: "…")` so each is translated on its own; see `docs/development/localization.md`.
- Command-line prototypes can be built in `prototypes/` for speed, but they stay out of this repo: never commit or merge them. A prototype either becomes a finished app feature or is dropped.
- Network drives are read-only: read test photos in place, but never write there, not even outputs, sidecars or caches. Copy photos into `samples/` only when a test must not depend on the mount.
- Each new open-source dependency (code, data, models or profiles): copy its LICENSE, any NOTICE, and a note of changes where its licence asks for one (CC BY-SA, Apache) into `app/Sources/CevicheMac/Resources/OpenSourceLicenses/credits/<id>/`, name them in `credits.json` there, and run `python3 -I app/scripts/credits.py --write`. That one manifest ships in the app bundle, fills Help › Open Source Licenses and generates `app/licenses/CREDITS.md`; the build fails when a notice is missing or unnamed or CREDITS.md is stale.
- Implementing a `ROADMAP.md` item: delete its row in the same branch (and its group heading once empty), and update **Order** if it names the item.
- Docs live in `docs/`: the feature list, plus building, testing and internals. There is no user guide. Update the page a change affects.
- Shipping a feature, or changing or removing one: update `docs/features.md` in the same change. One or two plain sentences per feature on what it does and how it is used, no step-by-step instructions, names as the menus show them.
