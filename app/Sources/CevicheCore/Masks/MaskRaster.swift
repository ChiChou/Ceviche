import Foundation
import CoreImage

/// Compact storage for generated mask mattes (one channel, 0…1).
///
/// Masks only scale an edit, so their precision needs are set by how far an edit can amplify a step:
/// 12 bits (0.07% per step) stay invisible under strong local edits, while 8 bits can band in smooth skies.
/// Values within 1/512 of black or white are snapped, so the solid areas outside a selection and the
/// solid areas inside it cost one byte per 32×32 tile. Mixed tiles store each 12-bit value as the
/// difference from a gradient prediction of its left and upper neighbours, and the whole body is LZMA-compressed.
///
/// Layout (little endian): "SMK1", version u8 (1, with bit 0x10 for the gradient predictor and 0x20 for LZMA),
/// bits u8 = 12, tile u16 = 32, width u32, height u32, then the compressed body: flags, one byte per tile,
/// row-major (0 black, 1 white, 2 mixed), then the mixed tiles' u16 deltas.
/// Rows run top to bottom.
public enum MaskRaster {
    static let magic = Data("SMK1".utf8)
    static let version: UInt8 = 1
    public static let bits = 12
    public static let tile = 32
    static var levels: Int { (1 << bits) - 1 }
    /// 1/512 of full scale in 16-bit units.
    static let snap = 128

    public static func isCompact(_ data: Data) -> Bool { data.prefix(magic.count) == magic }

    /// Renders and encodes a matte; `image` values are taken numerically (no color management).
    public static func encode(_ image: CIImage, context: CIContext) throws -> Data {
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0, width * height <= 100_000_000 else { throw EditorError.render }
        var values = [UInt16](repeating: 0, count: width * height)
        values.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 2, bounds: extent, format: .L16, colorSpace: nil) }
        return try encode(values, width: width, height: height)
    }

    /// `values` are 16-bit full-scale samples, rows top to bottom.
    static func encode(_ values: [UInt16], width: Int, height: Int) throws -> Data {
        precondition(values.count == width * height)
        let levels = self.levels
        var quantized = [UInt16](repeating: 0, count: values.count)
        for i in values.indices {
            let v = Int(values[i])
            quantized[i] = v <= snap ? 0 : v >= 65535 - snap ? UInt16(levels) : UInt16((v * levels + 32767) / 65535)
        }
        let columns = (width + tile - 1) / tile, rows = (height + tile - 1) / tile
        var flags = [UInt8](repeating: 0, count: columns * rows)
        var deltas: [UInt16] = []
        for ty in 0..<rows {
            for tx in 0..<columns {
                let x0 = tx * tile, y0 = ty * tile, x1 = min(width, x0 + tile), y1 = min(height, y0 + tile)
                var zero = true, full = true
                for y in y0..<y1 { for x in x0..<x1 { let q = quantized[y * width + x]; zero = zero && q == 0; full = full && q == UInt16(levels) } }
                if zero { flags[ty * columns + tx] = 0; continue }
                if full { flags[ty * columns + tx] = 1; continue }
                flags[ty * columns + tx] = 2
                for y in y0..<y1 { for x in x0..<x1 {
                    deltas.append(quantized[y * width + x] &- predict(quantized, x: x, y: y, x0: x0, y0: y0, width: width, gradient: true))
                } }
            }
        }
        var body = Data(flags)
        deltas.withUnsafeBufferPointer { body.append(Data(buffer: $0)) }
        var header = magic
        header.append(version | 0x10 | 0x20); header.append(UInt8(bits))
        withUnsafeBytes(of: UInt16(tile).littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(width).littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(height).littleEndian) { header.append(contentsOf: $0) }
        return header + (try (body as NSData).compressed(using: .lzma) as Data)
    }
    /// Within a tile: the left neighbour, or with `gradient` left + up − up-left (clamped), which suits smooth fields.
    @inline(__always) static func predict(_ q: [UInt16], x: Int, y: Int, x0: Int, y0: Int, width: Int, gradient: Bool) -> UInt16 {
        let left = x > x0 ? Int(q[y * width + x - 1]) : nil, up = y > y0 ? Int(q[(y - 1) * width + x]) : nil
        guard gradient, let left, let up else { return UInt16(left ?? up ?? 0) }
        let upLeft = Int(q[(y - 1) * width + x - 1])
        return UInt16(min(max(left, up), max(min(left, up), left + up - upLeft)))
    }

    /// 16-bit full-scale samples, rows top to bottom.
    static func decode(_ data: Data) throws -> (values: [UInt16], width: Int, height: Int) {
        func fail() -> Error { EditorError.invalidDocument(L10n.tr("The saved selection mask is damaged.")) }
        guard isCompact(data), data.count >= 16 else { throw fail() }
        let bytes = [UInt8](data.prefix(16))
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        let storedBits = Int(bytes[5]), tile = u16(6), width = u32(8), height = u32(12)
        let gradient = bytes[4] & 0x10 != 0, lzma = bytes[4] & 0x20 != 0
        guard bytes[4] & 0x0F == version, (1...16).contains(storedBits), tile > 0, width > 0, height > 0, width * height <= 100_000_000 else { throw fail() }
        let body = try (data.dropFirst(16) as NSData).decompressed(using: lzma ? .lzma : .lzfse) as Data
        let columns = (width + tile - 1) / tile, rows = (height + tile - 1) / tile
        guard body.count >= columns * rows else { throw fail() }
        let levels = (1 << storedBits) - 1
        var values = [UInt16](repeating: 0, count: width * height)
        var quantized = [UInt16](repeating: 0, count: width * height)
        try body.withUnsafeBytes { raw in
            let flags = raw.bindMemory(to: UInt8.self)
            var offset = columns * rows
            for ty in 0..<rows {
                for tx in 0..<columns {
                    let x0 = tx * tile, y0 = ty * tile, x1 = min(width, x0 + tile), y1 = min(height, y0 + tile)
                    switch flags[ty * columns + tx] {
                    case 0: continue
                    case 1: for y in y0..<y1 { for x in x0..<x1 { values[y * width + x] = 65535 } }
                    case 2:
                        let count = (x1 - x0) * (y1 - y0)
                        guard offset + count * 2 <= raw.count else { throw fail() }
                        var index = offset
                        for y in y0..<y1 { for x in x0..<x1 {
                            let delta = UInt16(raw[index]) | UInt16(raw[index + 1]) << 8; index += 2
                            let q = predict(quantized, x: x, y: y, x0: x0, y0: y0, width: width, gradient: gradient) &+ delta
                            guard q <= levels else { throw fail() }
                            quantized[y * width + x] = q
                            values[y * width + x] = UInt16((Int(q) * 65535 + levels / 2) / levels)
                        } }
                        offset += count * 2
                    default: throw fail()
                    }
                }
            }
        }
        return (values, width, height)
    }

    /// A numeric single-channel image.
    public static func image(from data: Data) -> CIImage? {
        guard let decoded = try? decode(data) else { return nil }
        let bytes = decoded.values.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: bytes as CFData),
              let image = CGImage(width: decoded.width, height: decoded.height, bitsPerComponent: 16, bitsPerPixel: 16, bytesPerRow: decoded.width * 2,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGImageByteOrderInfo.order16Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return CIImage(cgImage: image, options: [.colorSpace: NSNull()])
    }

}
