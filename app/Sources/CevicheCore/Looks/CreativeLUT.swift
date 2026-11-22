import Foundation
import CoreImage
import CryptoKit

/// The encoding a lookup table expects for its input and output values.
public enum LUTColorSpace: String, Codable, CaseIterable, Sendable {
    case sRGB = "sRGB", displayP3 = "Display P3", rec709 = "Rec. 709", linearSRGB = "Linear sRGB"
    var space: CGColorSpace {
        switch self {
        case .sRGB: return CGColorSpace(name: CGColorSpace.sRGB)!
        case .displayP3: return CGColorSpace(name: CGColorSpace.displayP3)!
        case .rec709: return CGColorSpace(name: CGColorSpace.itur_709)!
        case .linearSRGB: return CGColorSpace(name: CGColorSpace.linearSRGB)!
        }
    }
}

/// An imported 3D lookup table, embedded in the recipe so the source file is not needed.
/// Samples are stored as 16-bit normalized RGB with red varying fastest.
public struct CreativeLUT: Codable, Equatable, Sendable {
    public static let maxDimension = 65
    public static let maxFileBytes = 64 * 1024 * 1024
    public var name: String
    public var amount = 1.0
    public var enabled = true
    public var space = LUTColorSpace.sRGB
    public private(set) var dimension: Int
    public private(set) var samples: Data
    /// Identifies the table contents for caching and display.
    public private(set) var digest: String
    /// The library file this table was read from; storing a development writes one when it is nil.
    public var source: ResourceReference?
    /// Original compressed table, retained for resource storage and portable recipes.
    private(set) var haldPNG: Data?
    /// Equal when they render the same; which file the table was read from does not count.
    public static func == (a: Self, b: Self) -> Bool {
        a.name == b.name && a.amount == b.amount && a.enabled == b.enabled && a.space == b.space && a.dimension == b.dimension && a.samples == b.samples
    }

    init(name: String, dimension: Int, rgb: [Float]) {
        var data = Data(capacity: rgb.count * 2)
        for value in rgb {
            let encoded = UInt16((min(1, max(0, value)) * 65535).rounded())
            withUnsafeBytes(of: encoded.littleEndian) { data.append(contentsOf: $0) }
        }
        self.init(name: name, dimension: dimension, samples: data)
    }

    private init(name: String, dimension: Int, samples: Data) {
        self.name = name; self.dimension = dimension; self.samples = samples
        digest = SHA256.hash(data: samples).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    func validate() throws {
        guard name.count <= 200, (2...Self.maxDimension).contains(dimension), samples.count == dimension * dimension * dimension * 6 else {
            throw EditorError.invalidDocument(L10n.tr("Invalid lookup table."))
        }
        try check([amount], in: 0...1)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decode(String.self, forKey: .name)
        if let png = try c.decodeIfPresent(Data.self, forKey: .haldPNG) {
            try self.init(haldPNG: png, name: name)
        } else {
            self.init(name: name, dimension: try c.decode(Int.self, forKey: .dimension), samples: try c.decode(Data.self, forKey: .samples))
        }
        amount = try c.decode(Double.self, forKey: .amount)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        space = try c.decode(LUTColorSpace.self, forKey: .space)
        source = try c.decodeIfPresent(ResourceReference.self, forKey: .source)
    }
    enum CodingKeys: String, CodingKey { case name, amount, enabled, space, dimension, samples, source, haldPNG }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name); try c.encode(amount, forKey: .amount); try c.encode(enabled, forKey: .enabled)
        try c.encode(space, forKey: .space); try c.encode(dimension, forKey: .dimension)
        if let haldPNG { try c.encode(haldPNG, forKey: .haldPNG) }
        else { try c.encode(samples, forKey: .samples) }
        try c.encodeIfPresent(source, forKey: .source)
    }

    /// RGBA float cube data for Core Image.
    var cubeData: Data {
        let count = dimension * dimension * dimension
        var values = [Float](repeating: 1, count: count * 4)
        samples.withUnsafeBytes { raw in
            for i in 0..<count {
                for channel in 0..<3 {
                    values[i * 4 + channel] = Float(UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: (i * 3 + channel) * 2, as: UInt16.self))) / 65535
                }
            }
        }
        return values.withUnsafeBytes { Data($0) }
    }
}

// MARK: - .cube parsing

extension CreativeLUT {
    public init(contentsOf url: URL) throws {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= Self.maxFileBytes else { throw EditorError.invalidDocument(L10n.tr("Lookup table exceeds 64 MB.")) }
        try self.init(data: Data(contentsOf: url), name: url.deletingPathExtension().lastPathComponent)
    }

    /// Detects PNG by signature, including resources whose file was renamed.
    public init(data: Data, name: String) throws {
        guard data.count <= Self.maxFileBytes else { throw EditorError.invalidDocument(L10n.tr("Lookup table exceeds 64 MB.")) }
        if data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) { try self.init(haldPNG: data, name: name) }
        else { try self.init(cube: data, name: name) }
    }

    public init(haldPNG data: Data, name: String) throws {
        let table = try HaldCLUT(data: data)
        self.init(name: String(name.prefix(200)), dimension: table.dimension, rgb: table.rgb)
        haldPNG = data
        try validate()
    }

    /// Reads Resolve-style `.cube` text: 3D tables, 1D tables (expanded to 3D) and input domains.
    public init(cube data: Data, name fallback: String) throws {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1), !text.contains("\0") else {
            throw EditorError.invalidDocument(L10n.tr("Not a .cube lookup table."))
        }
        var title: String?, size3D: Int?, size1D: Int?
        var low = SIMD3<Float>(repeating: 0), high = SIMD3<Float>(repeating: 1)
        var values: [Float] = []
        values.reserveCapacity(33 * 33 * 33 * 3)
        func vector(_ parts: [Substring]) throws -> SIMD3<Float> {
            guard parts.count == 4, let r = Float(parts[1]), let g = Float(parts[2]), let b = Float(parts[3]), r.isFinite, g.isFinite, b.isFinite else {
                throw EditorError.invalidDocument(L10n.tr("Invalid .cube domain."))
            }
            return SIMD3(r, g, b)
        }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let parts = trimmed.split(whereSeparator: \.isWhitespace)
            switch parts[0].uppercased() {
            case "TITLE":
                title = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            case "LUT_3D_SIZE":
                guard parts.count == 2, let n = Int(parts[1]), (2...Self.maxDimension).contains(n) else { throw EditorError.invalidDocument(L10n.tr("Unsupported .cube size; use 2 to \(Self.maxDimension) points.")) }
                size3D = n
            case "LUT_1D_SIZE":
                guard parts.count == 2, let n = Int(parts[1]), (2...65536).contains(n) else { throw EditorError.invalidDocument(L10n.tr("Unsupported 1D .cube size.")) }
                size1D = n
            case "DOMAIN_MIN": low = try vector(parts)
            case "DOMAIN_MAX": high = try vector(parts)
            case "LUT_3D_INPUT_RANGE", "LUT_1D_INPUT_RANGE":
                guard parts.count == 3, let a = Float(parts[1]), let b = Float(parts[2]) else { throw EditorError.invalidDocument(L10n.tr("Invalid .cube input range.")) }
                low = SIMD3(repeating: a); high = SIMD3(repeating: b)
            default:
                guard parts.count == 3 else {
                    if parts[0].first?.isLetter == true { continue } // Unknown keywords are optional metadata.
                    throw EditorError.invalidDocument(L10n.tr("Invalid .cube data row."))
                }
                for part in parts {
                    guard let value = Float(part), value.isFinite else { throw EditorError.invalidDocument(L10n.tr("Invalid .cube data row.")) }
                    values.append(value)
                }
            }
        }
        guard (size3D == nil) != (size1D == nil) else { throw EditorError.invalidDocument(L10n.tr("A .cube file must declare exactly one LUT_3D_SIZE or LUT_1D_SIZE.")) }
        guard all(low .< high) else { throw EditorError.invalidDocument(L10n.tr("Invalid .cube domain.")) }
        let name = String((title?.isEmpty == false ? title! : fallback).prefix(200))
        if let n = size3D {
            guard values.count == n * n * n * 3 else { throw EditorError.invalidDocument(L10n.tr("The .cube file has \(values.count / 3) samples; expected \(n * n * n).")) }
            let identityDomain = low == SIMD3(repeating: 0) && high == SIMD3(repeating: 1)
            self.init(name: name, dimension: n, rgb: identityDomain ? values : Self.resample3D(values, n: n, low: low, high: high))
        } else {
            let n = size1D!
            guard values.count == n * 3 else { throw EditorError.invalidDocument(L10n.tr("The .cube file has \(values.count / 3) samples; expected \(n).")) }
            self.init(name: name, dimension: 33, rgb: Self.expand1D(values, n: n, low: low, high: high, dimension: 33))
        }
        try validate()
    }

    /// Re-samples a table defined over another input domain onto the 0…1 grid.
    static func resample3D(_ values: [Float], n: Int, low: SIMD3<Float>, high: SIMD3<Float>) -> [Float] {
        var result = [Float](repeating: 0, count: values.count)
        func sample(_ p: SIMD3<Float>) -> SIMD3<Float> {
            let x = (p - low) / (high - low) * Float(n - 1)
            let c = SIMD3(min(max(x.x, 0), Float(n - 1)), min(max(x.y, 0), Float(n - 1)), min(max(x.z, 0), Float(n - 1)))
            let i0 = SIMD3<Int>(Int(c.x), Int(c.y), Int(c.z)), i1 = SIMD3(min(i0.x + 1, n - 1), min(i0.y + 1, n - 1), min(i0.z + 1, n - 1))
            let f = c - SIMD3(Float(i0.x), Float(i0.y), Float(i0.z))
            func v(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Float> { let i = ((b * n + g) * n + r) * 3; return SIMD3(values[i], values[i + 1], values[i + 2]) }
            let c00 = v(i0.x, i0.y, i0.z) * (1 - f.x) + v(i1.x, i0.y, i0.z) * f.x
            let c10 = v(i0.x, i1.y, i0.z) * (1 - f.x) + v(i1.x, i1.y, i0.z) * f.x
            let c01 = v(i0.x, i0.y, i1.z) * (1 - f.x) + v(i1.x, i0.y, i1.z) * f.x
            let c11 = v(i0.x, i1.y, i1.z) * (1 - f.x) + v(i1.x, i1.y, i1.z) * f.x
            return (c00 * (1 - f.y) + c10 * f.y) * (1 - f.z) + (c01 * (1 - f.y) + c11 * f.y) * f.z
        }
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let s = sample(SIMD3(Float(r), Float(g), Float(b)) / Float(n - 1)), i = ((b * n + g) * n + r) * 3
            result[i] = s.x; result[i + 1] = s.y; result[i + 2] = s.z
        } } }
        return result
    }

    static func expand1D(_ values: [Float], n: Int, low: SIMD3<Float>, high: SIMD3<Float>, dimension: Int) -> [Float] {
        func curve(_ x: Float, _ channel: Int) -> Float {
            let p = min(max((x - low[channel]) / (high[channel] - low[channel]), 0), 1) * Float(n - 1)
            let i = min(Int(p), n - 2), f = p - Float(i)
            return values[i * 3 + channel] * (1 - f) + values[(i + 1) * 3 + channel] * f
        }
        var result: [Float] = []
        result.reserveCapacity(dimension * dimension * dimension * 3)
        for b in 0..<dimension { for g in 0..<dimension { for r in 0..<dimension {
            let d = Float(dimension - 1)
            result += [curve(Float(r) / d, 0), curve(Float(g) / d, 1), curve(Float(b) / d, 2)]
        } } }
        return result
    }
}

/// Applies a lookup table in its declared encoding, blended by amount.
final class LUTRenderer {
    private var cached: (digest: String, data: Data)?
    func apply(_ lut: CreativeLUT?, to image: CIImage, hdr: Bool) -> CIImage {
        guard let lut, lut.enabled, lut.amount > 0 else { return image }
        if cached?.digest != lut.digest { cached = (lut.digest, lut.cubeData) }
        let data = cached!.data
        return HDRRenderer.bounded(image, enabled: hdr) { source in
            let graded = source.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                "inputCubeDimension": lut.dimension, "inputCubeData": data, "inputColorSpace": lut.space.space
            ])
            return lut.amount >= 1 ? graded : FilmRenderer.blend(graded, over: source, amount: lut.amount)
        }
    }
}
