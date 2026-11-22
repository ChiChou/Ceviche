import XCTest
@testable import CevicheCore

final class XMPSidecarTests: XCTestCase {
    var folder: URL!
    var image: URL!
    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        folder = root.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        image = folder.appendingPathComponent("IMG_0001.ARW")
        try Data("not really a raw".utf8).write(to: image)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
    }
    func foreignPacket(exposure: Double) -> Data {
        Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="\(XMPPacket.rdf)">
        <rdf:Description xmlns:crs="\(XMPPacket.crs)" xmlns:xmp="\(XMPPacket.xmp)" xmp:CreatorTool="Adobe Photoshop Lightroom Classic" crs:Exposure2012="\(exposure)" xmp:Rating="4"/>
        </rdf:RDF></x:xmpmeta>
        """.utf8)
    }
    func edit(exposure: Double) -> Adjustments { var settings = Adjustments(); settings.exposure = exposure; return settings }

    func testNewPhotoWritesTheStandardSidecarAndReadsItBack() throws {
        let first = try XMPSidecar.resolve(for: image)
        XCTAssertNil(first.readURL); XCTAssertNil(first.preserved)
        XCTAssertEqual(first.writeURL.lastPathComponent, "IMG_0001.xmp")
        try first.write(adjustments: edit(exposure: 0.7), metadata: nil, defaults: Adjustments())
        let second = try XMPSidecar.resolve(for: image)
        XCTAssertEqual(second.readURL, first.writeURL); XCTAssertEqual(second.writeURL, first.writeURL); XCTAssertNil(second.preserved)
        XCTAssertEqual(try XMPCodec.apply(XMPPacket(url: first.writeURL), to: Adjustments()).adjustments.exposure, 0.7)
        XCTAssertEqual(try Data(contentsOf: image), Data("not really a raw".utf8))
    }
    func testAnotherEditorsSidecarIsLeftAloneAndCarried() throws {
        let theirs = folder.appendingPathComponent("IMG_0001.xmp"), data = foreignPacket(exposure: 1.5)
        try data.write(to: theirs)
        let first = try XMPSidecar.resolve(for: image)
        XCTAssertEqual(first.readURL, theirs); XCTAssertEqual(first.writeURL.lastPathComponent, "IMG_0001.ceviche.xmp")
        XCTAssertEqual(first.preserved, data)
        try first.write(adjustments: edit(exposure: 0.3), metadata: nil, defaults: Adjustments())
        XCTAssertEqual(try Data(contentsOf: theirs), data)
        // Ours is read first from now on, and keeps carrying their packet.
        let second = try XMPSidecar.resolve(for: image)
        XCTAssertEqual(second.readURL, first.writeURL); XCTAssertEqual(second.writeURL, first.writeURL); XCTAssertEqual(second.preserved, data)
        XCTAssertEqual(try XMPCodec.apply(XMPPacket(url: first.writeURL), to: Adjustments()).adjustments.exposure, 0.3)
    }
    func testOurSidecarRewrittenByAnotherEditorBecomesTheirs() throws {
        let first = try XMPSidecar.resolve(for: image)
        try first.write(adjustments: edit(exposure: 0.2), metadata: nil, defaults: Adjustments())
        let rewritten = String(decoding: try Data(contentsOf: first.writeURL), as: UTF8.self)
            .replacingOccurrences(of: XMPCodec.creatorTool, with: "Capture One")
        try Data(rewritten.utf8).write(to: first.writeURL)
        let second = try XMPSidecar.resolve(for: image)
        XCTAssertEqual(second.readURL, first.writeURL)
        XCTAssertEqual(second.writeURL.lastPathComponent, "IMG_0001.ceviche.xmp")
    }
    func testReadOnlyFolderWritesNothingAndSaysSo() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        guard !FileManager.default.isWritableFile(atPath: folder.path) else { throw XCTSkip("Running with permission to write anywhere") }
        XCTAssertFalse(XMPSidecar.folderIsWritable(for: image))
        let sidecar = try XMPSidecar.resolve(for: image)
        XCTAssertThrowsError(try sidecar.write(adjustments: edit(exposure: 0.9), metadata: nil, defaults: Adjustments())) {
            XCTAssertTrue(XMPSidecar.isUnwritable($0), "\($0)")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["IMG_0001.ARW"])
    }
    func testSaveCopyTakesThePhotoAndItsSidecarsAlong() throws {
        let theirs = folder.appendingPathComponent("IMG_0001.xmp"), data = foreignPacket(exposure: 1.5)
        try data.write(to: theirs)
        let elsewhere = folder.deletingLastPathComponent().appendingPathComponent("Copies")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let copy = elsewhere.appendingPathComponent("Beach.ARW")
        let sidecar = try XMPSidecar.saveCopy(of: image, to: copy, adjustments: edit(exposure: 0.4), metadata: nil, defaults: Adjustments())
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path)), ["Beach.ARW", "Beach.xmp", "Beach.ceviche.xmp"])
        XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: image))
        XCTAssertEqual(try Data(contentsOf: elsewhere.appendingPathComponent("Beach.xmp")), data)
        XCTAssertEqual(sidecar.writeURL.lastPathComponent, "Beach.ceviche.xmp")
        XCTAssertEqual(try XMPCodec.apply(XMPPacket(url: sidecar.writeURL), to: Adjustments()).adjustments.exposure, 0.4)
        // The original folder is as it was, and a second copy to the same name is refused rather than replacing it.
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)), ["IMG_0001.ARW", "IMG_0001.xmp"])
        XCTAssertThrowsError(try XMPSidecar.saveCopy(of: image, to: copy, adjustments: edit(exposure: 1), metadata: nil, defaults: Adjustments()))
        XCTAssertEqual(try XMPCodec.apply(XMPPacket(url: sidecar.writeURL), to: Adjustments()).adjustments.exposure, 0.4)
    }
}
