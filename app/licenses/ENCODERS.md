# Export encoder licenses and source

Ceviche is licensed under Apache-2.0. These open-source components have permissive
licenses; their notices and terms still apply. No Adobe DNG SDK or proprietary
converter is linked or redistributed.

| Component | Pinned version | License | Integration |
| --- | --- | --- | --- |
| [libwebp](https://github.com/webmproject/libwebp) | 1.6.0 | BSD-3-Clause | SwiftPM source build via SDWebImage/libwebp-Xcode, linked statically into `CevicheKit.framework` as `CWebP` |
| [libjxl](https://github.com/libjxl/libjxl) | 0.10.4 | BSD-3-Clause | SwiftPM source build via SDWebImage/libjxl-Xcode, linked statically into `CevicheKit.framework` as `CJXL` |
| Brotli | libjxl's pinned submodule | MIT | part of `CJXL` |
| Highway | libjxl's pinned submodule | Apache-2.0 OR BSD-3-Clause | part of `CJXL` |
| Little CMS | libjxl's pinned submodule | MIT | part of `CJXL` |

`Vendor/Package.swift` and `Vendor/Package.resolved` pin the encoder packages and their submodules.
`scripts/encoder-notices.py` copies upstream licenses, attribution, and patent notices
into the app's `Resources/EncoderLicenses`. These resources must remain with binary
distributions. The script fails on a missing notice.

BSD, MIT and Apache-2.0 notice requirements are retained; Highway also offers BSD-3-Clause.
None of these licenses requires publishing source.

For a release, use `scripts/archive-encoder-sources.sh` after building. Publish its
source archive alongside the application.
It contains the exact native encoder checkouts, including their submodules and notices.

