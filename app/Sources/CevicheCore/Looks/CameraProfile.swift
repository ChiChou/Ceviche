import Foundation
import CoreImage

/// The look-defining parts of a DNG camera profile (DCP): hue/saturation map,
/// look table and profile tone curve. Camera calibration matrices are deliberately not
/// used; Apple's RAW decoder supplies colorimetric RGB and these tables are applied
/// to it in linear ProPhoto RGB. This approximates, but does not reproduce, the rendering of the converter a profile was made for.
///
/// A third-party look profile is typically the camera's Adobe Standard profile with a
/// changed hue/saturation map and its own tone curve, so its tables carry that calibration of
/// that camera as well as the look. Apple's decoder already calibrates the camera, so when the
/// Adobe Standard profile is available the tables are stored as the difference from it
/// (`removingBase`), and only the look is applied.
public struct CameraProfile: Codable, Equatable, Sendable {
    public var name: String
    /// The DCP's UniqueCameraModel; the look is applied to any camera.
    public var camera: String
    /// Scales the tables toward identity and the tone curve toward the DNG default.
    public var amount = 1.0
    public var enabled = true
    /// The profile whose tables were subtracted from this one's, when that was possible.
    public var baseProfile: String?
    var illuminants: [Int] = []
    /// Hue, saturation and value divisions.
    var hueSatDimensions: [Int]?
    var hueSatMap1: Data?
    var hueSatMap2: Data?
    var hueSatSRGB = false
    var lookDimensions: [Int]?
    var lookTable: Data?
    var lookSRGB = false
    /// Linear input/output pairs.
    var toneCurve: [Double]?
    var exposureOffset = 0.0
    /// A chart profile's correction of the decoder's colour, applied to scene-linear light before any tone: a 3 × 3
    /// in linear ProPhoto (row-major) and a hue/saturation map over it with one value division
    /// (`calibrationDimensions`). Fitted on Apple's decode of a colour chart, so it holds for that camera in that
    /// light.
    var calibrationMatrix: [Double]?
    var calibrationDimensions: [Int]?
    var calibrationMap: Data?
    /// The chart photo's white balance in kelvin: the light the correction was made for.
    public var calibrationTemperature: Double?
    /// The separated look file this profile was read from; storing a development writes one when it is nil.
    public var source: ResourceReference?

    public var hasToneCurve: Bool { (toneCurve?.count ?? 0) >= 4 }
    public var hasTables: Bool { hueSatMap1 != nil || lookTable != nil }
    public var hasCalibration: Bool { calibrationMatrix != nil }
    /// A chart profile is worth using within this distance of its light, in mired: 170–200 away it is worse than no
    /// profile at all.
    public static let calibrationReach = 100.0
    /// Whether a chart profile suits a photo developed at `temperature`; true for every other profile.
    public func suits(temperature: Double) -> Bool {
        guard let light = calibrationTemperature, light > 0, temperature > 0 else { return true }
        return abs(1e6 / light - 1e6 / temperature) <= Self.calibrationReach
    }
    /// Equal when they render the same; which file the look was read from does not count.
    public static func == (a: Self, b: Self) -> Bool {
        a.name == b.name && a.camera == b.camera && a.amount == b.amount && a.enabled == b.enabled && a.baseProfile == b.baseProfile
            && a.illuminants == b.illuminants && a.hueSatDimensions == b.hueSatDimensions && a.hueSatMap1 == b.hueSatMap1 && a.hueSatMap2 == b.hueSatMap2
            && a.hueSatSRGB == b.hueSatSRGB && a.lookDimensions == b.lookDimensions && a.lookTable == b.lookTable && a.lookSRGB == b.lookSRGB
            && a.toneCurve == b.toneCurve && a.exposureOffset == b.exposureOffset
            && a.calibrationMatrix == b.calibrationMatrix && a.calibrationDimensions == b.calibrationDimensions && a.calibrationMap == b.calibrationMap
            && a.calibrationTemperature == b.calibrationTemperature
    }

    public init(name: String, camera: String = "") { self.name = name; self.camera = camera }

    func validate() throws {
        guard name.count <= 200, camera.count <= 200, (baseProfile?.count ?? 0) <= 200 else { throw EditorError.invalidDocument(L10n.tr("Invalid camera profile name.")) }
        try check([amount], in: 0...1); try check([exposureOffset], in: -10...10)
        func table(_ dimensions: [Int]?, _ data: Data?) throws {
            guard let data else { return }
            guard let d = dimensions, d.count == 3, (1...360).contains(d[0]), (2...256).contains(d[1]), (1...256).contains(d[2]),
                  data.count == d[0] * d[1] * d[2] * 12 else { throw EditorError.invalidDocument(L10n.tr("Invalid camera profile table.")) }
            let values = Self.floats(data)
            guard values.allSatisfy(\.isFinite) else { throw EditorError.invalidDocument(L10n.tr("Invalid camera profile table.")) }
        }
        try table(hueSatDimensions, hueSatMap1); try table(hueSatDimensions, hueSatMap2); try table(lookDimensions, lookTable)
        try table(calibrationDimensions, calibrationMap)
        if let matrix = calibrationMatrix {
            guard matrix.count == 9, matrix.allSatisfy({ $0.isFinite && abs($0) <= 16 }) else { throw EditorError.invalidDocument(L10n.tr("Invalid camera profile table.")) }
        }
        if calibrationMap != nil, calibrationMatrix == nil || calibrationDimensions?[2] != 1 { throw EditorError.invalidDocument(L10n.tr("Invalid camera profile table.")) }
        if let light = calibrationTemperature { try check([light], in: 1000...50_000) }
        if hueSatMap2 != nil && hueSatMap1 == nil { throw EditorError.invalidDocument(L10n.tr("Invalid camera profile table.")) }
        if let curve = toneCurve {
            guard curve.count >= 4, curve.count <= 8192, curve.count % 2 == 0, curve.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                  stride(from: 2, to: curve.count, by: 2).allSatisfy({ curve[$0] > curve[$0 - 2] }) else {
                throw EditorError.invalidDocument(L10n.tr("Invalid camera profile tone curve."))
            }
        }
    }

    /// Tables are stored little-endian, matching every Mac that runs Ceviche.
    static func floats(_ data: Data) -> [Float] {
        var values = [Float](repeating: 0, count: data.count / 4)
        _ = values.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return values
    }
    static func data(_ values: [Float]) -> Data { values.withUnsafeBytes { Data($0) } }
}

// MARK: - DCP parsing

extension CameraProfile {
    public static let maxFileBytes = 16 * 1024 * 1024

    public init(dcp url: URL) throws {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= Self.maxFileBytes else { throw EditorError.invalidDocument(L10n.tr("Camera profile exceeds 16 MB.")) }
        try self.init(dcp: Data(contentsOf: url))
    }

    public init(dcp data: Data) throws {
        let file = try DCPFile(data)
        name = file.string(50936) ?? L10n.tr("Camera profile")
        camera = file.string(50708) ?? ""
        illuminants = [file.integers(50778)?.first, file.integers(50779)?.first].compactMap { $0 }
        if let dims = file.integers(50937), dims.count == 3 {
            hueSatDimensions = dims
            hueSatMap1 = file.floats(50938).map(Self.data)
            hueSatMap2 = file.floats(50939).map(Self.data)
            if hueSatMap1 == nil, let second = hueSatMap2 { hueSatMap1 = second; hueSatMap2 = nil }
        }
        if let dims = file.integers(50981), dims.count == 3 {
            lookDimensions = dims
            lookTable = file.floats(50982).map(Self.data)
        }
        hueSatSRGB = file.integers(51107)?.first == 1
        lookSRGB = file.integers(51108)?.first == 1
        if let curve = file.floats(50940) { toneCurve = curve.map { min(1, max(0, Double($0))) } }
        exposureOffset = file.rationals(51109)?.first ?? 0
        if hueSatMap1 == nil { hueSatDimensions = nil }
        if lookTable == nil { lookDimensions = nil }
        if let matrix = file.floats(Self.calibrationMatrixTag), matrix.count == 9 {
            calibrationMatrix = matrix.map(Double.init)
            calibrationTemperature = file.floats(Self.calibrationLightTag)?.first.map(Double.init)
            if let dims = file.integers(Self.calibrationDimensionsTag), dims.count == 3, let map = file.floats(Self.calibrationMapTag) {
                calibrationDimensions = dims; calibrationMap = Self.data(map)
            }
        }
        try validate()
    }

    /// Private tags of a chart profile file: a DNG camera profile holds camera-native matrices, which a correction
    /// of Apple's decode is not, so other converters see a profile with a name and no tables.
    static let calibrationMatrixTag = 65_001, calibrationDimensionsTag = 65_002, calibrationMapTag = 65_003, calibrationLightTag = 65_004

    /// The profile as a DNG camera profile file with its calibration in the private tags.
    public func calibrationFile() -> Data {
        enum Value { case ascii(String), long([UInt32]), float([Float]) }
        var entries: [(UInt16, Value)] = [(50708, .ascii(camera)), (50936, .ascii(name)), (50941, .long([3]))]
        if let matrix = calibrationMatrix { entries.append((UInt16(Self.calibrationMatrixTag), .float(matrix.map(Float.init)))) }
        if let dims = calibrationDimensions, let map = calibrationMap {
            entries.append((UInt16(Self.calibrationDimensionsTag), .long(dims.map(UInt32.init))))
            entries.append((UInt16(Self.calibrationMapTag), .float(Self.floats(map))))
        }
        if let light = calibrationTemperature { entries.append((UInt16(Self.calibrationLightTag), .float([Float(light)]))) }
        entries.sort { $0.0 < $1.0 }
        func u16(_ v: UInt16, _ d: inout Data) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u32(_ v: UInt32, _ d: inout Data) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        // "IIRC": a little-endian DNG camera profile, its directory right after the header.
        var data = Data([0x49, 0x49, 0x52, 0x43])
        u32(8, &data)
        let directorySize = 2 + entries.count * 12 + 4
        var payload = Data(), directory = Data()
        u16(UInt16(entries.count), &directory)
        for (tag, value) in entries {
            var bytes = Data(), type: UInt16, count: UInt32
            switch value {
            case .ascii(let text): bytes = Data(text.utf8) + [0]; type = 2; count = UInt32(bytes.count)
            case .long(let values): values.forEach { u32($0, &bytes) }; type = 4; count = UInt32(values.count)
            case .float(let values): values.forEach { u32($0.bitPattern, &bytes) }; type = 11; count = UInt32(values.count)
            }
            u16(tag, &directory); u16(type, &directory); u32(count, &directory)
            if bytes.count <= 4 {
                directory.append(bytes); directory.append(Data(count: 4 - bytes.count))
            } else {
                u32(UInt32(8 + directorySize + payload.count), &directory)
                payload.append(bytes)
                if payload.count % 2 == 1 { payload.append(0) }
            }
        }
        u32(0, &directory)
        return data + directory + payload
    }

    /// Reads only the identifying tags, for fast indexing of large profile folders.
    static func identity(_ url: URL) throws -> (name: String, camera: String, light: Double?) {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let file = try DCPFile(data)
        guard let name = file.string(50936) else { throw EditorError.invalidDocument(L10n.tr("Camera profile has no name.")) }
        return (name, file.string(50708) ?? "", file.floats(calibrationLightTag)?.first.map(Double.init))
    }
}

// MARK: - Separating a look from its base profile

extension CameraProfile {
    /// This profile with `base`'s tables divided out, leaving the look that was built on top of
    /// them: hue shifts become differences, saturation and value scales become ratios, sampled on
    /// this profile's grid. A look table identical to the base's is dropped. The tone curve stays
    /// as it is; the renderer already replaces the DNG default curve with it.
    public func removingBase(_ base: CameraProfile) -> CameraProfile {
        var result = self
        result.baseProfile = base.name
        if let dims = hueSatDimensions, let first = hueSatMap1, let baseDims = base.hueSatDimensions, let baseFirst = base.hueSatMap1 {
            // Pair maps by illuminant; a base with one map serves both.
            func baseMap(for illuminant: Int?) -> Data {
                if let second = base.hueSatMap2, base.illuminants.count == 2, let illuminant, base.illuminants[1] == illuminant, base.illuminants[0] != illuminant { return second }
                return baseFirst
            }
            result.hueSatMap1 = Self.residual(first, dims, sRGB: hueSatSRGB, over: baseMap(for: illuminants.first), baseDims, baseSRGB: base.hueSatSRGB)
            if let second = hueSatMap2 {
                result.hueSatMap2 = Self.residual(second, dims, sRGB: hueSatSRGB, over: baseMap(for: illuminants.count > 1 ? illuminants[1] : nil), baseDims, baseSRGB: base.hueSatSRGB)
            }
        }
        if let dims = lookDimensions, let table = lookTable, let baseDims = base.lookDimensions, let baseTable = base.lookTable {
            let residual = Self.residual(table, dims, sRGB: lookSRGB, over: baseTable, baseDims, baseSRGB: base.lookSRGB)
            if Self.isIdentity(residual) { result.lookTable = nil; result.lookDimensions = nil } else { result.lookTable = residual }
        }
        return result
    }

    /// `table` relative to `base`, node by node: the base is sampled at each node of `table`'s grid.
    static func residual(_ table: Data, _ dims: [Int], sRGB: Bool, over base: Data, _ baseDims: [Int], baseSRGB: Bool) -> Data {
        let values = floats(table), baseValues = floats(base)
        let hueDivisions = dims[0], satDivisions = dims[1], valDivisions = dims[2]
        var out = values
        for v in 0..<valDivisions { for h in 0..<hueDivisions { for s in 0..<satDivisions {
            let hue = Float(h) / Float(hueDivisions) * 6
            let sat = Float(s) / Float(satDivisions - 1)
            // Value nodes are spaced in the table's own encoding; the base is sampled in its encoding.
            var value: Float = valDivisions < 2 ? 1 : Float(v) / Float(valDivisions - 1)
            if valDivisions > 1, sRGB != baseSRGB { value = sRGB ? CameraProfileRenderer.srgbDecode(value) : CameraProfileRenderer.srgbEncode(value) }
            let reference = CameraProfileRenderer.sample(baseValues, baseDims, hue: hue, sat: sat, value: value)
            let i = ((v * hueDivisions + h) * satDivisions + s) * 3
            out[i] = values[i] - reference.x
            out[i + 1] = values[i + 1] / max(1e-4, reference.y)
            out[i + 2] = values[i + 2] / max(1e-4, reference.z)
        } } }
        return data(out)
    }

    static func isIdentity(_ table: Data) -> Bool {
        let values = floats(table)
        return stride(from: 0, to: values.count, by: 3).allSatisfy { abs(values[$0]) < 0.01 && abs(values[$0 + 1] - 1) < 0.001 && abs(values[$0 + 2] - 1) < 0.001 }
    }
}

/// A minimal TIFF directory reader for DNG camera profiles ("IIRC"/"MMCR" magic).
struct DCPFile {
    struct Entry { let type: Int; let count: Int; let offset: Int }
    let data: Data
    let little: Bool
    var entries: [Int: Entry] = [:]

    init(_ data: Data) throws {
        self.data = data
        guard data.count >= 8 else { throw EditorError.invalidDocument(L10n.tr("Not a DNG camera profile.")) }
        let order = [data[data.startIndex], data[data.startIndex + 1]]
        if order == [0x49, 0x49] { little = true } else if order == [0x4D, 0x4D] { little = false } else { throw EditorError.invalidDocument(L10n.tr("Not a DNG camera profile.")) }
        let magic = Self.read16(data, 2, little)
        guard magic == 0x4352 || magic == 42 else { throw EditorError.invalidDocument(L10n.tr("Not a DNG camera profile.")) }
        let ifd = Int(Self.read32(data, 4, little))
        guard ifd + 2 <= data.count else { throw EditorError.invalidDocument(L10n.tr("Damaged camera profile.")) }
        let count = Int(Self.read16(data, ifd, little))
        guard count <= 1000, ifd + 2 + count * 12 <= data.count else { throw EditorError.invalidDocument(L10n.tr("Damaged camera profile.")) }
        for index in 0..<count {
            let base = ifd + 2 + index * 12
            let tag = Int(Self.read16(data, base, little)), type = Int(Self.read16(data, base + 2, little))
            let items = Int(Self.read32(data, base + 4, little))
            let size = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8][type] ?? 0
            guard size > 0, items >= 0, items <= data.count else { continue }
            let offset = size * items <= 4 ? base + 8 : Int(Self.read32(data, base + 8, little))
            guard offset >= 0, offset + size * items <= data.count else { throw EditorError.invalidDocument(L10n.tr("Damaged camera profile.")) }
            entries[tag] = Entry(type: type, count: items, offset: offset)
        }
    }
    static func read16(_ d: Data, _ o: Int, _ little: Bool) -> UInt16 {
        let a = UInt16(d[d.startIndex + o]), b = UInt16(d[d.startIndex + o + 1])
        return little ? a | b << 8 : a << 8 | b
    }
    static func read32(_ d: Data, _ o: Int, _ little: Bool) -> UInt32 {
        let bytes = (0..<4).map { UInt32(d[d.startIndex + o + $0]) }
        return little ? bytes[0] | bytes[1] << 8 | bytes[2] << 16 | bytes[3] << 24 : bytes[0] << 24 | bytes[1] << 16 | bytes[2] << 8 | bytes[3]
    }
    func string(_ tag: Int) -> String? {
        guard let e = entries[tag], e.type == 2 || e.type == 1 || e.type == 7 else { return nil }
        let bytes = data.subdata(in: data.startIndex + e.offset..<data.startIndex + e.offset + e.count).prefix { $0 != 0 }
        let text = String(data: Data(bytes), encoding: .utf8) ?? String(data: Data(bytes), encoding: .isoLatin1)
        return text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
    func integers(_ tag: Int) -> [Int]? {
        guard let e = entries[tag] else { return nil }
        switch e.type {
        case 3: return (0..<e.count).map { Int(Self.read16(data, e.offset + $0 * 2, little)) }
        case 4: return (0..<e.count).map { Int(Self.read32(data, e.offset + $0 * 4, little)) }
        default: return nil
        }
    }
    func floats(_ tag: Int) -> [Float]? {
        guard let e = entries[tag], e.type == 11 else { return nil }
        let start = data.startIndex + e.offset
        var words = [UInt32](repeating: 0, count: e.count)
        _ = words.withUnsafeMutableBytes { data.copyBytes(to: $0, from: start..<start + e.count * 4) }
        return words.map { Float(bitPattern: little ? UInt32(littleEndian: $0) : UInt32(bigEndian: $0)) }
    }
    func rationals(_ tag: Int) -> [Double]? {
        guard let e = entries[tag], e.type == 10 || e.type == 5 else { return nil }
        return (0..<e.count).map { i in
            let n = Self.read32(data, e.offset + i * 8, little), d = Self.read32(data, e.offset + i * 8 + 4, little)
            let num = e.type == 10 ? Double(Int32(bitPattern: n)) : Double(n), den = e.type == 10 ? Double(Int32(bitPattern: d)) : Double(d)
            return den == 0 ? 0 : num / den
        }
    }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }

// MARK: - Rendering

/// Bakes profile tables into a ROMM (ProPhoto) RGB color cube.
///
/// A DNG converter applies a profile's hue/saturation map to scene-linear values and the look table and
/// tone curve after the Basic tone controls, where Apple's decoder has already applied its own tone
/// response. The cube treats Apple's output as if the DNG default curve had produced it: it
/// undoes that curve, applies the tables, and reapplies the profile's own curve, or the default when
/// the profile has none. A profile with neither tables nor a curve renders unchanged.
final class CameraProfileRenderer {
    static let dimension = 48
    private var cached: (key: CacheKey, data: Data)?
    private struct CacheKey: Equatable { let profile: CameraProfile; let weight: Int }
    private static let space = CGColorSpace(name: CGColorSpace.rommrgb)!

    /// Applies the profile's tables and tone curve. Its baseline exposure offset is not used.
    func apply(_ profile: CameraProfile, to image: CIImage, temperature: Double, hdr: Bool) -> CIImage {
        guard profile.enabled, profile.hasTables || profile.hasToneCurve, profile.amount > 0 else { return image }
        // Quantized so white balance drags do not rebuild the cube for imperceptible changes.
        let weight = Int((Self.mapWeight(profile, temperature: temperature) * 20).rounded())
        let key = CacheKey(profile: profile, weight: weight)
        if cached?.key != key { cached = (key, Self.cube(profile, weight: Double(weight) / 20)) }
        let data = cached!.data
        return HDRRenderer.bounded(image, enabled: hdr) {
            $0.applyingFilter("CIColorCubeWithColorSpace", parameters: ["inputCubeDimension": Self.dimension, "inputCubeData": data, "inputColorSpace": Self.space])
        }
    }

    /// DNG interpolation between the two calibration maps, in inverse temperature.
    static func mapWeight(_ profile: CameraProfile, temperature: Double) -> Double {
        guard profile.hueSatMap2 != nil, profile.illuminants.count == 2 else { return 1 }
        let t1 = illuminantTemperature(profile.illuminants[0]), t2 = illuminantTemperature(profile.illuminants[1])
        guard t1 != t2 else { return 1 }
        let w = (1 / max(1000, temperature) - 1 / t2) / (1 / t1 - 1 / t2)
        return min(1, max(0, w))
    }
    static func illuminantTemperature(_ code: Int) -> Double {
        switch code {
        case 17, 3: return 2856
        case 24: return 3200
        case 15: return 3450
        case 2, 14: return 4150
        case 13: return 4600
        case 18: return 4874
        case 23: return 5003
        case 1, 4, 9, 20: return 5503
        case 12: return 6430
        case 10, 21: return 6504
        case 19: return 6774
        case 11, 22: return 7504
        default: return 5003
        }
    }

    static func cube(_ profile: CameraProfile, weight: Double) -> Data {
        let n = dimension
        let hueSat = profile.hueSatMap1.map { first -> [Float] in
            let a = CameraProfile.floats(first)
            guard let second = profile.hueSatMap2 else { return a }
            let b = CameraProfile.floats(second), w = Float(weight)
            return zip(a, b).map { $0 * w + $1 * (1 - w) }
        }
        let look = profile.lookTable.map(CameraProfile.floats)
        let curve = profile.toneCurve.map(MonotoneCurve.init)
        let amount = Float(profile.amount)
        // The profile's curve at the amount, blended with the default it replaces.
        let tone: (Float) -> Float = { x in
            let base = DNGDefaultToneCurve.value(x)
            guard let curve else { return base }
            return base * (1 - amount) + curve.value(x) * amount
        }
        var values = [Float](repeating: 1, count: n * n * n * 4)
        // Blue planes are independent, so they are filled on every core.
        values.withUnsafeMutableBufferPointer { buffer in
            let out = buffer
            DispatchQueue.concurrentPerform(iterations: n) { b in
                for g in 0..<n { for r in 0..<n {
                    var rgb = SIMD3<Float>(Float(r), Float(g), Float(b)) / Float(n - 1)
                    rgb = SIMD3(rommDecode(rgb.x), rommDecode(rgb.y), rommDecode(rgb.z))
                    rgb = baseTone(rgb, DNGDefaultToneCurve.inverse)
                    if let hueSat, let dims = profile.hueSatDimensions { rgb = applyMap(rgb, hueSat, dims, sRGB: profile.hueSatSRGB, amount: amount) }
                    if let look, let dims = profile.lookDimensions { rgb = applyMap(rgb, look, dims, sRGB: profile.lookSRGB, amount: amount) }
                    rgb = baseTone(rgb, tone)
                    let i = ((b * n + g) * n + r) * 4
                    out[i] = rommEncode(rgb.x); out[i + 1] = rommEncode(rgb.y); out[i + 2] = rommEncode(rgb.z)
                } }
            }
        }
        return values.withUnsafeBytes { Data($0) }
    }

    static func rommDecode(_ v: Float) -> Float { v < 1.0 / 32 ? v / 16 : pow(v, 1.8) }
    static func rommEncode(_ v: Float) -> Float { let c = min(1, max(0, v)); return c < 1.0 / 512 ? c * 16 : pow(c, 1 / 1.8) }
    static func srgbEncode(_ v: Float) -> Float { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }
    static func srgbDecode(_ v: Float) -> Float { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }

    /// The table's hue shift and saturation/value scales at a hue (0…6), saturation and value (the
    /// value in the table's own encoding), with hue wrapping and trilinear interpolation.
    static func sample(_ table: [Float], _ dims: [Int], hue h: Float, sat s: Float, value: Float) -> SIMD3<Float> {
        let hueDivisions = dims[0], satDivisions = dims[1], valDivisions = dims[2]
        let hScaled = hueDivisions < 2 ? 0 : h * Float(hueDivisions) / 6
        let sScaled = min(1, max(0, s)) * Float(satDivisions - 1)
        let vScaled = valDivisions < 2 ? 0 : min(1, max(0, value)) * Float(valDivisions - 1)
        var h0 = Int(hScaled), h1 = h0 + 1
        if h0 >= hueDivisions - 1 { h0 = max(0, hueDivisions - 1); h1 = 0 }
        let s0 = min(Int(sScaled), satDivisions - 2), v0 = valDivisions < 2 ? 0 : min(Int(vScaled), valDivisions - 2)
        let hf = hScaled - Float(Int(hScaled)), sf = sScaled - Float(s0), vf = vScaled - Float(v0)
        func entry(_ hi: Int, _ si: Int, _ vi: Int) -> SIMD3<Float> {
            let i = ((vi * hueDivisions + hi) * satDivisions + si) * 3
            return SIMD3(table[i], table[i + 1], table[i + 2])
        }
        func plane(_ vi: Int) -> SIMD3<Float> {
            let a = entry(h0, s0, vi) * (1 - sf) + entry(h0, s0 + 1, vi) * sf
            let b = entry(h1 % max(1, hueDivisions), s0, vi) * (1 - sf) + entry(h1 % max(1, hueDivisions), s0 + 1, vi) * sf
            return hueDivisions < 2 ? a : a * (1 - hf) + b * hf
        }
        var delta = plane(v0)
        if valDivisions > 1 { delta = delta * (1 - vf) + plane(v0 + 1) * vf }
        return delta
    }

    /// DNG HueSatMap/LookTable: hue shift in degrees and saturation/value scales, sampled in HSV.
    /// Value may leave 0…1; the tone curve that follows clips it.
    static func applyMap(_ rgb: SIMD3<Float>, _ table: [Float], _ dims: [Int], sRGB: Bool, amount: Float) -> SIMD3<Float> {
        var (h, s, v) = hsv(rgb)
        let delta = sample(table, dims, hue: h, sat: s, value: sRGB ? srgbEncode(min(1, v)) : v)
        let hueShift = delta.x * amount / 60
        let satScale = pow(max(0, delta.y), amount), valScale = pow(max(0, delta.z), amount)
        h += hueShift
        if h < 0 { h += 6 } else if h >= 6 { h -= 6 }
        s = min(1, s * satScale); v = max(0, v * valScale)
        return rgbFromHSV(h, s, v)
    }
    static func hsv(_ c: SIMD3<Float>) -> (Float, Float, Float) {
        let v = max(c.x, max(c.y, c.z)), gap = v - min(c.x, min(c.y, c.z))
        guard gap > 0, v > 0 else { return (0, 0, v) }
        var h: Float
        if c.x == v { h = (c.y - c.z) / gap; if h < 0 { h += 6 } }
        else if c.y == v { h = 2 + (c.z - c.x) / gap }
        else { h = 4 + (c.x - c.y) / gap }
        return (h, gap / v, v)
    }
    static func rgbFromHSV(_ h: Float, _ s: Float, _ v: Float) -> SIMD3<Float> {
        guard s > 0 else { return SIMD3(repeating: v) }
        let i = min(5, Int(h)), f = h - Float(i)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch i {
        case 0: return SIMD3(v, t, p)
        case 1: return SIMD3(q, v, p)
        case 2: return SIMD3(p, v, t)
        case 3: return SIMD3(p, q, v)
        case 4: return SIMD3(t, p, v)
        default: return SIMD3(v, p, q)
        }
    }
    static func baseTone(_ c: SIMD3<Float>, _ curve: MonotoneCurve) -> SIMD3<Float> { baseTone(c, curve.value) }
    /// The DNG SDK's hue-preserving RGB tone: map the largest and smallest channels and
    /// interpolate the middle channel between them.
    static func baseTone(_ c: SIMD3<Float>, _ curve: (Float) -> Float) -> SIMD3<Float> {
        let x = SIMD3(min(1, max(0, c.x)), min(1, max(0, c.y)), min(1, max(0, c.z)))
        let hi = max(x.x, max(x.y, x.z)), lo = min(x.x, min(x.y, x.z))
        let hiOut = curve(hi), loOut = curve(lo)
        guard hi > lo else { return SIMD3(repeating: hiOut) }
        func mapped(_ v: Float) -> Float { v == hi ? hiOut : v == lo ? loOut : loOut + (hiOut - loOut) * (v - lo) / (hi - lo) }
        return SIMD3(mapped(x.x), mapped(x.y), mapped(x.z))
    }
}

/// Fritsch–Carlson monotone cubic interpolation through ordered points.
struct MonotoneCurve {
    let xs: [Float], ys: [Float], slopes: [Float]
    init(_ pairs: [Double]) {
        xs = stride(from: 0, to: pairs.count, by: 2).map { Float(pairs[$0]) }
        ys = stride(from: 1, to: pairs.count, by: 2).map { Float(pairs[$0]) }
        let n = xs.count
        var secants = [Float](repeating: 0, count: max(0, n - 1))
        for i in 0..<max(0, n - 1) { secants[i] = (ys[i + 1] - ys[i]) / max(1e-9, xs[i + 1] - xs[i]) }
        var m = [Float](repeating: 0, count: n)
        if n > 1 {
            m[0] = secants[0]; m[n - 1] = secants[n - 2]
            for i in stride(from: 1, to: n - 1, by: 1) { m[i] = secants[i - 1] * secants[i] <= 0 ? 0 : (secants[i - 1] + secants[i]) / 2 }
            for i in 0..<(n - 1) where secants[i] == 0 { m[i] = 0; m[i + 1] = 0 }
            for i in 0..<(n - 1) where secants[i] != 0 {
                let a = m[i] / secants[i], b = m[i + 1] / secants[i], t = a * a + b * b
                if t > 9 { let k = 3 / t.squareRoot(); m[i] = k * a * secants[i]; m[i + 1] = k * b * secants[i] }
            }
        }
        slopes = m
    }
    func value(_ x: Float) -> Float {
        guard let first = xs.first, let last = xs.last else { return x }
        if x <= first { return ys[0] }
        if x >= last { return ys[ys.count - 1] }
        var lo = 0, hi = xs.count - 1
        while hi - lo > 1 { let mid = (lo + hi) / 2; if xs[mid] <= x { lo = mid } else { hi = mid } }
        let h = xs[hi] - xs[lo], t = (x - xs[lo]) / h, t2 = t * t, t3 = t2 * t
        return (2 * t3 - 3 * t2 + 1) * ys[lo] + (t3 - 2 * t2 + t) * h * slopes[lo] + (-2 * t3 + 3 * t2) * ys[hi] + (t3 - t2) * h * slopes[hi]
    }
}

// MARK: - Profile folders

public struct CameraProfileEntry: Codable, Hashable, Sendable {
    public let path: String
    public let name: String
    public let camera: String
    /// A chart profile's light in kelvin; nil for every other profile.
    public var light: Double?
    public var url: URL { URL(fileURLWithPath: path) }
}

/// Indexes user-chosen folders of DCP files. Profiles are user assets and are never bundled.
public final class CameraProfileLibrary: @unchecked Sendable {
    public static let shared = CameraProfileLibrary()
    private let lock = NSLock()
    private var indexed: [CameraProfileEntry] = []
    private var byName: [String: [CameraProfileEntry]] = [:]
    public init() {}

    /// Where the host converter keeps its camera profiles. Read for each camera's
    /// Adobe Standard profile, the base that third-party looks are built on; nothing is copied from them.
    public static var baseProfileFolders: [URL] {
        let user = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
        return [URL(fileURLWithPath: "/Library/Application Support/Adobe/CameraRaw/CameraProfiles", isDirectory: true),
                user?.appendingPathComponent("Application Support/Adobe/CameraRaw/CameraProfiles", isDirectory: true)].compactMap { $0 }
    }

    public var entries: [CameraProfileEntry] { lock.withLock { indexed } }

    /// The Adobe Standard profile made for the same camera as `camera` names, if indexed.
    public func base(for camera: String) -> CameraProfileEntry? {
        let key = CameraProfileResolver.normalized(camera)
        guard !key.isEmpty else { return nil }
        return lock.withLock { byName["adobe standard"] }?.first { CameraProfileResolver.normalized($0.camera) == key }
    }

    /// `profile` with its camera's Adobe Standard tables removed, when that profile is indexed and
    /// readable; otherwise unchanged, with `baseProfile` nil.
    public func separated(_ profile: CameraProfile) -> CameraProfile {
        guard profile.baseProfile == nil, profile.hasTables, let entry = base(for: profile.camera),
              let base = try? CameraProfile(dcp: entry.url) else { return profile }
        return profile.removingBase(base)
    }

    /// Recursively scans folders, reading only each profile's identifying tags.
    @discardableResult
    public func reload(folders: [URL]) -> [CameraProfileEntry] {
        var found: [CameraProfileEntry] = []
        var seen = Set<String>()
        for folder in folders {
            guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker where url.pathExtension.lowercased() == "dcp" {
                let path = url.resolvingSymlinksInPath().path
                guard seen.insert(path).inserted, let identity = try? CameraProfile.identity(url) else { continue }
                found.append(CameraProfileEntry(path: path, name: identity.name, camera: identity.camera, light: identity.light))
            }
        }
        found.sort { ($0.name, $0.camera, $0.path) < ($1.name, $1.camera, $1.path) }
        let names = Dictionary(grouping: found) { CameraProfileResolver.normalized($0.name) }
        lock.withLock { indexed = found; byName = names }
        return found
    }

    public func resolver(make: String, model: String) -> CameraProfileResolver {
        let names = lock.withLock { byName }
        return CameraProfileResolver(byName: names, make: make, model: model)
    }
}

/// Matches a profile name from a preset or sidecar against indexed DCP files.
public struct CameraProfileResolver: Sendable {
    /// Entries grouped by normalized profile name.
    let byName: [String: [CameraProfileEntry]]
    public let make: String
    public let model: String
    public init(entries: [CameraProfileEntry], make: String, model: String) {
        self.init(byName: Dictionary(grouping: entries) { Self.normalized($0.name) }, make: make, model: model)
    }
    init(byName: [String: [CameraProfileEntry]], make: String, model: String) { self.byName = byName; self.make = make; self.model = model }

    /// The converter's own profiles are not files a preset can name; Apple's camera color stands in for them.
    public static func isBuiltIn(_ name: String) -> Bool {
        ["adobe standard", "camera standard", "embedded", "adobe color", "adobe monochrome", "adobe vivid", "adobe landscape", "adobe portrait", "adobe neutral", "camera neutral", "camera faithful"].contains { normalized(name).hasPrefix($0) }
    }

    /// The Adobe Standard entry for the camera `entry` was made for.
    func base(for entry: CameraProfileEntry) -> CameraProfileEntry? {
        let key = Self.normalized(entry.camera)
        guard !key.isEmpty else { return nil }
        return byName["adobe standard"]?.first { Self.normalized($0.camera) == key }
    }

    /// Compares names the way preset menus display them; some packs use superscripts such as "⁺¹".
    public static func normalized(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Returns the best entry and whether it was made for this camera model.
    public func match(_ name: String) -> (entry: CameraProfileEntry, exact: Bool)? {
        guard let candidates = byName[Self.normalized(name)], !candidates.isEmpty else { return nil }
        let modelKey = Self.normalized(model), makeKey = Self.normalized(make).split(separator: " ").first.map(String.init) ?? ""
        func cameraModel(_ entry: CameraProfileEntry) -> String {
            let camera = Self.normalized(entry.camera)
            if !makeKey.isEmpty, camera.hasPrefix(makeKey + " ") { return String(camera.dropFirst(makeKey.count + 1)) }
            return camera
        }
        if !modelKey.isEmpty, let exact = candidates.first(where: { cameraModel($0) == modelKey || Self.normalized($0.camera) == modelKey || Self.normalized($0.camera).hasSuffix(" " + modelKey) }) { return (exact, true) }
        // Otherwise prefer the same make, then the longest shared model prefix (for example ILCE-7 for ILCE-7RM3).
        func score(_ entry: CameraProfileEntry) -> (Int, Int) {
            let camera = Self.normalized(entry.camera)
            let sameMake = !makeKey.isEmpty && camera.hasPrefix(makeKey) ? 1 : 0
            let shared = zip(cameraModel(entry), modelKey).prefix { $0 == $1 }.count
            return (sameMake, shared)
        }
        let best = candidates.max { a, b in
            let sa = score(a), sb = score(b)
            return sa != sb ? sa < sb : (a.camera, a.path) > (b.camera, b.path)
        }!
        return (best, false)
    }

    /// Loads the profile a preset names, with its camera's Adobe Standard tables removed when that
    /// profile is indexed. Without that separation a profile made for another camera would carry
    /// the other camera's calibration, so it is refused, as the converter it was made for refuses it.
    public func load(_ name: String, notes: inout [String]) -> CameraProfile? {
        guard let (entry, exact) = match(name) else { return nil }
        do {
            var profile = try CameraProfile(dcp: entry.url)
            profile.name = name
            let made = entry.camera.isEmpty ? L10n.tr("another camera") : entry.camera
            if profile.hasTables, let base = base(for: entry) {
                profile = profile.removingBase(try CameraProfile(dcp: base.url))
            } else if profile.hasTables {
                guard exact else {
                    notes.append(L10n.tr("Camera profile ‘\(name)’ is for \(made) only, with no base profile to separate its look; default camera color is used."))
                    return nil
                }
                notes.append(L10n.tr("No base profile for \(made), so ‘\(name)’ includes its camera calibration."))
            }
            if !exact {
                let target = [make, model].filter { !$0.isEmpty }.joined(separator: " ")
                notes.append(L10n.tr("Camera profile ‘\(name)’ was made for \(made); its look is applied to \(target.isEmpty ? L10n.key("this photo") : target)."))
            }
            return profile
        } catch {
            notes.append(L10n.tr("Camera profile ‘\(name)’ could not be read: \(error.localizedDescription)"))
            return nil
        }
    }
}
