import Foundation
import Accelerate
import simd

struct PanoramaFeature {
    var point: SIMD2<Double>
    var descriptor: [Float]
    var strength: Float
}

struct PanoramaMatch {
    var a: SIMD2<Double>
    var b: SIMD2<Double>
    var distance: Float
}

/// A single-channel image for alignment: log luminance of a reduced frame.
struct LuminancePlane {
    let width: Int
    let height: Int
    var values: [Float]
    init(width: Int, height: Int, values: [Float]) { self.width = width; self.height = height; self.values = values }
    /// Rec. 709 luminance of the developed frame, box-averaged down to `longEdge`.
    init(_ frame: PanoramaFrame, longEdge: Int) {
        let scale = min(1, Double(longEdge) / Double(max(frame.width, frame.height)))
        width = max(1, Int(Double(frame.width) * scale)); height = max(1, Int(Double(frame.height) * scale))
        let weights = SIMD4<Float>(0.2126, 0.7152, 0.0722, 0)
        var values = [Float](repeating: 0, count: width * height)
        let (w, h, sw, sh) = (width, height, frame.width, frame.height)
        frame.pixels.withUnsafeBufferPointer { pixels in
            values.withUnsafeMutableBufferPointer { out in
                let out = out
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    let y0 = y * sh / h, y1 = max(y0 + 1, (y + 1) * sh / h)
                    for x in 0..<w {
                        let x0 = x * sw / w, x1 = max(x0 + 1, (x + 1) * sw / w)
                        var sum = SIMD4<Float>(repeating: 0)
                        for sy in y0..<y1 { for sx in x0..<x1 {
                            let p = (sy * sw + sx) * 4
                            sum += SIMD4(pixels[p], pixels[p + 1], pixels[p + 2], 0)
                        }}
                        out[y * w + x] = max(0, (sum * weights).sum() / Float((y1 - y0) * (x1 - x0)))
                    }
                }
            }
        }
        self.values = values
    }
    /// Linear luminance averaged over 5 × 5 pixels, for exposure matching.
    func mean(at point: SIMD2<Double>) -> Double {
        let x = Int(point.x.rounded(.down)), y = Int(point.y.rounded(.down))
        var sum = 0.0, count = 0
        for dy in -2...2 { for dx in -2...2 {
            let px = x + dx, py = y + dy
            guard px >= 0, py >= 0, px < width, py < height else { continue }
            sum += Double(values[py * width + px]); count += 1
        }}
        return sum / Double(max(count, 1))
    }
}

/// Multiscale Harris corners with oriented gradient-histogram descriptors. A classical detector written for Ceviche,
/// not SIFT; it needs textured overlap between neighbouring photos.
enum PanoramaFeatures {
    static func detect(_ plane: LuminancePlane, limit: Int) -> [PanoramaFeature] {
        let gray = plane.values.map { log1p(max(0, $0) * 8) }
        var all: [PanoramaFeature] = []
        for scale in [1.0, 0.7, 0.5] {
            let width = Int(Double(plane.width) * scale), height = Int(Double(plane.height) * scale)
            guard width > 48, height > 48 else { continue }
            var g = [Float](repeating: 0, count: width * height)
            for y in 0..<height { for x in 0..<width {
                let sx = min(plane.width - 1, Int(Double(x) / scale)), sy = min(plane.height - 1, Int(Double(y) / scale))
                g[y * width + x] = gray[sy * plane.width + sx]
            }}
            // A small separable blur before the gradients suppresses demosaic noise.
            var smooth = g
            for y in 1..<height - 1 { for x in 1..<width - 1 {
                let i = y * width + x
                smooth[i] = (g[i - 1] + 2 * g[i] + g[i + 1]) * 0.25
            }}
            g = smooth
            for y in 1..<height - 1 { for x in 1..<width - 1 {
                let i = y * width + x
                smooth[i] = (g[i - width] + 2 * g[i] + g[i + width]) * 0.25
            }}
            var gx = g, gy = g
            for y in 1..<height - 1 { for x in 1..<width - 1 {
                let i = y * width + x
                gx[i] = (smooth[i + 1] - smooth[i - 1]) * 0.5
                gy[i] = (smooth[i + width] - smooth[i - width]) * 0.5
            }}
            // Integral images of the structure tensor give a 5 × 5 Harris window.
            let stride = width + 1
            var xx = [Double](repeating: 0, count: stride * (height + 1)), yy = xx, xy = xx
            for y in 0..<height {
                var sx = 0.0, sy = 0.0, sxy = 0.0
                for x in 0..<width {
                    let p = y * width + x, q = (y + 1) * stride + x + 1
                    let dx = Double(gx[p]), dy = Double(gy[p])
                    sx += dx * dx; sy += dy * dy; sxy += dx * dy
                    xx[q] = xx[q - stride] + sx; yy[q] = yy[q - stride] + sy; xy[q] = xy[q - stride] + sxy
                }
            }
            func box(_ values: [Double], _ x: Int, _ y: Int) -> Double {
                values[(y + 3) * stride + x + 3] + values[(y - 2) * stride + x - 2] - values[(y - 2) * stride + x + 3] - values[(y + 3) * stride + x - 2]
            }
            var response = [Float](repeating: 0, count: width * height)
            for y in 22..<height - 22 { for x in 22..<width - 22 {
                let a = box(xx, x, y), b = box(yy, x, y), c = box(xy, x, y)
                response[y * width + x] = Float(a * b - c * c - 0.04 * (a + b) * (a + b))
            }}
            var candidates: [(Int, Int, Float)] = []
            for y in 23..<height - 23 { for x in 23..<width - 23 {
                let v = response[y * width + x]
                guard v > 1e-8 else { continue }
                var peak = true
                for dy in -2...2 { for dx in -2...2 where (dx != 0 || dy != 0) && response[(y + dy) * width + x + dx] > v { peak = false } }
                if peak { candidates.append((x, y, v)) }
            }}
            candidates.sort { $0.2 > $1.2 }
            var occupied = [Bool](repeating: false, count: width * height)
            var selected = 0
            for (x, y, strength) in candidates {
                if selected >= limit / 2 { break }
                if occupied[y * width + x] { continue }
                for dy in -6...6 { for dx in -6...6 { occupied[(y + dy) * width + x + dx] = true } }
                var orientation = [Float](repeating: 0, count: 36)
                for dy in -8...8 { for dx in -8...8 {
                    let i = (y + dy) * width + x + dx, vx = gx[i], vy = gy[i]
                    let bin = min(35, Int((atan2(vy, vx) + .pi) * 36 / (2 * .pi)))
                    orientation[bin] += hypot(vx, vy) * exp(-Float(dx * dx + dy * dy) / 64)
                }}
                let best = orientation.indices.max { orientation[$0] < orientation[$1] }!
                let angle = (Float(best) + 0.5) * (2 * .pi / 36) - .pi
                let cosine = cos(angle), sine = sin(angle)
                var descriptor = [Float](repeating: 0, count: 128)
                for py in -8..<8 { for px in -8..<8 {
                    let rx = Int((Float(px) * cosine - Float(py) * sine).rounded()) + x
                    let ry = Int((Float(px) * sine + Float(py) * cosine).rounded()) + y
                    let i = ry * width + rx
                    var a = atan2(gy[i], gx[i]) - angle
                    while a < 0 { a += 2 * .pi }; while a >= 2 * .pi { a -= 2 * .pi }
                    let bin = min(7, Int(a * (8 / (2 * .pi))))
                    descriptor[((py + 8) / 4 * 4 + (px + 8) / 4) * 8 + bin] += hypot(gx[i], gy[i]) * exp(-Float(px * px + py * py) / 128)
                }}
                normalize(&descriptor)
                for k in descriptor.indices { descriptor[k] = min(0.2, descriptor[k]) }
                normalize(&descriptor)
                // Continuous coordinates: pixel x of this scale covers [x, x + 1) and is centred on x + 0.5.
                all.append(PanoramaFeature(point: SIMD2((Double(x) + 0.5) / scale, (Double(y) + 0.5) / scale), descriptor: descriptor, strength: strength))
                selected += 1
            }
        }
        return Array(all.sorted { $0.strength > $1.strength }.prefix(limit))
    }

    private static func normalize(_ d: inout [Float]) {
        let norm = sqrt(d.reduce(Float(0)) { $0 + $1 * $1 })
        if norm > 1e-8 { for k in d.indices { d[k] /= norm } }
    }

    /// Mutual nearest neighbours that pass the ratio test, one match per location.
    static func match(_ a: [PanoramaFeature], _ b: [PanoramaFeature], ratio: Double) -> [PanoramaMatch] {
        guard a.count >= 2, b.count >= 2 else { return [] }
        let da = a.flatMap(\.descriptor)
        var dbT = [Float](repeating: 0, count: b.count * 128)
        vDSP_mtrans(b.flatMap(\.descriptor), 1, &dbT, 1, 128, vDSP_Length(b.count))
        var scores = [Float](repeating: 0, count: a.count * b.count)
        vDSP_mmul(da, 1, dbT, 1, &scores, 1, vDSP_Length(a.count), vDSP_Length(b.count), 128)
        var reverse = [Int](repeating: -1, count: b.count)
        for j in b.indices {
            var best: Float = -.infinity
            for i in a.indices where scores[i * b.count + j] > best { best = scores[i * b.count + j]; reverse[j] = i }
        }
        var matches: [PanoramaMatch] = []
        for i in a.indices {
            var first: Float = .infinity, second: Float = .infinity, index = -1
            for j in b.indices {
                let distance = max(0, 2 - 2 * scores[i * b.count + j])
                if distance < first { second = first; first = distance; index = j } else if distance < second { second = distance }
            }
            if index >= 0, reverse[index] == i, first < Float(ratio * ratio) * second {
                matches.append(PanoramaMatch(a: a[i].point, b: b[index].point, distance: first))
            }
        }
        // The same corner found at two scales would otherwise count twice.
        var unique: [PanoramaMatch] = []
        for match in matches.sorted(by: { $0.distance < $1.distance })
        where !unique.contains(where: { simd_distance($0.a, match.a) < 4 || simd_distance($0.b, match.b) < 4 }) {
            unique.append(match)
        }
        return unique
    }
}
