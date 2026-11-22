import Foundation
import CoreImage
import Vision

/// What Vision finds in a portrait: the face and its landmarks, the person's outline (for the crown and the background)
/// and labels for what is worn. Points are fractions of the photo from the top left.
public struct IDPhotoAnalysis: Sendable {
    public struct Face: Sendable {
        public var bounds: CGRect
        public var crown: CGPoint
        public var chin: CGPoint
        public var eyes: CGPoint?
        /// Whether the crown came from the person's outline rather than the face's proportions.
        public var crownFromOutline: Bool
        /// Quarter turns clockwise that stand the head up: 1 when the top of the head points left, 2 when it points
        /// down, 3 when it points right. The markers only hold for a head that is roughly upright.
        public var uprightTurns = 0
        public var yaw: Double?, pitch: Double?, roll: Double?
        /// Eye height over width, the smaller eye; under about 0.12 an eye is closed.
        public var eyeOpenness: Double?
        /// The gap between the lips over the mouth's width.
        public var mouthOpening: Double?
        /// Vision's face capture quality, 0–1: sharpness, light and pose together.
        public var quality: Double?
        /// The difference in brightness between the face's two halves, in stops.
        public var sideLightStops: Double?
        /// The face's mean brightness, 0–1, and the share of it clipped.
        public var brightness: Double
        public var clipped: Double
        /// The cheeks' mean colour, sRGB 0–1: how warm or cool the light made the skin.
        public var skin: SIMD3<Double>?
        /// The face box's lower middle, left and right of the nose (fractions from the top left).
        static func cheeks(_ bounds: CGRect) -> CGRect {
            CGRect(x: bounds.minX + bounds.width * 0.12, y: bounds.minY + bounds.height * 0.45, width: bounds.width * 0.76, height: bounds.height * 0.3)
        }
        /// Where `skin` is measured: the cheeks without their outer edges.
        public var skinRegion: CGRect { let c = Self.cheeks(bounds); return c.insetBy(dx: c.width * 0.1, dy: 0) }
    }
    public var faces: [Face]
    /// Classifier confidence for what can't be worn: eyeglasses, sunglasses, hat, headgear, headphones and similar.
    public var labels: [String: Double]
    /// Mean background colour (sRGB 0–1) and spread of its brightness, measured beside and above the person.
    public var background: (color: SIMD3<Double>, spread: Double)?

    /// Plain wall to balance white on: above the head, or beside it when the head nearly touches the top.
    public var wallRegion: CGRect? {
        guard let face else { return nil }
        let head = face.chin.y - face.crown.y, unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let above = CGRect(x: face.bounds.minX, y: max(0, face.crown.y - head * 0.4), width: face.bounds.width, height: 0)
        let band = CGRect(x: above.minX, y: above.minY, width: above.width, height: face.crown.y - head * 0.06 - above.minY).intersection(unit)
        if band.height > 0.02 { return band }
        let side = CGRect(x: face.bounds.minX - face.bounds.width * 0.7, y: face.bounds.minY, width: face.bounds.width * 0.5, height: face.bounds.height * 0.4).intersection(unit)
        return side.width > 0.02 ? side : nil
    }

    public var face: Face? { faces.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height } }

    static let wornLabels = ["eyeglasses", "sunglasses", "hat", "headgear", "baseball_hat", "cowboy_hat", "sunhat", "hardhat", "helmet", "headphones", "scarf"]

    public static func analyze(_ image: CGImage) throws -> IDPhotoAnalysis {
        let handler = VNImageRequestHandler(cgImage: image)
        let landmarks = VNDetectFaceLandmarksRequest()
        let quality = VNDetectFaceCaptureQualityRequest()
        let person = VNGeneratePersonSegmentationRequest()
        person.qualityLevel = .accurate
        person.outputPixelFormat = kCVPixelFormatType_OneComponent8
        // The landmarks request reports yaw in 45° steps; revision 3 of the rectangles request measures it.
        let pose = VNDetectFaceRectanglesRequest()
        pose.revision = VNDetectFaceRectanglesRequestRevision3
        let classify = VNClassifyImageRequest()
        try handler.perform([landmarks, pose, person, classify])
        let poses = pose.results ?? []
        let observations = (landmarks.results ?? []).filter { $0.boundingBox.height > 0.03 }
        quality.inputFaceObservations = observations
        try? handler.perform([quality])
        let qualities = quality.results ?? []

        let mask = person.results?.first.map { Mask($0.pixelBuffer) }
        let pixels = Pixels(image)
        var faces: [Face] = []
        for observation in observations {
            var face = measure(observation, mask: mask, pixels: pixels)
            func overlap(_ a: CGRect) -> CGFloat { let i = a.intersection(observation.boundingBox); return i.isNull ? 0 : i.width * i.height }
            if let match = poses.max(by: { overlap($0.boundingBox) < overlap($1.boundingBox) }), overlap(match.boundingBox) > 0 {
                face.yaw = match.yaw.map { $0.doubleValue * 180 / .pi }
                face.pitch = match.pitch.map { $0.doubleValue * 180 / .pi }
            } else {
                face.yaw = nil; face.pitch = nil
            }
            face.quality = qualities.first { $0.boundingBox == observation.boundingBox }?.faceCaptureQuality.map(Double.init)
            faces.append(face)
        }
        var labels: [String: Double] = [:]
        for result in classify.results ?? [] where wornLabels.contains(result.identifier) { labels[result.identifier] = Double(result.confidence) }
        let face = faces.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
        return IDPhotoAnalysis(faces: faces, labels: labels, background: face.flatMap { background(around: $0, mask: mask, pixels: pixels) })
    }

    /// Landmarks to the points the layout needs. Vision's box runs from the brows to the chin; the crown is the top of
    /// the person's outline above the face's middle, or, without one, as far above the eyes as the chin is below them.
    static func measure(_ observation: VNFaceObservation, mask: Mask?, pixels: Pixels) -> Face {
        let box = observation.boundingBox
        func flip(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: 1 - p.y) }
        func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            (region?.normalizedPoints ?? []).map { flip(CGPoint(x: box.minX + $0.x * box.width, y: box.minY + $0.y * box.height)) }
        }
        let bounds = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
        let contour = points(observation.landmarks?.faceContour)
        let chin = contour.max { $0.y < $1.y } ?? CGPoint(x: bounds.midX, y: bounds.maxY)
        let left = points(observation.landmarks?.leftPupil).first, right = points(observation.landmarks?.rightPupil).first
        let eyes = left.flatMap { l in right.map { CGPoint(x: (l.x + $0.x) / 2, y: (l.y + $0.y) / 2) } }
        let eyeLevel = eyes ?? CGPoint(x: bounds.midX, y: bounds.minY + bounds.height * 0.35)
        // The head's vertical runs from the chin through the eyes; the crown is found along it.
        var crown = CGPoint(x: eyeLevel.x + (eyeLevel.x - chin.x), y: eyeLevel.y - (chin.y - eyeLevel.y))
        var fromOutline = false
        if let mask, let top = mask.top(between: bounds.minX + bounds.width * 0.3, and: bounds.maxX - bounds.width * 0.3, above: bounds.minY + bounds.height * 0.2) {
            // Keep a top that is plausibly the head: not a raised hand or a hat far above it.
            let estimate = crown.y, eyeToChin = chin.y - eyeLevel.y
            if top < eyeLevel.y - eyeToChin * 0.6 && top > estimate - eyeToChin * 0.6 {
                let t = (chin.y - top) / max(0.0001, chin.y - eyeLevel.y)
                crown = CGPoint(x: chin.x + (eyeLevel.x - chin.x) * t, y: top)
                fromOutline = true
            }
        }
        func openness(_ region: VNFaceLandmarkRegion2D?) -> Double? {
            let p = points(region)
            guard p.count >= 4, let minX = p.map(\.x).min(), let maxX = p.map(\.x).max(), let minY = p.map(\.y).min(), let maxY = p.map(\.y).max(), maxX > minX else { return nil }
            // In the photo's pixels; the y fractions are of the height.
            return (maxY - minY) * pixels.height / ((maxX - minX) * pixels.width)
        }
        let eyeOpenness = [openness(observation.landmarks?.leftEye), openness(observation.landmarks?.rightEye)].compactMap { $0 }.min()
        var mouth: Double?
        let inner = points(observation.landmarks?.innerLips), outer = points(observation.landmarks?.outerLips)
        if inner.count >= 4, let w0 = outer.map(\.x).min(), let w1 = outer.map(\.x).max(), w1 > w0,
           let h0 = inner.map(\.y).min(), let h1 = inner.map(\.y).max() {
            mouth = (h1 - h0) * pixels.height / ((w1 - w0) * pixels.width)
        }
        // Cheeks: the face box's lower middle, left and right of the nose.
        let cheeks = Face.cheeks(bounds)
        let leftHalf = pixels.mean(in: CGRect(x: cheeks.minX, y: cheeks.minY, width: cheeks.width * 0.4, height: cheeks.height))
        let rightHalf = pixels.mean(in: CGRect(x: cheeks.maxX - cheeks.width * 0.4, y: cheeks.minY, width: cheeks.width * 0.4, height: cheeks.height))
        let side = leftHalf.flatMap { l in rightHalf.map { r in abs(log2(max(0.01, l.luma) / max(0.01, r.luma))) } }
        let whole = pixels.mean(in: cheeks.insetBy(dx: cheeks.width * 0.1, dy: 0))
        // Which way is down the face, from between the eyes to the mouth, in the photo's pixels.
        func centre(_ p: [CGPoint]) -> CGPoint? {
            p.isEmpty ? nil : CGPoint(x: p.map(\.x).reduce(0, +) / CGFloat(p.count), y: p.map(\.y).reduce(0, +) / CGFloat(p.count))
        }
        var turns = 0
        if let eyeLine = centre(points(observation.landmarks?.leftEye) + points(observation.landmarks?.rightEye)),
           let mouthCentre = centre(points(observation.landmarks?.outerLips)) {
            let down = atan2((mouthCentre.x - eyeLine.x) * pixels.width, (mouthCentre.y - eyeLine.y) * pixels.height) * 180 / .pi
            turns = ((Int((down / 90).rounded()) % 4) + 4) % 4
        }
        var face = Face(bounds: bounds, crown: crown, chin: chin, eyes: eyes, crownFromOutline: fromOutline,
                    yaw: observation.yaw.map { $0.doubleValue * 180 / .pi }, pitch: observation.pitch.map { $0.doubleValue * 180 / .pi },
                    roll: observation.roll.map { $0.doubleValue * 180 / .pi }, eyeOpenness: eyeOpenness, mouthOpening: mouth,
                    quality: nil, sideLightStops: side, brightness: whole?.luma ?? 0.5, clipped: whole?.clipped ?? 0,
                    skin: pixels.statistics(in: cheeks.insetBy(dx: cheeks.width * 0.1, dy: 0)) { _, _ in true }?.0)
        face.uprightTurns = turns
        return face
    }

    /// The background beside and above the head, where the person's outline isn't: its mean colour and how much its
    /// brightness varies.
    static func background(around face: Face, mask: Mask?, pixels: Pixels) -> (SIMD3<Double>, Double)? {
        let head = face.chin.y - face.crown.y
        let region = CGRect(x: face.bounds.midX - head * 1.2 * pixels.height / pixels.width, y: max(0, face.crown.y - head * 0.35),
                            width: head * 2.4 * pixels.height / pixels.width, height: head * 1.1).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !region.isEmpty else { return nil }
        return pixels.statistics(in: region) { x, y in (mask?.value(x, y) ?? 0) < 0.2 }
    }
}

/// The person mask at its own resolution.
struct Mask {
    let width: Int, height: Int
    let values: [UInt8]
    init(_ buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        width = CVPixelBufferGetWidth(buffer); height = CVPixelBufferGetHeight(buffer)
        let row = CVPixelBufferGetBytesPerRow(buffer), base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        var values = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width { values[y * width + x] = base[y * row + x] } }
        self.values = values
    }
    /// At a point given as fractions from the top left, 0–1.
    func value(_ x: Double, _ y: Double) -> Double {
        let px = min(width - 1, max(0, Int(x * Double(width)))), py = min(height - 1, max(0, Int(y * Double(height))))
        return Double(values[py * width + px]) / 255
    }
    /// The highest row, as a fraction, where the person covers most of the columns between `x0` and `x1`, searching
    /// up from `start`.
    func top(between x0: Double, and x1: Double, above start: Double) -> Double? {
        let c0 = max(0, Int(x0 * Double(width))), c1 = min(width - 1, Int(x1 * Double(width)))
        guard c1 > c0 else { return nil }
        var row = min(height - 1, Int(start * Double(height))), top: Int?
        while row >= 0 {
            var covered = 0
            for c in c0...c1 where values[row * width + c] > 127 { covered += 1 }
            if Double(covered) / Double(c1 - c0 + 1) > 0.25 { top = row } else if top != nil { break }
            row -= 1
        }
        return top.map { Double($0) / Double(height) }
    }
}

/// The photo's sRGB pixels for measuring.
struct Pixels {
    let width: Double, height: Double
    private let w: Int, h: Int, data: [UInt8]
    init(_ image: CGImage) {
        // A 600 px copy is plenty for means and spreads.
        let scale = min(1, 600 / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        self.w = w; self.h = h
        width = Double(image.width); height = Double(image.height)
        var data = [UInt8](repeating: 0, count: w * h * 4)
        data.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            context?.interpolationQuality = .medium
            context?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        self.data = data
    }
    private func rgb(_ x: Int, _ y: Int) -> SIMD3<Double> {
        let i = (y * w + x) * 4
        return SIMD3(Double(data[i]), Double(data[i + 1]), Double(data[i + 2])) / 255
    }
    private func range(_ rect: CGRect) -> (ClosedRange<Int>, ClosedRange<Int>)? {
        let x0 = max(0, Int(rect.minX * Double(w))), x1 = min(w - 1, Int(rect.maxX * Double(w)))
        let y0 = max(0, Int(rect.minY * Double(h))), y1 = min(h - 1, Int(rect.maxY * Double(h)))
        return x1 >= x0 && y1 >= y0 ? (x0...x1, y0...y1) : nil
    }
    static func luma(_ c: SIMD3<Double>) -> Double { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }

    func mean(in rect: CGRect) -> (luma: Double, clipped: Double)? {
        guard let (xs, ys) = range(rect) else { return nil }
        var sum = 0.0, clipped = 0, count = 0
        for y in ys { for x in xs {
            let c = rgb(x, y); sum += Self.luma(c); count += 1
            if c.max() > 0.985 || c.max() < 0.02 { clipped += 1 }
        } }
        return count == 0 ? nil : (sum / Double(count), Double(clipped) / Double(count))
    }
    /// Mean colour and the standard deviation of brightness over the pixels `include` accepts.
    func statistics(in rect: CGRect, include: (Double, Double) -> Bool) -> (SIMD3<Double>, Double)? {
        guard let (xs, ys) = range(rect) else { return nil }
        var sum = SIMD3<Double>(repeating: 0), lumas: [Double] = []
        for y in ys { for x in xs where include((Double(x) + 0.5) / Double(w), (Double(y) + 0.5) / Double(h)) {
            let c = rgb(x, y); sum += c; lumas.append(Self.luma(c))
        } }
        guard lumas.count > 50 else { return nil }
        let mean = lumas.reduce(0, +) / Double(lumas.count)
        let spread = (lumas.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(lumas.count)).squareRoot()
        return (sum / Double(lumas.count), spread)
    }
}
