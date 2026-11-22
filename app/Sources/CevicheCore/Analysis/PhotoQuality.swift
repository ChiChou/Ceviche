import CoreGraphics
import Foundation
import ImageIO
import Vision

/// What the culling assistant measures on one photo. Vision supplies the faces (with landmarks and capture quality),
/// the salient subject, an aesthetics score and a feature print for similarity; sharpness and exposure come from the
/// pixels, since Vision has no measure of either. Rectangles are normalized with a top-left origin.
public struct PhotoQualityReport: Codable, Equatable, Sendable {
    public struct Face: Codable, Equatable, Sendable {
        /// Faces narrower than this fraction of the photo are too small for their eyes or focus to be judged.
        public static let judgedWidth = 0.06
        public var bounds: CGRect
        /// Vision's face capture quality, 0 to 1; meant for comparing shots of the same person.
        public var quality: Double?
        /// Height over width of each eye's outline; nil when Vision found no eye landmarks.
        public var leftEye: Double?
        public var rightEye: Double?
        /// The sharpest detail inside the face, on the same scale as `PhotoQualityReport.sharpness`.
        public var sharpness: Double?
        /// The lid gap over each eye's width from the face mesh (`FaceMeshEyes`), when that model is installed: open
        /// about 0.25–0.35, a laughing squint near 0.2, a blink under 0.1.
        public var meshLeftEye: Double?
        public var meshRightEye: Double?
        public init(bounds: CGRect, quality: Double? = nil, leftEye: Double? = nil, rightEye: Double? = nil, sharpness: Double? = nil,
                    meshLeftEye: Double? = nil, meshRightEye: Double? = nil) {
            self.bounds = bounds; self.quality = quality; self.leftEye = leftEye; self.rightEye = rightEye; self.sharpness = sharpness
            self.meshLeftEye = meshLeftEye; self.meshRightEye = meshRightEye
        }
        /// Both eyes look closed at `threshold`, by `EyeState`.
        public func eyesClosed(below threshold: Double) -> Bool {
            EyeState.closed(vision: leftEye.flatMap { l in rightEye.map { (l, $0) } }, mesh: meshLeftEye.flatMap { l in meshRightEye.map { (l, $0) } }, below: threshold)
        }
    }
    /// Edge crispness of the photo's most detailed areas: about 1 for a pixel-sharp edge, falling as edges spread.
    /// Nil when the photo has too little contrast to tell (fog, a plain sky).
    public var sharpness: Double?
    /// The same measure inside the subject (the faces, or what draws attention), which is what focus is judged on.
    public var subjectSharpness: Double?
    /// The crispest detail anywhere in the photo (its second-sharpest tile). Shake and motion soften every part of a
    /// frame; a shallow depth of field leaves this high.
    public var peakSharpness: Double?
    public var subject: CGRect?
    /// Median and 90th-percentile luminance, 0 to 1, as displayed.
    public var brightness: Double
    public var brightPercentile: Double
    /// Fractions of the photo clipped to white (any channel) and crushed to black.
    public var highlights: Double
    public var shadows: Double
    /// Vision's overall aesthetics score, -1 to 1, and whether it considers the photo a utility shot (a document, a
    /// receipt, a screenshot).
    public var aesthetics: Double?
    public var isUtility: Bool
    /// How far the near-neutral midtones sit from grey, as a distance in rgb chromaticity: up to about 0.03 for a
    /// neutral balance, 0.05 and up for a cast the eye sees at once (tungsten left at daylight, a green fluorescent tint).
    /// Nil when too little of the photo is near neutral to tell.
    public var colorCast: Double?
    public var faces: [Face]
    /// Seconds since 1970 from the EXIF capture time and sub-seconds, read as if UTC: comparable within one camera.
    public var captureDate: Double?
    public var camera: String
    public init(sharpness: Double? = nil, subjectSharpness: Double? = nil, subject: CGRect? = nil, brightness: Double = 0.4, brightPercentile: Double = 0.7,
                highlights: Double = 0, shadows: Double = 0, aesthetics: Double? = nil, isUtility: Bool = false, colorCast: Double? = nil, faces: [Face] = [], captureDate: Double? = nil, camera: String = "") {
        self.sharpness = sharpness; self.subjectSharpness = subjectSharpness; self.subject = subject; self.brightness = brightness
        self.brightPercentile = brightPercentile; self.highlights = highlights; self.shadows = shadows; self.aesthetics = aesthetics
        self.isUtility = isUtility; self.colorCast = colorCast; self.faces = faces; self.captureDate = captureDate; self.camera = camera
    }
}

public enum PhotoQualityAnalyzer {
    /// Changes whenever a measure changes, so cached reports from an older build are measured again. Feature prints of
    /// different revisions can't be compared, so a new macOS with a new default revision measures again too.
    /// v5 measures the camera preview where there is one, so its feature prints are not compared with v4's.
    public static var version: String { "quality-v5-print\(VNGenerateImageFeaturePrintRequest.defaultRevision)" }
    /// Long edge the photo is measured at: sharp enough to see a missed focus, small enough to stay quick.
    public static let pixelSize = 2048
    /// The smallest camera preview measured instead of the photo: Sony's 1616-pixel one still shows a missed focus.
    public static let previewMinimum = 1600

    /// Measures the photo at `url`. The feature print is returned archived, for `BurstDetector`.
    public static func analyze(_ url: URL) throws -> (report: PhotoQualityReport, featurePrint: Data?) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = ImageDecode.analysisImage(source, url: url, pixelSize: pixelSize, minimum: previewMinimum)
        else { throw CocoaError(.fileReadCorruptFile) }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        var result = try analyze(image)
        result.report.captureDate = captureDate(properties)
        result.report.camera = (properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any])?[kCGImagePropertyTIFFModel as String] as? String ?? ""
        return result
    }

    /// Measures an upright image.
    public static func analyze(_ image: CGImage) throws -> (report: PhotoQualityReport, featurePrint: Data?) {
        let pixels = try Luminance(image)
        let handler = VNImageRequestHandler(cgImage: image)
        let landmarks = VNDetectFaceLandmarksRequest()
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        let aesthetics = VNCalculateImageAestheticsScoresRequest()
        let print = VNGenerateImageFeaturePrintRequest()
        // Each request reports its own failure; one that cannot run leaves its measure out instead of the whole report.
        for request in [landmarks, saliency, aesthetics, print] as [VNRequest] { try? handler.perform([request]) }
        // Vision reports full confidence even for a "face" in dark rock; the landmark fit is what gives such a one away
        // (0.71 on that sample, 0.82 and up on real faces). A face left out only means no face-based judgement.
        let observations = (landmarks.results ?? []).filter { $0.boundingBox.width > 0.02 && ($0.landmarks?.confidence ?? 0) >= 0.75 }
        var qualities: [Double?] = observations.map { _ in nil }
        if !observations.isEmpty {
            let capture = VNDetectFaceCaptureQualityRequest()
            capture.inputFaceObservations = observations
            if (try? handler.perform([capture])) != nil, let results = capture.results, results.count == observations.count {
                qualities = results.map { $0.faceCaptureQuality.map(Double.init) }
            }
        }

        var report = PhotoQualityReport()
        let size = CGSize(width: image.width, height: image.height)
        report.faces = zip(observations, qualities).map { face, quality in
            let bounds = flipped(face.boundingBox)
            // The mesh's lids too, on faces large enough to judge.
            let mesh = bounds.width >= PhotoQualityReport.Face.judgedWidth
                ? FaceMeshEyes.openness(in: image, face: CGRect(x: bounds.minX * size.width, y: bounds.minY * size.height,
                                                                width: bounds.width * size.width, height: bounds.height * size.height)) : nil
            return PhotoQualityReport.Face(bounds: bounds, quality: quality,
                                           leftEye: face.landmarks?.leftEye.flatMap { openness($0.pointsInImage(imageSize: size)) },
                                           rightEye: face.landmarks?.rightEye.flatMap { openness($0.pointsInImage(imageSize: size)) },
                                           sharpness: pixels.sharpness(in: bounds), meshLeftEye: mesh?.left, meshRightEye: mesh?.right)
        }
        // The subject is the faces that matter (the largest and those near its size), else what Vision finds draws the
        // eye, unless that is most of the frame. A face too small to judge its focus on is not the subject.
        let largest = report.faces.map { $0.bounds.width }.max() ?? 0
        let prominent = report.faces.filter { $0.bounds.width >= max(largest * 0.4, PhotoQualityReport.Face.judgedWidth) }.map(\.bounds)
        if let first = prominent.first {
            report.subject = prominent.dropFirst().reduce(first) { $0.union($1) }
        } else if let salient = (saliency.results?.first?.salientObjects ?? []).map({ flipped($0.boundingBox) }).reduce(nil, { ($0 ?? $1).union($1) as CGRect? }),
                  salient.width * salient.height < 0.7 {
            report.subject = salient
        }
        report.sharpness = pixels.sharpness()
        report.peakSharpness = pixels.sharpness(best: true)
        report.subjectSharpness = report.subject.flatMap { pixels.sharpness(in: $0, best: true) } ?? report.sharpness
        (report.brightness, report.brightPercentile, report.highlights, report.shadows) = pixels.exposure()
        report.colorCast = pixels.colorCast
        if let score = aesthetics.results?.first {
            report.aesthetics = Double(score.overallScore); report.isUtility = score.isUtility
        }
        let featurePrint = try print.results?.first.map { try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
        return (report, featurePrint)
    }

    /// Distance between two archived feature prints; about 0 for the same picture.
    public static func distance(_ a: Data, _ b: Data) -> Double? {
        guard let first = featurePrint(a), let second = featurePrint(b) else { return nil }
        var distance: Float = 0
        do { try first.computeDistance(&distance, to: second) } catch { return nil }
        return Double(distance)
    }
    public static func featurePrint(_ data: Data) -> VNFeaturePrintObservation? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data)
    }

    /// Vision's rectangles start at the bottom left; the reports use the top left, as views do.
    static func flipped(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Height over width of an eye outline, measured across the line between its corners (the two points farthest apart),
    /// so a tilted head reads the same as an upright one. An open eye is about 0.3, a closed one under about 0.15.
    static func openness(_ points: [CGPoint]) -> Double? {
        guard points.count >= 4 else { return nil }
        var corners = (points[0], points[1]), widest = 0.0
        for i in points.indices { for j in points.indices where j > i {
            let d = hypot(points[i].x - points[j].x, points[i].y - points[j].y)
            if d > widest { widest = d; corners = (points[i], points[j]) }
        } }
        guard widest > 0 else { return nil }
        let axis = CGPoint(x: (corners.1.x - corners.0.x) / widest, y: (corners.1.y - corners.0.y) / widest)
        let offsets = points.map { ($0.x - corners.0.x) * -axis.y + ($0.y - corners.0.y) * axis.x }
        return Double(((offsets.max() ?? 0) - (offsets.min() ?? 0)) / widest)
    }

    /// The EXIF capture time with its sub-seconds, as seconds since 1970 read as UTC.
    static func captureDate(_ properties: [String: Any]) -> Double? {
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        guard let text = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String ?? tiff[kCGImagePropertyTIFFDateTime as String] as? String else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let date = formatter.date(from: String(text.prefix(19))) else { return nil }
        let subseconds = (exif[kCGImagePropertyExifSubsecTimeOriginal as String] as? String).flatMap { digits in
            Double("0." + digits.filter(\.isNumber))
        } ?? 0
        return date.timeIntervalSince1970 + subseconds
    }
}

/// The photo's displayed luminance and clipping, read once, with the tile measures the sharpness estimates share.
struct Luminance {
    let width: Int, height: Int
    /// Rec. 709 luma of the gamma-encoded values, 0 to 255.
    let luma: [UInt8]
    /// Pixels with any channel at white.
    let clipped: Int
    /// `PhotoQualityReport.colorCast`.
    let colorCast: Double?
    let tileSize: Int
    let columns: Int, rows: Int
    /// Per tile: how sharp its edges are relative to its contrast, or nil where it has too little contrast to tell.
    let tiles: [Double?]

    init(_ image: CGImage) throws {
        width = image.width; height = image.height
        guard width >= 16, height >= 16, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw CocoaError(.fileReadCorruptFile) }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { throw CocoaError(.fileReadCorruptFile) }
        let rgba = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var luma = [UInt8](repeating: 0, count: width * height), clipped = 0
        // The grey-world estimate over pixels that are nearly neutral and neither dark nor clipped: what should be
        // grey shows the balance, while a red jacket or a blue sky would only show the subject. A cast strong enough to
        // leave little near neutral is measured over every such pixel instead.
        var neutral = (count: 0, r: 0, g: 0, b: 0), lit = (count: 0, r: 0, g: 0, b: 0)
        for i in 0..<(width * height) {
            let r = Int(rgba[i * 4]), g = Int(rgba[i * 4 + 1]), b = Int(rgba[i * 4 + 2])
            let y = (r * 54 + g * 183 + b * 19) >> 8
            luma[i] = UInt8(y)
            let high = max(r, g, b)
            if high >= 254 { clipped += 1; continue }
            guard y >= 40 else { continue }
            lit.count += 1; lit.r += r; lit.g += g; lit.b += b
            if (high - min(r, g, b)) * 100 < high * 50 { neutral.count += 1; neutral.r += r; neutral.g += g; neutral.b += b }
        }
        self.luma = luma; self.clipped = clipped
        let sample = neutral.count * 50 >= width * height ? neutral : lit
        let total = Double(sample.r + sample.g + sample.b)
        if sample.count * 50 >= width * height, total > 0 {
            let third = 1 / 3.0
            let r = Double(sample.r) / total - third, g = Double(sample.g) / total - third, b = Double(sample.b) / total - third
            colorCast = (r * r + g * g + b * b).squareRoot()
        } else { colorCast = nil }
        tileSize = max(24, max(width, height) / 32)
        columns = (width + tileSize - 1) / tileSize; rows = (height + tileSize - 1) / tileSize
        tiles = Self.measureTiles(luma, width: width, height: height, tileSize: tileSize, columns: columns, rows: rows)
    }

    /// Per tile, the steepest gradients (98th percentile) over the tile's contrast (1st to 99th percentile of luma).
    /// A crisp edge climbs half its contrast per pixel; one spread over `s` pixels climbs about 0.4/s of it. Tiles with
    /// less than about 8% contrast are only noise or a smooth gradient and are left out. Scaled so a crisp edge is 1.
    private static func measureTiles(_ luma: [UInt8], width: Int, height: Int, tileSize: Int, columns: Int, rows: Int) -> [Double?] {
        var tiles = [Double?](repeating: nil, count: columns * rows)
        var gradients = [Int](repeating: 0, count: 256), levels = [Int](repeating: 0, count: 256)
        for row in 0..<rows {
            for column in 0..<columns {
                let x0 = max(1, column * tileSize), x1 = min(width - 1, (column + 1) * tileSize)
                let y0 = max(1, row * tileSize), y1 = min(height - 1, (row + 1) * tileSize)
                guard x1 - x0 >= 8, y1 - y0 >= 8 else { continue }
                for i in 0..<256 { gradients[i] = 0; levels[i] = 0 }
                for y in y0..<y1 {
                    let line = y * width
                    for x in x0..<x1 {
                        let gx = Int(luma[line + x + 1]) - Int(luma[line + x - 1])
                        let gy = Int(luma[line + width + x]) - Int(luma[line - width + x])
                        // Half the central difference is the climb per pixel, 0 to 255.
                        gradients[min(255, Int((Double(gx * gx + gy * gy)).squareRoot() / 2))] += 1
                        levels[Int(luma[line + x])] += 1
                    }
                }
                let count = (x1 - x0) * (y1 - y0)
                let low = percentile(levels, count, 0.01), high = percentile(levels, count, 0.99)
                let contrast = high - low
                guard contrast >= 20 else { continue }
                tiles[row * columns + column] = min(1.5, percentile(gradients, count, 0.98) / contrast / 0.5)
            }
        }
        return tiles
    }

    private static func percentile(_ histogram: [Int], _ count: Int, _ fraction: Double) -> Double {
        let target = Int(Double(count) * fraction)
        var seen = 0
        for (value, n) in histogram.enumerated() {
            seen += n
            if seen > target { return Double(value) }
        }
        return 255
    }

    /// The photo's detailed areas: the 90th percentile of its tiles, or nil with fewer than three tiles to judge.
    /// `best` takes the second-sharpest tile instead, for a subject, where an in-focus eye is enough.
    func sharpness(in region: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1), best: Bool = false) -> Double? {
        let c0 = max(0, Int(region.minX * Double(width)) / tileSize), c1 = min(columns - 1, Int(region.maxX * Double(width)) / tileSize)
        let r0 = max(0, Int(region.minY * Double(height)) / tileSize), r1 = min(rows - 1, Int(region.maxY * Double(height)) / tileSize)
        guard c0 <= c1, r0 <= r1 else { return nil }
        var values: [Double] = []
        for row in r0...r1 { for column in c0...c1 { if let value = tiles[row * columns + column] { values.append(value) } } }
        values.sort()
        if best { return values.isEmpty ? nil : values[max(0, values.count - 2)] }
        guard values.count >= 3 else { return nil }
        return values[min(values.count - 1, Int(Double(values.count) * 0.9))]
    }

    /// Median and 90th-percentile luminance (0 to 1), and the fractions clipped to white and crushed to black.
    func exposure() -> (Double, Double, Double, Double) {
        var histogram = [Int](repeating: 0, count: 256)
        for value in luma { histogram[Int(value)] += 1 }
        let count = luma.count
        let median = Self.percentile(histogram, count, 0.5) / 255, bright = Self.percentile(histogram, count, 0.9) / 255
        let crushed = histogram[0...3].reduce(0, +)
        return (median, bright, Double(clipped) / Double(count), Double(crushed) / Double(count))
    }
}
