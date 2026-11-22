import CoreGraphics
import CoreImage
import Foundation
import Vision

/// Measures the dominant near-horizontal/vertical edges in a bounded luminance preview.
public enum StraightenEstimator {
    public static func correction(for image: CGImage) -> Double? {
        let scale = min(1, 1024 / Double(max(image.width, image.height)))
        let w = max(3, Int(Double(image.width) * scale)), h = max(3, Int(Double(image.height) * scale))
        var pixels = [UInt8](repeating: 0, count: w * h)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            context.interpolationQuality = .high; context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
        }
        guard drawn else { return nil }
        // Suppress pixel stair-steps before measuring gradients, especially after a small rotation.
        let kernel = [1.0, 4, 6, 4, 1]
        var horizontal = [Double](repeating: 0, count: w * h), smoothPixels = horizontal
        for y in 0..<h { for x in 0..<w {
            for k in -2...2 { horizontal[y * w + x] += Double(pixels[y * w + min(w - 1, max(0, x + k))]) * kernel[k + 2] / 16 }
        } }
        for y in 0..<h { for x in 0..<w {
            for k in -2...2 { smoothPixels[y * w + x] += horizontal[min(h - 1, max(0, y + k)) * w + x] * kernel[k + 2] / 16 }
        } }
        var bins = [Double](repeating: 0, count: 181), count = 0
        for y in 1..<h - 1 { for x in 1..<w - 1 {
            func p(_ dx: Int, _ dy: Int) -> Double { smoothPixels[(y + dy) * w + x + dx] }
            let gx = -p(-1, -1) + p(1, -1) - 2 * p(-1, 0) + 2 * p(1, 0) - p(-1, 1) + p(1, 1)
            let gy = -p(-1, -1) - 2 * p(0, -1) - p(1, -1) + p(-1, 1) + 2 * p(0, 1) + p(1, 1)
            let weight = gx * gx + gy * gy
            guard weight > 1600 else { continue }
            var angle = atan2(gy, gx) * 180 / .pi
            angle -= (angle / 90).rounded() * 90
            guard abs(angle) <= 22.5 else { continue }
            bins[Int((angle * 4 + 90).rounded())] += weight; count += 1
        } }
        guard count >= 100 else { return nil }
        let smooth = bins.indices.map { i in (max(0, i - 2)...min(180, i + 2)).reduce(0.0) { $0 + bins[$1] } }
        let peak = smooth.indices.max { smooth[$0] < smooth[$1] }!
        guard smooth[peak] > bins.reduce(0, +) * 0.08 else { return nil }
        var sum = 0.0, weight = 0.0
        for i in max(0, peak - 3)...min(180, peak + 3) { sum += (Double(i) - 90) / 4 * bins[i]; weight += bins[i] }
        // Bitmap rows run downward, so the correction is opposite the measured roll.
        return weight > 0 ? -sum / weight : nil
    }

    /// The correction, in degrees and with the same sign as `correction(for:)`, that levels the line through the
    /// pupils of the largest face. Nil without a face whose pupils are found or more than 45° off.
    /// `irises`, when given, finds the two iris centres for a face box more precisely (the Face model's mesh); Vision's
    /// pupils are used without it or when it finds none.
    public static func eyeCorrection(for image: CGImage, irises: ((CGRect) throws -> (CGPoint, CGPoint)?)? = nil) throws -> Double? {
        let request = VNDetectFaceLandmarksRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        guard let face = request.results?.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) else { return nil }
        let size = CGSize(width: image.width, height: image.height)
        // Points in the image with y up; the line runs from the eye on the left of the picture to the other.
        var pair = try irises?(face.boundingBox)
        if pair == nil, let left = face.landmarks?.leftPupil, let right = face.landmarks?.rightPupil, left.pointCount > 0, right.pointCount > 0 {
            pair = (left.pointsInImage(imageSize: size)[0], right.pointsInImage(imageSize: size)[0])
        }
        guard let (a, b) = pair else { return nil }
        let (p, q) = a.x <= b.x ? (a, b) : (b, a)
        guard hypot(q.x - p.x, q.y - p.y) >= 8 else { return nil }
        let degrees = atan2(q.y - p.y, q.x - p.x) * 180 / .pi
        return abs(degrees) <= 45 ? degrees : nil
    }
}

extension RawRenderer {
    /// `StraightenEstimator.eyeCorrection` with the Face model's iris centres when it is installed.
    public func eyeCorrection(for image: CGImage) throws -> Double? {
        let source = CIImage(cgImage: image)
        return try StraightenEstimator.eyeCorrection(for: image) { box in
            guard let points = try self.faceMeshPoints(face: box, source: source) else { return nil }
            return (points[468], points[473])
        }
    }
}
