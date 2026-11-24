import Foundation
import XCTest
import CevicheCore

/// The default run covers every feature quickly; tests that compare the GPU with the CPU reference, run Core ML models
/// or develop full-size RAWs belong to the slow tier, which `make test-slow` (CEVICHE_SLOW_TESTS=1) adds.
public enum TestTier {
    public static var slow: Bool { ProcessInfo.processInfo.environment["CEVICHE_SLOW_TESTS"] == "1" }
    /// Skips the calling test unless the slow tier is on.
    public static func requireSlow(_ what: String = "Slow test") throws {
        guard slow else { throw XCTSkip("\(what): run with CEVICHE_SLOW_TESTS=1 (make test-slow)") }
    }
}

/// The real photos the tests read. They are local only, and never committed or named in the repository. Each role
/// below is a folder under `samples/tests/` in the git-ignored `samples/` folder, and the test takes whatever is in it:
/// one photo (with its sidecar, where the role says so), or several. `CEVICHE_SAMPLES` points elsewhere than `samples/`,
/// or is `off` to skip every sample test, as CI does (GitHub sets `CI`); a worktree without its own `samples/` uses its
/// main checkout's. A test whose folder is missing or empty skips.
public enum TestSamples {
    /// A landscape RAW, the default subject.
    public static let landscape = "landscape"
    /// Two frames of one scene shot seconds apart: a burst, or a short sequence.
    public static let burst = (first: "burst/first", second: "burst/second")
    /// A portrait RAW whose EXIF orientation rotates it.
    public static let portrait = "portrait"
    /// A phone DNG of a face against a plain wall, the ID Photo subject.
    public static let idPortrait = "id/portrait"
    /// A folder of further ID Photo portraits, all run when present.
    public static let idPortraits = "id/more"
    /// A portrait in front of a warm wall.
    public static let idWarmWall = "id/warm-wall"
    /// A portrait whose background is sky.
    public static let idSkyWall = "id/sky-wall"
    /// A RAW with another editor’s XMP sidecar that sets HDR, masks and a look.
    public static let hdrSidecar = "sidecar/hdr"
    /// A RAW with another editor’s XMP sidecar of plain development edits.
    public static let developedSidecar = "sidecar/developed"
    /// A RAW with another editor’s XMP sidecar that sets a retouch spot and an Adobe Color look.
    public static let retouchSidecar = "sidecar/retouch"
    /// A RAW and the camera's JPEG of the same frame.
    public static let rawJPEGPair = (raw: "raw-jpeg/raw", jpeg: "raw-jpeg/jpeg")
    /// The folder of other editors’ XMP sidecars, read for parsing only.
    public static let sidecars = "sidecar/all"
    /// A 24-patch chart in daylight a stop under, at normal exposure and a stop over; in tungsten at normal exposure
    /// and a stop under. Same camera, same chart.
    public static let chart = (daylightUnder: "chart/daylight-under", daylight: "chart/daylight", daylightOver: "chart/daylight-over",
                               tungsten: "chart/tungsten", tungstenUnder: "chart/tungsten-under")
    /// Two portrait RAWs with a face in both.
    public static let faceSeries = (reference: "face-series/reference", target: "face-series/target")
    /// Several RAWs of one scene in changing light; the first is the reference.
    public static let matchSeries = "match-series"
    /// Press profiles (CMYK) for coated and uncoated paper, and an RGB printer profile.
    public static let printProfiles = (coated: "print/coated", uncoated: "print/uncoated", rgb: "print/rgb")
    /// Pixel Shift sets: 4 shots and 16 shots from one Sony body, and a 4-shot still life from another.
    /// Pixel Shift sets: Sony's 4 and 16 shots, Pentax files that each hold one set, one Fujifilm set of 16, and a
    /// Hasselblad six-shot file.
    public static let pixelShift = (four: "pixel-shift/four", sixteen: "pixel-shift/sixteen", stillLife: "pixel-shift/still-life",
                                    pentax: "pixel-shift/pentax", fujifilm: "pixel-shift/fujifilm", hasselblad: "pixel-shift/hasselblad")
    /// Bracketed panoramas: one in CR2 with no 35 mm focal length in EXIF, one in DNG.
    public static let hdrPanorama = (cr2: "hdr-panorama/cr2", dng: "hdr-panorama/dng")
    /// Scans of a negative film roll.
    public static let negativeScans = "negative-scans"
    /// A tripod sequence with people moving through it.
    public static let tripodSequence = "tripod-sequence"
    /// A portrait with strangers behind the subject.
    public static let distractingPeople = "people/distracting"
    /// A phone DNG held upright that carries its own sky matte, with sky at the top.
    public static let skyMatte = "sky-matte"
    /// Light-painting frames for a lighten stack.
    public static let lightPainting = "light-painting"
    /// Every RAW in the corpus: with `rawJPEGPair.jpeg` and the sidecars, all a test may read.
    public static let raws = [landscape, burst.first, burst.second, portrait, hdrSidecar, developedSidecar, retouchSidecar, rawJPEGPair.raw]

    public static var root: URL {
        if let path = ProcessInfo.processInfo.environment["CEVICHE_SAMPLES"], !path.isEmpty, path.lowercased() != "off" { return URL(fileURLWithPath: path, isDirectory: true) }
        let local = repository.appendingPathComponent("samples", isDirectory: true)
        if FileManager.default.fileExists(atPath: local.path) { return local }
        return mainCheckout?.appendingPathComponent("samples", isDirectory: true) ?? local
    }
    /// The repository root: Tests/TestSupport/TestSupport.swift is three folders below `app`.
    public static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    /// The role's folder.
    public static func folder(_ role: String) -> URL { root.appendingPathComponent("tests").appendingPathComponent(role, isDirectory: true) }
    /// The role's photo: the first file in its folder by name that isn't a sidecar, or the folder when there is none.
    public static func url(_ role: String) -> URL { files(in: folder(role)).first { $0.pathExtension.lowercased() != "xmp" } ?? folder(role) }
    static func files(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    /// The git-ignored `presets/` folder of third-party develop presets and camera profiles, or `CEVICHE_PRESETS`;
    /// a worktree without its own uses its main checkout's.
    public static var presets: URL {
        if let path = ProcessInfo.processInfo.environment["CEVICHE_PRESETS"], !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        let local = repository.appendingPathComponent("presets", isDirectory: true)
        if FileManager.default.fileExists(atPath: local.path) { return local }
        return mainCheckout?.appendingPathComponent("presets", isDirectory: true) ?? local
    }
    /// The sample's URL, or a skip when it is not on this Mac.
    /// Off on CI and with `CEVICHE_SAMPLES=off`: real photos are for runs on a developer's Mac.
    public static var enabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["CEVICHE_SAMPLES"] { return path.lowercased() != "off" }
        return environment["CI"] == nil
    }
    /// The role's photo, or a skip.
    public static func require(_ role: String) throws -> URL {
        let folder = try requireFolder(role)
        guard let url = files(in: folder).first(where: { $0.pathExtension.lowercased() != "xmp" }) else { throw XCTSkip("No photo in \(folder.path)") }
        return url
    }
    public static func require(_ roles: [String]) throws -> [URL] { try roles.map { try require($0) } }
    /// The role's folder, or a skip when it is missing.
    public static func requireFolder(_ role: String) throws -> URL {
        guard enabled else { throw XCTSkip("Sample photos are off (CI or CEVICHE_SAMPLES=off)") }
        let folder = folder(role)
        guard FileManager.default.fileExists(atPath: folder.path) else { throw XCTSkip("No sample folder \(folder.path)") }
        return folder
    }
    /// Every file in the role's folder by name, optionally of some extensions, or a skip when there are none.
    public static func requireFiles(_ role: String, extensions: Set<String>? = nil, limit: Int = .max) throws -> [URL] {
        var urls = files(in: try requireFolder(role))
        if let extensions { urls = urls.filter { extensions.contains($0.pathExtension.lowercased()) } }
        guard !urls.isEmpty else { throw XCTSkip("No photos in \(folder(role).path)") }
        return Array(urls.prefix(limit))
    }
    /// The XMP sidecar beside a role's photo, or a skip when it is missing.
    public static func requireSidecar(_ role: String) throws -> URL {
        let url = try require(role).deletingPathExtension().appendingPathExtension("xmp")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("No sidecar in \(folder(role).path)") }
        return url
    }
    /// For a git worktree, the checkout it was made from: `.git` is a file naming `<main>/.git/worktrees/<name>`.
    static var mainCheckout: URL? {
        guard let text = try? String(contentsOf: repository.appendingPathComponent(".git"), encoding: .utf8),
              let line = text.split(separator: "\n").first, line.hasPrefix("gitdir: ") else { return nil }
        let gitdir = URL(fileURLWithPath: String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces))
        guard gitdir.deletingLastPathComponent().lastPathComponent == "worktrees" else { return nil }
        return gitdir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}

extension CatalogAsset {
    /// The row as a photo to insert again, with no EXIF and no development: for tests that copy a stored photo's row.
    public var asPhoto: CatalogPhoto {
        CatalogPhoto(asset: self, exif: CatalogExif(assetID: id, extractedMetadata: Data()), development: CatalogDevelopment(assetID: id))
    }
}
