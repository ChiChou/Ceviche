import XCTest
import CevicheTestSupport
import AppKit
import CoreImage
import SwiftUI
import CevicheCore
@testable import CevicheMac

final class HDREditorTests: XCTestCase {
    @MainActor func testHDRCanvasAndUndo() async throws {
        _ = NSApplication.shared
        let model = EditorModel()
        let ctx = CIContext()
        let image = CIImage(color: CIColor(red: 2, green: 0.4, blue: 0.1, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)!).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 32))
        let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        let cg: CGImage
        if #available(macOS 26, *) {
            cg = try XCTUnwrap(ctx.createCGImage(image, from: image.extent, format: .RGBAh, colorSpace: space, deferred: false, calculateHDRStats: true))
        } else {
            cg = try XCTUnwrap(CGImageCreateCopyWithContentHeadroom(2, try XCTUnwrap(ctx.createCGImage(image, from: image.extent, format: .RGBAh, colorSpace: space))))
        }
        model.preview = cg; model.originalPreview = cg
        model.edit { $0.hdr.enabled = true }
        XCTAssertTrue(model.adjustments.hdr.enabled)
        model.undo(); XCTAssertFalse(model.adjustments.hdr.enabled)
        model.redo(); XCTAssertTrue(model.adjustments.hdr.enabled)
        let edits = model.undoStack.count
        model.sdrPreview = true
        XCTAssertEqual(model.undoStack.count, edits)
        let view = ImageCanvas(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        view.model = model; view.image = cg; view.updateGeometry()
        let photo = try XCTUnwrap(view.subviews.first)
        photo.displayIfNeeded()
        if #available(macOS 26, *) { XCTAssertEqual(photo.layer?.preferredDynamicRange, .high) } else { XCTAssertEqual(photo.layer?.wantsExtendedDynamicRangeContent, true) }
        XCTAssertEqual(photo.frame.size, CGSize(width: 640, height: 320))
        XCTAssertNil(photo.hitTest(.zero))
        XCTAssertFalse(view.subviews.last!.isOpaque)
        model.comparing = true; model.setComparisonSplit(0.3); view.updateGeometry()
        // Subviews: photograph, source-resolution detail tile, original clip, tools overlay.
        XCTAssertEqual(view.subviews[2].frame.width, 192, accuracy: 0.01)
        XCTAssertFalse(view.subviews[2].isHidden)
        model.closeDocument()
    }
    @MainActor func testHDRScreenshotsWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["CEVICHE_UI_SNAPSHOTS"] == "1" else { throw XCTSkip("Optional HDR snapshots") }
        let model = EditorModel()
        await model.open(try TestSamples.require(TestSamples.hdrSidecar))
        XCTAssertNil(model.error); XCTAssertTrue(model.adjustments.hdr.enabled)
        model.xmpReport = nil
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1420, height: 920), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let catalog = CatalogModel(); catalog.viewMode = .detail
        let host = NSHostingView(rootView: CatalogWorkspace(catalog: catalog, editor: model).preferredColorScheme(.dark))
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close(); model.closeDocument() }
        for sdr in [false, true] {
            model.sdrPreview = sdr
            for _ in 0..<150 { try await Task.sleep(for: .milliseconds(100)); if !model.isRendering { break } }
            XCTAssertNil(model.error)
            try await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/ceviche-hdr-\(sdr ? "sdr" : "edr").png"))
        }
    }
}
