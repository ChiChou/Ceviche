import XCTest
import CevicheTestSupport
import ImageIO
import UniformTypeIdentifiers
import CevicheCore
@testable import CevicheMac

/// A photo edited outside any catalog keeps its development in an XMP sidecar beside it.
final class SidecarDevelopmentTests: XCTestCase {
    var folder: URL!
    var image: URL!
    override func setUpWithError() throws {
        (folder, image) = try EditorFixtures.photo()
    }
    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        try? FileManager.default.removeItem(at: folder)
    }
    var standard: URL { folder.appendingPathComponent("example.xmp") }

    @MainActor func testEditsSaveToTheSidecarAndReopen() async throws {
        let original = try Data(contentsOf: image)
        let editor = EditorModel()
        let opened = await editor.open(image, store: SidecarDevelopmentStore(image: image))
        XCTAssertTrue(opened); XCTAssertNil(editor.catalogAssetID); XCTAssertFalse(editor.keepsHistory)
        editor.edit { $0.exposure = 0.8 }
        XCTAssertTrue(editor.dirty)
        let flushed = await editor.flushEdits()
        XCTAssertTrue(flushed); XCTAssertFalse(editor.dirty); XCTAssertNil(editor.error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: standard.path))
        editor.closeDocument()
        await editor.open(image, store: SidecarDevelopmentStore(image: image))
        XCTAssertEqual(editor.adjustments.exposure, 0.8); XCTAssertFalse(editor.dirty)
        editor.closeDocument()
        XCTAssertEqual(try Data(contentsOf: image), original)
    }
    @MainActor func testAutosaveWritesTheSidecar() async throws {
        let editor = EditorModel()
        await editor.open(image, store: SidecarDevelopmentStore(image: image))
        editor.edit { $0.contrast = 25 }
        for _ in 0..<40 where editor.dirty { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertFalse(editor.dirty)
        XCTAssertEqual(try XMPCodec.apply(XMPPacket(url: standard), to: Adjustments()).adjustments.contrast, 25)
        editor.closeDocument()
    }
    @MainActor func testAnotherEditorsSidecarIsReadButNotOverwritten() async throws {
        let theirs = Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="\(XMPPacket.rdf)">
        <rdf:Description xmlns:crs="\(XMPPacket.crs)" xmlns:xmp="\(XMPPacket.xmp)" xmp:CreatorTool="Another Raw Editor" crs:Exposure2012="1.25" xmp:Rating="4"/>
        </rdf:RDF></x:xmpmeta>
        """.utf8)
        try theirs.write(to: standard)
        let editor = EditorModel()
        await editor.open(image, store: SidecarDevelopmentStore(image: image))
        XCTAssertNil(editor.failure); XCTAssertEqual(editor.adjustments.exposure, 1.25)
        editor.edit { $0.exposure = 0.5 }
        _ = await editor.save()
        XCTAssertEqual(try Data(contentsOf: standard), theirs)
        let ours = folder.appendingPathComponent("example.ceviche.xmp")
        let saved = try XMPCodec.apply(XMPPacket(url: ours), to: Adjustments())
        XCTAssertEqual(saved.adjustments.exposure, 0.5); XCTAssertEqual(saved.metadata.rating, 4)
        editor.closeDocument()
        await editor.open(image, store: SidecarDevelopmentStore(image: image))
        XCTAssertEqual(editor.adjustments.exposure, 0.5)
        editor.closeDocument()
    }
    @MainActor func testStrippingAnotherEditorsUnsupportedSettingsEndsTheWarning() async throws {
        let theirs = Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="\(XMPPacket.rdf)">
        <rdf:Description xmlns:crs="\(XMPPacket.crs)" xmlns:xmp="\(XMPPacket.xmp)" crs:Exposure2012="1.25" crs:FutureControl="7" xmp:Rating="4"/>
        </rdf:RDF></x:xmpmeta>
        """.utf8)
        try theirs.write(to: standard)
        let editor = EditorModel()
        await editor.open(image, store: SidecarDevelopmentStore(image: image))
        XCTAssertTrue(editor.xmpReport?.contains("FutureControl") == true); XCTAssertTrue(editor.canStripXMP)
        await editor.stripUnsupportedXMP()
        XCTAssertNil(editor.xmpReport); XCTAssertFalse(editor.canStripXMP); XCTAssertNil(editor.error)
        XCTAssertEqual(try Data(contentsOf: standard), theirs, "The other application's sidecar is left alone")
        let ours = try XMPPacket(url: folder.appendingPathComponent("example.ceviche.xmp"))
        XCTAssertNil(ours.nativeValue("SourcePacket"))
        editor.closeDocument()
        await editor.open(image, store: SidecarDevelopmentStore(image: image))
        XCTAssertNil(editor.xmpReport); XCTAssertEqual(editor.adjustments.exposure, 1.25)
        editor.closeDocument()
    }
    func testTheWarningNamesTheApplicationThatWroteTheSidecar() {
        func packet(_ tool: String) -> Data {
            Data("""
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="\(XMPPacket.rdf)">
            <rdf:Description xmlns:xmp="\(XMPPacket.xmp)" xmp:CreatorTool="\(tool)"/>
            </rdf:RDF></x:xmpmeta>
            """.utf8)
        }
        XCTAssertEqual(XMPCodec.sourceApplication(packet("Another Raw Editor 13.0 (Macintosh)")), "Another Raw Editor 13.0 (Macintosh)")
        XCTAssertEqual(XMPCodec.sourceApplication(packet("Second Raw Editor")), "Second Raw Editor")
        XCTAssertNil(XMPCodec.sourceApplication(packet(XMPCodec.creatorTool)))
        XCTAssertNil(XMPCodec.sourceApplication(nil))
    }
    @MainActor func testWithoutAStoreNothingIsWritten() async throws {
        let editor = EditorModel()
        await editor.open(image)
        editor.edit { $0.exposure = 1 }
        let flushed = await editor.flushEdits()
        let saved = await editor.save()
        XCTAssertTrue(flushed); XCTAssertFalse(saved)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["example.jpg"])
        editor.closeDocument()
    }
    @MainActor func testReadOnlyFolderKeepsEditsUnsavedUntilACopyIsSaved() async throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        guard !FileManager.default.isWritableFile(atPath: folder.path) else { throw XCTSkip("Running with permission to write anywhere") }
        let editor = EditorModel()
        await editor.open(image, store: SidecarDevelopmentStore(image: image))
        XCTAssertNil(editor.failure)
        editor.edit { $0.exposure = 0.6 }
        try await Task.sleep(for: .seconds(2))
        XCTAssertTrue(editor.dirty)
        let flushed = await editor.flushEdits()
        XCTAssertFalse(flushed); XCTAssertNil(editor.error)
        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        let copy = elsewhere.appendingPathComponent("example.jpg")
        let saved = await editor.saveCopy(to: copy)
        XCTAssertTrue(saved); XCTAssertFalse(editor.dirty); XCTAssertEqual(editor.sourceURL, copy)
        XCTAssertEqual(try XMPCodec.apply(XMPPacket(url: elsewhere.appendingPathComponent("example.xmp")), to: Adjustments()).adjustments.exposure, 0.6)
        // Later edits autosave beside the copy.
        editor.edit { $0.exposure = 0.9 }
        let again = await editor.flushEdits()
        XCTAssertTrue(again)
        XCTAssertEqual(try XMPCodec.apply(XMPPacket(url: elsewhere.appendingPathComponent("example.xmp")), to: Adjustments()).adjustments.exposure, 0.9)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["example.jpg"])
        editor.closeDocument()
    }
}
