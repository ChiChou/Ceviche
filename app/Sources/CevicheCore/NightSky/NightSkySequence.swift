import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import simd

/// One photo of a night sequence as read from its file. Capture time keeps the camera's clock: fractional seconds and a
/// recorded offset are used when present, and no time zone is assumed otherwise. Only differences matter here.
struct NightSkyFrameMetadata: Codable, Sendable {
    var base: HDRMergeFrameMetadata
    /// Seconds on the camera's clock at the start of the exposure, assuming the EXIF time marks the start.
    var time: Double?
    var exposure: Double?
    var fNumber: Double?
    var iso: Double?
    var focalLength35mm: Double?

    var filename: String { base.filename }
    /// The middle of the exposure, which sky motion is measured at.
    var midpoint: Double? { time.map { $0 + (exposure ?? 0) / 2 } }
    /// Light gathered relative to f/1 for one second; ISO is gain applied afterwards, not light.
    var light: Double? {
        guard let exposure, let fNumber, exposure > 0, fNumber > 0 else { return nil }
        return exposure / (fNumber * fNumber)
    }

    static func read(_ url: URL) throws -> NightSkyFrameMetadata {
        let base = try HDRMergeDecoder.metadata(url)
        var result = NightSkyFrameMetadata(base: base)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return result }
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        func number(_ key: CFString) -> Double? { ((exif[key as String] as? NSNumber)?.doubleValue).flatMap { $0 > 0 ? $0 : nil } }
        result.exposure = number(kCGImagePropertyExifExposureTime)
        result.fNumber = number(kCGImagePropertyExifFNumber)
        result.iso = ((exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue).flatMap { $0 > 0 ? $0 : nil }
        result.focalLength35mm = number(kCGImagePropertyExifFocalLenIn35mmFilm)
        if let text = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String, let seconds = Self.seconds(text) {
            var time = seconds
            if let subsec = exif[kCGImagePropertyExifSubsecTimeOriginal as String] as? String,
               let fraction = Double("0." + subsec.trimmingCharacters(in: .whitespaces)) { time += fraction }
            if let offset = exif[kCGImagePropertyExifOffsetTimeOriginal as String] as? String, let shift = Self.offset(offset) { time -= shift }
            result.time = time
        }
        return result
    }

    /// `yyyy:MM:dd HH:mm:ss` as seconds, read as if it were UTC.
    static func seconds(_ text: String) -> Double? {
        let parts = text.split(whereSeparator: { $0 == ":" || $0 == " " }).compactMap { Int($0) }
        guard parts.count >= 6 else { return nil }
        var components = DateComponents()
        components.year = parts[0]; components.month = parts[1]; components.day = parts[2]
        components.hour = parts[3]; components.minute = parts[4]; components.second = parts[5]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)?.timeIntervalSince1970
    }

    /// `±HH:MM` as seconds east of UTC.
    static func offset(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let sign = trimmed.first, sign == "+" || sign == "-" else { return nil }
        let parts = trimmed.dropFirst().split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return (sign == "-" ? -1 : 1) * (parts[0] * 3600 + parts[1] * 60)
    }
}

/// Pictures of night-sky rasters for previews, thumbnails and the DNG's embedded preview. Night photos are mostly dark, so
/// the picture is brightened by `exposure` (found once per sequence) and highlights roll off instead of clipping. The
/// linear result is never changed by this.
enum NightSkyFinishing {
    /// Interleaved RGB (3 floats per pixel) or RGBA (4) to sRGB, sampled down to fit `maxDimension`.
    static func picture(_ values: UnsafeBufferPointer<Float>, channels: Int, width: Int, height: Int, exposure: Float, maxDimension: Int? = nil) -> CGImage? {
        let scale = maxDimension.map { min(1, Double($0) / Double(max(width, height))) } ?? 1
        let w = max(1, Int(Double(width) * scale)), h = max(1, Int(Double(height) * scale))
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        bytes.withUnsafeMutableBufferPointer { out in
            let out = out
            DispatchQueue.concurrentPerform(iterations: h) { y in
                let sy = min(height - 1, Int((Double(y) + 0.5) / scale))
                for x in 0..<w {
                    let sx = min(width - 1, Int((Double(x) + 0.5) / scale))
                    let p = (sy * width + sx) * channels
                    var rgb = SIMD3(values[p], values[p + 1], values[p + 2])
                    if !(rgb.x.isFinite && rgb.y.isFinite && rgb.z.isFinite) { rgb = .zero }
                    rgb = simd_max(rgb * exposure, .zero)
                    let luminance = simd_dot(rgb, SIMD3(0.2126, 0.7152, 0.0722))
                    if luminance > HDRMergeFinishing.knee { rgb *= HDRMergeFinishing.compress(luminance) / luminance }
                    let q = (y * w + x) * 4
                    for c in 0..<3 {
                        let v = min(1, rgb[c])
                        let encoded = v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
                        out[q + c] = UInt8((encoded * 255).rounded())
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    static func picture(_ values: [Float], channels: Int, width: Int, height: Int, exposure: Float, maxDimension: Int? = nil) -> CGImage? {
        values.withUnsafeBufferPointer { picture($0, channels: channels, width: width, height: height, exposure: exposure, maxDimension: maxDimension) }
    }

    /// The brightening that puts the sky's median at a mid-gray, within reason.
    static func exposure(skyMedian: Float) -> Float {
        guard skyMedian > 0, skyMedian.isFinite else { return 1 }
        return max(1, min(256, 0.12 / skyMedian))
    }
}
