import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
import CevicheCore
@testable import CevicheMac

/// What the editor tests start from: a synthetic photo, a catalog of them, a catalog of sample photos.
enum EditorFixtures {
    /// A temporary folder holding `example.jpg`, a small green JPEG. The caller removes the folder.
    static func photo() throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("example.jpg")
        let context = CGContext(data: nil, width: 160, height: 100, bitsPerComponent: 8, bytesPerRow: 640,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.3, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 160, height: 100))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        return (directory, url)
    }

    /// A catalog of six copies of that photo, open in a model with its own preferences.
    @MainActor static func catalog() async throws -> (URL, CatalogModel, EditorModel) {
        let (directory, original) = try photo()
        let suite = UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        let model = CatalogModel(preferences: preferences)
        await model.openCatalog(directory.appendingPathComponent("Catalog"))
        preferences.removePersistentDomain(forName: suite)
        let store = try XCTUnwrap(model.store)
        for index in 0..<6 {
            let url = directory.appendingPathComponent("photo-\(index).jpg")
            try FileManager.default.copyItem(at: original, to: url)
            let prepared = try CatalogImporter.prepare(url)
            _ = try await store.insert(prepared.0, thumbnail: prepared.1)
        }
        await model.refresh()
        return (directory, model, EditorModel())
    }

    /// A catalog in `directory` of clones of `sources`, so the catalog never touches the samples.
    @MainActor static func catalog(of sources: [URL], in directory: URL) async throws -> CatalogModel {
        let model = CatalogModel(preferences: UserDefaults(suiteName: UUID().uuidString)!)
        await model.openCatalog(directory.appendingPathComponent("Catalog"))
        let store = try XCTUnwrap(model.store)
        for source in sources {
            let url = directory.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: url)
            let prepared = try CatalogImporter.prepare(url)
            _ = try await store.insert(prepared.0, thumbnail: prepared.1)
        }
        await model.refresh()
        XCTAssertEqual(model.assets.count, sources.count)
        return model
    }

    /// The photo once its thumbnail shows its saved edits. A batch stores the edits and returns; the thumbnails follow
    /// in the catalog's own queue.
    static func withCurrentThumbnail(_ store: CatalogStore, id: String, seconds: Double = 20) async throws -> CatalogPhoto {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            let photo = try await store.photo(id)
            if photo.thumbnailRenderKey == photo.renderKey || Date() >= deadline { return photo }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    /// Waits for the selection to reach a photo, which takes a few turns of the main actor.
    @MainActor static func settle(_ model: CatalogModel, id: String?, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<100 {
            if model.selected?.id == id { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Selection did not settle", file: file, line: line)
    }
}

extension NSView {
    /// The view as it draws now, written as a PNG.
    @MainActor func writePNG(to url: URL) throws {
        layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(bitmapImageRepForCachingDisplay(in: bounds))
        cacheDisplay(in: bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
