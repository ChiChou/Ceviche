import XCTest
import AppKit
import SwiftUI
import CevicheCore
import CevicheTestSupport
@testable import CevicheMac

/// Optional visual check of the tool windows: with CEVICHE_UI_SNAPSHOTS=1 and CEVICHE_TOOL naming one, imports that
/// tool's sample photos into a temporary catalog, opens the tool the way the Photo menu does and writes
/// CEVICHE_TOOL_OUTPUT/tool-<name>.png once its analysis and preview had CEVICHE_TOOL_WAIT seconds. CEVICHE_TOOL_STEPS=n
/// presses Return and captures again, n − 1 times. CEVICHE_TOOL_SAMPLES=<folder> takes the first 21 RAWs there (from
/// the file CEVICHE_TOOL_FROM names) instead of the samples; the panorama and night-sky tools have no samples and need it.
final class ToolSnapshotTests: XCTestCase {
    /// One tool: the photos it opens on and how the Photo menu opens it.
    private struct Tool {
        var sources: () throws -> [URL]
        var open: @MainActor (CatalogModel, [CatalogAsset]) throws -> Void
    }

    private static func files(_ role: String, limit: Int = 100) throws -> [URL] {
        try TestSamples.requireFiles(role, extensions: CatalogImporter.rawExtensions, limit: limit)
    }

    private static func raws(in directory: URL, limit: Int) throws -> [URL] {
        Array(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { CatalogImporter.rawExtensions.contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(limit))
    }

    /// Photos from CEVICHE_TOOL_SAMPLES, for the tools the samples don't cover.
    private static func own() throws -> [URL] {
        let environment = ProcessInfo.processInfo.environment
        guard let folder = environment["CEVICHE_TOOL_SAMPLES"] else { throw XCTSkip("Set CEVICHE_TOOL_SAMPLES to a folder of photos for this tool") }
        var sources = try raws(in: URL(fileURLWithPath: folder), limit: .max)
        if let first = environment["CEVICHE_TOOL_FROM"], let start = sources.firstIndex(where: { $0.lastPathComponent == first }) { sources = Array(sources[start...]) }
        return Array(sources.prefix(21))
    }

    private static func stack(_ mode: PhotoStackMode, limit: Int = 6) -> Tool {
        Tool(sources: { try files(TestSamples.tripodSequence, limit: limit) }) { model, assets in
            XCTAssertTrue(model.canStack(assets)); model.requestStack(assets, mode: mode); XCTAssertNotNil(model.photoStack)
        }
    }

    private static func nightSky(_ tool: NightSkyTool) -> Tool {
        Tool(sources: own) { model, assets in model.requestNightSky(tool, assets); XCTAssertNotNil(model.nightSky) }
    }

    private static let chart: () throws -> [URL] = { try [TestSamples.require(TestSamples.chart.daylightUnder)] }

    private static let tools: [String: Tool] = [
        "pixelshift": Tool(sources: { try files(TestSamples.pixelShift.four).filter { $0.pathExtension.lowercased() == "arw" } }) { model, assets in
            XCTAssertTrue(model.canPixelShift(assets)); model.requestPixelShift(assets); XCTAssertNotNil(model.pixelShift)
        },
        "hdrpano": Tool(sources: { try files(TestSamples.hdrPanorama.dng) }) { model, assets in
            XCTAssertTrue(model.canMergePanorama(assets)); model.requestPanoramaMerge(assets); XCTAssertNotNil(model.panoramaMerge)
        },
        "hdrmerge": Tool(sources: { try files(TestSamples.hdrPanorama.dng, limit: 3) }) { model, assets in
            XCTAssertTrue(model.canMergeHDR(assets)); model.requestHDRMerge(assets); XCTAssertNotNil(model.hdrMerge)
        },
        "pano": Tool(sources: own) { model, assets in
            XCTAssertTrue(model.canMergePanorama(assets)); model.requestPanoramaMerge(assets); XCTAssertNotNil(model.panoramaMerge)
        },
        "filters": Tool(sources: { [try TestSamples.require(TestSamples.landscape)] }) { model, assets in
            // The dialog opens on the last stack used: a polarizer, tonal contrast and diffusion. CEVICHE_TOOL_COMPARE
            // names the canvas's compare mode: single, split or sideBySide.
            if let compare = ProcessInfo.processInfo.environment["CEVICHE_TOOL_COMPARE"] { UserDefaults.standard.set(compare, forKey: "filtersCompare") }
            var polarizer = CreativeFilter(.polarizer)
            polarizer["azimuth"] = 100
            // CEVICHE_TOOL_FILTERS names other filters, by raw value and comma separated.
            let named = ProcessInfo.processInfo.environment["CEVICHE_TOOL_FILTERS"]?.split(separator: ",").compactMap { CreativeFilterKind(rawValue: String($0)) }.map { CreativeFilter($0) }
            let stack = CreativeFilterStack(named ?? [polarizer, CreativeFilter(.diffusion), CreativeFilter(.tonalContrast)]).ordered()
            UserDefaults.standard.set(try JSONEncoder().encode(stack), forKey: "filtersStack")
            XCTAssertTrue(model.canApplyFilters(assets)); model.requestFilters(assets); XCTAssertNotNil(model.filters)
        },
        "chart": Tool(sources: chart) { model, assets in
            XCTAssertTrue(model.canMakeChartProfile(assets)); model.requestChartProfile(assets); XCTAssertNotNil(model.chartProfile)
        },
        "stack": stack(.median),
        "sequence": stack(.sequence, limit: 8),
        "longexposure": stack(.mean),
        "lighten": Tool(sources: { try TestSamples.requireFiles(TestSamples.lightPainting) }) { model, assets in
            XCTAssertTrue(model.canStack(assets)); model.requestStack(assets, mode: .lighten); XCTAssertNotNil(model.photoStack)
        },
        "matchseries": Tool(sources: { try TestSamples.requireFiles(TestSamples.matchSeries) }) { model, assets in
            XCTAssertTrue(model.canMatchSeries(assets))
            model.requestMatchSeries(assets, reference: assets.first { $0.filename == (try? TestSamples.requireFiles(TestSamples.matchSeries))?.first?.lastPathComponent }); XCTAssertNotNil(model.matchSeries)
        },
        "startrails": nightSky(.starTrails),
        "nightdenoise": nightSky(.denoise),
        "meteors": nightSky(.meteorShower),
    ]

    @MainActor func testToolWindowWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CEVICHE_UI_SNAPSHOTS"] == "1", let name = environment["CEVICHE_TOOL"] else { throw XCTSkip("Optional tool snapshots") }
        guard let tool = Self.tools[name] else { throw XCTSkip("Unknown tool \(name): one of \(Self.tools.keys.sorted().joined(separator: ", "))") }
        let output = URL(fileURLWithPath: environment["CEVICHE_TOOL_OUTPUT"] ?? NSTemporaryDirectory()).appendingPathComponent("tool-\(name).png")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ToolSnapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // The filter dialog reads the app's own defaults; they go back as they were.
        let keys = ["filtersStack", "filtersCompare"], kept = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, kept) { UserDefaults.standard.set(value, forKey: key) } }
        let model = try await EditorFixtures.catalog(of: environment["CEVICHE_TOOL_SAMPLES"] == nil ? tool.sources() : Self.own(), in: directory)
        try tool.open(model, model.assets)

        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1400, height: 860), styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: CatalogWorkspace(catalog: model, editor: EditorModel()).preferredColorScheme(.dark).ignoresSafeArea(.container, edges: .top))
        host.appearance = NSAppearance(named: .darkAqua); window.contentView = host; window.makeKeyAndOrderFront(nil)
        let wait = Double(environment["CEVICHE_TOOL_WAIT"] ?? "") ?? 20
        // A step takes the tool further once it is ready, such as a tool's Continue.
        let steps = max(1, Int(environment["CEVICHE_TOOL_STEPS"] ?? "") ?? 1)
        for step in 0..<steps {
            try await Task.sleep(for: .seconds(wait))
            try host.writePNG(to: step == 0 ? output : output.deletingPathExtension().appendingPathExtension("\(step + 1).png"))
            if step + 1 < steps { NSApp.sendAction(#selector(NSResponder.insertNewline(_:)), to: nil, from: nil) }
        }
    }

    /// Filters go out as an export: the stack changes the file's pixels, and the catalog gains nothing.
    @MainActor func testFiltersExportAFileAndLeaveTheCatalogAlone() async throws {
        let (directory, model, _) = try await EditorFixtures.catalog()
        defer { try? FileManager.default.removeItem(at: directory) }
        let photo = try XCTUnwrap(model.assets.first), store = try XCTUnwrap(model.store), count = model.assets.count
        let folder = directory.appendingPathComponent("out"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var settings = ExportSettings(); settings.select(.png)
        let stack = CreativeFilterStack([CreativeFilter(.diffusion, amount: 100)])
        let made = try await CatalogModel.exportFile(photo, store: store, settings: settings, profile: .sRGB, to: folder), plain = try XCTUnwrap(made)
        let through = try await CatalogModel.exportFile(photo, store: store, settings: settings, profile: .sRGB, to: folder, filters: stack), filtered = try XCTUnwrap(through)
        XCTAssertNotEqual(plain, filtered)
        XCTAssertNotEqual(try Data(contentsOf: plain), try Data(contentsOf: filtered), "the stack reaches the exported pixels")
        await model.refresh()
        XCTAssertEqual(model.assets.count, count, "nothing is added to the catalog")
    }

    /// Filters hands the Export dialog the filtered photo, and cancelling that dialog leaves the tool open.
    @MainActor func testFiltersFeedTheExportDialog() async throws {
        let (directory, model, _) = try await EditorFixtures.catalog()
        defer { try? FileManager.default.removeItem(at: directory) }
        let kept = UserDefaults.standard.object(forKey: "filtersStack")
        defer { UserDefaults.standard.set(kept, forKey: "filtersStack") }
        UserDefaults.standard.set(try JSONEncoder().encode(CreativeFilterStack([CreativeFilter(.center)])), forKey: "filtersStack")
        model.requestFilters(Array(model.assets.prefix(1)))
        let filters = FiltersModel(request: try XCTUnwrap(model.filters))
        filters.start(catalog: model)
        for _ in 0..<300 where filters.after == nil { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(filters.canApply); XCTAssertEqual(filters.placed.map(\.kind), [.center])
        let preview = try await filters.makeExportPreview()
        XCTAssertNotNil(preview); XCTAssertNotNil(filters.outputSize)
        // The dialog shows the filtered photo, not the photo alone.
        func middle(_ image: CGImage?) throws -> [UInt8] {
            let image = try XCTUnwrap(image)
            var pixel = [UInt8](repeating: 0, count: 4)
            let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
            return pixel
        }
        let plain = try middle(filters.before), shown = try middle(preview)
        XCTAssertEqual(try middle(filters.after), shown, "the dialog previews what the tool shows")
        XCTAssertGreaterThan(Int(shown[1]), Int(plain[1]) + 8, "Darken / Lighten Center lifts the middle: \(plain) → \(shown)")
        // The chain: a filter switched on takes its usual place, trades places only within its kind, and Delete takes
        // the picked one out.
        filters.select(.fog); filters.select(.glow)
        XCTAssertEqual(filters.applied.map(\.kind), [.glow, .fog, .center]); XCTAssertEqual(filters.selection, .glow)
        XCTAssertFalse(filters.canMove(.glow, by: 1), "the lens filters come before the rest")
        filters.move(.fog, by: 1)
        XCTAssertEqual(filters.applied.map(\.kind), [.glow, .center, .fog])
        // The list's drag, within a run: the two picture filters trade places; the lens filter has its own run.
        XCTAssertEqual(filters.appliedGroups.lens.map(\.kind), [.glow]); XCTAssertEqual(filters.appliedGroups.picture.map(\.kind), [.center, .fog])
        filters.moveApplied(lens: false, from: IndexSet(integer: 1), to: 0)
        XCTAssertEqual(filters.applied.map(\.kind), [.glow, .fog, .center])
        filters.moveApplied(lens: false, from: IndexSet(integer: 0), to: 2)
        XCTAssertEqual(filters.applied.map(\.kind), [.glow, .center, .fog])
        // The border is a run of its own, round everything else.
        filters.setOn(.border, true)
        XCTAssertEqual(filters.appliedGroups.picture.map(\.kind), [.center, .fog]); XCTAssertEqual(filters.appliedGroups.border.map(\.kind), [.border])
        filters.moveApplied(lens: false, from: IndexSet(integer: 1), to: 0)
        XCTAssertEqual(filters.applied.map(\.kind), [.glow, .fog, .center, .border])
        filters.moveApplied(lens: false, from: IndexSet(integer: 0), to: 2)
        filters.remove(.border); filters.selection = .glow
        filters.setOn(.center, false)
        XCTAssertEqual(filters.applied.map(\.kind), [.glow, .fog])
        filters.removeSelection()
        XCTAssertEqual(filters.applied.map(\.kind), [.fog]); XCTAssertEqual(filters.selection, .fog)
        // The Export command, given while the tool is open, is the tool's to answer: the Library's dialog would show
        // the photo without the filters.
        model.requestExport(model.assets)
        XCTAssertNil(model.exportSession); XCTAssertEqual(model.filtersExport, 1)
        filters.showingExport = true; filters.dismissExport()
        XCTAssertFalse(filters.showingExport); XCTAssertNotNil(model.filters, "cancelling Export keeps the tool")
        filters.close(catalog: model)
        XCTAssertNil(model.filters)
    }

    /// What the Stack button does: the analyzed stacker goes to the catalog's background job, and its file comes back
    /// into the catalog with the Base photo's development.
    @MainActor func testStackingAddsTheResultToTheCatalogWithTheBaseEdits() async throws {
        let (directory, model, _) = try await EditorFixtures.catalog()
        defer { try? FileManager.default.removeItem(at: directory) }
        let photos = Array(model.assets.prefix(3)), store = try XCTUnwrap(model.store)
        var urls: [URL] = []
        for asset in photos { urls.append(try await model.resolveOriginal(asset)) }
        let stacker = try PhotoStacker(urls: urls)
        let analysis = try await Task.detached { try stacker.analyze() }.value
        // The Base photo is developed and has a dust spot removed; the others are untouched.
        let base = photos[analysis.reference], defaults = try RawRenderer(sourceURL: urls[analysis.reference]).info.defaults
        var edit = defaults; edit.contrast = 0.4; edit.saturation = -0.3
        var dust = RetouchStroke(mode: .heal, source: .init(x: 0.2, y: 0.2), target: .init(x: 0.3, y: 0.3), radius: 0.05, softness: 0.5, opacity: 1)
        dust.suggested = true
        edit.retouch = [dust]
        _ = try await store.saveEdits(edit, assetID: base.id, baseline: defaults)

        model.startStack(stacker, analysis: analysis, settings: PhotoStackSettings(), editsFrom: base, access: [])
        var stacked: CatalogAsset?, saved: Adjustments?
        for _ in 0..<300 where saved == nil {
            try await Task.sleep(for: .milliseconds(100))
            await model.refresh()
            // The fixtures are JPEGs: a stack of processed photos keeps their format (`ToolResult`), not DNG.
            stacked = model.assets.first { $0.filename.hasSuffix("-Stack.jpg") }
            if let stacked { saved = try await store.savedAdjustments(of: stacked) }
        }
        XCTAssertNotNil(stacked, "the stacked JPEG should be added to the catalog: \(ActivityCenter.shared.recent.map(\.title))")
        let carried = try XCTUnwrap(saved, "the stack should take the Base photo's edits")
        XCTAssertEqual(carried.contrast, 0.4, accuracy: 1e-6); XCTAssertEqual(carried.saturation, -0.3, accuracy: 1e-6)
        XCTAssertTrue(carried.retouch.isEmpty, "the photos' own dust spots are taken out before stacking, not carried onto the result")
    }

    /// The Stack window shows the stack as it will be saved: with the Base photo's edits, not as shot.
    @MainActor func testStackPreviewShowsTheBaseEdits() async throws {
        let (directory, model, _) = try await EditorFixtures.catalog()
        defer { try? FileManager.default.removeItem(at: directory) }
        let photos = Array(model.assets.prefix(3)), store = try XCTUnwrap(model.store)
        func green(_ image: CGImage) -> Double {
            var pixel = [UInt8](repeating: 0, count: 4)
            let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return Double(pixel[1]) - (Double(pixel[0]) + Double(pixel[2])) / 2
        }
        func preview() async throws -> CGImage {
            let stack = PhotoStackModel(request: PhotoStackRequest(assets: photos, mode: .median))
            stack.start(catalog: model)
            for _ in 0..<300 where stack.preview == nil { try await Task.sleep(for: .milliseconds(100)) }
            defer { stack.close(catalog: model) }
            return try XCTUnwrap(stack.preview?.image)
        }
        let asShot = green(try await preview())
        XCTAssertGreaterThan(asShot, 40, "the fixture is green")
        for photo in photos {
            let defaults = try RawRenderer(sourceURL: try await model.resolveOriginal(photo)).info.defaults
            var edit = defaults; edit.saturation = -100
            _ = try await store.saveEdits(edit, assetID: photo.id, baseline: defaults)
        }
        let developed = green(try await preview())
        XCTAssertLessThan(abs(developed), 6, "developed without colour, as the Base photo is")
    }
}
