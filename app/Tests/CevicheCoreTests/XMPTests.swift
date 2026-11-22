import XCTest
import CevicheTestSupport
@testable import CevicheCore

final class XMPTests: XCTestCase {
    func packet(_ attributes: String = "", _ children: String = "") throws -> XMPPacket {
        try XMPPacket(data: Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="\(XMPPacket.rdf)">
        <rdf:Description xmlns:crs="\(XMPPacket.crs)" xmlns:xmp="\(XMPPacket.xmp)" xmlns:dc="\(XMPPacket.dc)" xmlns:exif="\(XMPPacket.exif)" \(attributes)>\(children)</rdf:Description>
        </rdf:RDF></x:xmpmeta>
        """.utf8))
    }
    func testSparseImportNamespacesMetadataAndNestedLook() throws {
        let p = try packet("crs:Exposure2012=\"1.1\" crs:Highlights2012=\"-75\" xmp:Rating=\"5\" exif:GPSLatitude=\"46,30N\" exif:GPSLongitude=\"11,18E\"", """
        <crs:ToneCurvePV2012><rdf:Seq><rdf:li>0, 0</rdf:li><rdf:li>134, 103</rdf:li><rdf:li>255, 255</rdf:li></rdf:Seq></crs:ToneCurvePV2012>
        <crs:Look><rdf:Description crs:Exposure2012="4"><crs:ToneCurvePV2012><rdf:Seq><rdf:li>0, 255</rdf:li><rdf:li>255, 0</rdf:li></rdf:Seq></crs:ToneCurvePV2012></rdf:Description></crs:Look>
        <dc:title><rdf:Alt><rdf:li xml:lang="fr">Autre</rdf:li><rdf:li xml:lang="x-default">A &amp; B</rdf:li></rdf:Alt></dc:title>
        <dc:subject><rdf:Bag><rdf:li>mountain</rdf:li><rdf:li>snow</rdf:li></rdf:Bag></dc:subject>
        """)
        var base = Adjustments(); base.shadows = 34
        let imported = try XMPCodec.apply(p, to: base)
        XCTAssertEqual(imported.adjustments.exposure, 1.1); XCTAssertEqual(imported.adjustments.shadows, 34)
        XCTAssertEqual(imported.adjustments.curve.points.count, 3)
        XCTAssertEqual(imported.adjustments.curve.points[1].y, 103.0 / 255)
        XCTAssertEqual(imported.metadata.title, "A & B"); XCTAssertEqual(imported.metadata.keywords, "mountain, snow")
        XCTAssertEqual(imported.metadata.rating, 5); XCTAssertEqual(imported.metadata.latitude, 46.5)
        XCTAssertEqual(imported.metadata.longitude!, 11.3, accuracy: 0.000001)
        XCTAssertTrue(imported.warnings.joined().contains("Look"))
        let alternate = String(data: p.data, encoding: .utf8)!.replacingOccurrences(of: "crs:", with: "camera:").replacingOccurrences(of: "xmlns:crs", with: "xmlns:camera")
        XCTAssertEqual(try XMPCodec.apply(XMPPacket(data: Data(alternate.utf8)), to: base).adjustments, imported.adjustments)
    }
    func testLookThatNeedsInstalledTablesIsLeftOut() throws {
        func look(_ tables: String) throws -> XMPPacket {
            try packet("", """
            <crs:Look><rdf:Description crs:Name="Built In" crs:Amount="1" crs:SupportsAmount="false"><crs:Parameters><rdf:Description \(tables)>
            <crs:ToneCurvePV2012><rdf:Seq><rdf:li>0, 0</rdf:li><rdf:li>40, 35</rdf:li><rdf:li>224, 230</rdf:li><rdf:li>255, 255</rdf:li></rdf:Seq></crs:ToneCurvePV2012>
            </rdf:Description></crs:Parameters></rdf:Description></crs:Look>
            """)
        }
        // Only the curve of an installed profile travels in the sidecar, so the look is left out rather than shown partially.
        for tables in ["crs:LookTable=\"E1095149FDB39D7A057BAB208837E2E1\"", "crs:RGBTable=\"0123456789ABCDEF0123456789ABCDEF\""] {
            let imported = try XMPCodec.apply(look(tables), to: Adjustments())
            XCTAssertNil(imported.adjustments.look, tables)
            XCTAssertTrue(imported.warnings.contains { $0.contains("Built In") && $0.contains("not available here") }, tables)
        }
        let embedded = try XMPCodec.apply(look(""), to: Adjustments())
        XCTAssertEqual(embedded.adjustments.look?.name, "Built In")
        XCTAssertEqual(embedded.adjustments.look?.adjustments.curve.points.count, 4)
    }
    func testNativeExactRoundTripAndExternalChangeInvalidatesRecipe() throws {
        var a = Adjustments(); a.exposure = 1.75; a.geometry.flipHorizontal = true; a.quarterTurns = 1
        var mask = PhotoMask(kind: .linear); mask.adjustments.exposure = 0.4; a.masks = [mask]
        a.disabledSections.insert(.light); a.selectiveColors[1].hue = 17; a.curve.points[0].y = 0.03
        var metadata = CatalogMetadata(); metadata.title = "Snow & <sky>"; metadata.rating = 4; metadata.review = .rejected
        metadata.latitude = -46.75; metadata.longitude = 11.6; metadata.captureDay = "2026-09-30"
        let source = try packet("crs:Dehaze=\"23\"", "<crs:Look><rdf:Description crs:Name=\"Adobe Color\"/></crs:Look>").data
        let data = try XMPCodec.encode(adjustments: a, metadata: metadata, sourceData: source, filename: "photo.arw")
        let p = try XMPPacket(data: data)
        let imported = try XMPCodec.apply(p, to: Adjustments())
        XCTAssertEqual(imported.adjustments, a); XCTAssertEqual(imported.metadata, metadata); XCTAssertEqual(imported.sourceData, source)
        let exportedAgain = try XMPPacket(data: XMPCodec.encode(adjustments: a, sourceData: data))
        XCTAssertEqual(exportedAgain.value("SourcePacket", namespace: XMPPacket.native), source.base64EncodedString())
        let modified = String(data: data, encoding: .utf8)!.replacingOccurrences(of: "crs:Exposure2012=\"0.0\"", with: "crs:Exposure2012=\"2.0\"")
        XCTAssertNotEqual(modified, String(data: data, encoding: .utf8)!)
        let external = try XMPCodec.apply(XMPPacket(data: Data(modified.utf8)), to: Adjustments())
        XCTAssertEqual(external.adjustments.exposure, 2); XCTAssertEqual(external.adjustments.quarterTurns, 0)
        XCTAssertTrue(external.warnings.joined().contains("changed outside"))
    }
    func testCropColorAndRejectMappings() throws {
        let imported = try XMPCodec.apply(packet("crs:HasCrop=\"True\" crs:CropTop=\"0.1\" crs:CropLeft=\"0.2\" crs:CropBottom=\"0.8\" crs:CropRight=\"0.9\" crs:HueAdjustmentOrange=\"50\" xmp:Rating=\"-1\""), to: Adjustments())
        XCTAssertEqual(imported.adjustments.geometry.crop.y, 0.2, accuracy: 0.000001)
        XCTAssertEqual(imported.adjustments.geometry.crop.width, 0.7, accuracy: 0.000001)
        XCTAssertEqual(imported.adjustments.selectiveColors[1].hue, 30)
        XCTAssertEqual(imported.metadata.review, .rejected)
        let rotated = try XMPCodec.apply(packet("crs:HasCrop=\"True\" crs:CropAngle=\"5\" crs:CropTop=\"0.1\""), to: Adjustments())
        XCTAssertEqual(rotated.adjustments.geometry.crop, .full)
        XCTAssertTrue(rotated.warnings.joined().contains("manual alignment"))
    }
    func testPresetNameRestatedAndBuiltInLooks() throws {
        func preset(_ attributes: String, look: String, name: String = "Portra") throws -> XMPPacket {
            try packet("crs:PresetType=\"Normal\" crs:Name=\"Portra\" crs:Amount=\"1.000000\" crs:RequiresRenditionBehavior=\"True\" crs:Contrast2012=\"7\" \(attributes)", """
            <crs:Name><rdf:Alt><rdf:li xml:lang="x-default">\(name)</rdf:li></rdf:Alt></crs:Name>
            <crs:Look><rdf:Description crs:Name="\(look)" crs:Amount="1.000000"><crs:Group><rdf:Alt><rdf:li xml:lang="x-default">Profiles</rdf:li></rdf:Alt></crs:Group></rdf:Description></crs:Look>
            """)
        }
        // The name given twice is one name; settings given twice, or names that disagree, are still rejected.
        var existing = Adjustments(); existing.look = ImportedLook(name: "Old")
        let color = try XMPCodec.apply(preset("crs:Treatment=\"Color\"", look: "Adobe Color"), to: existing)
        XCTAssertEqual(color.adjustments.contrast, 7); XCTAssertNil(color.adjustments.look); XCTAssertFalse(color.adjustments.monochrome)
        XCTAssertEqual(color.warnings, ["Camera profile ‘Adobe Color’ is approximated with default camera color."])
        XCTAssertThrowsError(try preset("", look: "Adobe Color", name: "Ektar"))
        XCTAssertThrowsError(try packet("crs:Name=\"Portra\"", "<crs:Name><rdf:Seq><rdf:li>Portra</rdf:li></rdf:Seq></crs:Name>"))
        // A monochrome treatment or profile makes the photo black and white unless ConvertToGrayscale says otherwise.
        XCTAssertTrue(try XMPCodec.apply(preset("crs:Treatment=\"Monochrome\"", look: "Adobe Monochrome"), to: Adjustments()).adjustments.monochrome)
        XCTAssertTrue(try XMPCodec.apply(preset("", look: "Adobe Monochrome"), to: Adjustments()).adjustments.monochrome)
        XCTAssertFalse(try XMPCodec.apply(preset("crs:Treatment=\"Black &amp; White\" crs:ConvertToGrayscale=\"False\"", look: "Adobe Color"), to: Adjustments()).adjustments.monochrome)
        let partial = try XMPCodec.apply(packet("crs:Amount=\"0.5\""), to: Adjustments())
        XCTAssertTrue(partial.warnings.joined().contains("Amount"))
    }
    func testTextureAndDehazeImportExportAndApplyToMasks() throws {
        let imported = try XMPCodec.apply(packet("crs:Texture=\"-35\" crs:Dehaze=\"22\"", """
        <crs:MaskGroupBasedCorrections><rdf:Seq><rdf:li><rdf:Description crs:CorrectionName="Skin" crs:LocalTexture="-0.5" crs:LocalDehaze="0.3">
        <crs:CorrectionMasks><rdf:Seq><rdf:li crs:What="Mask/Gradient" crs:FullX="0.5" crs:FullY="0.2" crs:ZeroX="0.5" crs:ZeroY="0.8"/></rdf:Seq></crs:CorrectionMasks>
        </rdf:Description></rdf:li></rdf:Seq></crs:MaskGroupBasedCorrections>
        """), to: Adjustments())
        XCTAssertEqual(imported.adjustments.texture, -35); XCTAssertEqual(imported.adjustments.masks.first?.adjustments.texture, -50)
        XCTAssertEqual(imported.adjustments.dehaze, 22); XCTAssertEqual(imported.adjustments.masks.first?.adjustments.dehaze ?? 0, 30, accuracy: 1e-9)
        XCTAssertFalse(imported.warnings.joined().contains("Texture") || imported.warnings.joined().contains("Dehaze"), imported.warnings.joined())
        var a = Adjustments(); a.texture = 40; a.dehaze = -15
        let exported = try XMPCodec.apply(XMPPacket(data: XMPCodec.encode(adjustments: a)), to: Adjustments()).adjustments
        XCTAssertEqual(exported.texture, 40); XCTAssertEqual(exported.dehaze, -15)
        XCTAssertTrue(EditTransferItem.clarity.isModified(in: a))
    }
    func testMalformedUnsafeAndOutOfRangeInput() throws {
        XCTAssertThrowsError(try XMPPacket(data: Data("<invalid/>".utf8)))
        XCTAssertThrowsError(try XMPPacket(data: Data("<!DOCTYPE x [<!ENTITY e SYSTEM 'file:///tmp/private'>]><x>&e;</x>".utf8)))
        for encoding in [String.Encoding.utf16, .utf16LittleEndian, .utf16BigEndian] {
            let unsafe = "<?xml version=\"1.0\" encoding=\"UTF-16\"?><!DOCTYPE x [<!ENTITY e \"expansion\">]><x>&e;</x>"
            XCTAssertThrowsError(try XMPPacket(data: unsafe.data(using: encoding)!))
        }
        let utf16 = String(data: try packet("crs:Exposure2012=\"1\"").data, encoding: .utf8)!.data(using: .utf16)!
        XCTAssertEqual(try XMPPacket(data: utf16).value("Exposure2012"), "1")
        XCTAssertThrowsError(try XMPCodec.apply(packet("crs:Exposure2012=\"NaN\""), to: Adjustments()))
        XCTAssertThrowsError(try XMPCodec.apply(packet("xmp:Rating=\"6\""), to: Adjustments()))
        XCTAssertThrowsError(try XMPCodec.apply(packet("exif:GPSLatitude=\"91,0N\" exif:GPSLongitude=\"0,0E\""), to: Adjustments()))
        XCTAssertThrowsError(try packet("crs:Exposure2012=\"1\"", "<crs:Exposure2012>2</crs:Exposure2012>"))
        let clamped = try XMPCodec.apply(packet("crs:Sharpness=\"150\""), to: Adjustments())
        XCTAssertEqual(clamped.adjustments.sharpness, 100); XCTAssertTrue(clamped.warnings.joined().contains("limited"))
    }
    func testSampleSidecars() throws {
        let directory = try TestSamples.requireFolder(TestSamples.sidecars)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension.lowercased() == "xmp" }
        guard !files.isEmpty else { throw XCTSkip("No sidecars in \(directory.path)") }
        for url in files {
            let imported = try XMPCodec.apply(XMPPacket(url: url), to: Adjustments())
            _ = try imported.adjustments.validated()
            XCTAssertEqual(imported.sourceData, try Data(contentsOf: url))
        }
        let edited = try XMPCodec.apply(XMPPacket(url: TestSamples.requireSidecar(TestSamples.developedSidecar)), to: Adjustments())
        XCTAssertEqual(edited.adjustments.exposure, 1.1); XCTAssertEqual(edited.adjustments.curve.points.count, 5)
        XCTAssertEqual(edited.adjustments.curve.points[1].x, 57.0 / 255)
    }
    func testStrippingSourceXMPKeepsTheDevelopmentAndEndsTheWarning() async throws {
        let (directory, original) = try CatalogTests().fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        try packet("crs:Exposure2012=\"1.2\" crs:FutureControl=\"7\" xmp:Rating=\"4\"").data
            .write(to: original.deletingPathExtension().appendingPathExtension("XMP"))
        let prepared = try CatalogImporter.prepare(original)
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        let inserted = try await store.insert(prepared.0, thumbnail: prepared.1)
        let before = try await store.photo(inserted.id)
        XCTAssertTrue(before.xmpWarnings.contains("FutureControl")); XCTAssertNotNil(before.xmpData)
        let stripped = try await store.stripSourceXMP([inserted.id, "missing"])
        XCTAssertEqual(stripped, [inserted.id])
        let after = try await store.photo(inserted.id)
        XCTAssertNil(after.xmpData); XCTAssertEqual(after.xmpWarnings, ""); XCTAssertEqual(after.rating, 4)
        XCTAssertEqual(after.adjustmentsData, before.adjustmentsData)
        XCTAssertEqual(try JSONDecoder().decode(Adjustments.self, from: after.adjustmentsData!).exposure, 1.2)
        let again = try await store.stripSourceXMP([inserted.id])
        XCTAssertEqual(again, [])
    }
    func testAutomaticCatalogImportHistoryAndOriginalProtection() async throws {
        let (directory, original) = try CatalogTests().fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = try Data(contentsOf: original)
        let sidecar = original.deletingPathExtension().appendingPathExtension("XMP")
        let source = try packet("crs:Exposure2012=\"1.2\" xmp:Rating=\"4\"").data
        try source.write(to: sidecar)
        let prepared = try CatalogImporter.prepare(original)
        let root = directory.appendingPathComponent("Catalog"), store = try CatalogStore(root: root)
        let inserted = try await store.insert(prepared.0, thumbnail: prepared.1), asset = try await store.photo(inserted.id)
        XCTAssertEqual(asset.rating, 4); XCTAssertEqual(asset.xmpData, source)
        XCTAssertEqual(try JSONDecoder().decode(Adjustments.self, from: asset.adjustmentsData!).exposure, 1.2)
        XCTAssertNotEqual(asset.thumbnailRenderKey, asset.renderKey)
        let baseline = try JSONDecoder().decode(Adjustments.self, from: asset.adjustmentsData!)
        let next = try XMPCodec.apply(packet("crs:Exposure2012=\"2.1\" xmp:Rating=\"5\""), to: baseline, metadata: asset.metadata)
        try await store.importXMP(next, assetID: inserted.id, baseline: baseline)
        let reopened = try CatalogStore(root: root)
        let current = try await reopened.photo(asset.id)
        XCTAssertEqual(current.rating, 5); XCTAssertEqual(current.xmpData, next.sourceData)
        let revisions = try await reopened.history(assetID: asset.id)
        XCTAssertEqual(revisions.count, 4)
        try await reopened.restore(revisions.last { $0.kind == .edit }!)
        let restored = try await reopened.photo(asset.id)
        XCTAssertEqual(try JSONDecoder().decode(Adjustments.self, from: restored.adjustmentsData!).exposure, 1.2)
        // Reset drops the imported packet, so settings other software wrote stop travelling with the photo; ratings stay.
        try await reopened.resetEdits(to: Adjustments(), assetID: asset.id)
        let reset = try await reopened.photo(asset.id)
        XCTAssertNil(reset.xmpData); XCTAssertEqual(reset.xmpWarnings, ""); XCTAssertEqual(reset.rating, 5)
        XCTAssertEqual(try JSONDecoder().decode(Adjustments.self, from: reset.adjustmentsData!), Adjustments())
        XCTAssertThrowsError(try XMPCodec.write(source, to: original, protecting: original))
        let alias = directory.appendingPathComponent("alias.xmp")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
        XCTAssertThrowsError(try XMPCodec.write(source, to: alias, protecting: original))
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertEqual(try Data(contentsOf: sidecar), source)
        let ambiguous = directory.appendingPathComponent("photo.jpg.xmp"); try source.write(to: ambiguous)
        XCTAssertThrowsError(try XMPPacket.sidecar(for: original))
        XCTAssertTrue(CatalogImporter.supported(original), "JPEG must be recognized as an image")
        XCTAssertEqual(try CatalogImporter.files(in: [original, sidecar]), [sidecar.standardizedFileURL])
        XCTAssertThrowsError(try CatalogImporter.files(in: [sidecar, ambiguous]))
        let explicit = try CatalogImporter.prepare(sidecar)
        // The duplicate key is the locator of the photo the sidecar describes.
        XCTAssertEqual(explicit.0.importPath, explicit.0.origin)
        XCTAssertEqual(AssetLocator(string: explicit.0.importPath), .file(path: original.resolvingSymlinksInPath().path))
    }

    func testReportsKeepOnlyNonEmptyNotes() {
        XCTAssertNil(XMPCodec.compatibilityReport("  \n\n "))
        XCTAssertEqual(XMPCodec.compatibilityReport("Camera profile ‘X’ not found.\n\n \n\nLens Blur was not applied."),
                       "Camera profile ‘X’ not found.\n\nLens Blur was not applied.")
    }
}
