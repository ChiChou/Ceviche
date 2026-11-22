import Foundation
import CoreGraphics
import simd

/// Pictures of a merged HDR raster for the merge preview and the DNG's embedded preview.
enum HDRMergeFinishing {
    /// Luminance up to `knee` is shown as is; above it a shoulder approaches white smoothly, so highlights the merge
    /// recovered stay visible instead of clipping. Hue is kept by scaling the three channels together.
    static let knee: Float = 0.6

    @inline(__always) static func compress(_ y: Float) -> Float {
        y <= knee ? y : knee + (1 - knee) * (1 - exp(-(y - knee) / (1 - knee)))
    }

    static func picture(_ image: PanoramaRaster, maxDimension: Int? = nil) -> CGImage? {
        let scale = maxDimension.map { min(1, Double($0) / Double(max(image.width, image.height))) } ?? 1
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        bytes.withUnsafeMutableBufferPointer { out in
            let out = out
            DispatchQueue.concurrentPerform(iterations: height) { y in
                let sy = min(image.height - 1, Int((Double(y) + 0.5) / scale))
                for x in 0..<width {
                    let sx = min(image.width - 1, Int((Double(x) + 0.5) / scale))
                    let p = (sy * image.width + sx) * 4
                    var rgb = simd_max(SIMD3(image.rgba[p], image.rgba[p + 1], image.rgba[p + 2]), .zero)
                    let luminance = simd_dot(rgb, SIMD3(0.2126, 0.7152, 0.0722))
                    if luminance > knee { rgb *= compress(luminance) / luminance }
                    let q = (y * width + x) * 4
                    for c in 0..<3 {
                        let v = min(1, rgb[c])
                        let encoded = v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
                        out[q + c] = UInt8((encoded * 255).rounded())
                    }
                }
            }
        }
        return cgImage(bytes, width: width, height: height)
    }

    /// A grayscale mask, white where `values` are high: where moving areas came from the reference alone. The slight
    /// disagreement every pair of brackets has only lowers weights a little, so it is left out of the picture.
    static func mask(_ values: [Float], width: Int, height: Int) -> CGImage? {
        let bytes = values.map { UInt8((HDRMerger.smoothstep(0.35, 0.65, $0) * 255).rounded()) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// A grayscale picture of values from 0 to 1, white at 1.
    static func gray(_ values: [Float], width: Int, height: Int) -> CGImage? {
        let bytes = values.map { UInt8((max(0, min(1, $0)) * 255).rounded()) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func cgImage(_ bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
