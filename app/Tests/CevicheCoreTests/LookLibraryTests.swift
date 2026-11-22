import XCTest
import CevicheTestSupport
import Metal
@testable import CevicheCore

/// Builds little-endian DNG camera profiles for tests.
enum DCPFixture {
    static func make(name: String, camera: String, hueShift: Float = 0, satScale: Float = 1, valScale: Float = 1, dims: [UInt32] = [6, 2, 1], curve: [Float]? = nil, look: Bool = false) -> Data {
        var entries: [(tag: UInt16, type: UInt16, count: UInt32, payload: Data)] = []
        func ascii(_ s: String) -> Data { Data(s.utf8) + Data([0]) }
        func floats(_ v: [Float]) -> Data { v.reduce(into: Data()) { d, f in withUnsafeBytes(of: f.bitPattern.littleEndian) { d.append(contentsOf: $0) } } }
        func longs(_ v: [UInt32]) -> Data { v.reduce(into: Data()) { d, x in withUnsafeBytes(of: x.littleEndian) { d.append(contentsOf: $0) } } }
        entries.append((50708, 2, UInt32(ascii(camera).count), ascii(camera)))
        entries.append((50936, 2, UInt32(ascii(name).count), ascii(name)))
        // Hues × saturations × values, 6 × 2 × 1 unless given; every node holds the same shift and scales.
        let nodes = Int(dims.reduce(1, *))
        let map: [Float] = (0..<nodes).flatMap { _ -> [Float] in [hueShift, satScale, valScale] }
        entries.append((50937, 4, 3, longs(dims)))
        entries.append((50938, 11, UInt32(map.count), floats(map)))
        if let curve { entries.append((50940, 11, UInt32(curve.count), floats(curve))) }
        if look {
            let table: [Float] = (0..<12).flatMap { _ -> [Float] in [0, 0.5, 1] }
            entries.append((50981, 4, 3, longs([6, 2, 1])))
            entries.append((50982, 11, UInt32(table.count), floats(table)))
        }
        entries.sort { $0.tag < $1.tag }
        var header = Data("IIRC".utf8) + longs([8])
        let directorySize = 2 + entries.count * 12 + 4
        var payloadOffset = 8 + directorySize
        var directory = Data(), payloads = Data()
        withUnsafeBytes(of: UInt16(entries.count).littleEndian) { directory.append(contentsOf: $0) }
        for e in entries {
            withUnsafeBytes(of: e.tag.littleEndian) { directory.append(contentsOf: $0) }
            withUnsafeBytes(of: e.type.littleEndian) { directory.append(contentsOf: $0) }
            withUnsafeBytes(of: e.count.littleEndian) { directory.append(contentsOf: $0) }
            if e.payload.count <= 4 { directory.append(e.payload + Data(count: 4 - e.payload.count)) }
            else { directory.append(longs([UInt32(payloadOffset)])); payloads.append(e.payload); payloadOffset += e.payload.count }
        }
        directory.append(longs([0]))
        header.append(directory); header.append(payloads)
        return header
    }
}

final class LookLibraryTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("looks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func write(_ text: String, _ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url); return url
    }
    func identityCube(_ n: Int, title: String = "Identity", invert: Bool = false) -> String {
        var lines = ["# test", "TITLE \"\(title)\"", "LUT_3D_SIZE \(n)"]
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let v = [r, g, b].map { Double($0) / Double(n - 1) }.map { invert ? 1 - $0 : $0 }
            lines.append(v.map { String(format: "%.6f", $0) }.joined(separator: " "))
        } } }
        return lines.joined(separator: "\n")
    }

    // MARK: DCP

    func testDCPParsingTablesAndTransforms() throws {
        let data = DCPFixture.make(name: "Stock 400 - S", camera: "Sony ILCE-7", hueShift: 30, satScale: 0.5, curve: [0, 0, 0.5, 0.7, 1, 1])
        let profile = try CameraProfile(dcp: data)
        XCTAssertEqual(profile.name, "Stock 400 - S"); XCTAssertEqual(profile.camera, "Sony ILCE-7")
        XCTAssertEqual(profile.hueSatDimensions, [6, 2, 1]); XCTAssertTrue(profile.hasToneCurve); XCTAssertTrue(profile.hasTables)
        // Red shifted by 30° toward yellow, at half saturation.
        let red = CameraProfileRenderer.applyMap(SIMD3(1, 0, 0), CameraProfile.floats(profile.hueSatMap1!), [6, 2, 1], sRGB: false, amount: 1)
        let (h, s, v) = CameraProfileRenderer.hsv(red)
        XCTAssertEqual(h, 0.5, accuracy: 0.001); XCTAssertEqual(s, 0.5, accuracy: 0.001); XCTAssertEqual(v, 1, accuracy: 0.001)
        // Amount zero is identity for the tables.
        let unchanged = CameraProfileRenderer.applyMap(SIMD3(1, 0.2, 0.1), CameraProfile.floats(profile.hueSatMap1!), [6, 2, 1], sRGB: false, amount: 0)
        XCTAssertEqual(unchanged.x, 1, accuracy: 0.0001); XCTAssertEqual(unchanged.y, 0.2, accuracy: 0.0001)
        // Hue-preserving base tone maps the extreme channels through the curve.
        let curve = MonotoneCurve(profile.toneCurve!)
        XCTAssertEqual(curve.value(0.5), 0.7, accuracy: 0.0001)
        let toned = CameraProfileRenderer.baseTone(SIMD3(0.5, 0.25, 0), curve)
        XCTAssertEqual(toned.x, 0.7, accuracy: 0.0001); XCTAssertEqual(toned.z, 0, accuracy: 0.0001)
        XCTAssertEqual(toned.y, 0.35, accuracy: 0.0001)
        // Embedded in recipes and documents.
        var a = Adjustments(); a.cameraProfile = profile
        let decoded = try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(decoded.cameraProfile, profile)
        XCTAssertThrowsError(try CameraProfile(dcp: Data("not a profile".utf8)))
        XCTAssertThrowsError(try CameraProfile(dcp: data.prefix(40)))
    }

    func testIdentityProfileCubeIsNeutral() {
        var profile = CameraProfile(name: "Neutral")
        profile.hueSatDimensions = [6, 2, 1]
        profile.hueSatMap1 = CameraProfile.data((0..<12).flatMap { _ -> [Float] in [0, 1, 1] })
        let cube = CameraProfile.floats(CameraProfileRenderer.cube(profile, weight: 1))
        let n = CameraProfileRenderer.dimension
        for (r, g, b) in [(0, 0, 0), (n - 1, 0, 0), (10, 20, 30), (n - 1, n - 1, n - 1)] {
            let i = ((b * n + g) * n + r) * 4
            XCTAssertEqual(cube[i], Float(r) / Float(n - 1), accuracy: 0.002)
            XCTAssertEqual(cube[i + 1], Float(g) / Float(n - 1), accuracy: 0.002)
            XCTAssertEqual(cube[i + 2], Float(b) / Float(n - 1), accuracy: 0.002)
        }
    }

    func testDefaultToneCurveInvertsAndProfileCurveReplacesIt() throws {
        // The SDK curve is monotone through (0, 0) and (1, 1) and inverts to the input.
        XCTAssertEqual(DNGDefaultToneCurve.value(0), 0); XCTAssertEqual(DNGDefaultToneCurve.value(1), 1)
        XCTAssertEqual(DNGDefaultToneCurve.value(0.18), 0.388, accuracy: 0.005)
        for x: Float in [0.001, 0.02, 0.18, 0.5, 0.9] { XCTAssertEqual(DNGDefaultToneCurve.inverse(DNGDefaultToneCurve.value(x)), x, accuracy: 0.0005) }
        // A profile carrying the default curve itself renders unchanged; one with a lifted curve brightens mid-gray by its lift.
        let n = CameraProfileRenderer.dimension
        func gray(_ profile: CameraProfile, _ level: Int) -> Float {
            let cube = CameraProfile.floats(CameraProfileRenderer.cube(profile, weight: 1))
            return cube[((level * n + level) * n + level) * 4]
        }
        let samePoints = stride(from: 0, through: 1, by: 1 / 64.0).flatMap { [$0, Double(DNGDefaultToneCurve.value(Float($0)))] }
        let same = try CameraProfile(dcp: DCPFixture.make(name: "Default", camera: "Test", curve: samePoints.map(Float.init)))
        XCTAssertTrue(same.hasToneCurve)
        for level in [3, 12, 24, 40, n - 1] { XCTAssertEqual(gray(same, level), Float(level) / Float(n - 1), accuracy: 0.004) }
        let lifted = try CameraProfile(dcp: DCPFixture.make(name: "Lift", camera: "Test", curve: samePoints.enumerated().map { $0.offset % 2 == 0 ? Float($0.element) : Float(min(1, $0.element + 0.1)) }))
        let mid = CameraProfileRenderer.rommEncode(CameraProfileRenderer.rommDecode(24 / Float(n - 1)) + 0.1)
        XCTAssertEqual(gray(lifted, 24), mid, accuracy: 0.004)
        // Amount halves the lift.
        var half = lifted; half.amount = 0.5
        XCTAssertEqual(gray(half, 24), CameraProfileRenderer.rommEncode(CameraProfileRenderer.rommDecode(24 / Float(n - 1)) + 0.05), accuracy: 0.004)
    }

    func testRemovingBaseLeavesTheLook() throws {
        // A look built on a base: the base's own calibration (hue +10°, saturation ×1.5, value ×2) plus the look's hue +20°.
        let base = try CameraProfile(dcp: DCPFixture.make(name: "Adobe Standard", camera: "Sony ILCE-7M2", hueShift: 10, satScale: 1.5, valScale: 2, dims: [6, 3, 1]))
        let film = try CameraProfile(dcp: DCPFixture.make(name: "Stock - S", camera: "Sony ILCE-7M2", hueShift: 30, satScale: 1.5, valScale: 2, dims: [6, 2, 1], look: true))
        let separated = film.removingBase(base)
        XCTAssertEqual(separated.baseProfile, "Adobe Standard")
        let residual = CameraProfile.floats(separated.hueSatMap1!)
        for node in stride(from: 0, to: residual.count, by: 3) {
            XCTAssertEqual(residual[node], 20, accuracy: 0.001); XCTAssertEqual(residual[node + 1], 1, accuracy: 0.001); XCTAssertEqual(residual[node + 2], 1, accuracy: 0.001)
        }
        // The base has no look table, so the film's stays; a look table equal to the base's is dropped.
        XCTAssertNotNil(separated.lookTable)
        var baseWithLook = base; baseWithLook.lookDimensions = film.lookDimensions; baseWithLook.lookTable = film.lookTable
        XCTAssertNil(film.removingBase(baseWithLook).lookTable)
        // Identical profiles separate to identity tables, which render neutrally.
        let identity = film.removingBase(film)
        XCTAssertTrue(CameraProfile.isIdentity(identity.hueSatMap1!))
        let decoded = try JSONDecoder().decode(CameraProfile.self, from: JSONEncoder().encode(separated))
        XCTAssertEqual(decoded, separated)
    }

    func testProfileResolverMatchesCameraAndNormalizesNames() throws {
        let folder = root.appendingPathComponent("profiles")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try DCPFixture.make(name: "Push\u{207A}\u{00B9} - S", camera: "Sony ILCE-7").write(to: folder.appendingPathComponent("a.dcp"))
        try DCPFixture.make(name: "Push\u{207A}\u{00B9} - S", camera: "Sony NEX-7").write(to: folder.appendingPathComponent("b.dcp"))
        try DCPFixture.make(name: "Push\u{207A}\u{00B9} - S", camera: "Sony ILCE-7RM3", hueShift: 25, satScale: 1.5).write(to: folder.appendingPathComponent("c.dcp"))
        try Data("junk".utf8).write(to: folder.appendingPathComponent("broken.dcp"))
        let library = CameraProfileLibrary()
        XCTAssertEqual(library.reload(folders: [folder]).count, 3)
        let exact = library.resolver(make: "SONY", model: "ILCE-7RM3").match("Push+1 - S")
        XCTAssertEqual(exact?.entry.camera, "Sony ILCE-7RM3"); XCTAssertEqual(exact?.exact, true)
        let near = library.resolver(make: "SONY", model: "ILCE-7RM4").match("push⁺¹ - s")
        XCTAssertEqual(near?.entry.camera, "Sony ILCE-7RM3"); XCTAssertEqual(near?.exact, false)
        XCTAssertNil(library.resolver(make: "SONY", model: "ILCE-7RM3").match("Stock 400"))
        // Without the ILCE-7RM3's Adobe Standard the look cannot be separated from that camera's calibration:
        // the camera it was made for still gets it, with a note; another camera does not.
        var notes: [String] = []
        let unseparated = library.resolver(make: "SONY", model: "ILCE-7RM3").load("Push+1 - S", notes: &notes)
        XCTAssertNil(unseparated?.baseProfile); XCTAssertTrue(notes.joined().contains("No base profile for Sony ILCE-7RM3"))
        notes = []
        XCTAssertNil(library.resolver(make: "SONY", model: "ILCE-7RM4").load("Push+1 - S", notes: &notes))
        XCTAssertTrue(notes.joined().contains("is for Sony ILCE-7RM3 only"))
        // With it, the profile loads for both, as the look alone.
        try DCPFixture.make(name: "Adobe Standard", camera: "Sony ILCE-7RM3", hueShift: 5, satScale: 1.5).write(to: folder.appendingPathComponent("standard.dcp"))
        XCTAssertEqual(library.reload(folders: [folder]).count, 4)
        XCTAssertEqual(library.base(for: "Sony ILCE-7RM3")?.name, "Adobe Standard"); XCTAssertNil(library.base(for: "Sony ILCE-7RM4"))
        notes = []
        let separated = try XCTUnwrap(library.resolver(make: "SONY", model: "ILCE-7RM3").load("Push+1 - S", notes: &notes))
        XCTAssertEqual(separated.baseProfile, "Adobe Standard"); XCTAssertEqual(notes, [])
        let residual = CameraProfile.floats(separated.hueSatMap1!)
        XCTAssertEqual(residual[0], 20, accuracy: 0.001); XCTAssertEqual(residual[1], 1, accuracy: 0.001)
        XCTAssertEqual(library.separated(try CameraProfile(dcp: folder.appendingPathComponent("c.dcp"))).baseProfile, "Adobe Standard")
        // Sidecar import loads the profile; a missing one clears the previous profile with a note.
        let packet = try XMPPacket(data: Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="\(XMPPacket.rdf)"><rdf:Description xmlns:crs="\(XMPPacket.crs)" crs:CameraProfile="Push⁺¹ - S" crs:LensProfileEnable="0" crs:EnableCalibration="False" crs:AutoTone="False"/></rdf:RDF></x:xmpmeta>
        """.utf8))
        let imported = try XMPCodec.apply(packet, to: Adjustments(), profiles: library.resolver(make: "SONY", model: "ILCE-7RM4"))
        XCTAssertEqual(imported.adjustments.cameraProfile?.camera, "Sony ILCE-7RM3")
        XCTAssertEqual(imported.adjustments.cameraProfile?.baseProfile, "Adobe Standard")
        XCTAssertFalse(imported.adjustments.lensCorrection)
        XCTAssertTrue(imported.adjustments.disabledSections.contains(.calibration))
        XCTAssertFalse(imported.warnings.joined().contains("Unsupported: "))
        XCTAssertTrue(imported.warnings.joined().contains("was made for Sony ILCE-7RM3"))
        var withProfile = Adjustments(); withProfile.cameraProfile = CameraProfile(name: "Old")
        let missing = try XMPCodec.apply(packet, to: withProfile, profiles: CameraProfileResolver(entries: [], make: "", model: ""))
        XCTAssertNil(missing.adjustments.cameraProfile)
        XCTAssertTrue(missing.warnings.joined().contains("not found"))
        // The converter's own profiles are never loaded as looks, even when indexed.
        let standard = try XMPPacket(data: Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="\(XMPPacket.rdf)"><rdf:Description xmlns:crs="\(XMPPacket.crs)" crs:CameraProfile="Adobe Standard"/></rdf:RDF></x:xmpmeta>
        """.utf8))
        let builtIn = try XMPCodec.apply(standard, to: withProfile, profiles: library.resolver(make: "SONY", model: "ILCE-7RM3"))
        XCTAssertNil(builtIn.adjustments.cameraProfile)
        XCTAssertTrue(builtIn.warnings.joined().contains("approximated with default camera color"))
    }

    /// An installed third-party profile whose camera's base profile is indexed, and a library preset that names it.
    static func installedLook(_ index: CameraProfileLibrary) throws -> (profile: CameraProfileEntry, preset: URL) {
        let library = LookLibrary.standard
        _ = index.reload(folders: [library.folder(.profiles)] + CameraProfileLibrary.baseProfileFolders)
        let own = library.folder(.profiles).path
        let candidates = index.entries.filter { $0.path.hasPrefix(own) && !CameraProfileResolver.isBuiltIn($0.name) && index.base(for: $0.camera) != nil }
        guard !candidates.isEmpty else { throw XCTSkip("No installed look profile has its camera's base profile available") }
        let byName = Dictionary(grouping: candidates) { CameraProfileResolver.normalized($0.name) }
        let presets = FileManager.default.enumerator(at: library.folder(.presets), includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "lrtemplate" } ?? []
        for preset in presets {
            guard let text = try? String(contentsOf: preset, encoding: .utf8), let range = text.range(of: "CameraProfile = \"") else { continue }
            let name = String(text[range.upperBound...].prefix { $0 != "\"" })
            if let entry = byName[CameraProfileResolver.normalized(name)]?.first { return (entry, preset) }
        }
        throw XCTSkip("No installed preset names an installed look profile")
    }

    /// Optional: an installed look profile against its camera's base profile from the host converter's folders.
    func testInstalledProfileSeparatesFromItsBase() throws {
        let index = CameraProfileLibrary()
        let (entry, preset) = try Self.installedLook(index)
        let film = try CameraProfile(dcp: entry.url), base = try CameraProfile(dcp: try XCTUnwrap(index.base(for: entry.camera)).url)
        let separated = film.removingBase(base)
        XCTAssertEqual(separated.baseProfile, "Adobe Standard")
        if let map = separated.hueSatMap1 {
            let residual = CameraProfile.floats(map)
            let hues = stride(from: 0, to: residual.count, by: 3).map { residual[$0] }
            let sats = stride(from: 1, to: residual.count, by: 3).map { residual[$0] }
            XCTAssertLessThan(hues.map(abs).max()!, 45); XCTAssertGreaterThan(sats.min()!, 0.1); XCTAssertLessThan(sats.max()!, 10)
        }
        // Through the whole chain: the preset names the profile, and the profile's own camera gets the separated look.
        let words = entry.camera.split(separator: " ", maxSplits: 1).map(String.init)
        let resolver = index.resolver(make: words.first ?? "", model: words.count > 1 ? words[1] : "")
        let (adjustments, notes) = try DevelopPreset.apply(preset, to: Adjustments(), defaults: Adjustments(), profiles: resolver)
        XCTAssertEqual(adjustments.cameraProfile?.baseProfile, "Adobe Standard", notes.joined(separator: "\n"))
        XCTAssertEqual(adjustments.cameraProfile?.camera, entry.camera)
        XCTAssertFalse(notes.joined().contains("was made for"), notes.joined(separator: "\n"))
        // A camera the pack never covered gets the look too, separated, and says so.
        let other = index.resolver(make: words.first ?? "", model: "no such model")
        let (applied, otherNotes) = try DevelopPreset.apply(preset, to: Adjustments(), defaults: Adjustments(), profiles: other)
        XCTAssertEqual(applied.cameraProfile?.baseProfile, "Adobe Standard")
        XCTAssertTrue(otherNotes.joined().contains("was made for \(entry.camera)"), otherNotes.joined(separator: "\n"))
    }

    /// Optional: an installed preset rendered on a sample RAW, with the look separated from the camera.
    func testInstalledPresetRendersOnRAW() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        let index = CameraProfileLibrary()
        let (_, preset) = try Self.installedLook(index)
        let (renderer, settings) = try RawRenderer.open(try Self.sampleRAW())
        let info = renderer.info
        let (applied, notes) = try DevelopPreset.apply(preset, to: settings, defaults: settings, profiles: index.resolver(make: info.make ?? "", model: info.camera))
        let profile = try XCTUnwrap(applied.cameraProfile, notes.joined(separator: "\n"))
        XCTAssertEqual(profile.baseProfile, "Adobe Standard")
        let before = try await Self.channels(renderer, settings)
        var profileOnly = settings; profileOnly.cameraProfile = profile
        let after = try await Self.channels(renderer, profileOnly)
        XCTAssertTrue(after.allSatisfy { $0.isFinite && $0 > 0 && $0 < 1 }, "\(after)")
        // The film curve changes the tone, but the look stays a look: not a blackout or washout.
        XCTAssertGreaterThan(abs(after[1] - before[1]), 0.002, "profile had no effect: \(before) vs \(after)")
        XCTAssertLessThan(abs(after[1] - before[1]), 0.25, "profile is far from the base rendering: \(before) vs \(after)")
        var off = profileOnly; off.cameraProfile?.enabled = false
        let disabled = try await Self.channels(renderer, off)
        XCTAssertEqual(disabled[1], before[1], accuracy: 0.001)
    }

    // MARK: LUT

    func testCubeParsingDomainsAndErrors() throws {
        let identity = try CreativeLUT(cube: Data(identityCube(3, title: "Soft").utf8), name: "file")
        XCTAssertEqual(identity.name, "Soft"); XCTAssertEqual(identity.dimension, 3)
        let values = CameraProfile.floats(identity.cubeData)
        XCTAssertEqual(values[4 * 1], 0.5, accuracy: 0.0001); XCTAssertEqual(values[4 * 26 + 2], 1, accuracy: 0.0001)
        // A domain of 0…2 means grid point 1.0 samples the table's midpoint.
        let wide = try CreativeLUT(cube: Data(("DOMAIN_MIN 0 0 0\nDOMAIN_MAX 2 2 2\n" + identityCube(3)).utf8), name: "wide")
        XCTAssertEqual(CameraProfile.floats(wide.cubeData)[4 * 2], 0.5, accuracy: 0.001)
        let oneD = try CreativeLUT(cube: Data("LUT_1D_SIZE 2\n1 1 1\n0 0 0\n".utf8), name: "invert")
        XCTAssertEqual(oneD.dimension, 33); XCTAssertEqual(CameraProfile.floats(oneD.cubeData)[0], 1, accuracy: 0.0001)
        XCTAssertThrowsError(try CreativeLUT(cube: Data("0 0 0\n".utf8), name: "x"))
        XCTAssertThrowsError(try CreativeLUT(cube: Data("LUT_3D_SIZE 2\n0 0 0\n".utf8), name: "x"))
        XCTAssertThrowsError(try CreativeLUT(cube: Data("LUT_3D_SIZE 200\n".utf8), name: "x"))
        XCTAssertThrowsError(try CreativeLUT(cube: Data([0, 5, 22, 0, 1]), name: "x"))
        var a = Adjustments(); a.lut = identity; a.lut?.amount = 0.4
        let decoded = try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(decoded.lut, a.lut); XCTAssertEqual(decoded.lut?.digest, identity.digest)
        let transferred = try EditTransfer(sourceName: "x", adjustments: a).applying(to: Adjustments())
        XCTAssertEqual(transferred.lut, a.lut)
    }

    /// The landscape RAW from the local samples.
    static func sampleRAW() throws -> URL {
        try TestSamples.require(TestSamples.landscape)
    }

    /// Mean red, green and blue (0…1) of the first 100,000 pixels of a 16-bit preview.
    static func channels(_ renderer: RawRenderer, _ a: Adjustments) async throws -> [Double] {
        let image = try await renderer.preview(a).image
        let data = image.dataProvider!.data! as Data
        var sums = [0.0, 0.0, 0.0]
        let pixels = min(data.count / 8, 100_000)
        data.withUnsafeBytes { bytes in
            let words = bytes.bindMemory(to: UInt16.self)
            for i in stride(from: 0, to: pixels * 4, by: 4) { for c in 0..<3 { sums[c] += Double(words[i + c]) } }
        }
        return sums.map { $0 / Double(pixels) / 65535 }
    }

    func testLUTAndProfileRenderOnRAW() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        let (renderer, settings) = try RawRenderer.open(Self.sampleRAW())
        let base = try await Self.channels(renderer, settings)
        var inverted = settings; inverted.lut = try CreativeLUT(cube: Data(identityCube(2, invert: true).utf8), name: "invert")
        let lutMean = try await Self.channels(renderer, inverted)
        XCTAssertGreaterThan(abs(lutMean[1] - base[1]), 0.04)
        inverted.lut?.enabled = false
        let disabledMean = try await Self.channels(renderer, inverted)
        XCTAssertEqual(disabledMean[1], base[1], accuracy: 0.002)
        // A profile whose curve ends at half white, replacing the default curve, darkens the photo.
        var profiled = settings
        profiled.cameraProfile = try CameraProfile(dcp: DCPFixture.make(name: "Dark", camera: "Test", curve: [0, 0, 0.5, 0.1, 1, 0.5], look: true))
        let profileMean = try await Self.channels(renderer, profiled)
        XCTAssertLessThan(profileMean[1], base[1] - 0.05)
    }

    // MARK: Presets

    func testSavedPresetCarriesOnlyTheEdits() throws {
        let library = LookLibrary(root: root)
        var baseline = Adjustments(); baseline.temperature = 5200
        var edited = baseline
        edited.exposure = 0.7; edited.grain.amount = 30; edited.geometry.crop = CropRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        XCTAssertThrowsError(try DevelopPreset.save(baseline, baseline: baseline, name: "Nothing", in: library))
        let url = try DevelopPreset.save(edited, baseline: baseline, name: "Warm & grainy", in: library)
        XCTAssertEqual(url.path, library.folder(.presets).appendingPathComponent("User Presets/Warm & grainy.xmp").path)
        XCTAssertEqual(try DevelopPreset.save(edited, baseline: baseline, name: "Warm & grainy", in: library).lastPathComponent, "Warm & grainy 2.xmp")
        XCTAssertEqual(try library.tree(.presets).first?.children?.map(\.name), ["Warm & grainy", "Warm & grainy 2"])

        // Other editors get the edited groups alone (Light, Film grain): no white balance, crop or untouched groups.
        let packet = try DevelopPreset.packet(url)
        XCTAssertEqual(packet.value("Name"), "Warm & grainy")
        XCTAssertEqual(packet.value("PresetType"), "Normal")
        XCTAssertEqual(packet.value("Exposure2012"), "0.7")
        XCTAssertEqual(packet.value("GrainAmount"), "30.0")
        for name in ["Temperature", "WhiteBalance", "HasCrop", "CropTop", "Vibrance", "Sharpness", "RawFileName"] { XCTAssertNil(packet.value(name), name) }

        // On another photo, its own white balance, crop and other edits stay.
        var other = Adjustments(); other.temperature = 3400; other.vibrance = 20; other.geometry.crop = CropRect(x: 0, y: 0, width: 0.8, height: 0.8)
        let (applied, notes) = try DevelopPreset.apply(url, to: other, defaults: other)
        XCTAssertTrue(notes.isEmpty)
        var expected = other; expected.exposure = 0.7; expected.grain = edited.grain
        XCTAssertEqual(applied, expected)

        // Edited by another application, the portable fields still apply as a preset.
        let text = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "crs:Exposure2012=\"0.7\"", with: "crs:Exposure2012=\"1.2\"")
        let changed = try write(text, "Presets/changed.xmp")
        let (portable, _) = try DevelopPreset.apply(changed, to: other, defaults: other)
        XCTAssertEqual(portable.exposure, 1.2); XCTAssertEqual(portable.temperature, 3400); XCTAssertEqual(portable.geometry.crop, other.geometry.crop)
    }

    func testLRTemplateConversionAndLenientCurves() throws {
        let url = try write("""
        s = {
            id = "X", internalName = "Max", title = "S - Stock \\"Max\\" ++", type = "Develop",
            value = {
                settings = {
                    CameraProfile = "Missing - SO",
                    Exposure2012 = 0.5, ParametricDarks = 4, ParametricDarks = -7,
                    ConvertToGrayscale = false, EnableSplitToning = false,
                    ToneCurvePV2012 = { 1, 53, 35, 56, 146, 149, 255, 239, },
                    GradientBasedCorrections = { { What = "Correction", CorrectionAmount = 1, CorrectionMasks = { { What = "Mask/Gradient", FullX = 0.5, FullY = 0, ZeroX = 0.5, ZeroY = 1, }, }, LocalExposure2012 = 0.5, }, },
                    LuminanceNoiseReductionDetail = 70,
                },
                uuid = "Y",
            },
            version = 0,
        }
        """, "Presets/test.lrtemplate")
        let packet = try DevelopPreset.packet(url)
        XCTAssertEqual(packet.value("ParametricDarks"), "-7")
        let (a, notes) = try DevelopPreset.apply(url, to: Adjustments(), defaults: Adjustments())
        XCTAssertEqual(a.exposure, 0.5); XCTAssertEqual(a.parametricCurve.darks, -7); XCTAssertEqual(a.luminanceNoiseDetail, 70)
        XCTAssertEqual(a.curve.points.first?.x, 0); XCTAssertEqual(a.curve.points.first?.y ?? 0, 53.0 / 255, accuracy: 1e-9)
        XCTAssertEqual(a.curve.points.last?.x, 1)
        XCTAssertTrue(a.disabledSections.contains(.splitToning))
        XCTAssertEqual(a.masks.count, 1); XCTAssertEqual(a.masks[0].adjustments.exposure, 2, accuracy: 0.0001)
        XCTAssertTrue(notes.joined().contains("Missing - SO"))
        let brush = try write("s = { title = \"Burn\", type = \"LocalizedAdjustmentPreset\", value = { exposure2012 = -0.1, }, }", "Presets/brush.lrtemplate")
        XCTAssertThrowsError(try DevelopPreset.packet(brush))
        XCTAssertTrue(DevelopPreset.isBrushPreset(brush))
        XCTAssertThrowsError(try LRTemplate.packet("s = { value = { settings = { A = } } }"))
    }

    func testPresetKeepsGeometryAndMetadataFromNativeRecipe() throws {
        var source = Adjustments(); source.exposure = 1.2; source.geometry.flipHorizontal = true
        let url = root.appendingPathComponent("native.xmp")
        try XMPCodec.encode(adjustments: source).write(to: url)
        var target = Adjustments(); target.quarterTurns = 2
        let (result, _) = try DevelopPreset.apply(url, to: target, defaults: Adjustments())
        XCTAssertEqual(result.exposure, 1.2); XCTAssertFalse(result.geometry.flipHorizontal); XCTAssertEqual(result.quarterTurns, 2)
    }

    // MARK: Library management

    func testLibraryImportRoutesKindsAndManagesFiles() throws {
        let library = LookLibrary(root: root.appendingPathComponent("Library"))
        let pack = root.appendingPathComponent("Pack")
        _ = try write("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"\(XMPPacket.rdf)\"><rdf:Description xmlns:crs=\"\(XMPPacket.crs)\" crs:Exposure2012=\"1\"/></rdf:RDF></x:xmpmeta>", "Pack/Develop/Sony/Film.xmp")
        _ = try write("s = { title = \"Burn\", type = \"LocalizedAdjustmentPreset\", value = { }, }", "Pack/Local/Burn.lrtemplate")
        try FileManager.default.createDirectory(at: pack.appendingPathComponent("Profiles"), withIntermediateDirectories: true)
        try DCPFixture.make(name: "Film", camera: "Sony ILCE-7").write(to: pack.appendingPathComponent("Profiles/Film.dcp"))
        _ = try write(identityCube(2), "Pack/LUTs/Look.CUBE")
        _ = try write("binary", "Pack/LUTs/._Look.CUBE")
        _ = try write("notes", "Pack/readme.txt")
        let summary = try library.importItems([pack], kind: .presets)
        XCTAssertEqual(summary.copied, [.presets: 1, .profiles: 1, .luts: 1])
        XCTAssertEqual(summary.skipped.count, 1) // The brush preset.
        let presets = try library.tree(.presets)
        XCTAssertEqual(presets.map(\.name), ["Pack"])
        let film = library.folder(.presets).appendingPathComponent("Pack/Develop/Sony/Film.xmp")
        XCTAssertTrue(FileManager.default.fileExists(atPath: film.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.folder(.profiles).appendingPathComponent("Pack/Profiles/Film.dcp").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.folder(.luts).appendingPathComponent("Pack/LUTs/Look.CUBE").path))
        // Importing the same file again gets a Finder-style name.
        _ = try library.importItems([pack.appendingPathComponent("Develop/Sony/Film.xmp")], kind: .presets)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.folder(.presets).appendingPathComponent("Film.xmp").path))
        _ = try library.importItems([pack.appendingPathComponent("Develop/Sony/Film.xmp")], kind: .presets)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.folder(.presets).appendingPathComponent("Film 2.xmp").path))
        // Rename keeps the extension; invalid names are rejected.
        let renamed = try library.rename(film, to: "Stock")
        XCTAssertEqual(renamed.lastPathComponent, "Stock.xmp")
        XCTAssertThrowsError(try library.rename(renamed, to: "../escape"))
        XCTAssertThrowsError(try library.rename(renamed, to: ".hidden"))
        // Move into a new folder, but never into itself or across kinds.
        let folder = try library.newFolder(in: library.folder(.presets), name: "Favorites")
        let moved = try library.move([renamed], into: folder)
        XCTAssertEqual(moved.first?.deletingLastPathComponent().lastPathComponent, "Favorites")
        let packFolder = library.folder(.presets).appendingPathComponent("Pack")
        XCTAssertThrowsError(try library.move([packFolder], into: packFolder.appendingPathComponent("Develop")))
        XCTAssertThrowsError(try library.move([moved[0]], into: library.folder(.luts)))
        XCTAssertThrowsError(try library.trash([library.folder(.presets)]))
        XCTAssertThrowsError(try library.rename(root.appendingPathComponent("Pack/readme.txt"), to: "x"))
        try library.trash([folder])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertThrowsError(try library.importItems([pack], kind: .presets, into: root))
    }
}
