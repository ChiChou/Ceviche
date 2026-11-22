import Foundation

/// Hue ranges use the sidecar's 0–100 purple/green slider coordinates, not degrees.
public struct Defringe: Codable, Equatable, Sendable {
    public enum Band: Equatable, Sendable {
        case purple, green

        /// Convert the working-space hue in degrees to the same slider coordinates as the Metal kernel.
        func sliderHue(_ degrees: Double) -> Double? {
            let hue = (degrees - (self == .purple ? 240 : 60)) / 1.2
            return (0...100).contains(hue) ? hue : nil
        }
    }

    public var purpleAmount = 0.0, purpleLow = 30.0, purpleHigh = 70.0
    public var greenAmount = 0.0, greenLow = 40.0, greenHigh = 60.0
    public init() {}
    enum CodingKeys: String, CodingKey {
        case purpleAmount, purpleLow, purpleHigh, greenAmount, greenLow, greenHigh
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        purpleAmount = try c.decodeIfPresent(Double.self, forKey: .purpleAmount) ?? 0
        purpleLow = try c.decodeIfPresent(Double.self, forKey: .purpleLow) ?? 30
        purpleHigh = try c.decodeIfPresent(Double.self, forKey: .purpleHigh) ?? 70
        greenAmount = try c.decodeIfPresent(Double.self, forKey: .greenAmount) ?? 0
        greenLow = try c.decodeIfPresent(Double.self, forKey: .greenLow) ?? 40
        greenHigh = try c.decodeIfPresent(Double.self, forKey: .greenHigh) ?? 60
    }
    public var isIdentity: Bool { purpleAmount == 0 && greenAmount == 0 }
    public mutating func setPickedRange(_ range: ClosedRange<Double>, for band: Band) {
        switch band {
        case .purple:
            purpleLow = range.lowerBound; purpleHigh = range.upperBound
            if purpleAmount == 0 { purpleAmount = 10 }
        case .green:
            greenLow = range.lowerBound; greenHigh = range.upperBound
            if greenAmount == 0 { greenAmount = 10 }
        }
    }
    func validate() throws {
        try check([purpleAmount, greenAmount], in: 0...20)
        try check([purpleLow, purpleHigh, greenLow, greenHigh], in: 0...100)
        guard purpleLow <= purpleHigh, greenLow <= greenHigh else { throw EditorError.invalidDocument(L10n.tr("Invalid defringe hue range.")) }
    }
}

public struct PostCropVignette: Codable, Equatable, Sendable {
    public var amount = 0.0, midpoint = 50.0, feather = 50.0, highlights = 0.0, roundness = 0.0
    public init() {}
    func validate() throws {
        try check([amount, roundness], in: -100...100)
        try check([midpoint, feather, highlights], in: 0...100)
    }
}

/// A sampled color and three four-point falloff ranges. Rendering is an approximation.
public struct PointColor: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var hue = 0.0, saturation = 0.5, luminance = 0.5
    public var hueShift = 0.0, saturationShift = 0.0, luminanceShift = 0.0, range = 0.5, variance = 0.0
    public var hueRange = [0.0, 0.25, 0.75, 1.0]
    public var saturationRange = [0.0, 0.25, 0.75, 1.0]
    public var luminanceRange = [0.0, 0.25, 0.75, 1.0]
    public init() {}
    public init(red: Double, green: Double, blue: Double) {
        let hsl = FilmMath.hsl(SIMD3(red, green, blue)); hue = hsl.x; saturation = hsl.y; luminance = hsl.z
    }
    public var isIdentity: Bool { hueShift == 0 && saturationShift == 0 && luminanceShift == 0 && variance == 0 }
    func validate() throws {
        try check([hue, saturation, luminance, range], in: 0...1)
        try check([hueShift, saturationShift, luminanceShift], in: -1...1)
        try check([variance], in: -100...100)
        for bounds in [hueRange, saturationRange, luminanceRange] {
            guard bounds.count == 4, bounds == bounds.sorted() else { throw EditorError.invalidDocument(L10n.tr("Invalid point color range.")) }
            try check(bounds, in: 0...1)
        }
    }
    func transform(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        guard !isIdentity else { return rgb }
        var hsl = FilmMath.hsl(rgb)
        let delta = hsl.x - hue, hueDistance = delta - floor(delta + 0.5)
        func centered(_ value: Double, _ center: Double) -> Double {
            value < center ? 0.5 * value / max(0.000001, center) : 0.5 + 0.5 * (value - center) / max(0.000001, 1 - center)
        }
        func weight(_ value: Double, _ bounds: [Double]) -> Double {
            // Range broadens the sample-centered interval without changing its inner full-effect region.
            let width = 0.25 + range * 1.5, x = 0.5 + (value - 0.5) / width
            if x < bounds[0] || x > bounds[3] { return 0 }
            if x < bounds[1] { return FilmMath.smooth((x - bounds[0]) / max(1e-6, bounds[1] - bounds[0])) }
            if x > bounds[2] { return 1 - FilmMath.smooth((x - bounds[2]) / max(1e-6, bounds[3] - bounds[2])) }
            return 1
        }
        let coverage = weight(hueDistance + 0.5, hueRange) * weight(centered(hsl.y, saturation), saturationRange) * weight(centered(hsl.z, luminance), luminanceRange)
        guard coverage > 0 else { return rgb }
        // Avoid introducing color into unselected neutrals.
        let chromaWeight = FilmMath.smooth(hsl.y / 0.05)
        hsl.x += (hueShift * 0.5 + hueDistance * variance / 100) * coverage * chromaWeight
        hsl.y = min(1, max(0, hsl.y + saturationShift * coverage * chromaWeight))
        hsl.z = min(1, max(0, hsl.z + luminanceShift * coverage * 0.5))
        return FilmMath.rgb(hsl)
    }
}

public struct ImportedLook: Codable, Equatable, Sendable {
    public var name: String
    public var amount = 1.0
    public var enabled = true
    public var adjustments = PixelAdjustments()
    public init(name: String) { self.name = name }
    func validate() throws {
        guard name.count <= 200 else { throw EditorError.invalidDocument(L10n.tr("Invalid look name.")) }
        try check([amount], in: 0...2); _ = try adjustments.validated()
    }
}

func check(_ values: [Double], in range: ClosedRange<Double>) throws {
    guard values.allSatisfy({ $0.isFinite && range.contains($0) }) else { throw EditorError.invalidDocument(L10n.tr("Adjustment values are out of range.")) }
}

extension FilmMath {
    static func rgb(_ hsl: SIMD3<Double>) -> SIMD3<Double> {
        let chroma = (1 - abs(2 * hsl.z - 1)) * hsl.y
        return clamp(hue(hsl.x) * chroma + SIMD3(repeating: hsl.z - chroma / 2))
    }
}
