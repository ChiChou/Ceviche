# ID photo presets

The ID Photo tool's presets live in `app/Sources/CevicheCore/Resources/IDPhotoSpecs.json`, each with the official
source it was taken from. Sizes are width × height; head is crown to chin. A preset says what the photo must measure,
not that a document office will accept it: capture rules (an approved photographer, no edits, age exceptions) are
outside what the tool checks.

| Preset | Print (mm) | Head (mm) | Background | Digital upload | Source |
|---|---|---|---|---|---|
| ICAO passport | 35×45 | 31.5–36 | white or light |  | [icao.int](https://www.icao.int/sites/default/files/FAL/Annex_A-Photograph_Guidelines.pdf) |
| US passport | 50.8×50.8 | 25.4–34.9 | white |  | [travel.state.gov](https://travel.state.gov/content/travel/en/passports/how-apply/photos.html) |
| US visa | 50.8×50.8 | 25.4–34.9 | white | 600×600–1200×1200 px, ≤240 KB | [travel.state.gov](https://travel.state.gov/content/travel/en/us-visas/visa-information-resources/photos.html) |
| US green card | 50.8×50.8 | 25.4–34.9 | white |  | [uscis.gov](https://www.uscis.gov/sites/default/files/document/forms/i-485instr.pdf) |
| CA passport | 50×70 | 31–36 | white or light | 1200×1800–3000×4500 px, ≤5 MB | [canada.ca](https://www.canada.ca/en/immigration-refugees-citizenship/services/canadian-passports/photos.html) |
| CA visa | 35×45 | 31–36 | white or light |  | [canada.ca](https://www.canada.ca/en/immigration-refugees-citizenship/services/application/application-forms-guides/temporary-resident-visa-application-photograph-specifications.html) |
| GB passport | 35×45 | 29–34 | light grey | ≥600×750 px, ≤10 MB | [gov.uk](https://www.gov.uk/photos-for-passports/photo-requirements) |
| EU visa | 35×45 | 32–36 | white |  | [uk.diplo.de](https://uk.diplo.de/uk-en/02/visa/visa-faq-2442852) |
| DE passport / ID card | 35×45 | 32–36 | white or light |  | [personalausweisportal.de](https://www.personalausweisportal.de/SharedDocs/downloads/Webs/PA/DE/informationsmaterial/weiterefuehrendes-material/Lichtbildschablone_bfrei.pdf?__blob=publicationFile&v=7) |
| FR passport / ID card | 35×45 | 32–36 | light blue |  | [service-public.gouv.fr](https://www.service-public.gouv.fr/particuliers/vosdroits/F10619) |
| IT passport | 35×45 | 31.5–36 | white or light |  | [conschicago.esteri.it](https://conschicago.esteri.it/wp-content/uploads/2025/10/foto-per-passaporto.pdf) |
| NL passport / ID card | 35×45 | 26–30 | white or light |  | [rijksoverheid.nl](https://www.rijksoverheid.nl/onderwerpen/paspoort-en-identiteitskaart/eisen-pasfoto-paspoort-id-kaart) |
| AU passport | 35×45 | 32–36 | white or light |  | [passports.gov.au](https://www.passports.gov.au/help/passport-photos) |
| JP passport | 35×45 | 32–36 | white or light | 600×730 px, ≤600 KB | [mofa.go.jp](https://www.mofa.go.jp/mofaj/toko/passport/ic_photo.html) |
| KR passport | 35×45 | 32–36 | white | 395×507–431×550 px, ≤500 KB | [passport.go.kr](https://www.passport.go.kr/home/kor/contents.do?menuPos=32) |
| SG passport | 35×45 | 25–35 | white | 400×514 px, ≤8 MB | [ica.gov.sg](https://www.ica.gov.sg/photo-guidelines) |
| BE passport / ID card | 35×45 | 31–36 | white or light |  | [france.diplomatie.belgium.be](https://france.diplomatie.belgium.be/sites/default/files/2024-06/Normes%20standards%20photos%20d%27identit%C3%A9.pdf) |
| FI passport / ID card | 36×47 | 32–36 | white or light | 500×653 px, ≤250 KB | [poliisi.fi](https://poliisi.fi/documents/25235045/31329600/Passport-photograph-instructions-by-the-police-2020-EN-fixed.pdf/1eec2f4c-aed7-68e0-c112-0a8f25e0328d/Passport-photograph-instructions-by-the-police-2020-EN-fixed.pdf) |
| PL passport | 35×45 | 31.5–36 | white or light |  | [gov.pl](https://www.gov.pl/web/uw-lubelski/informacja-dotyczaca-fotografii-do-dokumentu-paszportowego) |

## Adding or changing a preset

Cite the issuing authority's own page, or a consulate's copy when the authority's is unreachable, in `source`. Leave
a measurement out rather than infer it, and keep what the authority leaves open in `notes`.

## Known limits

- A digital photo keeps the print's aspect ratio; uploads with their own (Japan 600×730, Canada's online renewal)
  come out at the print's.
- `backgroundNote`, `headwear` and `earsVisible` are in the data but not read; there is no minimum file size.
- Head detection can put the crown on the hair outline; France, Finland and Korea measure from the skull.
