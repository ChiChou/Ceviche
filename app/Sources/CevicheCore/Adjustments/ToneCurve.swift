// Includes adaptations from RAWmakase, Copyright (c) 2026 RAWmakase contributors (MIT).
// See app/Sources/CevicheMac/Resources/OpenSourceLicenses/credits/rawmakase/SOURCE.txt.
import Foundation

public struct CurvePoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// Nonuniform control points: a natural cubic spline over SDR, shape-preserving cubic interpolation beyond it.
///
/// Inputs and outputs are sRGB-encoded values for SDR (0…1). For HDR the domain continues past SDR white
/// in stops: a value v > 1 sits at 1 + log2(v), up to `1 + maximumStops`. The black (x = 0) and SDR-white
/// (x = 1) anchors always exist; points beyond white shape HDR highlights, and past the last point the
/// curve continues at slope 1, so an SDR-only curve leaves HDR highlights' relative levels unchanged.
public struct ToneCurve: Codable, Equatable, Sendable {
    public static let minimumSpacing = 0.001
    public static let maximumStops = 10.0
    public static var maximumInput: Double { 1 + maximumStops }
    public var points: [CurvePoint]
    public init(points: [CurvePoint] = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]) { self.points = points }
    public init(from decoder: Decoder) throws {
        self.init(points: try decoder.singleValueContainer().decode([CurvePoint].self))
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(points)
    }
    public func validate() throws {
        guard points.count >= 2, points.count <= 1001, points.first?.x == 0, points.contains(where: { $0.x == 1 }),
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...Self.maximumInput).contains($0.x) && (0...($0.x <= 1 ? 1 : Self.maximumInput)).contains($0.y) }),
              zip(points, points.dropFirst()).allSatisfy({ $1.x - $0.x >= Self.minimumSpacing - 1e-10 }) else {
            throw EditorError.invalidDocument(L10n.tr("Curve points must be ordered, separated, and inside the graph."))
        }
    }
    public var isIdentity: Bool { points.allSatisfy { abs($0.x - $0.y) < 1e-10 } }
    /// The SDR-white anchor (x = 1).
    public var whiteIndex: Int { points.firstIndex { $0.x == 1 } ?? points.count - 1 }
    /// Points within the SDR range, for SDR-only formats such as PV2012 sidecar curves.
    public var sdrPoints: [CurvePoint] { points.filter { $0.x <= 1 } }
    /// Black and SDR white are anchors: they move only vertically and cannot be removed.
    public func isAnchor(_ index: Int) -> Bool { index == 0 || index == whiteIndex }
    static func outputRange(forInput x: Double) -> ClosedRange<Double> { 0...(x <= 1 ? 1 : maximumInput) }

    /// `upper` is the largest input the editor shows: 1 for SDR, 1 + headroom stops for HDR.
    @discardableResult
    public mutating func insert(x: Double, y: Double, upper: Double = 1) -> Int? {
        let upper = min(Self.maximumInput, max(1, upper))
        guard x.isFinite, y.isFinite, x > 0, x <= upper, x != 1,
              points.allSatisfy({ abs($0.x - x) >= Self.minimumSpacing }) else { return nil }
        let index = points.firstIndex(where: { $0.x > x }) ?? points.count
        let range = Self.outputRange(forInput: x)
        points.insert(CurvePoint(x: x, y: min(range.upperBound, max(range.lowerBound, y))), at: index)
        return index
    }
    public mutating func move(at index: Int, x: Double, y: Double, upper: Double = 1) {
        guard points.indices.contains(index), x.isFinite, y.isFinite else { return }
        if !isAnchor(index) {
            // Points stay on their side of SDR white so the anchor keeps its meaning.
            let low = points[index - 1].x + Self.minimumSpacing
            let high = index + 1 < points.count ? points[index + 1].x - Self.minimumSpacing : min(Self.maximumInput, max(1, upper))
            points[index].x = min(high, max(low, x))
        }
        let range = Self.outputRange(forInput: points[index].x)
        points[index].y = min(range.upperBound, max(range.lowerBound, y))
    }
    public mutating func remove(at index: Int) {
        guard points.indices.contains(index), !isAnchor(index) else { return }
        points.remove(at: index)
    }

    /// The SDR range is a natural cubic spline through its points, as other RAW editors read sidecar and
    /// preset curves: it may overshoot between points and is clipped to 0…1. Beyond SDR white, harmonic-mean
    /// tangents keep each segment within its two anchor values. The graph and GPU lookup tables use this same function.
    public func value(at x: Double) -> Double {
        guard points.count >= 2 else { return x }
        if x <= points[0].x { return points[0].y }
        if x <= 1 { return Self.naturalSpline(sdrPoints, at: x) }
        // Past the last point the curve continues at slope 1 (HDR highlights keep their spacing in stops).
        if x >= points[points.count - 1].x { return max(0, points[points.count - 1].y + (x - points[points.count - 1].x)) }
        let i = (points.firstIndex(where: { $0.x >= x }) ?? (points.count - 1)) - 1
        func slope(_ index: Int) -> Double {
            (points[index + 1].y - points[index].y) / (points[index + 1].x - points[index].x)
        }
        // SDR white is a boundary: each side uses its own slope there, so HDR points never bend the SDR range.
        let white = points[i + 1].x == 1 ? i + 1 : points[i].x == 1 ? i : -1
        func tangent(_ index: Int) -> Double {
            if index == 0 { return slope(0) }
            if index == points.count - 1 { return slope(index - 1) }
            if index == white { return index == i + 1 ? slope(index - 1) : slope(index) }
            let left = slope(index - 1), right = slope(index)
            guard left * right > 0 else { return 0 }
            let h0 = points[index].x - points[index - 1].x, h1 = points[index + 1].x - points[index].x
            let w0 = 2 * h1 + h0, w1 = h1 + 2 * h0
            return (w0 + w1) / (w0 / left + w1 / right)
        }
        let h = points[i + 1].x - points[i].x, t = (x - points[i].x) / h
        let t2 = t * t, t3 = t2 * t
        let value = (2 * t3 - 3 * t2 + 1) * points[i].y + (t3 - 2 * t2 + t) * h * tangent(i)
            + (-2 * t3 + 3 * t2) * points[i + 1].y + (t3 - t2) * h * tangent(i + 1)
        return min(Self.maximumInput, max(0, value))
    }

    /// Zero second derivatives at the two end points.
    static func naturalSpline(_ points: [CurvePoint], at x: Double) -> Double {
        let n = points.count
        guard n > 2 else {
            let t = (x - points[0].x) / (points[n - 1].x - points[0].x)
            return min(1, max(0, points[0].y + (points[n - 1].y - points[0].y) * t))
        }
        var second = [Double](repeating: 0, count: n), upper = [Double](repeating: 0, count: n)
        for i in 1..<(n - 1) {
            let left = points[i].x - points[i - 1].x, right = points[i + 1].x - points[i].x
            let diagonal = 2 * (left + right) - left * upper[i - 1]
            let rhs = 6 * ((points[i + 1].y - points[i].y) / right - (points[i].y - points[i - 1].y) / left)
            upper[i] = right / diagonal
            second[i] = (rhs - left * second[i - 1]) / diagonal
        }
        for i in stride(from: n - 2, through: 1, by: -1) { second[i] -= upper[i] * second[i + 1] }
        let i = min(n - 2, max(0, (points.firstIndex(where: { $0.x > x }) ?? n) - 1))
        let h = points[i + 1].x - points[i].x, a = (points[i + 1].x - x) / h, b = (x - points[i].x) / h
        let value = a * points[i].y + b * points[i + 1].y + ((a * a * a - a) * second[i] + (b * b * b - b) * second[i + 1]) * h * h / 6
        return min(1, max(0, value))
    }

    /// Samples over 0…1 read with linear interpolation, for evaluating a curve per pixel.
    func table(count: Int = 4096) -> [Double] { (0...count).map { value(at: Double($0) / Double(count)) } }
}
