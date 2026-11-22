import Foundation
import CoreGraphics
import ImageIO

/// Hald level L stores an L² cube in an L³-square PNG, red varying fastest.
/// Preserve encoded samples: profiles and image orientation must not transform LUT data.
struct HaldCLUT {
    let dimension: Int
    let rgb: [Float]
    init(data: Data) throws {
        let table = try HaldPixels(data: data)
        dimension = min(table.dimension, 64)
        let pixels = table.samples(dimension: dimension)
        var values = [Float]()
        values.reserveCapacity(dimension * dimension * dimension * 3)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            for channel in 0..<3 { values.append(Float(pixels[i + channel]) / 65535) }
        }
        rgb = values
    }
}

private struct HaldPixels {
    let dimension: Int
    let pixels: [UInt16]
    init(data: Data) throws {
        guard data.count <= CreativeLUT.maxFileBytes else { throw EditorError.invalidDocument(L10n.tr("Lookup table exceeds 64 MB.")) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.png",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              width == height, (8...4096).contains(width),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == image.height else { throw EditorError.invalidDocument(L10n.tr("Invalid Hald CLUT PNG.")) }
        let level = Int(pow(Double(image.width), 1.0 / 3.0).rounded())
        guard level >= 2, level <= 16, level * level * level == image.width else {
            throw EditorError.invalidDocument(L10n.tr("Invalid Hald CLUT PNG."))
        }
        dimension = level * level
        if image.colorSpace?.model == .monochrome {
            guard image.bitsPerPixel == image.bitsPerComponent,
                  [8, 16].contains(image.bitsPerComponent),
                  let data = image.dataProvider?.data else { throw EditorError.invalidDocument(L10n.tr("Invalid Hald CLUT PNG.")) }
            let bytes = CFDataGetBytePtr(data)!, depth = image.bitsPerComponent
            let little = image.bitmapInfo.intersection(.byteOrderMask) == .byteOrder16Little
            var buffer = [UInt16](repeating: 65535, count: image.width * image.height * 4)
            for y in 0..<image.height { for x in 0..<image.width {
                let offset = y * image.bytesPerRow + x * depth / 8
                let value: UInt16 = depth == 8 ? UInt16(bytes[offset])*257 :
                    (little ? UInt16(bytes[offset]) | UInt16(bytes[offset+1]) << 8 : UInt16(bytes[offset]) << 8 | UInt16(bytes[offset+1]))
                let i = (y * image.width + x) * 4
                buffer[i] = value; buffer[i+1] = value; buffer[i+2] = value
            } }
            pixels = buffer
            return
        }
        let space = CGColorSpaceCreateDeviceRGB()
        guard let raw = image.copy(colorSpace: space) else { throw EditorError.invalidDocument(L10n.tr("Invalid Hald CLUT PNG.")) }
        var buffer = [UInt16](repeating: 0, count: image.width * image.height * 4)
        let decoded = buffer.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 16, bytesPerRow: image.width * 8, space: space,
                bitmapInfo: CGBitmapInfo.byteOrder16Little.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setBlendMode(.copy)
            context.draw(raw, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard decoded else { throw EditorError.invalidDocument(L10n.tr("Invalid Hald CLUT PNG.")) }
        guard stride(from: 3, to: buffer.count, by: 4).allSatisfy({ buffer[$0] == 65535 }) else {
            throw EditorError.invalidDocument(L10n.tr("Invalid Hald CLUT PNG."))
        }
        pixels = buffer
    }
    func samples(dimension out: Int) -> [UInt16] {
        if out == dimension { return pixels }
        var result = [UInt16](repeating: 65535, count: out * out * out * 4)
        let n = dimension
        for b in 0..<out { for g in 0..<out { for r in 0..<out {
            let coordinates = [r, g, b].map { Double($0) * Double(n - 1) / Double(out - 1) }
            let lo = coordinates.map { min(Int($0), n - 2) }
            let f = (0..<3).map { coordinates[$0] - Double(lo[$0]) }
            for channel in 0..<3 {
                var value = 0.0
                for z in 0...1 { for y in 0...1 { for x in 0...1 {
                    let i = (((lo[2] + z) * n + lo[1] + y) * n + lo[0] + x) * 4 + channel
                    value += Double(pixels[i]) * (x == 0 ? 1-f[0] : f[0]) * (y == 0 ? 1-f[1] : f[1]) * (z == 0 ? 1-f[2] : f[2])
                } } }
                result[((b * out + g) * out + r) * 4 + channel] = UInt16(min(65535, max(0, value.rounded())))
            }
        } } }
        return result
    }
}
