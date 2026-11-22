import Foundation
import CoreGraphics

/// The photo in the eleven zones of the Zone System, 0 (black) to X (white), for judging tones in black and white.
///
/// Zones are equal steps of CIE L*: zone n is centred on L* 10n, so zone V is middle grey (L* 50, 18 % reflectance).
/// Anything brighter than white, as in HDR, is zone X.
public struct ZoneMap: Sendable {
    public static let count = 11
    public let width: Int
    public let height: Int
    /// One zone per pixel, rows from the top; 255 where the photo is transparent.
    public let zones: [UInt8]
    /// Each zone's share of the photo's pixels.
    public let shares: [Double]

    /// Measures `image` at most `maxWidth` pixels wide.
    public init(_ image: CGImage, maxWidth: Int = 2048) {
        let pixels = Scopes.pixels(image, maxWidth: maxWidth, linear: true)
        width = pixels.width; height = pixels.height
        var zones = [UInt8](repeating: 255, count: width * height)
        var counts = [Double](repeating: 0, count: Self.count)
        for index in 0..<(width * height) {
            let i = index * 4, alpha = pixels.data[i + 3]
            guard alpha > 0.000001 else { continue }
            let y = (0.2126 * pixels.data[i] + 0.7152 * pixels.data[i + 1] + 0.0722 * pixels.data[i + 2]) / alpha
            let zone = Self.zone(luminance: Double(y))
            zones[index] = UInt8(zone); counts[zone] += 1
        }
        self.zones = zones
        let total = max(1, counts.reduce(0, +))
        shares = counts.map { $0 / total }
    }

    /// The zone of a relative luminance (linear, 1 = white).
    public static func zone(luminance: Double) -> Int {
        guard luminance.isFinite else { return 0 }
        return min(count - 1, max(0, Int((lightness(luminance) / 10).rounded())))
    }
    /// CIE L* of a relative luminance.
    public static func lightness(_ y: Double) -> Double {
        let y = max(0, y)
        return y > 216.0 / 24389 ? 116 * cbrt(y) - 16 : y * 24389 / 27
    }
    /// The zone's own grey, sRGB-encoded 0…1: L* 10n.
    public static func grey(_ zone: Int) -> Double {
        let l = Double(min(count - 1, max(0, zone))) * 10
        let y = l > 8 ? pow((l + 16) / 116, 3) : l * 27 / 24389
        return y <= 0.0031308 ? 12.92 * y : 1.055 * pow(y, 1 / 2.4) - 0.055
    }
    /// The zone's numeral: 0, I … X.
    public static func numeral(_ zone: Int) -> String {
        ["0", "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X"][min(count - 1, max(0, zone))]
    }

    /// The zone at a point of the photo (0…1, top-left origin).
    public func zone(at point: CGPoint) -> Int? {
        guard width > 0, height > 0, point.x >= 0, point.y >= 0, point.x <= 1, point.y <= 1 else { return nil }
        let x = min(width - 1, Int(point.x * Double(width))), y = min(height - 1, Int(point.y * Double(height)))
        let zone = zones[y * width + x]
        return zone == 255 ? nil : Int(zone)
    }

    /// Each pixel in its zone's grey. With a zone isolated, that zone shows in `tint` and the rest dimmed, so where it
    /// falls stands out.
    public func image(isolating isolated: Int? = nil, tint: (red: Double, green: Double, blue: Double) = (1, 0.8, 0.1)) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        var palette = (0..<Self.count).map { zone -> (UInt8, UInt8, UInt8) in
            let g = UInt8((Self.grey(zone) * 255).rounded())
            return (g, g, g)
        }
        if let isolated, (0..<Self.count).contains(isolated) {
            palette = palette.enumerated().map { zone, grey in
                if zone == isolated { return (UInt8(tint.red * 255), UInt8(tint.green * 255), UInt8(tint.blue * 255)) }
                let dim = UInt8(Double(grey.0) * 0.3)
                return (dim, dim, dim)
            }
        }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for (index, zone) in zones.enumerated() where zone != 255 {
            let c = palette[Int(zone)], p = index * 4
            bytes[p] = c.0; bytes[p + 1] = c.1; bytes[p + 2] = c.2; bytes[p + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
