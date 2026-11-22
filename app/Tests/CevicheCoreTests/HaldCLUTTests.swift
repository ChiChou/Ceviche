import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import GRDB
@testable import CevicheCore

final class HaldCLUTTests: XCTestCase {
    /// A known asymmetric colour transform catches flips, channel swaps and lost 16-bit precision.
    static func png(level: Int = 2, depth: Int = 16, gray: Bool = false, transparent: Bool = false, side: Int? = nil) throws -> Data {
        let n = level * level, width = side ?? level * level * level
        var bytes = Data()
        for i in 0..<width*width {
            let r = i % n, g = (i / n) % n, b = i / (n*n)
            let channels = gray ? [Double(i % 64) / 63] : [Double(r)/Double(n-1), 1-Double(g)/Double(n-1), Double(b)/Double(n-1)]
            for value in channels {
                if depth == 8 { bytes.append(UInt8((min(1,value) * 255).rounded())) }
                else {
                    var word = UInt16((min(1,value) * 63000 + 123).rounded()).littleEndian
                    withUnsafeBytes(of: &word) { bytes.append(contentsOf: $0) }
                }
            }
            if !gray {
                if depth == 8 { bytes.append(transparent ? 0 : 255) }
                else { var alpha: UInt16 = transparent ? 0 : 65535; withUnsafeBytes(of: &alpha) { bytes.append(contentsOf: $0) } }
            }
        }
        let channels = gray ? 1 : 4
        let info = (gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue)
            | (depth == 16 ? CGBitmapInfo.byteOrder16Little.rawValue : 0)
        let image = try XCTUnwrap(CGImage(width: width, height: width, bitsPerComponent: depth, bitsPerPixel: depth*channels,
            bytesPerRow: width*depth/8*channels, space: gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: info), provider: CGDataProvider(data: bytes as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testRGBPrecisionOrderingAndLargeTableResampling() throws {
        for (level, depth) in [(2, 8), (2, 16), (9, 16)] {
            let png = try Self.png(level: level, depth: depth)
            let lut = try CreativeLUT(data: png, name: "Film")
            let n = min(level*level, 64)
            XCTAssertEqual(lut.dimension, n)
            XCTAssertEqual(lut.haldPNG, png)
            let samples = CameraProfile.floats(lut.cubeData)
            for b in [0, n/2, n-1] { for g in [0, n/2, n-1] { for r in [0, n/2, n-1] {
                let i = ((b*n+g)*n+r)*4
                for (channel, value) in [Double(r)/Double(n-1), 1-Double(g)/Double(n-1), Double(b)/Double(n-1)].enumerated() {
                    let expected = depth == 8 ? value : (value*63000+123)/65535
                    XCTAssertEqual(Double(samples[i+channel]), expected, accuracy: 2.0/65535)
                }
            } } }
        }
    }

    func testGrayscalePreservesEncodedSamples() throws {
        for depth in [8, 16] {
            let lut = try CreativeLUT(haldPNG: Self.png(depth: depth, gray: true), name: "Mono")
            let values = CameraProfile.floats(lut.cubeData)
            for i in 0..<64 {
                let expected = depth == 8 ? (Double(i)/63*255).rounded()/255 : (Double(i)/63*63000+123).rounded()/65535
                for c in 0..<3 { XCTAssertEqual(Double(values[i*4+c]), expected, accuracy: 1.0/65535) }
            }
        }
    }

    func testInvalidPNGsAndPortableRecipe() throws {
        XCTAssertThrowsError(try CreativeLUT(haldPNG: Data("bad".utf8), name: "Bad"))
        XCTAssertThrowsError(try CreativeLUT(haldPNG: Self.png(side: 9), name: "Bad"))
        XCTAssertThrowsError(try CreativeLUT(haldPNG: Self.png(transparent: true), name: "Bad"))
        var lut = try CreativeLUT(haldPNG: Self.png(), name: "Film")
        lut.amount = 0.35; lut.enabled = false; lut.space = .displayP3
        let encoded = try JSONEncoder().encode(lut)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(json["samples"], "Portable recipes retain PNG instead of expanded samples")
        let decoded = try JSONDecoder().decode(CreativeLUT.self, from: encoded)
        XCTAssertEqual(decoded, lut); XCTAssertEqual(decoded.haldPNG, lut.haldPNG)
    }

    func testLibraryImportsPNGWithoutConversionAndFindsMovedResource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Pack/Film.png")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        let png = try Self.png(); try png.write(to: source)
        try Data("not a PNG".utf8).write(to: source.deletingLastPathComponent().appendingPathComponent("Bad.png"))
        let library = LookLibrary(root: root.appendingPathComponent("Looks"))
        let imported = try library.importItems([source.deletingLastPathComponent()], kind: .luts)
        XCTAssertEqual(imported.total, 1); XCTAssertEqual(imported.skipped.count, 1)
        let file = try XCTUnwrap(library.files(.luts).first)
        XCTAssertEqual(file.pathExtension, "png"); XCTAssertEqual(try Data(contentsOf: file), png)
        XCTAssertEqual(try library.tree(.luts).first?.children?.count, 1)
        let resources = FolderResources(root: library.root)
        let reference = try XCTUnwrap(resources.reference(for: file))
        let renamed = file.deletingLastPathComponent().appendingPathComponent("Renamed.png")
        try FileManager.default.moveItem(at: file, to: renamed)
        XCTAssertEqual(try resources.data(for: reference), png)
    }

    func testCatalogRetainsPNGInFolderAndDatabaseStorage() async throws {
        for database in [false, true] {
            let (root, photo) = try CatalogTests().fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let resources = FolderResources(root: root.appendingPathComponent("Looks"))
            let catalog = root.appendingPathComponent("Catalog")
            let store = try CatalogStore(root: catalog, resources: database ? .database : .folder(resources))
            let prepared = try CatalogImporter.prepare(photo)
            let asset = try await store.insert(prepared.0, thumbnail: prepared.1)
            let png = try Self.png()
            var edits = Adjustments(); edits.lut = try CreativeLUT(haldPNG: png, name: "Hald")
            edits.lut?.amount = 0.6
            try await store.saveEdits(edits, assetID: asset.id, baseline: Adjustments())
            let saved = try await store.savedAdjustments(of: store.asset(asset.id))
            XCTAssertEqual(saved?.lut, edits.lut)
            XCTAssertEqual(saved?.lut?.haldPNG, png)
            XCTAssertEqual(saved?.lut?.source?.path, "LUTs/Imported/Hald.png")
            if database {
                let db = try DatabaseQueue(path: catalog.appendingPathComponent("catalog.sqlite").path)
                let stored = try await db.read { try Data.fetchOne($0, sql: "SELECT data FROM resource WHERE path = 'LUTs/Imported/Hald.png'") }
                XCTAssertEqual(stored, png)
            } else {
                XCTAssertEqual(try Data(contentsOf: resources.root.appendingPathComponent("LUTs/Imported/Hald.png")), png)
                XCTAssertFalse(FileManager.default.fileExists(atPath: resources.root.appendingPathComponent("LUTs/Imported/Hald.cube").path))
            }
        }
    }
}
