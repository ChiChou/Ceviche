// swift-tools-version: 5.10
import PackageDescription
// 15.0 for every build: the App Store app target alone raises its own to 26.0 (Platforms/macOS/Config/Ceviche.xcconfig).
let macOSMinimum = Context.environment["CEVICHE_MACOS_MIN"] ?? "15.0"
// CEVICHE_IOS=1 (build.config or the environment; scripts/config.sh): scripts/vendor.sh also builds the codecs for iOS,
// and they are linked there. Off by default: iOS builds then offer no WebP or JPEG XL export.
let codecPlatforms: [Platform] = Context.environment["CEVICHE_IOS"] == "1" ? [.macOS, .iOS] : [.macOS]
let package = Package(
    name: "Ceviche", defaultLocalization: "en", platforms: [.macOS(macOSMinimum), .iOS("26.0")],
    // The app, its index service and its MCP helper are targets of Ceviche.xcodeproj and share CevicheKit, one dynamic
    // library of the app's code and everything it links, which Xcode builds as CevicheKit.framework.
    products: [.library(name: "CevicheKit", type: .dynamic, targets: ["CevicheMac", "CevicheCore"]), .library(name: "CevicheCore", targets: ["CevicheCore"])],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        // Static libraries built by scripts/vendor.sh from Vendor/Package.swift, which pins the sources.
        .binaryTarget(name: "CWebP", path: "Vendor/Frameworks/CWebP.xcframework"),
        .binaryTarget(name: "CJXL", path: "Vendor/Frameworks/CJXL.xcframework"),
        .target(name: "DustRemoval", linkerSettings: [.linkedFramework("Accelerate")]),
        .target(name: "CDNG", linkerSettings: [.linkedLibrary("z")]),
        // Sensor data straight from RAW files, for what Apple's decoder doesn't expose (Pixel Shift's exposures).
        // Optimized in debug builds too: its decoders run per sample.
        .target(name: "CameraRaw", swiftSettings: [.unsafeFlags(["-O"])]),
        // The film print: the stocks and their spectral model, and the Metal kernels that develop and print a frame.
        // Optimized in debug builds too: it builds each film's spectral tables in Swift, which takes minutes unoptimized.
        .target(name: "FilmPrint", resources: [.copy("Resources/Stocks"), .copy("Resources/rec2020-reflectance-prior.coeff")],
                swiftSettings: [.unsafeFlags(["-O"])]),
        // Optimized in debug builds too: its per-pixel loops (AI denoise's tiles, the analyses) run 10–15 times slower
        // unoptimized, so a debug build's denoise took minutes.
        .target(name: "CevicheCore", dependencies: ["CSQLite", "DustRemoval", "CDNG", "CameraRaw", "FilmPrint", .product(name: "GRDB", package: "GRDB.swift"),
                                                     .target(name: "CWebP", condition: .when(platforms: codecPlatforms)),
                                                     .target(name: "CJXL", condition: .when(platforms: codecPlatforms))], resources: [.process("Resources")],
                swiftSettings: [.unsafeFlags(["-O"])],
                // Release links (CevicheKit) keep the codecs' symbols private and drop unused code: 0.9 MB less.
                linkerSettings: [.unsafeFlags(["-Xlinker", "-dead_strip", "-Xlinker", "-unexported_symbols_list",
                                               "-Xlinker", "\(Context.packageDirectory)/Vendor/Frameworks/codec-symbols.txt"],
                                              .when(configuration: .release))]),
        .target(name: "CevicheMac", dependencies: ["CevicheCore"], resources: [.copy("Resources/OpenSourceLicenses")]),
        // The slow-tier switch, the sample corpus and shared fixtures, for both test targets.
        .target(name: "CevicheTestSupport", dependencies: ["CevicheCore"], path: "Tests/TestSupport"),
        .testTarget(name: "CevicheCoreTests", dependencies: ["CevicheCore", "CameraRaw", "DustRemoval", "CevicheTestSupport"]),
        .testTarget(name: "CevicheMacTests", dependencies: ["CevicheMac", "CevicheTestSupport"]),
        // Tools for looking at results rather than asserting them: parameter sweeps and sample-sequence runs that write
        // images for review, each behind its own environment variable. `make test` leaves them out.
        .testTarget(name: "ReviewTools", dependencies: ["CevicheCore", "CevicheTestSupport"])
    ]
)
