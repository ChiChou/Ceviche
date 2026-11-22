import Foundation
import CoreGraphics
import simd

/// Cropping and the preview picture, the same at preview and full size so the preview shows the merge's framing.
enum PanoramaFinishing {
    /// Boundary Warp, then Auto Crop or Fill Edges. `progress` hears the fill's windows done and their total.
    static func finish(_ raster: PanoramaRaster, settings: PanoramaSettings, progress: (Int, Int) -> Void = { _, _ in },
                       cancelled: () -> Bool = { false }) throws -> PanoramaRaster {
        let warped = settings.boundaryWarp > 0 ? PanoramaWarp.warp(raster, amount: settings.boundaryWarp) : raster
        if cancelled() { throw CancellationError() }
        if settings.autoCrop { return crop(warped) }
        if settings.fillEdges { return try PanoramaEdgeFill.fill(warped, progress: progress, cancelled: cancelled) }
        return warped
    }

    /// The largest axis-aligned rectangle the photos fully cover (histogram stack per row).
    static func crop(_ image: PanoramaRaster) -> PanoramaRaster {
        guard let r = coveredRectangle(image) else { return image }
        var pixels = [Float](); pixels.reserveCapacity(r.width * r.height * 4)
        for y in r.minY..<r.minY + r.height {
            let start = (y * image.width + r.minX) * 4
            pixels.append(contentsOf: image.rgba[start..<start + r.width * 4])
        }
        return PanoramaRaster(width: r.width, height: r.height, rgba: pixels)
    }

    static func coveredRectangle(_ image: PanoramaRaster) -> (minX: Int, minY: Int, width: Int, height: Int)? {
        var heights = [Int](repeating: 0, count: image.width), area = 0
        var best = (minX: 0, minY: 0, width: 0, height: 0)
        for y in 0..<image.height {
            for x in 0..<image.width { heights[x] = image.rgba[(y * image.width + x) * 4 + 3] > 0.99 ? heights[x] + 1 : 0 }
            var stack: [Int] = []
            for x in 0...image.width {
                let current = x == image.width ? 0 : heights[x]
                while let last = stack.last, heights[last] > current {
                    let h = heights[stack.removeLast()], start = (stack.last ?? -1) + 1, w = x - start
                    if w * h > area { area = w * h; best = (start, y - h + 1, w, h) }
                }
                stack.append(x)
            }
        }
        return area > 0 ? best : nil
    }

    /// An sRGB picture of the linear pixels, clipped at white, for the merge preview and the DNG's embedded preview.
    static func picture(_ image: PanoramaRaster, maxDimension: Int? = nil) -> CGImage? {
        let scale = maxDimension.map { min(1, Double($0) / Double(max(image.width, image.height))) } ?? 1
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBufferPointer { out in
            let out = out
            DispatchQueue.concurrentPerform(iterations: height) { y in
                let sy = min(image.height - 1, Int((Double(y) + 0.5) / scale))
                for x in 0..<width {
                    let sx = min(image.width - 1, Int((Double(x) + 0.5) / scale))
                    let p = (sy * image.width + sx) * 4, a = image.rgba[p + 3]
                    guard a > 0 else { continue }
                    let rgb = simd_max(SIMD3(image.rgba[p], image.rgba[p + 1], image.rgba[p + 2]), .zero)
                    let q = (y * width + x) * 4
                    for c in 0..<3 {
                        let v = min(1, rgb[c])
                        let encoded = v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
                        out[q + c] = UInt8((encoded * min(1, a) * 255).rounded())
                    }
                    out[q + 3] = UInt8((min(1, a) * 255).rounded())
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
