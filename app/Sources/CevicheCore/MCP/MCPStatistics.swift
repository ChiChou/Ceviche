import Foundation
import CoreGraphics

/// Numeric description of an SDR sRGB preview so agents can judge tone, color and clipping without
/// inspecting pixels. Values are fractions in 0…1 computed on the same 8-bit image the client sees.
public struct MCPStatistics: Sendable {
    public static let bins = 64
    public struct Channel: Sendable {
        public let mean: Double, minimum: Double, maximum: Double
        public let percentiles: [Int: Double]
        public let histogram: [Double]
        var json: [String: Any] {
            var object: [String: Any] = ["mean": round(mean), "min": round(minimum), "max": round(maximum), "histogram": histogram.map(round)]
            for (p, v) in percentiles { object["p\(p)"] = round(v) }
            return object
        }
    }
    public let pixels: Int
    public let red: Channel, green: Channel, blue: Channel, luminance: Channel
    public let meanColor: [Double]
    /// HSV saturation over pixels brighter than `saturationFloor`; near-black pixels are noise-dominated.
    public static let saturationFloor = 0.05
    public let meanSaturation: Double
    public let saturationP95: Double
    /// Fraction of pixels with every channel at 0 (crushed) or any channel at 255 (clipped).
    public let blackFraction: Double
    public let whiteFraction: Double
    public let clippedChannels: [Double]

    public var json: [String: Any] {
        ["pixels": pixels, "bins": Self.bins, "range": "0…1 sRGB; histogram entries are pixel fractions per bin",
         "red": red.json, "green": green.json, "blue": blue.json, "luminance": luminance.json,
         "meanColor": meanColor.map(Self.round), "meanSaturation": Self.round(meanSaturation), "saturationP95": Self.round(saturationP95),
         "saturationFloor": Self.saturationFloor,
         "clipping": ["black": Self.round(blackFraction), "white": Self.round(whiteFraction),
                      "red": Self.round(clippedChannels[0]), "green": Self.round(clippedChannels[1]), "blue": Self.round(clippedChannels[2])]]
    }
    public static func round(_ value: Double) -> Double { (value * 10000).rounded() / 10000 }

    /// Measures an 8-bit RGBA image. Alpha is ignored; the image is expected to be opaque sRGB. Nil when the image
    /// cannot be drawn, rather than all-zero statistics.
    public init?(image: CGImage) {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(rgba: bytes, width: width, height: height)
    }
    public init(rgba bytes: [UInt8], width: Int, height: Int) {
        let count = max(1, width * height)
        var counts = Array(repeating: Array(repeating: 0, count: 256), count: 4)
        var sums = [Double](repeating: 0, count: 4), colorSum = [Double](repeating: 0, count: 3)
        var black = 0, white = 0, clipped = [0, 0, 0]
        var saturations = [Double](); saturations.reserveCapacity(count)
        for index in stride(from: 0, to: width * height * 4, by: 4) {
            let r = Int(bytes[index]), g = Int(bytes[index + 1]), b = Int(bytes[index + 2])
            let y = min(255, Int((Double(r) * 0.2126 + Double(g) * 0.7152 + Double(b) * 0.0722).rounded()))
            counts[0][r] += 1; counts[1][g] += 1; counts[2][b] += 1; counts[3][y] += 1
            sums[0] += Double(r); sums[1] += Double(g); sums[2] += Double(b); sums[3] += Double(y)
            if r == 0 && g == 0 && b == 0 { black += 1 }
            if r == 255 || g == 255 || b == 255 { white += 1 }
            if r == 255 { clipped[0] += 1 }; if g == 255 { clipped[1] += 1 }; if b == 255 { clipped[2] += 1 }
            let high = max(r, g, b), low = min(r, g, b)
            if Double(y) / 255 >= Self.saturationFloor { saturations.append(Double(high - low) / Double(high)) }
        }
        func channel(_ i: Int) -> Channel {
            let total = Double(count)
            var minimum = 255, maximum = 0
            for v in 0..<256 where counts[i][v] > 0 { minimum = min(minimum, v); maximum = max(maximum, v) }
            var percentiles: [Int: Double] = [:]
            var cumulative = 0
            var targets = [1, 5, 25, 50, 75, 95, 99].map { ($0, Int((Double($0) / 100 * Double(count - 1)).rounded())) }
            for v in 0..<256 {
                cumulative += counts[i][v]
                while let first = targets.first, cumulative > first.1 { percentiles[first.0] = Double(v) / 255; targets.removeFirst() }
            }
            for remaining in targets { percentiles[remaining.0] = Double(maximum) / 255 }
            var histogram = [Double](repeating: 0, count: Self.bins)
            for v in 0..<256 { histogram[v * Self.bins / 256] += Double(counts[i][v]) / total }
            return Channel(mean: sums[i] / total / 255, minimum: Double(minimum) / 255, maximum: Double(maximum) / 255, percentiles: percentiles, histogram: histogram)
        }
        for i in 0..<3 { colorSum[i] = sums[i] / Double(count) / 255 }
        saturations.sort()
        pixels = width * height
        red = channel(0); green = channel(1); blue = channel(2); luminance = channel(3)
        meanColor = colorSum
        meanSaturation = saturations.isEmpty ? 0 : saturations.reduce(0, +) / Double(saturations.count)
        saturationP95 = saturations.isEmpty ? 0 : saturations[Int((Double(saturations.count - 1) * 0.95).rounded())]
        blackFraction = Double(black) / Double(count); whiteFraction = Double(white) / Double(count)
        clippedChannels = clipped.map { Double($0) / Double(count) }
    }
}
