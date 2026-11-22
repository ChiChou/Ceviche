import Foundation
import Accelerate

/// The dense stage on vImage (SIMD, multi-core): the reference implementation's `comb_threshold` image,
/// `dilate(adaptiveThreshold(grey)) | (grey <= mean/ratio)`.
enum AccelerateDenseDetector {
    enum Failure: Error { case vImage(vImage_Error, String) }

    private static func check(_ err: vImage_Error, _ what: String) throws {
        if err != kvImageNoError { throw Failure.vImage(err, what) }
    }

    static func run(_ image: RGBAImage, parameters p: DenseParameters) throws -> DenseOutput {
        let w = image.width, h = image.height
        var gray = [UInt8](repeating: 0, count: w * h)
        var boxMean = [UInt8](repeating: 0, count: w * h)
        var adaptive = [UInt8](repeating: 0, count: w * h)
        var dilated = [UInt8](repeating: 0, count: w * h)
        var pixels = image.pixels

        // 1. Grey (BT.601 weights, same as OpenCV / libjpeg).
        try pixels.withUnsafeMutableBytes { src in
            try gray.withUnsafeMutableBytes { dst in
                var s = vImage_Buffer(data: src.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                var d = vImage_Buffer(data: dst.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                let matrix: [Int16] = [77, 150, 29, 0] // R, G, B, A ; sums to 256
                try check(vImageMatrixMultiply_ARGB8888ToPlanar8(&s, &d, matrix, 256, nil, 128, vImage_Flags(kvImageNoFlags)), "grey")
            }
        }

        // 1b. Optional noise smoothing.
        if p.smoothingRadius > 0 {
            var smoothed = [UInt8](repeating: 0, count: w * h)
            try gray.withUnsafeMutableBytes { g in
                try smoothed.withUnsafeMutableBytes { m in
                    var s = vImage_Buffer(data: g.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                    var d = vImage_Buffer(data: m.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                    let k = UInt32(2 * p.smoothingRadius + 1)
                    try check(vImageBoxConvolve_Planar8(&s, &d, nil, 0, 0, k, k, 0, vImage_Flags(kvImageEdgeExtend)), "smooth")
                }
            }
            gray = smoothed
        }

        // 2. Global threshold from the exact histogram.
        var hist = [vImagePixelCount](repeating: 0, count: 256)
        try gray.withUnsafeMutableBytes { g in
            var s = vImage_Buffer(data: g.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
            try check(vImageHistogramCalculation_Planar8(&s, &hist, vImage_Flags(kvImageNoFlags)), "histogram")
        }
        let globalT = globalDarkThreshold(histogram: hist.map { UInt64($0) }, pixelCount: w * h, parameters: p)

        // 3. Local mean (box filter, replicated edges like OpenCV's BORDER_REPLICATE).
        try gray.withUnsafeMutableBytes { g in
            try boxMean.withUnsafeMutableBytes { m in
                var s = vImage_Buffer(data: g.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                var d = vImage_Buffer(data: m.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                let k = UInt32(p.adaptiveBlockSize)
                try check(vImageBoxConvolve_Planar8(&s, &d, nil, 0, 0, k, k, 0, vImage_Flags(kvImageEdgeExtend)), "box")
            }
        }

        // 4. Adaptive threshold: grey <= localMean - C.
        let c = p.adaptiveOffset
        gray.withUnsafeBufferPointer { g in
            boxMean.withUnsafeBufferPointer { m in
                adaptive.withUnsafeMutableBufferPointer { a in
                    parallelRows(h) { r0, r1 in
                        var i = r0 * w
                        let end = r1 * w
                        while i < end {
                            a[i] = Int(g[i]) <= Int(m[i]) - c ? 255 : 0
                            i += 1
                        }
                    }
                }
            }
        }

        // 5. Square dilation (van Herk max filter).
        if p.dilationRadius > 0 {
            try adaptive.withUnsafeMutableBytes { a in
                try dilated.withUnsafeMutableBytes { d in
                    var s = vImage_Buffer(data: a.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                    var dd = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                    let k = vImagePixelCount(2 * p.dilationRadius + 1)
                    try check(vImageMax_Planar8(&s, &dd, nil, 0, 0, k, k, vImage_Flags(kvImageNoFlags)), "max")
                }
            }
        } else {
            dilated = adaptive
        }

        // 6. Combine with the global dark threshold.
        if globalT >= 0 {
            gray.withUnsafeBufferPointer { g in
                dilated.withUnsafeMutableBufferPointer { d in
                    parallelRows(h) { r0, r1 in
                        var i = r0 * w
                        let end = r1 * w
                        while i < end {
                            if Int(g[i]) <= globalT { d[i] = 255 }
                            i += 1
                        }
                    }
                }
            }
        }
        let grayCopy = gray, seeds = adaptive
        return DenseOutput(combined: BinaryImage(width: w, height: h, pixels: dilated)) { x, y, rw, rh in
            var g = [UInt8](repeating: 0, count: rw * rh), sd = g
            for r in 0..<rh {
                let src = (y + r) * w + x
                g.replaceSubrange((r * rw)..<((r + 1) * rw), with: grayCopy[src..<(src + rw)])
                sd.replaceSubrange((r * rw)..<((r + 1) * rw), with: seeds[src..<(src + rw)])
            }
            return (g, sd)
        }
    }
}
