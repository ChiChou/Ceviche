# Ceviche identity

Adopted 27 November 2026: a soft, sculpted ceviche bowl with a lowercase Nunito Bold 700 wordmark.

<img src="../../../app/Platforms/macOS/Resources/AppIcon.png" width="160" alt="Ceviche app icon">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="wordmark-reversed.svg">
  <img src="wordmark.svg" width="300" alt="ceviche">
</picture>

## Tracked assets

| File | Purpose |
| --- | --- |
| `bowl-source.png` | Opaque 1024 × 1024 sRGB artwork; no platform corner mask. This is the source for both apps. |
| `../../../app/Platforms/macOS/Resources/AppIcon.png` | Mac master: artwork in an 824-pixel continuous rounded square, centered on a transparent 1024-pixel canvas, with a short shadow. |
| `../../../app/Platforms/macOS/Resources/AppIcon.icns` | Mac application icon, including small and Retina renditions. |
| `wordmark.svg`, `wordmark-reversed.svg` | Nunito Bold 700 glyph outlines with the font's spacing; graphite and porcelain versions. They do not require an installed font. |
| `fonts/Nunito.ttf` | Unmodified variable font used to reproduce the outlines; not bundled in the app. |
| `bowl-system.png` | Approved identity presentation, including appearance and monochrome directions. Its lettering is the earlier type study; the SVG wordmarks supersede it. |
| `bowl-system-prompt.json`, `bowl-source-prompts.json` | Built-in imagegen prompts and asset provenance. |

The bowl is the mark. Three ivory fish pieces, two coral pieces, one lime wedge and two short pink onion strips
form a fixed composition, with a thin shallow rim and restrained shading. Keep its proportions and placement;
do not stretch it to fill an icon. Avoid enclosing onion crescents, star-shaped garnish or letter motifs.

The bowl occupies approximately three quarters of the unmasked square. The Mac export adds its own frame and
transparent outer margin for the existing `.icns` pipeline. iPhone and iPad use the opaque source directly;
their system supplies the corner mask. Do not copy the framed Mac PNG into a mobile asset catalog.

The current exports provide the light icon. Dark, tinted, clear and flat monochrome examples on the presentation
remain design references, not separately shipped or native-validated assets. The presentation is not sliced up
to make application icons. A future layered Icon Composer asset should retain this composition.

## Wordmark and color

Use lowercase `ceviche`, Nunito Bold 700, upright, with the font's default spacing. The outlined exports are the
canonical wordmarks. Porcelain `#F8F5F1` and graphite `#423D37` are their background/foreground roles; coral,
lime and onion pink stay in the bowl artwork. Keep the wordmark clear of the bowl rim and shadow.

Nunito is by Vernon Adams, Cyreal and Jacques Le Bailly. The source font is pinned to upstream revision
`8c6a9bb9732545b9ed53f29ec5e1ab0ff53c4e6f`; its SHA-256 is
`bb55a5ca5c2042335b3991af27c4d0705d0ef41cac6164ac737fd8f2a1e85207`.
Its [SIL Open Font License](../../../app/Sources/CevicheMac/Resources/OpenSourceLicenses/credits/nunito/LICENSE)
and [source record](../../../app/Sources/CevicheMac/Resources/OpenSourceLicenses/credits/nunito/SOURCE.txt)
are registered in the app's credits manifest as an identity export dependency.

## Rebuilding

From the repository root on macOS:

```sh
swift app/scripts/identity.swift
bash app/scripts/app-icon.sh
python3 -I app/scripts/credits.py
```

The first command uses Core Text for the wordmark outlines and a native continuous corner path for the Mac
frame, so no generated transparency edge is shipped. The second exports the `.icns` through the existing
`sips`/`iconutil` and pinned compression pipeline. Commit the source, generated assets, scripts and notices together.
Inspect the result on light and dark backgrounds at 16, 32, 64, 128 and 256 pixels when changing the artwork.

Platform references: [Apple app icons](https://developer.apple.com/design/human-interface-guidelines/app-icons/)
and [Icon Composer](https://developer.apple.com/icon-composer/).
