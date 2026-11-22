import Foundation
import CoreImage
import Metal
import simd

/// Merges overlapping RAW photos into a panorama DNG. Align once, preview each choice of options from the cached
/// alignment, then merge at full size. Use from one task at a time; long steps check `Task.isCancelled`.
public final class PanoramaMerger: @unchecked Sendable {
    public let urls: [URL]
    /// Each photo's own retouching, taken out of it before the photos are aligned: dust is in each photo's own place.
    /// Set before analysis.
    public var retouch: [URL: [RetouchStroke]] = [:]
    /// The largest panorama the merge can hold, in pixels: the GPU's largest buffer (16 bytes a pixel), about
    /// 64 bytes a pixel of memory for the blend, its copies and the encoder, and the classic-TIFF size of the DNG.
    /// Panoramas are rendered at full size up to this and reduced only beyond it.
    public lazy var maxPixels: Double = min(compositor.device.map { Double($0.maxBufferLength) / 16 } ?? .infinity,
                                            MemoryBudget.bytes / Double(48 + PanoramaCompositor.bytesPerPixel), 600e6)

    private let compositor: PanoramaCompositor
    private let context: CIContext
    private var metadata: [PanoramaFrameMetadata] = []
    /// The white balance every photo is developed with: the middle photo's as shot.
    private var whiteBalance = (temperature: 5000.0, tint: 0.0)
    private var previewTextures: [PanoramaSource] = []
    private var solution: PanoramaSolution?
    /// How the canvas is laid out: a vertical sweep runs down the picture.
    private var straightening = PanoramaGeometry.Straightening(world: matrix_identity_double3x3, transposed: false, flipped: false)
    private var gains: [Double] = []
    private var blended: [PanoramaProjection: PanoramaRaster] = [:]
    /// Filled previews, which take seconds, kept for the last few choices of options.
    private var filled: [(settings: PanoramaSettings, raster: PanoramaRaster)] = []
    public private(set) var alignment: PanoramaAlignment?

    /// Pictures made in memory that stand in for the files, one for each of `urls`: merged brackets for an HDR panorama.
    private let inputs: [PanoramaInput]?
    /// What the DNG says made it.
    var process = PanoramaDNGWriter.Kind.panorama.rawValue
    /// False leaves the shutter time and exposure bias out of the DNG, for inputs made from several exposures.
    var keepsExposure = true

    /// Photos are aligned at 1400 px, as in the panorama CLI; the preview is drawn from those copies reduced to 1000 px.
    static let registrationLongEdge = 1400, previewLongEdge = 1000

    /// `useGPU` false runs the blend on the CPU, as on a Mac without a usable GPU.
    public init(urls: [URL], useGPU: Bool = true) throws {
        guard urls.count >= 2 else { throw PanoramaError.message(L10n.tr("Choose at least two photos to merge.")) }
        self.urls = urls; inputs = nil
        compositor = PanoramaCompositor(useGPU: useGPU)
        let options: [CIContextOption: Any] = [.workingColorSpace: PanoramaDecoder.space, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false]
        context = compositor.device.map { CIContext(mtlDevice: $0, options: options) } ?? CIContext(options: options)
    }

    /// A panorama of pictures made in memory. `urls` names the photo each stands for, whose camera and place the DNG keeps.
    init(urls: [URL], inputs: [PanoramaInput], useGPU: Bool = true) throws {
        guard urls.count >= 2, inputs.count == urls.count else { throw PanoramaError.message(L10n.tr("Choose at least two photos to merge.")) }
        self.urls = urls; self.inputs = inputs
        compositor = PanoramaCompositor(useGPU: useGPU)
        let options: [CIContextOption: Any] = [.workingColorSpace: PanoramaDecoder.space, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false]
        context = compositor.device.map { CIContext(mtlDevice: $0, options: options) } ?? CIContext(options: options)
    }

    /// `retouched` false leaves the photo's own retouching out, for aligning: a fill or patch must not move features.
    private func decode(_ index: Int, longEdge: Int?, whiteBalance: (temperature: Double, tint: Double), retouched: Bool = true) throws -> PanoramaFrame {
        if let inputs { return try inputs[index].decode(longEdge) }
        return try PanoramaDecoder.decode(urls[index], longEdge: longEdge, whiteBalance: whiteBalance, context: context,
                                          retouch: retouched ? retouch[urls[index]] ?? [] : [])
    }

    // MARK: Alignment

    public func align(progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) throws -> PanoramaAlignment {
        let count = urls.count
        let frames = try inputs?.map(\.metadata) ?? urls.map(PanoramaDecoder.metadata)
        if Set(frames.map { "\($0.make) \($0.model)" }).count > 1 {
            throw PanoramaError.message(L10n.tr("These photos come from different cameras. Panoramas need photos from one camera."))
        }
        let whiteBalance = (temperature: frames[count / 2].temperature, tint: frames[count / 2].tint)
        var planes = [LuminancePlane?](repeating: nil, count: count)
        var textures = [PanoramaSource?](repeating: nil, count: count)
        var failures = [String?](repeating: nil, count: count)
        let lock = NSLock()
        var decoded = 0
        let compositor = self.compositor
        DispatchQueue.concurrentPerform(iterations: count) { i in
            guard !Task.isCancelled else { return }
            do {
                let frame = try self.decode(i, longEdge: Self.registrationLongEdge, whiteBalance: whiteBalance, retouched: false)
                let plane = LuminancePlane(try self.inputs?[i].registration?() ?? frame, longEdge: Self.registrationLongEdge)
                // The preview shows the retouching the merge burns in.
                let shown = self.inputs == nil ? PanoramaDecoder.retouched(frame, self.retouch[self.urls[i]] ?? []) : frame
                let texture = try compositor.texture(shown, longEdge: Self.previewLongEdge)
                let done = lock.withLock { planes[i] = plane; textures[i] = texture; decoded += 1; return decoded }
                progress(0.5 * Double(done) / Double(count), L10n.tr("Reading \(frames[i].filename)"))
            } catch { lock.withLock { failures[i] = error.localizedDescription } }
        }
        if Task.isCancelled { throw CancellationError() }
        if let failure = failures.compactMap({ $0 }).first { throw PanoramaError.message(failure) }
        let luminance = planes.map { $0! }

        progress(0.55, L10n.tr("Finding features"))
        var features = [[PanoramaFeature]](repeating: [], count: count)
        features.withUnsafeMutableBufferPointer { out in
            let out = out
            // On equalized luminance, so dark night frames (stars, a lit horizon) find as many corners as daylight ones.
            DispatchQueue.concurrentPerform(iterations: count) { i in out[i] = PanoramaFeatures.detect(HDRMergeAlignment.equalized(luminance[i], floor: 1e-4), limit: 1800) }
        }
        let cameras = zip(frames, luminance).map { frame, plane in
            let equivalent = frame.focalLength35mm ?? 50
            return PanoramaCamera(width: Double(plane.width), height: Double(plane.height),
                                  focal: equivalent * hypot(Double(plane.width), Double(plane.height)) / hypot(36, 24))
        }
        // A few photos are matched all with all: a grid or a sweep through the zenith isn't a strip in capture order.
        // Longer sequences match each photo with the next three.
        var pairs: [(Int, Int)] = []
        for a in 0..<count { for b in a + 1..<(count <= 12 ? count : min(count, a + 4)) { pairs.append((a, b)) } }
        progress(0.7, L10n.tr("Aligning photos"))
        // Star fields have corners enough but nothing to tell one star from another; they are matched by their pattern.
        var stars = [[SIMD2<Double>]](repeating: [], count: count)
        stars.withUnsafeMutableBufferPointer { out in
            let out = out
            DispatchQueue.concurrentPerform(iterations: count) { i in out[i] = PanoramaStars.detect(luminance[i]) }
        }
        var solution = try PanoramaGeometry.solve(cameras: cameras, features: features, pairs: pairs, threshold: 3, minimumInliers: 18,
                                                  stars: stars, cancelled: { Task.isCancelled })
        if Task.isCancelled { throw CancellationError() }
        // The recorded 35 mm equivalent anchors the field of view; without one the focal length is free to move further.
        let focalRange = frames.allSatisfy({ $0.focalLength35mm != nil }) ? 0.9...1.1 : 0.8...1.25
        let distortion = !frames.allSatisfy(\.lensCorrected)
        var refined = PanoramaGeometry.refineLens(cameras: cameras, edges: solution.edges, members: solution.included, anchor: solution.anchor,
                                                  rotations: solution.rotations, focalRange: focalRange, distortion: distortion)
        if distortion, refined.lens != PanoramaGeometry.Lens() {
            // Matched again through the fitted lens: near the frame edges, where the barrel is strongest, the pinhole
            // model turned good matches away.
            progress(0.8, L10n.tr("Aligning photos"))
            let rematched = try PanoramaGeometry.solve(cameras: refined.cameras, features: features, pairs: pairs, threshold: 3, minimumInliers: 18,
                                                       stars: stars, cancelled: { Task.isCancelled })
            if Task.isCancelled { throw CancellationError() }
            if rematched.included.count >= solution.included.count {
                solution = rematched
                refined = PanoramaGeometry.refineLens(cameras: cameras, edges: solution.edges, members: solution.included, anchor: solution.anchor,
                                                      rotations: solution.rotations, start: refined.lens, focalRange: focalRange, distortion: true)
            }
        }
        solution.cameras = refined.cameras
        let residuals = PanoramaGeometry.errors(cameras: refined.cameras, rotations: refined.rotations, edges: solution.edges, members: Set(solution.included)).sorted()
        solution.medianError = residuals[residuals.count / 2]
        solution.p95Error = residuals[min(residuals.count - 1, Int(Double(residuals.count) * 0.95))]
        let straightening = PanoramaGeometry.straighten(rotations: refined.rotations, members: solution.included)
        solution.rotations = refined.rotations.map { straightening.world * $0 }
        progress(0.9, L10n.tr("Matching exposure"))
        var gains = Self.gains(planes: luminance, edges: solution.edges, members: solution.included, anchor: solution.anchor)
        // Inputs evened out by their recorded exposure come back to the anchor's own, so the panorama develops like it.
        if let inputs { let factor = inputs[solution.anchor].exposureFactor; gains = gains.map { $0 / factor } }

        self.metadata = frames; self.whiteBalance = whiteBalance; self.solution = solution; self.gains = gains; blended = [:]; filled = []
        self.straightening = straightening
        previewTextures = textures.map { $0! }

        var available = Set<PanoramaProjection>()
        for projection in PanoramaProjection.allCases where previewLayout(projection) != nil { available.insert(projection) }
        guard !available.isEmpty else { throw PanoramaError.message(L10n.tr("These photos cover a full circle; 360° panoramas can’t be merged yet.")) }
        let alignment = PanoramaAlignment(filenames: frames.map(\.filename), included: solution.included,
            medianErrorPixels: solution.medianError, p95ErrorPixels: solution.p95Error,
            available: available, suggested: suggest(available))
        self.alignment = alignment
        progress(1, "")
        return alignment
    }

    /// Cylindrical, unless the panorama is tall enough (more than about 100° across the strip) that a cylinder would
    /// stretch its edges: then spherical. Perspective only when nothing else can show it.
    private func suggest(_ available: Set<PanoramaProjection>) -> PanoramaProjection {
        if let layout = previewLayout(.cylindrical) {
            let across = Double(layout.transposed ? layout.width : layout.height) / layout.focal
            if across < 2.4 || !available.contains(.spherical) { return .cylindrical }
        }
        return available.contains(.spherical) ? .spherical : .perspective
    }

    /// Scalar exposure gains relative to the anchor from luminance ratios at matched points, within two stops.
    static func gains(planes: [LuminancePlane], edges: [PanoramaEdge], members: [Int], anchor: Int) -> [Double] {
        var constraints: [(Int, Int, Double, Double)] = []
        for edge in edges where members.contains(edge.a) && members.contains(edge.b) {
            let ratios = edge.matches.compactMap { match -> Double? in
                let a = planes[edge.a].mean(at: match.a), b = planes[edge.b].mean(at: match.b)
                guard a > 0.005, b > 0.005, a < 0.95, b < 0.95 else { return nil }
                return log(a / b)
            }.sorted()
            if ratios.count >= 8 { constraints.append((edge.a, edge.b, ratios[ratios.count / 2], Double(ratios.count))) }
        }
        var values = [Double](repeating: 0, count: planes.count)
        for _ in 0..<100 {
            for i in members where i != anchor {
                var total = 0.0, weight = 0.0
                for (a, b, delta, w) in constraints {
                    if a == i { total += (values[b] - delta) * w; weight += w }
                    if b == i { total += (values[a] + delta) * w; weight += w }
                }
                if weight > 0 { values[i] = max(-log(4), min(log(4), total / weight)) }
            }
        }
        return values.map(exp)
    }

    // MARK: Preview

    private func previewLayout(_ projection: PanoramaProjection) -> PanoramaLayout? {
        guard let solution else { return nil }
        let focal = previewCameras().map(\.focal).sorted()
        return PanoramaLayout(cameras: previewCameras(), rotations: solution.rotations, members: solution.included,
                              projection: projection, focal: focal[focal.count / 2], maxPixels: 8e6,
                              transposed: straightening.transposed, flipped: straightening.flipped)
    }
    private func previewCameras() -> [PanoramaCamera] {
        guard let solution else { return [] }
        return zip(solution.cameras, previewTextures).map { camera, texture in camera.resized(width: texture.width, height: texture.height) }
    }

    public func preview(_ settings: PanoramaSettings) throws -> PanoramaPreview {
        let raster = try previewRaster(settings)
        if Task.isCancelled { throw CancellationError() }
        let fills = settings.fillEdges && !settings.autoCrop
        let finished: PanoramaRaster
        if fills, let cached = filled.first(where: { $0.settings == settings }) { finished = cached.raster }
        else {
            finished = try PanoramaFinishing.finish(raster, settings: settings, cancelled: { Task.isCancelled })
            if fills { filled = [(settings, finished)] + filled.prefix(3) }
        }
        guard let image = PanoramaFinishing.picture(finished) else {
            throw PanoramaError.message(L10n.tr("The preview could not be drawn."))
        }
        let source = solution.map { MergePreviewSource(raster: finished, writer: ToolResultWriter(dng: PanoramaDNGWriter(metadata: metadata[$0.anchor],
            source: .merge(urls[$0.anchor], process: process, exposure: keepsExposure)), source: urls[$0.anchor]), base: $0.anchor) }
        return PanoramaPreview(image: image, source: source, settings: settings)
    }

    /// The preview's blend before cropping, cached per projection.
    func previewRaster(_ settings: PanoramaSettings) throws -> PanoramaRaster {
        guard let solution else { throw PanoramaError.message(L10n.tr("Align the photos first.")) }
        let raster: PanoramaRaster
        if let cached = blended[settings.projection] { raster = cached }
        else {
            guard let layout = previewLayout(settings.projection) else {
                throw PanoramaError.message(L10n.tr("\(settings.projection.title) projection can’t show these photos."))
            }
            raster = try compositor.render(layout: layout, cameras: solution.cameras, rotations: solution.rotations, gains: gains,
                                           frames: solution.included, texture: { self.previewTextures[$0] }, progress: { _ in },
                                           cancelled: { Task.isCancelled })
            blended[settings.projection] = raster
        }
        return raster
    }

    // MARK: Merge

    /// Renders every photo at full size and writes the DNG. Photos are developed two at a time. `progress` reports the
    /// fraction done and the current step.
    public func merge(_ settings: PanoramaSettings, to url: URL, progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) throws {
        guard let solution else { throw PanoramaError.message(L10n.tr("Align the photos first.")) }
        let full = solution.cameras.indices.map { i in solution.cameras[i].resized(width: metadata[i].width, height: metadata[i].height) }
        let focal = solution.included.map { full[$0].focal }.sorted()
        guard let layout = PanoramaLayout(cameras: full, rotations: solution.rotations, members: solution.included,
                                          projection: settings.projection, focal: focal[focal.count / 2], maxPixels: maxPixels,
                                          transposed: straightening.transposed, flipped: straightening.flipped) else {
            throw PanoramaError.message(L10n.tr("\(settings.projection.title) projection can’t show these photos."))
        }
        var ready: [Int: PanoramaSource] = [:]
        let order = solution.included, urls = self.urls, compositor = self.compositor, whiteBalance = self.whiteBalance
        let texture: (Int) throws -> PanoramaSource = { index in
            if let texture = ready.removeValue(forKey: index) { return texture }
            let start = order.firstIndex(of: index)!
            let batch = Array(order[start..<min(order.count, start + 2)])
            let names = batch.map { urls[$0].lastPathComponent }.joined(separator: " and ")
            progress(0.75 * Double(start) / Double(order.count), L10n.tr("Developing \(names) (\(start + 1) of \(order.count))"))
            var loaded = [PanoramaSource?](repeating: nil, count: batch.count), failure: Error?
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: batch.count) { k in
                do {
                    let frame = try self.decode(batch[k], longEdge: nil, whiteBalance: whiteBalance)
                    let texture = try compositor.texture(frame)
                    lock.withLock { loaded[k] = texture }
                } catch { lock.withLock { failure = error } }
            }
            if let failure { throw failure }
            for (k, i) in batch.enumerated() { ready[i] = loaded[k] }
            return ready.removeValue(forKey: index)!
        }
        let raster = try compositor.render(layout: layout, cameras: solution.cameras, rotations: solution.rotations, gains: gains,
                                           frames: order, texture: texture,
                                           progress: { progress(0.75 * Double($0) / Double(order.count), L10n.tr("Blending photo \($0) of \(order.count)")) },
                                           cancelled: { Task.isCancelled })
        if Task.isCancelled { throw CancellationError() }
        if settings.boundaryWarp > 0 { progress(0.75, L10n.tr("Warping edges")) }
        else if settings.autoCrop { progress(0.75, L10n.tr("Cropping")) }
        let finished = try PanoramaFinishing.finish(raster, settings: settings,
                                                    progress: { progress(0.76 + 0.06 * Double($0) / Double($1), L10n.tr("Filling edges")) },
                                                    cancelled: { Task.isCancelled })
        var anchor = metadata[solution.anchor]
        anchor.captureTime = PanoramaFrameMetadata.captureTime(after: solution.included.map { metadata[$0].captureTime }) ?? anchor.captureTime
        if Task.isCancelled { throw CancellationError() }
        let writer = PanoramaDNGWriter(metadata: anchor, preview: PanoramaFinishing.picture(finished, maxDimension: 1024),
                                       source: .merge(urls[solution.anchor], process: process, exposure: keepsExposure))
        let size = "\(finished.width.formatted()) × \(finished.height.formatted())"
        try writer.write(finished, to: url, progress: { progress(0.82 + 0.18 * $0, L10n.tr("Writing \(size) DNG")) }, cancelled: { Task.isCancelled })
        progress(1, L10n.tr("Saved"))
    }
}

/// A picture made in memory that takes a photo's place in a panorama.
struct PanoramaInput {
    var metadata: PanoramaFrameMetadata
    /// What the picture's values were multiplied by to even out exposure between the inputs.
    var exposureFactor = 1.0
    /// The picture reduced to fit a long edge, or at full size for nil. Called from several threads at once.
    var decode: @Sendable (Int?) throws -> PanoramaFrame
    /// The picture to find features on, when it differs from the one shown and merged.
    var registration: (@Sendable () throws -> PanoramaFrame)? = nil
}

// MARK: Latent image

/// What alignment solved, small enough for a latent image's manifest: reopening decodes the preview copies again but
/// skips finding features, matching them and fitting the lens.
public struct PanoramaSolved: Codable, Equatable, Sendable {
    struct Camera: Codable, Equatable { var width, height, focal, k1, k2: Double }
    var cameras: [Camera]
    /// Each a column-major 3 × 3.
    var rotations: [[Double]]
    var included: [Int]
    var anchor: Int
    var medianError, p95Error: Double
    var world: [Double]
    var transposed, flipped: Bool
    var gains: [Double]
    var temperature, tint: Double

    var frameCount: Int { cameras.count }
    func validate(frames: Int) throws {
        let numbers = cameras.flatMap { [$0.width, $0.height, $0.focal, $0.k1, $0.k2] } + rotations.flatMap { $0 } + world + gains + [medianError, p95Error, temperature, tint]
        guard cameras.count == frames, rotations.count == frames, gains.count == frames, rotations.allSatisfy({ $0.count == 9 }), world.count == 9,
              included.count >= 2, Set(included).count == included.count, included.allSatisfy((0..<frames).contains), included.contains(anchor),
              cameras.allSatisfy({ $0.width > 0 && $0.height > 0 && $0.focal > 0 }), numbers.allSatisfy(\.isFinite) else { throw LatentImage.invalid() }
    }
}

private extension simd_double3x3 {
    var columns9: [Double] { [columns.0, columns.1, columns.2].flatMap { [$0.x, $0.y, $0.z] } }
    init(columns9 v: [Double]) { self.init(SIMD3(v[0], v[1], v[2]), SIMD3(v[3], v[4], v[5]), SIMD3(v[6], v[7], v[8])) }
}

extension PanoramaMerger {
    /// The last alignment's solution; nil before aligning.
    public var solved: PanoramaSolved? {
        guard let solution else { return nil }
        return PanoramaSolved(cameras: solution.cameras.map { .init(width: $0.width, height: $0.height, focal: $0.focal, k1: $0.k1, k2: $0.k2) },
                              rotations: solution.rotations.map(\.columns9), included: solution.included, anchor: solution.anchor,
                              medianError: solution.medianError, p95Error: solution.p95Error, world: straightening.world.columns9,
                              transposed: straightening.transposed, flipped: straightening.flipped, gains: gains,
                              temperature: whiteBalance.temperature, tint: whiteBalance.tint)
    }

    /// Takes a saved alignment of these photos in place of `align`: decodes the preview copies only.
    public func restore(_ solved: PanoramaSolved, progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) throws -> PanoramaAlignment {
        let count = urls.count
        try solved.validate(frames: count)
        let frames = try inputs?.map(\.metadata) ?? urls.map(PanoramaDecoder.metadata)
        let whiteBalance = (temperature: solved.temperature, tint: solved.tint)
        var textures = [PanoramaSource?](repeating: nil, count: count)
        var failures = [String?](repeating: nil, count: count)
        let lock = NSLock()
        var decoded = 0
        let compositor = self.compositor
        DispatchQueue.concurrentPerform(iterations: count) { i in
            guard !Task.isCancelled else { return }
            do {
                let frame = try self.decode(i, longEdge: Self.previewLongEdge, whiteBalance: whiteBalance)
                let texture = try compositor.texture(frame, longEdge: Self.previewLongEdge)
                let done = lock.withLock { textures[i] = texture; decoded += 1; return decoded }
                progress(Double(done) / Double(count), L10n.tr("Reading \(frames[i].filename)"))
            } catch { lock.withLock { failures[i] = error.localizedDescription } }
        }
        if Task.isCancelled { throw CancellationError() }
        if let failure = failures.compactMap({ $0 }).first { throw PanoramaError.message(failure) }
        let cameras = solved.cameras.map { PanoramaCamera(width: $0.width, height: $0.height, focal: $0.focal, k1: $0.k1, k2: $0.k2) }
        solution = PanoramaSolution(cameras: cameras, rotations: solved.rotations.map(simd_double3x3.init(columns9:)), included: solved.included,
                                    anchor: solved.anchor, edges: [], medianError: solved.medianError, p95Error: solved.p95Error)
        straightening = PanoramaGeometry.Straightening(world: simd_double3x3(columns9: solved.world), transposed: solved.transposed, flipped: solved.flipped)
        metadata = frames; self.whiteBalance = whiteBalance; gains = solved.gains; blended = [:]; filled = []
        previewTextures = textures.map { $0! }
        var available = Set<PanoramaProjection>()
        for projection in PanoramaProjection.allCases where previewLayout(projection) != nil { available.insert(projection) }
        guard !available.isEmpty else { throw LatentImage.invalid() }
        let alignment = PanoramaAlignment(filenames: frames.map(\.filename), included: solved.included, medianErrorPixels: solved.medianError,
                                          p95ErrorPixels: solved.p95Error, available: available, suggested: suggest(available))
        self.alignment = alignment
        return alignment
    }
}

/// What a panorama latent image keeps: the options, whether each position was merged to HDR first, and the alignment.
public struct PanoramaLatent: Codable, Equatable, Sendable {
    public var settings: PanoramaSettings
    public var hdr: Bool
    public var deghosting: HDRDeghosting
    public var solved: PanoramaSolved?
    public init(settings: PanoramaSettings, hdr: Bool, deghosting: HDRDeghosting, solved: PanoramaSolved?) {
        self.settings = settings; self.hdr = hdr; self.deghosting = deghosting; self.solved = solved
    }
}

extension LatentImage {
    public static let panorama = "panorama"
    public init(id: String = UUID().uuidString, catalogID: String, sources: [Source], panorama: PanoramaLatent, width: Int, height: Int) throws {
        self.init(type: Self.panorama, id: id, catalogID: catalogID, sources: sources, settings: try JSONEncoder().encode(panorama),
                  analysisID: "", width: width, height: height, alignedAllSky: false, alignedStrokes: [])
    }
    public func panoramaSettings() throws -> PanoramaLatent {
        guard type == Self.panorama else { throw Self.invalid() }
        return try JSONDecoder().decode(PanoramaLatent.self, from: settings)
    }
}
