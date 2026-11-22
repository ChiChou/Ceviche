import XCTest
import CevicheTestSupport
import AppKit
import SwiftUI
import CevicheCore
@testable import CevicheMac

final class ExportDialogTests: XCTestCase {
    @MainActor func testSinglePhotoExportSheetHasAFixedSize() async throws {
        _ = NSApplication.shared
        let model = EditorModel()
        model.info = ImageInfo(filename: "test.arw", width: 7952, height: 5304, isRAW: true, defaults: Adjustments())
        let snapshots = ProcessInfo.processInfo.environment["CEVICHE_UI_SNAPSHOTS"] == "1"
        if snapshots {
            await model.open(try TestSamples.require(TestSamples.landscape))
            XCTAssertNil(model.error)
        }
        let window = Self.hostWindow(ExportTestHost(model: model))
        defer { model.showExport = false; window.close(); model.closeDocument() }
        model.prepareExport()
        let (sheet, content) = try await Self.attachedSheet(of: window)
        try Self.assertFixed(sheet, content)
        if snapshots { try capture(content, "ceviche-export-default") }
        // Option changes and size warnings stay inside the same sheet.
        model.exportSettings.select(.jpeg)
        let source = try XCTUnwrap(model.outputSize)
        model.exportSettings.sizing.setWidth(9000, source: source)
        model.exportSettings.sizing.setHeight(9000, source: source)
        try await Task.sleep(for: .milliseconds(200))
        try Self.assertFixed(sheet, content)
        if snapshots { try capture(content, "ceviche-export-size-warnings") }
    }

    @MainActor func testBatchExportSheetHasAFixedSize() async throws {
        _ = NSApplication.shared
        let (directory, catalog, _) = try await EditorFixtures.catalog()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertGreaterThan(catalog.assets.count, 1)
        let window = Self.hostWindow(CatalogExportTestHost(catalog: catalog))
        defer { catalog.exportSession?.dismissExport(); window.close() }
        catalog.requestExport(catalog.assets)
        let session = try XCTUnwrap(catalog.exportSession)
        XCTAssertTrue(session.exportsManyPhotos)
        let (sheet, content) = try await Self.attachedSheet(of: window)
        for _ in 0..<40 where session.busy { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(200))
        try Self.assertFixed(sheet, content)
        XCTAssertNil(session.exportSubtitle)
        if ProcessInfo.processInfo.environment["CEVICHE_UI_SNAPSHOTS"] == "1" { try capture(content, "ceviche-export-batch") }
        session.exportSettings.sizing.longEdge = 2048
        try await Task.sleep(for: .milliseconds(200))
        try Self.assertFixed(sheet, content)
    }

    @MainActor private static func hostWindow(_ root: some View) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1380, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root.preferredColorScheme(.dark))
        window.makeKeyAndOrderFront(nil)
        return window
    }
    @MainActor private static func attachedSheet(of window: NSWindow) async throws -> (NSWindow, NSView) {
        for _ in 0..<40 where window.attachedSheet == nil { try await Task.sleep(for: .milliseconds(50)) }
        let sheet = try XCTUnwrap(window.attachedSheet)
        try await Task.sleep(for: .milliseconds(300))
        return (sheet, try XCTUnwrap(sheet.contentView))
    }
    @MainActor private static func assertFixed(_ sheet: NSWindow, _ content: NSView, file: StaticString = #filePath, line: UInt = #line) throws {
        content.layoutSubtreeIfNeeded()
        XCTAssertFalse(sheet.styleMask.contains(.resizable), "The export sheet is not resizable", file: file, line: line)
        XCTAssertEqual(content.bounds.width, ExportDialog<EditorModel>.size.width, accuracy: 1, file: file, line: line)
        XCTAssertEqual(content.bounds.height, ExportDialog<EditorModel>.size.height, accuracy: 1, file: file, line: line)
    }
    @MainActor func testHDRControlsAndEstimatePreserveDocument() async throws {
        let (directory, source) = try EditorFixtures.photo()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = EditorModel(); await model.open(source)
        model.edit { $0.hdr.enabled = true }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1380, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ExportTestHost(model: model).preferredColorScheme(.dark))
        window.makeKeyAndOrderFront(nil)
        defer { model.showExport = false; window.close(); model.closeDocument() }
        // An HDR photo opens the dialog in HDR whatever the last export was.
        model.prepareExport(format: .heif)
        XCTAssertTrue(model.exportSettings.hdr); XCTAssertEqual(model.exportSettings.hdrEncoding, .pq); XCTAssertEqual(model.exportSettings.depth, 10)
        for _ in 0..<40 where window.attachedSheet == nil { try await Task.sleep(for: .milliseconds(50)) }
        let content = try XCTUnwrap(window.attachedSheet?.contentView)
        try await Task.sleep(for: .milliseconds(300))
        func elements(_ value: Any, depth: Int = 0) -> [any NSAccessibilityProtocol] {
            guard depth < 25 else { return [] }
            let element = value as? any NSAccessibilityProtocol
            let children = (element?.accessibilityChildren() ?? []) + ((value as? NSView)?.subviews ?? [])
            return (element.map { [$0] } ?? []) + children.flatMap { elements($0, depth: depth + 1) }
        }
        func find(_ label: String) -> (any NSAccessibilityProtocol)? {
            elements(content).first { $0.accessibilityLabel() == label }
        }
        XCTAssertNotNil(find("HDR")); XCTAssertNotNil(find("SDR"))
        XCTAssertNil(find("Lock aspect ratio")); XCTAssertNil(find("Unlock aspect ratio"))
        let before = model.adjustments, undoCount = model.undoStack.count
        XCTAssertTrue(model.showExport)
        if ProcessInfo.processInfo.environment["CEVICHE_UI_SNAPSHOTS"] == "1" { try capture(content, "ceviche-export-hdr") }
        // JPEG keeps HDR as a gain map, so the choice stays; the encoding follows the container.
        model.exportSettings.select(.jpeg)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNotNil(find("HDR")); XCTAssertTrue(model.exportSettings.hdr)
        XCTAssertEqual(model.exportSettings.hdrEncoding, .gainMap); XCTAssertEqual(model.exportSettings.depth, 8)
        XCTAssertEqual(model.exportSettings.profileLabel, "sRGB + HDR gain map")
        if ProcessInfo.processInfo.environment["CEVICHE_UI_SNAPSHOTS"] == "1" { try capture(content, "ceviche-export-jpeg-estimate") }
        model.exportSettings.select(.webp); model.exportSettings.lossless = true
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(find("HDR")); XCTAssertNotNil(find("Lossless"))
        XCTAssertTrue(elements(content).contains { $0.accessibilityRole() == .textField }, "Rendered formats offer size fields")
        XCTAssertEqual(model.exportSettings.depth, 8)
        model.exportSettings.lossless = false
        try await Task.sleep(for: .milliseconds(200))
        if ProcessInfo.processInfo.environment["CEVICHE_EXPORT_SNAPSHOTS"] == "1" {
            try capture(content, "ceviche-export-webp")
        }
        model.exportSettings.select(.jxl)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNotNil(find("16-bit")); XCTAssertEqual(model.exportSettings.depth, 16)
        if ProcessInfo.processInfo.environment["CEVICHE_EXPORT_SNAPSHOTS"] == "1" { try capture(content, "ceviche-export-jxl") }
        model.exportSettings.select(.png)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNotNil(find("16-bit"))
        XCTAssertTrue(elements(content).contains { $0.accessibilityRole() == .textField })
        XCTAssertEqual(model.adjustments, before); XCTAssertEqual(model.undoStack.count, undoCount)
    }

    @MainActor func testPreparingExportUsesCurrentCroppedAspectRatioWithoutEditingThePhoto() throws {
        let model = EditorModel()
        model.info = ImageInfo(filename: "test.arw", width: 6000, height: 4000, isRAW: true, defaults: Adjustments())
        model.exportSettings.sizing.setWidth(1200, source: try XCTUnwrap(model.outputSize))
        model.adjustments.quarterTurns = 1
        let before = model.adjustments
        model.prepareExport()
        XCTAssertEqual(try model.exportSettings.sizing.dimensions(for: XCTUnwrap(model.outputSize)), ExportDimensions(width: 1200, height: 1800))
        XCTAssertEqual(model.adjustments, before)
        XCTAssertTrue(model.undoStack.isEmpty)
    }

    @MainActor func testExportDialogRemembersTheLastSettingsAndDefaultsToHDRForHDRPhotos() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ExportDialogTests." + UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: defaults.volatileDomainNames.first ?? "") }
        let first = EditorModel(preferences: defaults)
        first.info = ImageInfo(filename: "a.arw", width: 6000, height: 4000, isRAW: true, defaults: Adjustments())
        first.prepareExport(format: .png)
        XCTAssertFalse(first.exportSettings.hdr)
        first.exportSettings.depth = 8; first.exportSettings.quality = 0.7; first.exportSettings.includeMetadata = false
        first.exportSettings.sizing.select(.medium, source: try XCTUnwrap(first.outputSize))
        first.exportSettings.rememberAsLastUsed(defaults)
        // The next photo's dialog starts from those settings, sized for the new photo.
        let second = EditorModel(preferences: defaults)
        second.info = ImageInfo(filename: "b.arw", width: 3000, height: 3000, isRAW: true, defaults: Adjustments())
        second.prepareExport()
        XCTAssertEqual(second.exportSettings.format, .png); XCTAssertEqual(second.exportSettings.depth, 8)
        XCTAssertEqual(second.exportSettings.quality, 0.7); XCTAssertFalse(second.exportSettings.includeMetadata)
        XCTAssertEqual(second.exportSettings.sizing.preset, .medium)
        XCTAssertEqual(try second.exportSettings.sizing.dimensions(for: XCTUnwrap(second.outputSize)), ExportDimensions(width: 2560, height: 2560))
        // An HDR photo turns HDR on in the remembered format: PNG stores it as 16-bit PQ.
        second.edit { $0.hdr.enabled = true }
        second.prepareExport()
        XCTAssertTrue(second.exportSettings.hdr); XCTAssertEqual(second.exportSettings.hdrEncoding, .pq); XCTAssertEqual(second.exportSettings.depth, 16)
        // Each container offers the encodings ImageIO can write into it.
        XCTAssertEqual(ExportFormat.jpeg.hdrEncodings, [.gainMap]); XCTAssertEqual(ExportFormat.tiff.hdrEncodings.first, .linear)
        XCTAssertTrue(ExportFormat.heif.hdrEncodings.contains(.hlg)); XCTAssertFalse(ExportFormat.png.hdrEncodings.contains(.gainMap))
        second.prepareExport(format: .jpeg)
        XCTAssertTrue(second.exportSettings.hdr); XCTAssertEqual(second.exportSettings.hdrEncoding, .gainMap); XCTAssertEqual(second.exportSettings.depth, 8)
        XCTAssertEqual(second.exportSettings.profileLabel, "sRGB + HDR gain map")
    }

    @MainActor private func capture(_ view: NSView, _ name: String) throws {
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "/private/tmp/\(name).png"))
    }
}

private struct CatalogExportTestHost: View {
    @ObservedObject var catalog: CatalogModel
    var body: some View {
        Color.clear.frame(minWidth: 1380, minHeight: 900)
            .sheet(item: $catalog.exportSession) { ExportDialog(model: $0) }
    }
}

private struct ExportTestHost: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        Color.clear.frame(minWidth: 1380, minHeight: 900)
            .sheet(isPresented: $model.showExport) { ExportDialog(model: model) }
    }
}
