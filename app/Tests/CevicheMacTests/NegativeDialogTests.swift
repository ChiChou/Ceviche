import XCTest
import AppKit
import SwiftUI
import CoreImage
@testable import CevicheCore
@testable import CevicheMac

final class NegativeDialogTests: XCTestCase {
    @MainActor func testOrientationHistoryPerScanAndDNGOutput() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        // All files and the catalog belong to this test.
        let catalog = CatalogModel(preferences: preferences)
        await catalog.openCatalog(directory.appendingPathComponent("Test.cevichecatalog"))
        defer { preferences.removePersistentDomain(forName: suite) }
        let store = try XCTUnwrap(catalog.store)
        var rgba = [Float](repeating: 1, count: 160 * 100 * 4)
        for y in 0..<100 { for x in 0..<160 {
            let p = 4 * (y * 160 + x)
            let density: Float = x > 15 && x < 145 && y > 10 && y < 90 ? 0.4 + Float(x) / 70 + Float(y) / 100 : 0
            rgba[p] = 0.8 / exp2(density); rgba[p + 1] = 0.4 / exp2(density); rgba[p + 2] = 0.2 / exp2(density)
        }}
        let metadata = PanoramaFrameMetadata(filename: "scan.dng", make: "", model: "", width: 160, height: 100,
                                             focalLength35mm: nil, captureTime: nil, temperature: 5500, tint: 0)
        let source = directory.appendingPathComponent("scan.dng")
        try PanoramaDNGWriter(metadata: metadata).write(PanoramaRaster(width: 160, height: 100, rgba: rgba), to: source)
        let second = directory.appendingPathComponent("scan-2.dng")
        try FileManager.default.copyItem(at: source, to: second)
        var assets: [CatalogAsset] = []
        for url in [source, second] {
            let prepared = try CatalogImporter.prepare(url)
            assets.append(try await store.insert(prepared.0, thumbnail: prepared.1))
        }
        let request = NegativeRequest(assets: assets)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1080, height: 660), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: NegativeDialog(catalog: catalog, request: request).preferredColorScheme(.dark))
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { catalog.negativeHistory?.stop(); window.close() }
        for _ in 0..<100 where catalog.negativeHistory?.stage != .ready { try await Task.sleep(for: .milliseconds(50)) }
        let model = try XCTUnwrap(catalog.negativeHistory)
        XCTAssertEqual(model.stage, .ready)
        // Each scan its own; the roll is tested below.
        model.roll = false
        defer { UserDefaults.standard.removeObject(forKey: "negativeRoll") }
        try await Task.sleep(for: .milliseconds(200)); host.layoutSubtreeIfNeeded()
        let initialFrame = model.frame
        model.rotate(clockwise: true)
        model.flip(horizontal: true)
        model.flip(horizontal: false)
        let oriented = model.orientation
        XCTAssertEqual(model.frame, initialFrame)
        model.undo(); model.redo()
        XCTAssertEqual(model.orientation, oriented)
        model.undo(); model.undo(); model.undo()
        XCTAssertEqual(model.orientation, NegativeOrientation())
        model.redo(); model.redo(); model.redo()
        model.index = 1
        for _ in 0..<100 where model.stage == .loading { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(model.stage, .ready); XCTAssertEqual(model.orientation, NegativeOrientation())
        XCTAssertTrue(model.undoStack.isEmpty)
        model.rotate(clockwise: false)
        model.index = 0
        for _ in 0..<100 where model.stage == .loading { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(model.stage, .ready); XCTAssertEqual(model.orientation, oriented)
        let choices = model.allChoices()
        XCTAssertEqual(choices[assets[0].id]?.orientation, oriented)
        XCTAssertEqual(choices[assets[1].id]?.orientation, NegativeOrientation().rotated(clockwise: false))
        model.undo(); XCTAssertNotEqual(model.orientation, oriented)
        model.redo()

        // The saved orientation reaches the DNG as pixels, rather than an EXIF tag for another editor to interpret.
        let baseline = directory.appendingPathComponent("baseline.dng")
        try NegativeConverter.convert(source, to: baseline, frame: model.frame, film: model.film)
        let context = NegativeConverter.context()
        for (i, orientation) in [oriented, oriented.flipped(horizontal: true)].enumerated() {
            let positive = directory.appendingPathComponent("positive-\(i).dng")
            try NegativeConverter.convert(source, to: positive, frame: model.frame, film: model.film, orientation: orientation)
            let expected = orientation.apply(to: try XCTUnwrap(CIRAWFilter(imageURL: baseline)?.outputImage))
            let actual = try XCTUnwrap(CIRAWFilter(imageURL: positive)?.outputImage)
            XCTAssertEqual(actual.extent.size, expected.extent.size)
            let expectedPixels = NegativeConverter.pixels(expected, context: context).rgba
            let actualPixels = NegativeConverter.pixels(actual, context: context).rgba
            XCTAssertEqual(actualPixels.count, expectedPixels.count)
            XCTAssertLessThan(zip(actualPixels, expectedPixels).map { abs($0 - $1) }.max() ?? 1, 0.002)
        }

        window.setContentSize(CGSize(width: 500, height: 480))
        try await Task.sleep(for: .milliseconds(200)); host.layoutSubtreeIfNeeded()
        if ProcessInfo.processInfo.environment["CEVICHE_UI_SNAPSHOTS"] == "1" {
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/ceviche-negative-controls.png"))
        }
    }

    /// Balanced as a roll, scans share film, orientation and a picked base and convert with the roll's density
    /// range; a picked base is undone like any other change.
    @MainActor func testRollSharesOneInversion() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        let catalog = CatalogModel(preferences: preferences)
        await catalog.openCatalog(directory.appendingPathComponent("Test.cevichecatalog"))
        defer { preferences.removePersistentDomain(forName: suite) }
        let store = try XCTUnwrap(catalog.store)
        var assets: [CatalogAsset] = []
        // The second negative is a stop denser: a brighter frame on the same roll.
        for (i, extra) in [Float(0), 1].enumerated() {
            var rgba = [Float](repeating: 1, count: 160 * 100 * 4)
            for y in 0..<100 { for x in 0..<160 {
                let p = 4 * (y * 160 + x)
                let density: Float = x > 15 && x < 145 && y > 10 && y < 90 ? 0.4 + extra + Float(x) / 70 + Float(y) / 100 : 0
                rgba[p] = 0.8 / exp2(density); rgba[p + 1] = 0.4 / exp2(density); rgba[p + 2] = 0.2 / exp2(density)
            }}
            let url = directory.appendingPathComponent("scan-\(i).dng")
            let metadata = PanoramaFrameMetadata(filename: url.lastPathComponent, make: "", model: "", width: 160, height: 100,
                                                 focalLength35mm: nil, captureTime: nil, temperature: 5500, tint: 0)
            try PanoramaDNGWriter(metadata: metadata).write(PanoramaRaster(width: 160, height: 100, rgba: rgba), to: url)
            let prepared = try CatalogImporter.prepare(url)
            assets.append(try await store.insert(prepared.0, thumbnail: prepared.1))
        }
        UserDefaults.standard.set(true, forKey: "negativeRoll")
        defer { UserDefaults.standard.removeObject(forKey: "negativeRoll") }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1080, height: 660), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: NegativeDialog(catalog: catalog, request: NegativeRequest(assets: assets)).preferredColorScheme(.dark))
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { catalog.negativeHistory?.stop(); window.close() }
        for _ in 0..<100 where catalog.negativeHistory?.stage != .ready { try await Task.sleep(for: .milliseconds(50)) }
        let model = try XCTUnwrap(catalog.negativeHistory)
        func measured() async throws {
            for _ in 0..<200 where !model.canConvert { try await Task.sleep(for: .milliseconds(50)) }
            XCTAssertTrue(model.canConvert)
        }
        XCTAssertTrue(model.isRoll)
        try await measured()
        let first = try XCTUnwrap(model.rollInversions)
        XCTAssertEqual(first.count, 2)
        // One film: one density range and balance, each scan on its own base.
        XCTAssertEqual(first[assets[0].id]?.density, first[assets[1].id]?.density)
        XCTAssertEqual(first[assets[0].id]?.gamma, first[assets[1].id]?.gamma)

        model.rotate(clockwise: true)
        let film = model.film, rotated = model.orientation
        model.index = 1
        for _ in 0..<100 where model.stage != .ready { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(model.orientation, rotated); XCTAssertEqual(model.film, film)
        try await measured()
        XCTAssertEqual(model.rollInversions, first)

        // The film beside the picture, picked as the base.
        model.pickBase(at: CGPoint(x: 0.03, y: 0.5))
        let picked = try XCTUnwrap(model.base)
        try await measured()
        // The test scans carry no exposure, so the picked base is used at 1 on both.
        XCTAssertEqual(model.rollInversions?[assets[0].id]?.base, picked)
        XCTAssertEqual(model.rollInversions?[assets[1].id]?.base, picked)
        let choices = model.allChoices()
        XCTAssertEqual(choices.count, 2)
        XCTAssertNotNil(choices[assets[0].id]?.frame); XCTAssertNotNil(choices[assets[1].id]?.frame)
        XCTAssertEqual(choices[assets[0].id]?.inversion, model.rollInversions?[assets[0].id])
        XCTAssertEqual(choices[assets[1].id]?.inversion, model.rollInversions?[assets[1].id])
        XCTAssertEqual(choices[assets[0].id]?.orientation, rotated)
        model.undo()
        XCTAssertNil(model.base)
        try await measured()
        XCTAssertEqual(model.rollInversions, first)
    }
}
