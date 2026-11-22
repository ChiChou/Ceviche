import XCTest
import CevicheTestSupport
import AppKit
import SwiftUI
import CevicheCore
@testable import CevicheMac

final class EditorSnapshotTests: XCTestCase {
    @MainActor func testCapturePanelsWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["CEVICHE_UI_SNAPSHOTS"] == "1" else { throw XCTSkip("Optional visual snapshots") }
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        let model = EditorModel(preferences: preferences)
        await model.open(try TestSamples.require(TestSamples.landscape))
        XCTAssertNil(model.error)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1420, height: 920), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let catalog = CatalogModel(preferences: preferences); catalog.viewMode = .detail
        let host = NSHostingView(rootView: CatalogWorkspace(catalog: catalog, editor: model).preferredColorScheme(.dark))
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close(); model.closeDocument() }
        for tab in [ToolTab.crop, .remove, .light, .detail, .masks, .info] {
            model.toolTab = tab
            if tab == .masks {
                model.addMask(.linear); model.beginMask(at: MaskPoint(x: 0.5, y: 0.2)); model.dragMask(to: MaskPoint(x: 0.5, y: 0.65)); model.endMask()
                model.updateMask { $0.name = "Foreground light"; $0.adjustments.exposure = 0.5 }
                model.addMask(.radial); model.beginMask(at: MaskPoint(x: 0.5, y: 0.5)); model.dragMask(to: MaskPoint(x: 0.7, y: 0.7)); model.endMask()
                model.updateMask { $0.name = "Subject detail"; $0.adjustments.clarity = 20 }
                model.maskTool = nil
            }
            try await Task.sleep(for: .seconds(1))
            host.layoutSubtreeIfNeeded()
            try capture(host, "ceviche-\(tab.rawValue.lowercased())")
            if tab == .masks {
                model.addComponent(.linear, operation: .intersect)
                model.updateSelection { $0.start = .init(x: 0.3, y: 0.2); $0.end = .init(x: 0.8, y: 0.8) }
                model.maskTool = nil
                try await Task.sleep(for: .seconds(1)); host.layoutSubtreeIfNeeded(); try capture(host, "ceviche-mask-components")
                model.editSelectedMask(in: .light)
                model.editTarget { $0.selectiveColors[1].saturation = -25; $0.splitToning.shadowSaturation = 15 }
                try await Task.sleep(for: .seconds(1)); host.layoutSubtreeIfNeeded(); try capture(host, "ceviche-local-color")
            }
        }
        if let root = ProcessInfo.processInfo.environment["CEVICHE_LOOKS_ROOT"] {
            // Camera profiles and LUTs still apply from files; the Light & Color panel shows the applied look.
            let library = LookLibrary(root: URL(fileURLWithPath: root))
            model.toolTab = .light
            for kind in [LookKind.profiles, .luts] {
                guard let first = library.files(kind).first else { continue }
                await model.applyLook(first, kind: kind)
                try await Task.sleep(for: .seconds(1.5)); host.layoutSubtreeIfNeeded()
                try capture(host, "ceviche-looks-\(kind.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))")
            }
        }
        model.prepareExport()
        for format in [CevicheCore.ExportFormat.tiff, .jpeg, .png] {
            model.exportSettings.select(format)
            if format == .png {
                model.addMask(.radial); model.beginMask(at: MaskPoint(x: 0.5, y: 0.5)); model.dragMask(to: MaskPoint(x: 0.75, y: 0.75)); model.endMask()
                model.updateMask { $0.cutsOutBackground = true; $0.feather = 0.04 }
                model.edit { $0.quarterTurns = 1 }
            }
            let export = NSHostingView(rootView: ExportDialog(model: model).preferredColorScheme(.dark))
            window.contentView = export
            window.setContentSize(export.fittingSize)
            try await Task.sleep(for: .seconds(1))
            export.layoutSubtreeIfNeeded()
            try capture(export, format == .tiff ? "ceviche-export" : "ceviche-export-\(format.rawValue.lowercased())")
        }
    }
    @MainActor private func capture(_ view: NSView, _ name: String) throws {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "/private/tmp/\(name).png"))
    }
}
