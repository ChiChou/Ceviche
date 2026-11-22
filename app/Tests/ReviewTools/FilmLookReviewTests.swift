import XCTest
import CevicheTestSupport
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import CevicheCore

/// Writes film renderings of the sample photos for a look by eye: CEVICHE_FILM_REVIEW_DIR names the folder.
final class FilmLookReviewTests: XCTestCase {
    func testWriteFilmLooks() async throws {
        guard let folder = ProcessInfo.processInfo.environment["CEVICHE_FILM_REVIEW_DIR"] else { throw XCTSkip("Set CEVICHE_FILM_REVIEW_DIR") }
        try XCTSkipUnless(FilmCatalog.shared.isAvailable)
        let output = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        print("films:", FilmCatalog.shared.films.map { "\($0.id)[\($0.media.map(\.id).joined(separator: ","))]" }.joined(separator: " "))
        for (name, sample) in [("landscape", TestSamples.landscape), ("portrait", TestSamples.portrait)] {
            let (renderer, defaults) = try RawRenderer.open(try TestSamples.require(sample))
            func write(_ label: String, size: Double = 1400, _ change: (inout Adjustments) -> Void) async throws {
                var settings = defaults; change(&settings)
                let start = Date()
                let image = try await renderer.displayImage(settings, maxDimension: size, sdr: true)
                print(String(format: "%@ %@ %dx%d %.2fs", name, label, image.width, image.height, Date().timeIntervalSince(start)))
                let url = output.appendingPathComponent("\(name)-\(label).jpg")
                let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
                XCTAssertTrue(CGImageDestinationFinalize(destination))
            }
            try await write("0-camera") { _ in }
            for film in FilmCatalog.shared.films where ProcessInfo.processInfo.environment["CEVICHE_FILM_REVIEW_ALL"] == "1" || ["portra400", "trix400", "vision500t"].contains(film.id) || film.kind == .slide {
                try await write("film-\(film.id)") { $0.film = FilmSimulation(stock: film.id) }
            }
            for medium in FilmCatalog.shared.film("portra400")?.media ?? [] {
                try await write("portra400-on-\(medium.id)") { $0.film = FilmSimulation(stock: "portra400"); $0.film?.medium = medium.id }
            }
            try await write("portra400-exposure+1") { $0.film = FilmSimulation(stock: "portra400"); $0.film?.printExposure = 1 }
            try await write("portra400-exposure+0.05") { $0.film = FilmSimulation(stock: "portra400"); $0.film?.printExposure = 0.05 }
            try await write("portra400-yellow+20") { $0.film = FilmSimulation(stock: "portra400"); $0.film?.yellow = 20 }
            try await write("portra400-tungsten") { $0.film = FilmSimulation(stock: "portra400"); $0.film?.light = .tungsten }
            try await write("portra400-amount50") { $0.film = FilmSimulation(stock: "portra400"); $0.film?.amount = 50 }
            try await write("portra400-full", size: 8000) { $0.film = FilmSimulation(stock: "portra400") }
        }
    }
}

/// Times the preview through the film for each kind of edit: CEVICHE_FILM_TIMING=1 prints seconds per render.
final class FilmTimingReviewTests: XCTestCase {
    func testTimeFilmEdits() async throws {
        guard ProcessInfo.processInfo.environment["CEVICHE_FILM_TIMING"] == "1" else { throw XCTSkip("Set CEVICHE_FILM_TIMING=1") }
        try XCTSkipUnless(FilmCatalog.shared.isAvailable)
        let (renderer, defaults) = try RawRenderer.open(try TestSamples.require(TestSamples.landscape))
        func time(_ label: String, _ change: (inout Adjustments) -> Void) async throws {
            var settings = defaults; change(&settings)
            let start = Date()
            _ = try await renderer.preview(settings)
            print(String(format: "timing %@ %.3fs", label, Date().timeIntervalSince(start)))
        }
        if let path = ProcessInfo.processInfo.environment["CEVICHE_FILM_TIMING_RAW"] {
            let (large, largeDefaults) = try RawRenderer.open(URL(fileURLWithPath: path))
            for (label, film) in [("camera", nil), ("portra400", FilmSimulation(stock: "portra400")), ("portra400 again", FilmSimulation(stock: "portra400")), ("trix400", FilmSimulation(stock: "trix400"))] as [(String, FilmSimulation?)] {
                var settings = largeDefaults; settings.film = film
                var start = Date()
                _ = try await large.preview(settings)
                let previewTime = Date().timeIntervalSince(start)
                start = Date()
                let job = try await large.prepareDetail(settings, region: CGRect(x: 0, y: 0, width: 1, height: 1), photoWidth: 2800)
                let tile = try job?.render()
                let fitted = Date().timeIntervalSince(start)
                start = Date()
                let zoomed = try await large.prepareDetail(settings, region: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), photoWidth: 14000)?.render()
                print(String(format: "timing large %@: preview %.2fs, fitted tile %.2fs (%d px), zoomed tile %.2fs (%d px)", label, previewTime, fitted, tile?.image.width ?? 0, Date().timeIntervalSince(start), zoomed?.image.width ?? 0))
            }
        }
        // The Darkroom's stock tiles at two per row (260 px) and three per row (176 px), cold tables then warm.
        for size in [260.0, 176, 260, 176] {
            let all = FilmCatalog.shared.films.map { FilmSimulation(stock: $0.id) }
            var varied = defaults; varied.exposure += size / 100_000
            let start = Date()
            var count = 0
            for batch in stride(from: 0, to: all.count, by: 2) { count += try await renderer.filmPreviews(varied, films: Array(all[batch..<min(batch + 2, all.count)]), size: size).count }
            print(String(format: "timing tiles %.0f px: %d in %.2fs", size, count, Date().timeIntervalSince(start)))
        }
        for size in [700.0, 800, 900] {
            var ringed = defaults; ringed.film = FilmSimulation(stock: "portra400")
            let start = Date()
            do {
                let ring = try await renderer.filmRingAround(ringed, filtrations: [-10.0, 0, 10].flatMap { m in [-10.0, 0, 10].map { (yellow: $0, magenta: m) } }, size: size)
                print(String(format: "timing ring %.0f: %d prints %.3fs", size, ring.count, Date().timeIntervalSince(start)))
            } catch { print("timing ring \(size) failed: \(error)") }
        }
        try await time("camera") { _ in }
        try await time("camera again") { $0.exposure += 0.1 }
        try await time("portra400 first") { $0.film = FilmSimulation(stock: "portra400") }
        try await time("portra400 same") { $0.film = FilmSimulation(stock: "portra400") }
        for step in 1...4 { try await time("print exposure \(step)") { $0.film = FilmSimulation(stock: "portra400"); $0.film?.printExposure = Double(step) * 0.1 } }
        for step in 1...3 { try await time("yellow \(step)") { $0.film = FilmSimulation(stock: "portra400"); $0.film?.yellow = Double(step) } }
        for step in 1...3 { try await time("grain \(step)") { $0.film = FilmSimulation(stock: "portra400"); $0.film?.grain = 100 + Double(step) } }
        for step in 1...3 { try await time("scene exposure \(step)") { $0.film = FilmSimulation(stock: "portra400"); $0.exposure += Double(step) * 0.1 } }
        for step in 1...3 { try await time("amount \(step)") { $0.film = FilmSimulation(stock: "portra400"); $0.film?.amount = 100 - Double(step) } }
        for stock in ["ektar100", "velvia50", "trix400", "vision500t"] { try await time("stock \(stock)") { $0.film = FilmSimulation(stock: stock) } }
        for medium in ["screen", "lab-scan", "vision-2383"] { try await time("medium \(medium)") { $0.film = FilmSimulation(stock: "portra400"); $0.film?.medium = medium } }
        try await time("light tungsten") { $0.film = FilmSimulation(stock: "portra400"); $0.film?.light = .tungsten }
        try await time("push") { $0.film = FilmSimulation(stock: "portra400"); $0.film?.push = 1 }
    }
}
