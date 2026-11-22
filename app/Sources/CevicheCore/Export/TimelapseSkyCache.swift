#if os(macOS)
import Foundation
import CoreImage
import CryptoKit

/// Refined sky masks live on local temporary disk, not in sequence-sized RAM. One cache is shared by previews
/// and encoder passes; its owner supplies a key including source identity, edits, crop, size and HDR mode.
public final class TimelapseSkyCache: @unchecked Sendable {
    let directory: URL
    private let lock = NSLock()
    private var computed = 0
    var computationCount: Int { lock.withLock { computed } }

    public init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ceviche-Timelapse-Sky-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }

    /// Half-float numeric masks at the refinement size (at most 1280 pixels), before upsampling to export size.
    /// The first use also reads back this representation, so hits and misses produce identical mask values.
    func mask(key: String, context: CIContext, make: () throws -> CIImage) throws -> CIImage {
        try lock.withLock {
            try Task.checkCancellation()
            let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
            let url = directory.appendingPathComponent(digest + ".mask")
            if let data = try? Data(contentsOf: url, options: .mappedIfSafe), let image = Self.image(data) { return image }
            let image = try make(), w = Int(image.extent.width), h = Int(image.extent.height)
            guard w > 0, h > 0, w <= 1280, h <= 1280 else { throw EditorError.render }
            var pixels = Data(count: w * h * 2)
            pixels.withUnsafeMutableBytes {
                context.render(image, toBitmap: $0.baseAddress!, rowBytes: w * 2,
                               bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .Rh, colorSpace: nil)
            }
            var data = Data()
            for value in [UInt32(w).littleEndian, UInt32(h).littleEndian] {
                withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
            }
            data.append(pixels)
            try Task.checkCancellation()
            // The mask is computed: a cache that can't be written only means computing it again next time.
            try? data.write(to: url, options: .atomic)
            computed += 1
            guard let result = Self.image(data) else { throw EditorError.render }
            return result
        }
    }

    private static func image(_ data: Data) -> CIImage? {
        guard data.count >= 8 else { return nil }
        let w = Int(data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self)) })
        let h = Int(data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) })
        guard w > 0, h > 0, w <= 1280, h <= 1280, data.count == 8 + w * h * 2 else { return nil }
        return CIImage(bitmapData: Data(data.dropFirst(8)), bytesPerRow: w * 2, size: CGSize(width: w, height: h), format: .Rh, colorSpace: nil)
    }
}
#endif
