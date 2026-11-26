import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Vision

/// Merge Best Faces: from a burst of the same group, the frame where everyone has their eyes open, faces the camera and
/// is sharp; when there is none, a base frame with each person's best face from another frame put into it.
///
/// Faces are found on a 3072-pixel reading of each frame with both Vision face detectors on overlapping tiles (a night
/// group's faces are too small for one pass), measured on each face cut out and enlarged, and paired frame to frame by
/// where they stand once the group's shift is taken out. A swap is aligned around the head, matched in brightness on the
/// band around it and blended through a feathered ellipse; it is refused when the head moved toward or away from the
/// camera, turned or tilted, when another face lies inside it, when the light differs, or when the band around the head
/// still differs after alignment (a hand, hair or a neighbour moved). Frames are read with the decoder's defaults.
public final class BestFacesMerger: @unchecked Sendable {
    public struct Face: Sendable {
        /// Full-resolution pixels of its frame, top-left origin.
        public let box: CGRect
        /// Each eye's openness from Vision's outline and from the face mesh's lids (`EyeState`); nil when too small to
        /// measure or without the mesh.
        public let vision: (Double, Double)?
        public let mesh: (Double, Double)?
        /// How open the eyes are, 0 closed to about 0.3 open: the mesh's more open eye, else Vision's.
        public var eyes: Double? { mesh.map { max($0.0, $0.1) } ?? vision.map { max($0.0, $0.1) } }
        public let yaw: Double?, pitch: Double?, roll: Double?
        public let quality: Double?
        /// Edge crispness of the face; compared only between one person's faces.
        public let sharpness: Double
    }
    public enum Problem: Hashable, Sendable { case eyesClosed, turned, lookingUpOrDown, soft }
    public struct Person: Sendable {
        /// Per frame: this person's face, or nil where they weren't found.
        public let faces: [Face?]
        public let scores: [Double?]
        public let problems: [[Problem]]
        public func isGood(_ frame: Int) -> Bool { faces[frame] != nil && problems[frame].isEmpty }
    }
    public enum Refusal: Hashable, Sendable {
        case notInBase, outOfFrame, sizeChanged, turned, tilted, faceInside, headMoved, lightDiffers, surroundingsDiffer
    }
    public struct Plan: Sendable {
        /// The head area replaced, full pixels of the base, top-left origin.
        public let region: CGRect
        let ring: CGRect
        /// Base pixel = source pixel + shift.
        let shift: CGVector
        let gain: Double
    }
    public struct Swap: Sendable {
        public let refusals: [Refusal]
        public let plan: Plan?
        public var accepted: Bool { refusals.isEmpty && plan != nil }
    }

    struct Frame {
        let full: CIImage
        let size: CGSize
        let analysis: CGImage
        let scale: Double
        let captureDate: Double?
        var faces: [Face] = []
    }

    public let names: [String]
    /// The photos, in capture order.
    let urls: [URL]
    public let persons: [Person]
    /// A frame where everyone is good, the best of them; nil when there is none.
    public let bestShot: Int?
    /// The best shot, or the frame with the most good faces.
    public let suggestedBase: Int
    public var size: CGSize { frames[suggestedBase].size }
    let frames: [Frame]
    /// Each frame's shift onto the first, full pixels.
    private let toFirst: [CGVector]
    /// Each photo's own retouching by URL, burnt into it before faces are blended.
    public var retouch: [URL: [RetouchStroke]] = [:]
    private let lock = NSLock()
    private var swapCache: [Int: [[Swap?]]] = [:]

    static let analysisEdge = 3072.0
    static let eyePixels = 60.0

    /// Reads the frames, in capture order, and finds and pairs everyone's faces.
    public init(urls: [URL], progress: @Sendable (Double, String) -> Void = { _, _ in }) throws {
        var frames: [Frame] = []
        for (index, url) in urls.enumerated() {
            try Task.checkCancellation()
            progress(Double(index) / Double(urls.count) * 0.95, L10n.tr("Finding faces in \(url.lastPathComponent)…"))
            frames.append(try autoreleasepool { try Self.read(url) })
        }
        let order = frames.indices.sorted { (frames[$0].captureDate ?? 0, urls[$0].lastPathComponent) < (frames[$1].captureDate ?? 0, urls[$1].lastPathComponent) }
        guard order.count >= 2 else { throw BestFacesError.tooFewPhotos }
        guard frames.contains(where: { !$0.faces.isEmpty }) else { throw BestFacesError.noFaces }
        // Frames of one group only: every two of them have their faces mostly in the same places. A photo of another
        // moment, place or group stops the merge rather than being swapped from.
        progress(0.96, L10n.tr("Comparing photos…"))
        for (n, i) in order.enumerated() { for j in order[(n + 1)...] {
            try Task.checkCancellation()
            if !Self.sameGroup(frames[i], frames[j]) { throw BestFacesError.notOneGroup(urls[i].lastPathComponent, urls[j].lastPathComponent) }
        } }
        frames = order.map { frames[$0] }
        names = order.map { urls[$0].lastPathComponent }
        self.urls = order.map { urls[$0] }
        self.frames = frames

        // People: each frame's faces paired with the previous frame's.
        var toFirst: [CGVector] = [.zero]
        var tracks: [[Int?]] = frames[0].faces.indices.map { i in frames.indices.map { $0 == 0 ? i : nil } }
        var anchors = frames[0].faces.map { CGPoint(x: $0.box.midX, y: $0.box.midY) }
        for f in frames.indices.dropFirst() {
            let (matched, step) = Self.match(frames[f - 1], frames[f])
            toFirst.append(CGVector(dx: toFirst[f - 1].dx + step.dx, dy: toFirst[f - 1].dy + step.dy))
            for t in tracks.indices { if let i = tracks[t][f - 1], let j = matched[i] { tracks[t][f] = j } }
            for j in frames[f].faces.indices where !matched.values.contains(j) {
                tracks.append(frames.indices.map { $0 == f ? j : nil })
                anchors.append(CGPoint(x: frames[f].faces[j].box.midX + toFirst[f].dx, y: frames[f].faces[j].box.midY + toFirst[f].dy))
            }
        }
        self.toFirst = toFirst
        let order2 = anchors.indices.sorted { anchors[$0].x < anchors[$1].x }
        let persons = order2.map { t in
            Self.judge(frames.indices.map { f in tracks[t][f].map { frames[f].faces[$0] } })
        }
        self.persons = persons
        let count = frames.indices.map { f in persons.filter { $0.isGood(f) }.count }
        let total = frames.indices.map { f in persons.compactMap { $0.scores[f] }.reduce(0, +) }
        bestShot = frames.indices.filter { f in persons.allSatisfy { $0.isGood(f) } }.max { total[$0] < total[$1] }
        suggestedBase = bestShot ?? frames.indices.max { (count[$0], total[$0]) < (count[$1], total[$1]) }!
        progress(1, L10n.tr("Comparing faces…"))
    }

    // MARK: Choices
    /// Every person's face from every other frame, checked as a swap into `base`.
    public func swaps(base: Int) -> [[Swap?]] {
        lock.lock(); if let cached = swapCache[base] { lock.unlock(); return cached }; lock.unlock()
        let shift = frames.indices.map { CGVector(dx: toFirst[$0].dx - toFirst[base].dx, dy: toFirst[$0].dy - toFirst[base].dy) }
        let result: [[Swap?]] = persons.map { person in
            frames.indices.map { f -> Swap? in
                guard f != base, let face = person.faces[f] else { return nil }
                guard let target = person.faces[base] else { return Swap(refusals: [.notInBase], plan: nil) }
                return check(base: base, target: target, source: f, face: face, shift: shift[f])
            }
        }
        lock.lock(); swapCache[base] = result; lock.unlock()
        return result
    }

    /// Each person's frame: the base's face where it is good, else the best good face whose swap is accepted.
    public func preset(base: Int) -> [Int] {
        let swaps = swaps(base: base)
        return persons.indices.map { p in
            let person = persons[p]
            guard !person.isGood(base) else { return base }
            let options = frames.indices.filter { $0 != base && person.isGood($0) && swaps[p][$0]?.accepted == true }
            return options.max { (person.scores[$0] ?? 0) < (person.scores[$1] ?? 0) } ?? base
        }
    }

    // MARK: Images
    /// The base with each person's face from their chosen frame. A refused swap that has a plan is made anyway: the
    /// person chose it.
    public func composite(base: Int, choice: [Int]) -> CIImage {
        let swaps = swaps(base: base)
        var image = frames[base].full
        for (p, f) in choice.enumerated() where f != base {
            guard let plan = swaps[p][f]?.plan else { continue }
            image = blend(image, source: frames[f].full, plan: plan, height: frames[base].size.height)
        }
        return image
    }
    public func preview(base: Int, choice: [Int], longEdge: Double) -> CGImage? {
        let image = composite(base: base, choice: choice)
        let s = min(1, longEdge / max(image.extent.width, image.extent.height))
        let small = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1])
        return Self.context.createCGImage(small, from: small.extent.integral, format: .RGBA8, colorSpace: Self.displaySpace)
    }
    /// A person's face in one frame, square around the head, `pixels` on a side.
    public func face(person: Int, frame: Int, pixels: Int) -> CGImage? {
        guard let face = persons[person].faces[frame] else { return nil }
        let side = max(face.box.width, face.box.height) * 1.7
        let region = CGRect(x: face.box.midX - side / 2, y: face.box.midY - side / 2, width: side, height: side)
        return Self.render(frames[frame].full, region: region, height: frames[frame].size.height, edge: Double(pixels))
    }
    /// The result, like the other merges: every photo developed without a tone response under the base photo's white
    /// balance (a processed photo linearized through its profile) and with its own `retouch`, the chosen faces blended in,
    /// so it develops with the base photo's edits. A DNG for RAW photos, else as `url`'s extension names.
    public func write(base: Int, choice: [Int], to url: URL, progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) throws {
        let frames = try urls.map { try HDRMergeDecoder.metadata($0) }
        guard Set(frames.map(\.isRAW)).count == 1 else { throw PanoramaError.message(L10n.tr("Merge RAW photos or processed photos, not both.")) }
        var metadata = frames[base].panorama
        metadata.captureTime = PanoramaFrameMetadata.captureTime(after: frames.map(\.captureTime))
        let balance = (temperature: metadata.temperature, tint: metadata.tint)
        let swaps = swaps(base: base)
        progress(0.1, L10n.tr("Blending faces"))
        func developed(_ f: Int) throws -> CIImage {
            try HDRMergeDecoder.developedImage(urls[f], metadata: frames[f], longEdge: nil, whiteBalance: balance, retouch: retouch[urls[f]] ?? [])
        }
        var image = try developed(base)
        let height = image.extent.height
        for (p, f) in choice.enumerated() where f != base {
            guard let plan = swaps[p][f]?.plan else { continue }
            try Task.checkCancellation()
            image = blend(image, source: try developed(f), plan: plan, height: height, linear: true)
        }
        let width = Int(image.extent.width.rounded(.down)), rows = Int(height.rounded(.down))
        var pixels = [Float](repeating: 0, count: width * rows * 4)
        pixels.withUnsafeMutableBytes {
            Self.linearContext.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 16, bounds: CGRect(x: 0, y: 0, width: width, height: rows),
                                      format: .RGBAf, colorSpace: PanoramaDecoder.space)
        }
        for i in pixels.indices where !pixels[i].isFinite { pixels[i] = 0 }
        let raster = PanoramaRaster(width: width, height: rows, rgba: pixels)
        let writer = ToolResultWriter(dng: PanoramaDNGWriter(metadata: metadata, kind: .bestFaces, preview: HDRMergeFinishing.picture(raster, maxDimension: 1024),
                                                             source: .merge(urls[base], process: PanoramaDNGWriter.Kind.bestFaces.rawValue)), source: urls[base])
        let format = url.pathExtension.uppercased()
        try writer.write(raster, to: url, progress: { progress(0.5 + 0.5 * $0, L10n.tr("Writing \(format)")) }, cancelled: { Task.isCancelled })
    }
    /// Fresh for each merge: a shared context would keep the full-size photos developed through it.
    static var linearContext: CIContext { CIContext(options: [.workingColorSpace: PanoramaDecoder.space, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false]) }

    /// A frame for the filmstrip, `pixels` on its long side.
    public func thumbnail(frame: Int, pixels: Int) -> CGImage? {
        let image = frames[frame].analysis
        return Self.resized(image, scale: Double(pixels) / Double(max(image.width, image.height)))
    }
    /// How many people look good in the frame.
    public func goodCount(_ frame: Int) -> Int { persons.filter { $0.isGood(frame) }.count }

    // MARK: Reading
    static let context = CIContext(options: [.cacheIntermediates: false])
    static let displaySpace = CGColorSpace(name: CGColorSpace.displayP3)!
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static func read(_ url: URL) throws -> Frame {
        let image: CIImage
        if let raw = CIRAWFilter(imageURL: url), let output = raw.outputImage { image = output }
        else if let read = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) { image = read }
        else { throw BestFacesError.unreadable(url.lastPathComponent) }
        let full = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let size = full.extent.size
        let scale = min(1, analysisEdge / max(size.width, size.height))
        let small = full.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
        guard let analysis = context.createCGImage(small, from: small.extent.integral, format: .RGBA8, colorSpace: sRGB) else {
            throw BestFacesError.unreadable(url.lastPathComponent)
        }
        var frame = Frame(full: full, size: size, analysis: analysis, scale: Double(analysis.width) / size.width, captureDate: captureDate(url))
        frame.faces = try faces(in: frame)
        return frame
    }

    static func captureDate(_ url: URL) -> Double? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return nil }
        return PhotoQualityAnalyzer.captureDate(properties)
    }

    static func render(_ image: CIImage, region: CGRect, height: Double, edge: Double? = nil) -> CGImage? {
        let ci = CGRect(x: region.minX, y: height - region.maxY, width: region.width, height: region.height).integral
        var piece = image.cropped(to: ci).transformed(by: CGAffineTransform(translationX: -ci.minX, y: -ci.minY))
        if let edge, max(ci.width, ci.height) > edge {
            piece = piece.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: edge / max(ci.width, ci.height), kCIInputAspectRatioKey: 1])
        }
        let out = CGRect(x: 0, y: 0, width: floor(piece.extent.width), height: floor(piece.extent.height))
        guard out.width >= 1, out.height >= 1 else { return nil }
        return context.createCGImage(piece, from: out, format: .RGBA8, colorSpace: sRGB)
    }

    static func resized(_ image: CGImage, scale: Double) -> CGImage? {
        let w = max(1, Int((Double(image.width) * scale).rounded())), h = max(1, Int((Double(image.height) * scale).rounded()))
        guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        c.interpolationQuality = .high
        c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return c.makeImage()
    }

    // MARK: Faces
    /// Both detectors on the whole reading and on tiles of 0.6 × its short side enlarged to 1600 pixels, then each face
    /// measured on the full image.
    static func faces(in frame: Frame) throws -> [Face] {
        let image = frame.analysis
        let W = Double(image.width), H = Double(image.height)
        var boxes: [CGRect] = []
        func look(_ crop: CGRect) throws {
            try Task.checkCancellation()
            let crop = crop.integral.intersection(CGRect(x: 0, y: 0, width: W, height: H))
            guard crop.width >= 16, crop.height >= 16, let piece = image.cropping(to: crop) else { return }
            let s = max(1, 1600 / max(crop.width, crop.height))
            let input = s > 1 ? (resized(piece, scale: s) ?? piece) : piece
            for o in try FaceDetection.faces(cgImage: input) {
                let r = o.boundingBox
                let box = CGRect(x: crop.minX + r.minX * crop.width, y: crop.minY + (1 - r.maxY) * crop.height, width: r.width * crop.width, height: r.height * crop.height)
                if !boxes.contains(where: { FaceDetection.same($0, box) }) { boxes.append(box) }
            }
        }
        try look(CGRect(x: 0, y: 0, width: W, height: H))
        let side = min(W, H) * 0.6
        var y = 0.0
        repeat {
            var x = 0.0
            repeat { try look(CGRect(x: min(x, max(0, W - side)), y: min(y, max(0, H - side)), width: side, height: side)); x += side * 0.75 } while x + side * 0.25 < W
            y += side * 0.75
        } while y + side * 0.25 < H
        return boxes.compactMap { box in
            measure(CGRect(x: box.minX / frame.scale, y: box.minY / frame.scale, width: box.width / frame.scale, height: box.height / frame.scale), in: frame)
        }
    }

    /// Landmarks, pose and capture quality on the face cut out and enlarged; nil when the landmarks don't fit a face.
    static func measure(_ box: CGRect, in frame: Frame) -> Face? {
        let side = max(box.width, box.height) * 2
        let region = CGRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side).intersection(CGRect(origin: .zero, size: frame.size))
        guard let crop = render(frame.full, region: region, height: frame.size.height, edge: 512) else { return nil }
        let input = crop.width < 384 ? (resized(crop, scale: 384 / Double(crop.width)) ?? crop) : crop
        let size = CGSize(width: input.width, height: input.height)
        let local = CGRect(x: (box.minX - region.minX) / region.width, y: 1 - (box.maxY - region.minY) / region.height,
                           width: box.width / region.width, height: box.height / region.height)
        let handler = VNImageRequestHandler(cgImage: input)
        let landmarks = VNDetectFaceLandmarksRequest()
        landmarks.inputFaceObservations = [VNFaceObservation(boundingBox: local)]
        let pose = VNDetectFaceRectanglesRequest()
        guard (try? handler.perform([landmarks, pose])) != nil, let face = landmarks.results?.first, (face.landmarks?.confidence ?? 0) >= 0.75 else { return nil }
        let capture = VNDetectFaceCaptureQualityRequest()
        capture.inputFaceObservations = [face]
        try? handler.perform([capture])
        let posed = (pose.results ?? []).min { hypot($0.boundingBox.midX - 0.5, $0.boundingBox.midY - 0.5) < hypot($1.boundingBox.midX - 0.5, $1.boundingBox.midY - 0.5) }
        func degrees(_ n: NSNumber?) -> Double? { n.map { $0.doubleValue * 180 / .pi } }
        var vision: (Double, Double)?, mesh: (Double, Double)?
        if box.width >= eyePixels {
            if let l = face.landmarks?.leftEye.flatMap({ PhotoQualityAnalyzer.openness($0.pointsInImage(imageSize: size)) }),
               let r = face.landmarks?.rightEye.flatMap({ PhotoQualityAnalyzer.openness($0.pointsInImage(imageSize: size)) }) { vision = (l, r) }
            let s = frame.scale
            mesh = FaceMeshEyes.openness(in: frame.analysis, face: CGRect(x: box.minX * s, y: box.minY * s, width: box.width * s, height: box.height * s))
                .map { ($0.left, $0.right) }
        }
        let sharp = render(frame.full, region: box.insetBy(dx: box.width * 0.1, dy: box.height * 0.1), height: frame.size.height, edge: 256).map { Gray($0).crispness } ?? 0
        return Face(box: box, vision: vision, mesh: mesh, yaw: degrees(posed?.yaw), pitch: degrees(posed?.pitch), roll: degrees(posed?.roll),
                    quality: capture.results?.first?.faceCaptureQuality.map(Double.init), sharpness: sharp)
    }

    /// Good = eyes ≥ 0.15, turned ≤ 25°, up or down ≤ 20°, at least 80 % as sharp as this person's sharpest face.
    static func judge(_ faces: [Face?]) -> Person {
        let best = faces.compactMap { $0?.sharpness }.max() ?? 1
        var scores: [Double?] = [], problems: [[Problem]] = []
        for face in faces {
            guard let face else { scores.append(nil); problems.append([]); continue }
            let yaw = abs(face.yaw ?? 0), pitch = abs(face.pitch ?? 0), sharp = best > 0 ? face.sharpness / best : 1
            var found: [Problem] = []
            if EyeState.closed(vision: face.vision, mesh: face.mesh, below: 0.12) { found.append(.eyesClosed) }
            if yaw > 25 { found.append(.turned) }
            if pitch > 20 { found.append(.lookingUpOrDown) }
            if sharp < 0.8 { found.append(.soft) }
            scores.append(0.45 * (face.eyes.map { min(1, $0 / 0.25) } ?? 0.7) + 0.25 * (1 - min(1, yaw / 40)) + 0.2 * sharp + 0.1 * (face.quality ?? 0.5))
            problems.append(found)
        }
        return Person(faces: faces, scores: scores, problems: problems)
    }

    // MARK: Pairing
    /// Two frames of one burst: at least four-fifths of the larger frame's faces pair up.
    static func sameGroup(_ a: Frame, _ b: Frame) -> Bool {
        let most = max(a.faces.count, b.faces.count)
        return most > 0 && Double(match(a, b).pairs.count) >= 0.8 * Double(most)
    }

    /// Faces of `b` paired with those of `a` and the shift from `b` to `a`: the registration's, or the median offset of
    /// each face to its nearest when that pairs more (registration reads a dark night frame poorly).
    static func match(_ a: Frame, _ b: Frame) -> (pairs: [Int: Int], shift: CGVector) {
        var options = [registration(a, b)]
        if !a.faces.isEmpty, !b.faces.isEmpty {
            let offsets = b.faces.map { fb -> CGVector in
                let near = a.faces.min { hypot($0.box.midX - fb.box.midX, $0.box.midY - fb.box.midY) < hypot($1.box.midX - fb.box.midX, $1.box.midY - fb.box.midY) }!
                return CGVector(dx: near.box.midX - fb.box.midX, dy: near.box.midY - fb.box.midY)
            }
            let dx = offsets.map(\.dx).sorted(), dy = offsets.map(\.dy).sorted()
            options.append(CGVector(dx: dx[dx.count / 2], dy: dy[dy.count / 2]))
        }
        return options.map { (pairs(a.faces, b.faces, $0), $0) }.max { $0.0.count < $1.0.count }!
    }
    /// A pair is closer than 0.7 face widths once `b` is moved by `d`.
    static func pairs(_ a: [Face], _ b: [Face], _ d: CGVector) -> [Int: Int] {
        var candidates: [(Int, Int, Double)] = []
        for (i, fa) in a.enumerated() { for (j, fb) in b.enumerated() {
            let dist = hypot(fb.box.midX + d.dx - fa.box.midX, fb.box.midY + d.dy - fa.box.midY)
            if dist < 0.7 * max(fa.box.width, fb.box.width) { candidates.append((i, j, dist)) }
        } }
        var result: [Int: Int] = [:], used = Set<Int>()
        for (i, j, _) in candidates.sorted(by: { $0.2 < $1.2 }) where result[i] == nil && !used.contains(j) { result[i] = j; used.insert(j) }
        return result
    }
    /// The shift from `b` to `a` in full pixels, by registration of 1024-pixel copies.
    static func registration(_ a: Frame, _ b: Frame) -> CGVector {
        let edge = 1024.0
        guard let ra = resized(a.analysis, scale: edge / Double(a.analysis.width)), let rb = resized(b.analysis, scale: edge / Double(b.analysis.width)) else { return .zero }
        let s = shift(reference: ra, floating: rb)
        let k = Double(a.analysis.width) / edge / a.scale
        return CGVector(dx: s.dx * k, dy: s.dy * k)
    }
    /// The shift carrying `floating` onto `reference`, their pixels, top-left origin: Vision's translational
    /// registration, its sign settled by which reading leaves the smaller difference.
    static func shift(reference: CGImage, floating: CGImage) -> CGVector {
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: floating)
        try? VNImageRequestHandler(cgImage: reference).perform([request])
        let t = request.results?.first?.alignmentTransform ?? .identity
        let (a, b) = (Gray(reference), Gray(floating))
        let candidates = [CGVector(dx: t.tx, dy: -t.ty), CGVector(dx: t.tx, dy: t.ty), CGVector(dx: -t.tx, dy: t.ty), CGVector(dx: -t.tx, dy: -t.ty), .zero]
        return candidates.min { Gray.residual(a, b, $0) < Gray.residual(a, b, $1) }!
    }

    // MARK: Swapping
    static func region(_ face: CGRect) -> CGRect {
        CGRect(x: face.midX - 0.8 * face.width, y: face.minY - 0.6 * face.height, width: 1.6 * face.width, height: 2.05 * face.height)
    }
    /// Above this, the band around the head differs too much after alignment (mean luma, 0–255): clean swaps measured
    /// 4–12 on a night group, a head that moved against the people behind it 15–22.
    static let bandLimit = 14.0

    func check(base: Int, target: Face, source: Int, face: Face, shift: CGVector) -> Swap {
        var refusals: [Refusal] = []
        let ratio = face.box.width / target.box.width
        if ratio < 0.87 || ratio > 1.15 { refusals.append(.sizeChanged) }
        if let a = face.yaw, let b = target.yaw, abs(a - b) > 20 { refusals.append(.turned) }
        if let a = face.roll, let b = target.roll, abs(a - b) > 12 { refusals.append(.tilted) }
        let region = Self.region(target.box), feather = 0.1 * region.width
        let core = region.insetBy(dx: feather, dy: feather)
        for other in frames[base].faces where other.box != target.box {
            let i = core.intersection(other.box)
            if !i.isNull, i.width * i.height > 0.08 * other.box.width * other.box.height { refusals.append(.faceInside); break }
        }
        let margin = 0.35 * target.box.width
        let ring = region.insetBy(dx: -margin, dy: -margin).intersection(CGRect(origin: .zero, size: frames[base].size))
        guard let a = Self.render(frames[base].full, region: ring, height: frames[base].size.height, edge: 384),
              let b = Self.render(frames[source].full, region: ring.offsetBy(dx: -shift.dx, dy: -shift.dy), height: frames[source].size.height, edge: 384)
        else { return Swap(refusals: [.outOfFrame], plan: nil) }
        let local = Self.shift(reference: a, floating: b)
        let k = ring.width / Double(a.width)
        if hypot(local.dx * k, local.dy * k) > 0.5 * target.box.width { refusals.append(.headMoved) }
        let ga = Gray(a), gb = Gray(b)
        let cx = (region.midX - ring.minX) / ring.width, cy = (region.midY - ring.minY) / ring.height
        let rx = core.width / 2 / ring.width, ry = core.height / 2 / ring.height
        let band: (Double, Double) -> Bool = { x, y in pow((x - cx) / (rx * 1.15), 2) + pow((y - cy) / (ry * 1.15), 2) > 1 }
        var sa = 0.0, sb = 0.0
        let step = max(1, ga.w / 128)
        for y in stride(from: 0, to: ga.h, by: step) { for x in stride(from: 0, to: ga.w, by: step) where band(Double(x) / Double(ga.w), Double(y) / Double(ga.h)) {
            if let vb = gb.sample(Double(x) - local.dx, Double(y) - local.dy) { sa += Double(ga[x, y]); sb += Double(vb) }
        } }
        let gain = sb > 0 ? sa / sb : 1
        if gain < 0.8 || gain > 1.25 { refusals.append(.lightDiffers) }
        var gained = gb
        gained.v = gb.v.map { min(255, $0 * Float(gain)) }
        let residual = Gray.residual(ga, gained, local, inside: band)
        if !residual.isFinite || residual > Self.bandLimit { refusals.append(.surroundingsDiffer) }
        return Swap(refusals: refusals, plan: Plan(region: region, ring: ring, shift: CGVector(dx: shift.dx + local.dx * k, dy: shift.dy + local.dy * k), gain: gain))
    }

    /// `source` moved onto the composite and blended through the head's ellipse. `linear` is for linear values: the gain
    /// was measured on display values.
    func blend(_ composite: CIImage, source: CIImage, plan: Plan, height: Double, linear: Bool = false) -> CIImage {
        let r = plan.region, feather = 0.1 * r.width
        let w = Int(r.width.rounded()), h = Int(r.height.rounded())
        guard w > 0, h > 0, let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                               bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return composite }
        c.setFillColor(gray: 1, alpha: 1)
        c.fillEllipse(in: CGRect(x: feather, y: feather, width: Double(w) - 2 * feather, height: Double(h) - 2 * feather))
        guard let ellipse = c.makeImage() else { return composite }
        let hard = CIImage(cgImage: ellipse)
        let soft = hard.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: feather / 2.5]).cropped(to: hard.extent)
        let mask = soft.transformed(by: CGAffineTransform(translationX: r.minX, y: height - r.maxY))
            .composited(over: CIImage(color: .black).cropped(to: composite.extent))
        let g = CGFloat(linear ? pow(plan.gain, 2.2) : plan.gain)
        let moved = source.transformed(by: CGAffineTransform(translationX: plan.shift.dx, y: -plan.shift.dy))
            .applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: g, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
                                                          "inputBVector": CIVector(x: 0, y: 0, z: g, w: 0)])
        return moved.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: composite, kCIInputMaskImageKey: mask]).cropped(to: composite.extent)
    }
}

public enum BestFacesError: LocalizedError {
    case tooFewPhotos, noFaces, notOneGroup(String, String), unreadable(String)
    public var errorDescription: String? {
        switch self {
        case .tooFewPhotos: L10n.tr("Choose two or more photos of the same group.")
        case .noFaces: L10n.tr("No faces were found in these photos.")
        case .notOneGroup(let a, let b): L10n.tr("\(a) and \(b) don’t show the same group in the same places. Choose frames shot together.")
        case .unreadable(let name): L10n.tr("\(name) couldn’t be read.")
        }
    }
}

/// Luma 0…255, row 0 at the top.
struct Gray {
    let w: Int, h: Int
    var v: [Float]
    init(_ image: CGImage) {
        let width = image.width, height = image.height
        w = width; h = height
        var bytes = [UInt8](repeating: 0, count: width * height)
        bytes.withUnsafeMutableBytes { buffer in
            let c = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGImageAlphaInfo.none.rawValue)
            c?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        v = bytes.map(Float.init)
    }
    @inline(__always) subscript(x: Int, y: Int) -> Float { v[y * w + x] }
    @inline(__always) func sample(_ x: Double, _ y: Double) -> Float? {
        let xi = Int(x.rounded()), yi = Int(y.rounded())
        guard xi >= 0, yi >= 0, xi < w, yi < h else { return nil }
        return v[yi * w + xi]
    }
    /// RMS Laplacian over RMS gradient: how fast edges change, whatever the contrast.
    var crispness: Double {
        guard w > 2, h > 2 else { return 0 }
        var lap = 0.0, grad = 0.0
        for y in 1..<(h - 1) { for x in 1..<(w - 1) {
            let c = Double(self[x, y])
            let l = Double(self[x - 1, y]) + Double(self[x + 1, y]) + Double(self[x, y - 1]) + Double(self[x, y + 1]) - 4 * c
            let gx = Double(self[x + 1, y]) - Double(self[x - 1, y]), gy = Double(self[x, y + 1]) - Double(self[x, y - 1])
            lap += l * l; grad += gx * gx + gy * gy
        } }
        return grad > 0 ? (lap / grad).squareRoot() : 0
    }
    /// Mean absolute difference where `b`, moved by `d`, overlaps `a`; only inside `mask` (fractions of `a`) when given.
    static func residual(_ a: Gray, _ b: Gray, _ d: CGVector, inside: ((Double, Double) -> Bool)? = nil) -> Double {
        var sum = 0.0, n = 0.0
        let step = max(1, min(a.w, a.h) / 160)
        for y in stride(from: 0, to: a.h, by: step) { for x in stride(from: 0, to: a.w, by: step) {
            if let inside, !inside(Double(x) / Double(a.w), Double(y) / Double(a.h)) { continue }
            guard let vb = b.sample(Double(x) - d.dx, Double(y) - d.dy) else { continue }
            sum += Double(abs(a[x, y] - vb)); n += 1
        } }
        return n > 0 ? sum / n : .infinity
    }
}
