import XCTest
import CevicheTestSupport
@testable import CevicheMac
import CevicheCore

/// Times a hover over the Darkroom's films on a real photo: CEVICHE_FILM_TIMING=1 prints the latencies.
final class FilmHoverTimingTests: XCTestCase {
    @MainActor func testTimeHoverWhileTilesRender() async throws {
        guard ProcessInfo.processInfo.environment["CEVICHE_FILM_TIMING"] == "1" else { throw XCTSkip("Set CEVICHE_FILM_TIMING=1") }
        try XCTSkipUnless(FilmCatalog.shared.isAvailable)
        let model = EditorModel()
        defer { model.closeDocument() }
        let opened = await model.open(try TestSamples.require(TestSamples.landscape))
        XCTAssertTrue(opened)
        func settle(_ label: String, since start: Date) async throws {
            var first: Double?
            let shown = model.preview
            for _ in 0..<4000 {
                if first == nil, model.preview !== shown { first = Date().timeIntervalSince(start) }
                if !model.isRendering { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            print(String(format: "hover-timing %@ first %.3fs settled %.3fs tiles %d", label, first ?? -1, Date().timeIntervalSince(start), model.filmPreviews.count))
        }
        var start = Date()
        model.edit { $0.film = FilmSimulation(stock: "portra400") }
        try await settle("apply portra", since: start)
        start = Date()
        model.prewarmFilmPreviews(after: .zero)
        for stock in ["trix400", "velvia50", "ektar100", "vision500t", "gold200", "hp5plus"] {
            guard FilmCatalog.shared.film(stock) != nil else { continue }
            var hovered = model.adjustments; hovered.film = (model.adjustments.film ?? FilmSimulation()).with(stock: FilmCatalog.shared.film(stock)!)
            let begin = Date()
            model.showLookPreview(hovered)
            try await settle("hover \(stock)", since: begin)
        }
        model.showLookPreview(nil)
        try await settle("back to portra", since: Date())
        var begin = Date()
        var count = await model.filmPrints(model.adjustments, exposures: [-1, -0.5, 0, 0.5, 1]).count
        print(String(format: "hover-timing strip of %d prints %.3fs", count, Date().timeIntervalSince(begin)))
        begin = Date()
        count = await model.filmPrints(model.adjustments, exposures: [1.5]).count
        print(String(format: "hover-timing strip step, %d new print %.3fs", count, Date().timeIntervalSince(begin)))
        // Darkroom edits leave the stock previews alone.
        let tiles = model.filmPreviews.count
        model.editFilm { $0.printExposure = 0.5 }
        XCTAssertEqual(model.filmPreviews.count, tiles)
        model.editFilm { $0.printExposure = 0 }
        try await settle("print exposure edits", since: Date())
        // A sweep across the tiles: only the last film has to arrive.
        let sweep = Date()
        for stock in ["trix400", "velvia50", "ektar100", "vision500t", "portra400", "trix400", "velvia50", "acros100"] {
            var hovered = model.adjustments; hovered.film = (model.adjustments.film ?? FilmSimulation()).with(stock: FilmCatalog.shared.film(stock)!)
            model.showLookPreview(hovered)
            try await Task.sleep(for: .milliseconds(60))
        }
        try await settle("sweep of 8", since: sweep)
        for _ in 0..<2000 where model.filmPreviews.count < FilmCatalog.shared.films.count { try await Task.sleep(for: .milliseconds(10)) }
        print(String(format: "hover-timing all tiles %.3fs (%d)", Date().timeIntervalSince(start), model.filmPreviews.count))
        for stock in ["trix400", "velvia50", "ektar100"] {
            var hovered = model.adjustments; hovered.film = (model.adjustments.film ?? FilmSimulation()).with(stock: FilmCatalog.shared.film(stock)!)
            let begin = Date()
            model.showLookPreview(hovered)
            try await settle("warm hover \(stock)", since: begin)
        }
    }
}
