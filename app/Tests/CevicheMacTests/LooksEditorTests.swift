import XCTest
import AppKit
import SwiftUI
import CevicheCore
@testable import CevicheMac

final class LooksEditorTests: XCTestCase {
    @MainActor private func model() -> EditorModel {
        let model = EditorModel(preferences: UserDefaults(suiteName: "LooksEditorTests.\(UUID())")!)
        model.info = ImageInfo(filename: "fixture", width: 600, height: 400, isRAW: false, defaults: Adjustments())
        return model
    }

    @MainActor func testPresetsProduceADevelopmentInDevelop() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LooksEditorTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var source = Adjustments(); source.exposure = 1.2
        let url = folder.appendingPathComponent("Bright.xmp")
        try XMPCodec.encode(adjustments: source).write(to: url)
        let model = model()
        let (settings, _) = try await model.lookAdjustments(url, kind: .presets)
        XCTAssertEqual(settings.exposure, 1.2)
        XCTAssertEqual(model.adjustments.exposure, 0, "Working out a look leaves the photo as it was")
    }

    @MainActor func testApplyingALookIsANamedHistoryStepThatUndoes() async throws {
        let (directory, url) = try EditorFixtures.photo()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let catalog = CatalogModel(preferences: preferences), editor = EditorModel()
        await catalog.openCatalog(directory.appendingPathComponent("Catalog"))
        let store = try XCTUnwrap(catalog.store), prepared = try CatalogImporter.prepare(url)
        let photo = try await store.insert(prepared.0, thumbnail: prepared.1)
        await catalog.refresh()
        _ = await catalog.openPhoto(photo, editor: editor)
        var source = Adjustments(); source.exposure = 1.2
        let preset = directory.appendingPathComponent("Bright.xmp")
        try XMPCodec.encode(adjustments: source).write(to: preset)

        await editor.applyLook(preset, kind: .presets, reportInline: true)
        XCTAssertNil(editor.error)
        XCTAssertEqual(editor.adjustments.exposure, 1.2)
        XCTAssertFalse(editor.dirty, "Saved as its own step, not left for autosave")
        let steps = try await store.history(assetID: photo.id).filter { $0.kind == .edit }
        XCTAssertEqual(steps.map(\.summary), ["Applied preset “Bright”", "Original development"])
        XCTAssertTrue(steps[0].milestone, "Later slider changes are not folded into the look's step")

        editor.undo()
        XCTAssertEqual(editor.adjustments.exposure, 0)
    }

    @MainActor func testAPresetsAmountSetsItsStrengthUntilAnotherEdit() async throws {
        let (directory, url) = try EditorFixtures.photo()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let catalog = CatalogModel(preferences: preferences), editor = EditorModel()
        await catalog.openCatalog(directory.appendingPathComponent("Catalog"))
        let store = try XCTUnwrap(catalog.store), prepared = try CatalogImporter.prepare(url)
        let photo = try await store.insert(prepared.0, thumbnail: prepared.1)
        await catalog.refresh()
        _ = await catalog.openPhoto(photo, editor: editor)
        editor.edit { $0.contrast = 10 }
        var source = Adjustments(); source.exposure = 1.2; source.contrast = 30
        let preset = directory.appendingPathComponent("Bright.xmp")
        try XMPCodec.encode(adjustments: source).write(to: preset)

        await editor.applyLook(preset, kind: .presets, reportInline: true)
        let applied = try XCTUnwrap(editor.presetOnPhoto)
        XCTAssertEqual(applied.name, "Bright"); XCTAssertEqual(applied.amount, 1); XCTAssertEqual(editor.adjustments.exposure, 1.2)
        let look = LookFile(url: preset, kind: .presets)
        XCTAssertTrue(editor.isOnPhoto(look), "The Looks tab marks the preset on the photo")
        XCTAssertFalse(editor.isOnPhoto(LookFile(url: directory.appendingPathComponent("Other.xmp"), kind: .presets)))
        // A drag on Amount is one undo step.
        let steps = editor.undoStack.count
        editor.beginGesture(); editor.setPresetAmount(0.8); editor.setPresetAmount(0.5); editor.endGesture()
        XCTAssertEqual(editor.adjustments.exposure, 0.6, accuracy: 1e-9); XCTAssertEqual(editor.adjustments.contrast, 20, accuracy: 1e-9)
        XCTAssertEqual(editor.presetOnPhoto?.amount, 0.5); XCTAssertEqual(editor.undoStack.count, steps + 1)
        editor.undo()
        XCTAssertEqual(editor.adjustments.exposure, 1.2); XCTAssertEqual(editor.presetOnPhoto?.amount, 1, "Back at full strength")
        editor.setPresetAmount(0.5)
        // Off shows the photo without the preset and keeps the strength for turning it on again.
        editor.setPresetEnabled(false)
        XCTAssertEqual(editor.adjustments.exposure, 0); XCTAssertEqual(editor.adjustments.contrast, 10)
        XCTAssertEqual(editor.presetOnPhoto?.enabled, false)
        editor.setPresetEnabled(true); XCTAssertEqual(editor.adjustments.exposure, 0.6, accuracy: 1e-9)
        // Any other edit settles the strength, and the card goes.
        editor.edit { $0.vibrance = 5 }
        XCTAssertNil(editor.presetOnPhoto); XCTAssertTrue(editor.isOnPhoto(look), "Still the photo's preset under the edit")
        editor.undo(); XCTAssertNotNil(editor.presetOnPhoto)
        // Removing goes back to the photo before the preset, as one undo step.
        editor.removePreset()
        XCTAssertEqual(editor.adjustments.exposure, 0); XCTAssertEqual(editor.adjustments.contrast, 10); XCTAssertNil(editor.presetOnPhoto)
        XCTAssertFalse(editor.isOnPhoto(look))
        editor.undo(); XCTAssertEqual(editor.adjustments.exposure, 0.6, accuracy: 1e-9)
        // Applied again and undone, the photo is back where it was before the preset: nothing is marked.
        await editor.applyLook(preset, kind: .presets, reportInline: true); XCTAssertTrue(editor.isOnPhoto(look))
        editor.undo(); XCTAssertFalse(editor.isOnPhoto(look))
    }

    @MainActor func testPreviewShowsALookUntilAnEditOrAnotherPanel() {
        let model = model()
        model.toolTab = .looks
        var look = model.adjustments; look.exposure = 2
        model.showLookPreview(look)
        XCTAssertEqual(model.displayAdjustments.exposure, 2)
        XCTAssertEqual(model.adjustments.exposure, 0, "A preview is not an edit")
        model.edit { $0.contrast = 10 }
        XCTAssertNil(model.lookPreview, "An edit replaces the preview")
        XCTAssertEqual(model.displayAdjustments.contrast, 10)

        model.showLookPreview(look)
        model.toolTab = .light
        XCTAssertNil(model.lookPreview, "Leaving Looks ends the preview")

        model.toolTab = .looks
        model.beginGesture()
        model.showLookPreview(look)
        XCTAssertNil(model.lookPreview, "No preview while a slider is dragged")
        model.endGesture()
    }

    /// Renders the Looks tab over a real photo with a fixture library, when `CEVICHE_LOOKS_SNAPSHOTS` names an output
    /// folder and `CEVICHE_SNAPSHOT_PHOTO` a photo to open.
    @MainActor func testCaptureLooksPanelWhenRequested() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let output = env["CEVICHE_LOOKS_SNAPSHOTS"], let photo = env["CEVICHE_SNAPSHOT_PHOTO"] else { throw XCTSkip("Optional visual snapshots") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LooksSnapshot-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func preset(_ path: String, _ name: String, _ fields: String) throws {
            let url = root.appendingPathComponent("Presets/" + path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try """
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" crs:PresetType="Normal" crs:Version="15.0" crs:ProcessVersion="11.0" \(fields)><crs:Name><rdf:Alt><rdf:li xml:lang="x-default">\(name)</rdf:li></rdf:Alt></crs:Name></rdf:Description></rdf:RDF></x:xmpmeta>
            """.write(to: url, atomically: true, encoding: .utf8)
        }
        try preset("Film/Warm Fade.xmp", "Warm Fade", #"crs:Exposure2012="+0.30" crs:Contrast2012="-25" crs:Shadows2012="+30" crs:Blacks2012="+20" crs:Temperature="+12" crs:Saturation="-10""#)
        try preset("Film/Cool Matte.xmp", "Cool Matte", #"crs:Contrast2012="-30" crs:Highlights2012="-40" crs:Blacks2012="+35" crs:Saturation="-20" crs:Vibrance="+10""#)
        try preset("Black & White/High Contrast.xmp", "High Contrast", #"crs:ConvertToGrayscale="True" crs:Contrast2012="+45" crs:Clarity2012="+25" crs:LensProfileEnable="1" crs:AutoLateralCA="1""#)
        let luts = root.appendingPathComponent("LUTs", isDirectory: true)
        try FileManager.default.createDirectory(at: luts, withIntermediateDirectories: true)
        try "TITLE \"Teal Orange\"\nLUT_3D_SIZE 2\n0 0.05 0.1\n1 0.3 0.1\n0 0.9 0.8\n1 1 0.6\n0 0.1 0.4\n0.9 0.4 0.5\n0.1 0.9 1\n1 1 1\n".write(to: luts.appendingPathComponent("Teal Orange.cube"), atomically: true, encoding: .utf8)

        let storage = ResourceStorage.shared
        ResourceStorage.shared = .folder(FolderResources(root: root))
        defer { ResourceStorage.shared = storage }
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        let model = EditorModel(preferences: preferences)
        await model.open(URL(fileURLWithPath: photo))
        XCTAssertNil(model.error)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1420, height: 920), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let catalog = CatalogModel(preferences: preferences); catalog.viewMode = .detail
        let host = NSHostingView(rootView: CatalogWorkspace(catalog: catalog, editor: model).preferredColorScheme(.dark))
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close(); model.closeDocument() }
        func capture(_ name: String) async throws {
            try await Task.sleep(for: .seconds(1.5)); host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
        }
        // A folder opened earlier opens again, as at the next launch.
        UserDefaults.standard.set("Black & White", forKey: "looksOpenFolders.Presets")
        defer { UserDefaults.standard.removeObject(forKey: "looksOpenFolders.Presets") }
        model.toolTab = .looks
        try await capture("looks-library")
        let warm = LookFile(url: root.appendingPathComponent("Presets/Film/Warm Fade.xmp"), kind: .presets)
        model.previewLook(warm)
        try await capture("looks-preview")
        XCTAssertNotNil(model.lookPreview); XCTAssertEqual(model.adjustments.exposure, 0, "Previewing leaves the development alone")
        model.endLookPreview()
        await model.applyLook(luts.appendingPathComponent("Teal Orange.cube"), kind: .luts, reportInline: true)
        await model.applyLook(root.appendingPathComponent("Presets/Black & White/High Contrast.xmp"), kind: .presets, reportInline: true)
        XCTAssertNotNil(model.adjustments.lut); XCTAssertNil(model.lookPreview)
        try await capture("looks-applied")
        model.setPresetAmount(0.5)
        try await capture("looks-amount")
        model.xmpReport = (model.lookNotes?.report ?? "") + "\n\nCamera profile ‘Fuji 400H SO’ not found; default camera color is used."
        try await capture("looks-report")
        model.xmpReport = Array(repeating: "Camera profile ‘Fuji 400H SO’ not found; default camera color is used.", count: 12).joined(separator: "\n\n")
        try await capture("looks-report-long")
    }
}
