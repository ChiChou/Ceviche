// swift-tools-version: 5.10
// Third-party codecs Ceviche bundles without modifying. scripts/vendor.sh builds them once, optimized, into static
// libraries in Vendor/Frameworks (one xcframework each: macOS on Apple silicon, and iOS with CEVICHE_IOS=1), which
// app/Package.swift links into CevicheKit, so neither app configuration compiles them.
import PackageDescription
let package = Package(
    name: "CevicheVendor", platforms: [.macOS("15.0"), .iOS("26.0")],
    products: [.library(name: "CWebP", type: .static, targets: ["CWebP"]), .library(name: "CJXL", type: .static, targets: ["CJXL"])],
    dependencies: [
        .package(url: "https://github.com/SDWebImage/libwebp-Xcode.git", exact: "1.6.0"),
        .package(url: "https://github.com/SDWebImage/libjxl-Xcode.git", exact: "0.10.4")
    ],
    targets: [
        .target(name: "CWebP", dependencies: [.product(name: "libwebp", package: "libwebp-Xcode")], publicHeadersPath: "."),
        .target(name: "CJXL", dependencies: [.product(name: "libjxl", package: "libjxl-Xcode")], publicHeadersPath: ".")
    ]
)
