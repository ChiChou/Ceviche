import CoreImage
import CoreML
import Vision

/// Optional local prototype. Uses the same Vision landmark observations as portrait quality analysis.
public enum BlemishDetector {
    public static var modelURL: URL? { BundledModel.blemishes.url }

    struct Candidate {
        var spot: DustSpot
        var confidence: Float
    }

    static func candidates(in image: CGImage, modelURL: URL, sensitivity: Double, region: CGRect?) throws -> (faces: Int, spots: [DustSpot]) {
        let request = VNDetectFaceLandmarksRequest()
        var regions: [(CGRect, VNFaceLandmarks2D?)]
        if let region {
            regions = [(region, nil)]
        } else {
            try VNImageRequestHandler(cgImage: image).perform([request])
            regions = (request.results ?? []).map { ($0.boundingBox, $0.landmarks) }
        }
        guard !regions.isEmpty else { return (0, []) }
        let model = try VNCoreMLModel(for: MLModel(contentsOf: modelURL))
        let frame = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        func search(_ b: CGRect, features: VNFaceLandmarks2D?, contextScale: Double) throws -> [Candidate] {
            var found: [Candidate] = []
            let box = CGRect(x: b.minX * frame.width, y: (1 - b.maxY) * frame.height,
                             width: b.width * frame.width, height: b.height * frame.height)
            let side = max(box.width, box.height) * contextScale
            let crop = CGRect(x: box.midX - side/2, y: box.midY - side/2, width: side, height: side).integral.intersection(frame)
            guard let portrait = image.cropping(to: crop) else { return [] }
            let detection = VNCoreMLRequest(model: model)
            detection.imageCropAndScaleOption = .scaleFill
            try VNImageRequestHandler(cgImage: portrait).perform([detection])
            guard let mask = (detection.results?.first as? VNCoreMLFeatureValueObservation)?.featureValue.multiArrayValue,
                  mask.shape.map(\.intValue) == [1, 1, 768, 768], mask.dataType == .float32 else { throw EditorError.render }
            let protected = [features?.leftEye, features?.rightEye, features?.leftEyebrow, features?.rightEyebrow, features?.outerLips]
                .compactMap { region -> CGRect? in
                    guard let points = region?.normalizedPoints, !points.isEmpty else { return nil }
                    let positions = points.map { CGPoint(x: box.minX + $0.x * box.width, y: box.maxY - $0.y * box.height) }
                    return positions.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
                        .insetBy(dx: -0.015 * box.width, dy: -0.015 * box.height)
                }
            // Vision's face box ends around the brows. Include the forehead while excluding the crop's background.
            let skin = CGRect(x: box.minX, y: box.minY - box.height * 0.24, width: box.width, height: box.height * 1.24)
            let threshold = Float(0.85 - 0.7 * sensitivity)
            for component in components(mask, threshold: threshold) {
                let bounds = component.bounds
                let point = CGPoint(x: crop.minX + bounds.midX / 768 * crop.width, y: crop.minY + bounds.midY / 768 * crop.height)
                let inside = region != nil ? box.contains(point) : hypot((point.x - skin.midX) / (skin.width/2), (point.y - skin.midY) / (skin.height/2)) < 1
                guard inside,
                      !protected.contains(where: { $0.contains(point) }) else { continue }
                let radius = max(bounds.width * crop.width, bounds.height * crop.height) / 768 * 0.8
                let spot = DustSpot(center: MaskPoint(x: point.x/frame.width, y: 1 - point.y/frame.height),
                                    radius: radius / min(frame.width, frame.height))
                found.append(Candidate(spot: spot, confidence: component.peak))
            }
            return found
        }
        var candidates: [Candidate] = []
        for (box, features) in regions {
            var found = try search(box, features: features, contextScale: 1.5)
            // A tight manual selection can make a single mole too large in the model's 768 px input.
            // Retry with more surrounding skin while still accepting marks only inside the original box.
            if region != nil && found.isEmpty { found = try search(box, features: features, contextScale: 3) }
            candidates.append(contentsOf: found)
        }
        return (regions.count, candidates.sorted { $0.confidence > $1.confidence }.map(\.spot))
    }

    /// Eight-connected islands in the native probability map, omitting isolated pixels and broad patches.
    private static func components(_ mask: MLMultiArray, threshold: Float) -> [(bounds: CGRect, peak: Float)] {
        let side = 768, row = mask.strides[2].intValue, column = mask.strides[3].intValue
        let data = mask.dataPointer.assumingMemoryBound(to: Float.self)
        var active = [Bool](repeating: false, count: side * side)
        for y in 0..<side { for x in 0..<side { active[y * side + x] = data[y * row + x * column] >= threshold } }
        var result: [(CGRect, Float)] = []
        for seed in active.indices where active[seed] {
            var stack = [seed], count = 0, peak: Float = 0
            var bounds = CGRect.null
            active[seed] = false
            while let pixel = stack.popLast() {
                let y = pixel / side, x = pixel % side
                count += 1
                peak = max(peak, data[y * row + x * column])
                bounds = bounds.union(CGRect(x: x, y: y, width: 1, height: 1))
                for ny in max(0, y-1)...min(side-1, y+1) {
                    for nx in max(0, x-1)...min(side-1, x+1) where active[ny * side + nx] {
                        active[ny * side + nx] = false
                        stack.append(ny * side + nx)
                    }
                }
            }
            if count >= 4, max(bounds.width, bounds.height) <= 42 { result.append((bounds, peak)) }
        }
        return result
    }
}

extension RawRenderer {
    /// `faces`, when given, keeps only spots on those faces (Vision face boxes, a little grown).
    public func blemishStrokes(_ settings: Adjustments, modelURL: URL, sensitivity: Double, region: CGRect? = nil, faces only: [CGRect]? = nil) throws -> (faces: Int, strokes: [RetouchStroke]) {
        var base = settings
        base.geometry = GeometryAdjustments(); base.quarterTurns = 0; base.masks = []; base.postCropVignette = PostCropVignette()
        let input = try pipeline(base, maxDimension: 4000)
        guard let image = context.createCGImage(input, from: input.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { throw EditorError.render }
        let (faces, spots) = try BlemishDetector.candidates(in: image, modelURL: modelURL, sensitivity: sensitivity, region: region)
        let w = Double(image.width), h = Double(image.height), side = min(w, h)
        var strokes: [RetouchStroke] = []
        // Each spot is kept with the face it lies on, a little grown, so it can be told whose it is.
        let kept = only.map { $0.map { ($0, $0.insetBy(dx: -$0.width * 0.2, dy: -$0.height * 0.2)) } }
        for spot in spots {
            let owner = kept?.first { $0.1.contains(CGPoint(x: spot.center.x, y: spot.center.y)) }?.0
            if kept != nil, owner == nil { continue }
            guard settings.retouch.count + strokes.count < DustFinder.strokeLimit else { break }
            let occupied = (settings.retouch + strokes).contains { stroke in
                stroke.points.contains { hypot(($0.x - spot.center.x) * w, ($0.y - spot.center.y) * h) < max(stroke.radius, spot.radius) * side }
            }
            if !occupied {
                var stroke = RetouchStroke(mode: .heal, source: spot.center, target: spot.center, radius: DustFinder.clampedRadius(spot.radius), softness: 0.4, opacity: 1)
                stroke.face = true; stroke.faceBox = owner
                strokes.append(stroke)
            }
        }
        var withStrokes = settings
        withStrokes.retouch += strokes
        if !strokes.isEmpty {
            let sources = try retouchSources(for: strokes, settings: withStrokes)
            for i in strokes.indices { if let source = sources[strokes[i].id] { strokes[i].source = source } }
        }
        return (faces, strokes)
    }
}
