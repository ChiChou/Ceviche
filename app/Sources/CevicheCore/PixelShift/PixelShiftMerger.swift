import Foundation
import CoreImage
import ImageIO
import Metal
import simd
import CameraRaw

public struct PixelShiftFrameInfo: Identifiable, Sendable {
    public let index: Int
    public let filename: String
    /// How far the sensor moved from the first shot, in pixels.
    public let shift: SIMD2<Double>
    /// Stops this shot's exposure was evened out by.
    public let stops: Double
    public var id: Int { index }
}

public struct PixelShiftAnalysis: Sendable {
    /// In shot order.
    public let frames: [PixelShiftFrameInfo]
    /// 4, or 16 for the sets that double the width and height.
    public var shots: Int { frames.count }
    /// Size of the merged photo, as the sensor is oriented.
    public let width: Int
    public let height: Int
    /// EXIF orientation of the photos.
    public let orientation: Int
    public let camera: String
    /// Whether the merge can be a DNG the app develops; a larger one is written as a TIFF or JPEG.
    public var developable: Bool { max(width, height) <= PanoramaDNGWriter.developableSide }
}

public struct PixelShiftPreview: @unchecked Sendable {
    /// The first four shots merged at full size, as the sensor is oriented.
    public var image: CGImage
    /// The preview as the result's DNG, for developing it with the first photo's edits.
    public let source: MergePreviewSource?
    /// White where something moved between the shots and one shot alone is used.
    public let motion: CGImage?
    /// The share of the photo taken from one shot.
    public let motionCoverage: Double
}

/// How a set that isn't merged from its CFA samples is read, shown and merged.
protocol PixelShiftComposer: AnyObject, Sendable {
    func preview() throws -> PixelShiftPreview
    func mergedRaster(progress: @escaping @Sendable (Double, String) -> Void) throws -> PanoramaRaster
}
extension PixelShiftFusion: PixelShiftComposer {}
extension PixelShiftMultiShot: PixelShiftComposer {}

/// Merges a Pixel Shift set into a linear DNG.
/// - Sony Pixel Shift Multi Shooting (4 or 16 ARWs) and Pentax Pixel Shift Resolution (four exposures in one PEF or
///   DNG): the shots are read as the sensor recorded them (`CameraRaw`), four of them give full colour at every pixel,
///   sixteen twice the width and height. The colour is fitted to Apple's development of the first shot, so the result
///   matches the camera's other photos in the app.
/// - Fujifilm Pixel Shift Multi Shot (`PixelShiftFusion`): Apple develops each shot and they are interleaved.
/// - Hasselblad's six-shot multi-shot (`PixelShiftMultiShot`): six exposures in one FFF.
/// Files that aren't RAW (a camera's own JPEG, an in-camera composite) are left out of the selection.
public final class PixelShiftMerger: @unchecked Sendable {
    public let urls: [URL]
    private var infos: [SensorFrame] = []
    /// Sets merged other than from their CFA samples: Fujifilm's, Hasselblad's.
    private var fusion: PixelShiftComposer?
    private var orientation = 1
    private var samples: [[UInt16]] = []
    private var offsets: [PixelShiftOffset] = []
    private var matrix: [Float] = []
    private let engine: PixelShiftEngine
    private let context: CIContext
    /// Merges only this part of the sensor (even origin and size), so tests run on a piece of a real set.
    var window: (x: Int, y: Int, width: Int, height: Int)?
    /// Mask growth and softening, in sensor pixels.
    static let dilate = 2, blur = 6

    /// Whether one photo can hold a whole set: Pentax's Pixel Shift Resolution and Hasselblad's multi-shot keep every
    /// shot in one file. Judged from the catalog's file type and camera alone, so a menu never reads the file; a photo
    /// from one of those cameras taken without it is turned away by the dialog, which reads the file.
    public static func mayHoldSet(filename: String, camera: String) -> Bool {
        switch (filename as NSString).pathExtension.lowercased() {
        case "pef", "dng": PentaxRAW.pixelShiftModels.contains(camera.trimmingCharacters(in: .whitespaces))
        case "fff": true
        default: false
        }
    }

    public init(urls: [URL]) throws {
        self.urls = urls
        guard let device = MTLCreateSystemDefaultDevice() else { throw EditorError.noGPU }
        engine = (try? PixelShiftGPU(device: device)) ?? PixelShiftCPU()
        context = CIContext(mtlDevice: device, options: [.workingColorSpace: PanoramaDecoder.space, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
    }
    init(urls: [URL], engine: PixelShiftEngine) throws {
        self.urls = urls; self.engine = engine
        context = CIContext(options: [.workingColorSpace: PanoramaDecoder.space, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
    }

    // MARK: Analysis

    /// Reads the shots in their order, measures how the sensor moved between them and fits the colour.
    public func analyze(progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) throws -> PixelShiftAnalysis {
        progress(0, L10n.tr("Reading photos…"))
        var read: [(url: URL, info: SensorFrame)]
        var known: [(dx: Int, dy: Int)]?
        switch try PixelShiftSelection(urls) {
        case .fujifilm(let shots):
            let fusion = try PixelShiftFusion(shots, context: context)
            let analysis = try fusion.analyze(progress: progress)
            self.fusion = fusion; orderedURLs = fusion.urls; orientation = fusion.shots[0].orientation
            return analysis
        case .hasselblad(let url, let shot):
            let multiShot = try PixelShiftMultiShot(url: url, shot: shot)
            let analysis = try multiShot.analyze(progress: progress)
            fusion = multiShot; orderedURLs = [url]; orientation = shot.orientation
            return analysis
        case .pentax(let url, let frames):
            read = frames.map { (url, $0) }
            // The sensor's movement between the exposures, in the order the file stores them.
            known = [(0, 0), (0, -1), (-1, -1), (-1, 0)]
        case .sony(let frames):
            read = frames
            let first = read[0].info
            for item in read where item.info.width != first.width || item.info.height != first.height || item.info.cfa != first.cfa || item.info.model != first.model {
                throw PanoramaError.message(L10n.tr("\(item.url.lastPathComponent) is from a different camera or size than \(read[0].url.lastPathComponent)."))
            }
            if read.allSatisfy({ $0.info.sonyShift != nil }) {
                let groups = Set(read.map { $0.info.sonyShift!.group }), places = Set(read.map { $0.info.sonyShift!.index })
                guard groups.count == 1, read[0].info.sonyShift!.shots == read.count, places.count == read.count else {
                    throw PanoramaError.message(L10n.tr("These photos aren’t one complete Pixel Shift set. Choose all 4 or 16 photos of one set."))
                }
                read.sort { $0.info.sonyShift!.index < $1.info.sonyShift!.index }
            } else if read.contains(where: { $0.info.sonyShift != nil }) {
                throw PanoramaError.message(L10n.tr("These photos aren’t one complete Pixel Shift set. Choose all 4 or 16 photos of one set."))
            }
        }
        infos = read.map(\.info)
        let ordered = read.map(\.url)
        orientation = infos[0].orientation
        samples = []
        for (k, url) in ordered.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            progress(0.3 * Double(k) / Double(ordered.count), L10n.tr("Reading \(url.lastPathComponent)"))
            var frame: [UInt16]
            do { frame = try infos[k].samples(url) } catch let error as CameraRawError { throw error.pixelShift(url) }
            // The colour is fitted on the whole first shot, whatever part is merged.
            if k == 0 { matrix = try Self.colourMatrix(url, info: infos[0], samples: frame, context: context) }
            if let window {
                let full = infos[k].width
                var part = [UInt16](repeating: 0, count: window.width * window.height)
                for y in 0..<window.height { for x in 0..<window.width { part[y * window.width + x] = frame[(y + window.y) * full + x + window.x] } }
                frame = part
                infos[k].width = window.width; infos[k].height = window.height; infos[k].crop = (0, 0, window.width, window.height)
            }
            samples.append(frame)
        }
        let info = infos[0], w = info.width, h = info.height
        let scale = info.black.map { 1 / (info.white - $0) }
        offsets = [PixelShiftOffset(dx: 0, dy: 0, subX: 0, subY: 0, gain: 1, sigma: 1)]
        try samples[0].withUnsafeBufferPointer { r in
            let reference = PixelShiftCFA(samples: r.baseAddress!, width: w, height: h, black: info.black, scale: scale)
            for k in 1..<samples.count {
                if Task.isCancelled { throw CancellationError() }
                progress(0.3 + 0.6 * Double(k - 1) / Double(samples.count - 1), L10n.tr("Aligning photos"))
                offsets.append(samples[k].withUnsafeBufferPointer { f in
                    PixelShiftAligner.align(reference: reference, frame: PixelShiftCFA(samples: f.baseAddress!, width: w, height: h, black: info.black, scale: scale),
                                            known: known?[k])
                })
            }
        }
        let sigmas = offsets.dropFirst().map(\.sigma).sorted()
        offsets[0].sigma = sigmas[sigmas.count / 2]
        _ = try sets()
        orderedURLs = Array(NSOrderedSet(array: ordered)) as? [URL] ?? ordered
        let factor = samples.count == 16 ? 2 : 1
        return PixelShiftAnalysis(frames: ordered.indices.map { k in
            PixelShiftFrameInfo(index: k, filename: ordered[k].lastPathComponent, shift: SIMD2(offsets[k].subX, offsets[k].subY), stops: Double(log2(offsets[k].gain)))
        }, width: info.crop.width * factor, height: info.crop.height * factor, orientation: info.orientation,
           camera: [info.make, info.model].filter { !$0.isEmpty }.joined(separator: " "))
    }
    private var orderedURLs: [URL] = []

    /// One 4-shot set: which shots, their whole-pixel offsets from the set's first, and where its pixel (0,0) lands on
    /// the grid at twice the size (0 or 1 in each direction; (0,0) for a 4-shot set).
    private struct ShotSet { var shots: [Int]; var offsets: [PixelShiftOffset]; var base: (x: Int, y: Int) }

    /// A 4-shot set must put every colour on every pixel; a 16-shot set is four of them on half-pixel lattices.
    private func sets() throws -> [ShotSet] {
        func covers(_ offsets: [PixelShiftOffset]) -> Bool {
            Set(offsets.map { (($0.dx % 2 + 2) % 2) * 2 + ($0.dy % 2 + 2) % 2 }).count == 4
        }
        let failed = PanoramaError.message(L10n.tr("The sensor positions of these photos don’t form a Pixel Shift set. The camera or the scene may have moved."))
        if offsets.count == 4 {
            guard covers(offsets) else { throw failed }
            return [ShotSet(shots: [0, 1, 2, 3], offsets: offsets, base: (0, 0))]
        }
        // Offsets in half pixels; their parity is the lattice a shot fills.
        let halves = offsets.map { (x: Int((2 * $0.subX).rounded()), y: Int((2 * $0.subY).rounded())) }
        let lattice = halves.map { (x: ($0.x % 2 + 2) % 2, y: ($0.y % 2 + 2) % 2) }
        let groups = Dictionary(grouping: offsets.indices, by: { lattice[$0].y * 2 + lattice[$0].x }).sorted { $0.key < $1.key }
        guard groups.count == 4, groups.allSatisfy({ $0.value.count == 4 }) else { throw failed }
        return try groups.map { group in
            let anchor = group.value[0]
            func whole(_ k: Int) -> (Int, Int) { ((halves[k].x - lattice[k].x) / 2, (halves[k].y - lattice[k].y) / 2) }
            let a = whole(anchor)
            let relative = group.value.map { k -> PixelShiftOffset in var r = offsets[k]; let o = whole(k); r.dx = o.0 - a.0; r.dy = o.1 - a.1; return r }
            guard covers(relative) else { throw failed }
            return ShotSet(shots: group.value, offsets: relative, base: (2 * a.0 + lattice[anchor].x, 2 * a.1 + lattice[anchor].y))
        }
    }

    private func parameters(_ set: ShotSet) -> PixelShiftParameters {
        let info = infos[set.shots[0]], scale = info.black.map { 1 / (info.white - $0) }
        var p = PixelShiftParameters()
        p.width = UInt32(info.width); p.height = UInt32(info.height)
        let o = set.offsets
        p.ox = (Int32(o[0].dx), Int32(o[1].dx), Int32(o[2].dx), Int32(o[3].dx))
        p.oy = (Int32(o[0].dy), Int32(o[1].dy), Int32(o[2].dy), Int32(o[3].dy))
        p.gain = (o[0].gain, o[1].gain, o[2].gain, o[3].gain)
        p.sigma = (o[0].sigma, o[1].sigma, o[2].sigma, o[3].sigma)
        p.black = (info.black[0], info.black[1], info.black[2], info.black[3]); p.scale = (scale[0], scale[1], scale[2], scale[3])
        p.cfa = (UInt32(info.cfa[0]), UInt32(info.cfa[1]), UInt32(info.cfa[2]), UInt32(info.cfa[3]))
        p.wb = (info.whiteBalance[0], info.whiteBalance[1], info.whiteBalance[2], 0)
        let m = matrix
        p.matrix = (m[0], m[1], m[2], 0, m[3], m[4], m[5], 0, m[6], m[7], m[8], 0)
        return p
    }

    private func merge(_ set: ShotSet) throws -> [Float] {
        func with(_ k: Int, _ pointers: [UnsafePointer<UInt16>], _ body: ([UnsafePointer<UInt16>]) throws -> [Float]) rethrows -> [Float] {
            guard k < set.shots.count else { return try body(pointers) }
            return try samples[set.shots[k]].withUnsafeBufferPointer { try with(k + 1, pointers + [$0.baseAddress!], body) }
        }
        return try with(0, []) { try engine.merge(frames: $0, parameters: parameters(set), dilate: Self.dilate, blur: Self.blur) }
    }

    // MARK: Colour

    /// White-balanced camera RGB to linear sRGB, fitted to Apple's development of the same shot on 32-pixel blocks:
    /// the camera's colour and exposure as every other photo and merge in the app has them, with no table of cameras.
    static func colourMatrix(_ url: URL, info: SensorFrame, samples: [UInt16], context: CIContext) throws -> [Float] {
        let failed = PanoramaError.message(L10n.tr("\(url.lastPathComponent) can’t be decoded."))
        let side = 32, columns = info.crop.width / side, rows = info.crop.height / side
        guard columns >= 8, rows >= 8, let raw = CIRAWFilter(imageURL: url) else { throw failed }
        raw.orientation = .up
        raw.scaleFactor = Float(min(1, 2 * Double(max(columns, rows)) / Double(max(raw.nativeSize.width, raw.nativeSize.height))))
        raw.exposure = 0; raw.boostAmount = 0; raw.boostShadowAmount = 0
        if raw.isLocalToneMapSupported { raw.localToneMapAmount = 0 }
        if raw.isLensCorrectionSupported { raw.isLensCorrectionEnabled = false }
        guard var image = raw.outputImage, image.extent.width > 8, image.extent.height > 8 else { throw failed }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        // Averaged down to one value a block.
        image = image.transformed(by: CGAffineTransform(scaleX: CGFloat(columns) / image.extent.width, y: CGFloat(rows) / image.extent.height))
        var developed = [Float](repeating: 0, count: columns * rows * 4)
        developed.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: columns * 16, bounds: CGRect(x: 0, y: 0, width: columns, height: rows),
                           format: .RGBAf, colorSpace: PanoramaDecoder.space)
        }

        let scale = info.black.map { 1 / (info.white - $0) }
        var camera = [SIMD3<Double>](repeating: .zero, count: columns * rows), usable = [Bool](repeating: false, count: columns * rows)
        samples.withUnsafeBufferPointer { s in
            camera.withUnsafeMutableBufferPointer { camera in usable.withUnsafeMutableBufferPointer { usable in
                let camera = camera, usable = usable
                DispatchQueue.concurrentPerform(iterations: rows) { by in
                    for bx in 0..<columns {
                        var sum = SIMD3<Double>.zero, count = SIMD3<Double>.zero, peak: Float = 0
                        for y in (info.crop.y + by * side)..<(info.crop.y + (by + 1) * side) {
                            for x in (info.crop.x + bx * side)..<(info.crop.x + (bx + 1) * side) {
                                let p = (y & 1) * 2 + (x & 1), v = (Float(s[y * info.width + x]) - info.black[p]) * scale[p]
                                sum[info.cfa[p]] += Double(v); count[info.cfa[p]] += 1; peak = max(peak, v)
                            }
                        }
                        let mean = sum / count * SIMD3(info.whiteBalance.map(Double.init))
                        camera[by * columns + bx] = mean
                        // Away from clipping, where Apple recovers highlights its own way, and out of the noise.
                        usable[by * columns + bx] = peak < 0.7 && mean.max() < 0.8 && mean.min() > 0.004
                    }
                }
            } }
        }
        func fit(_ keep: [Bool]) -> simd_double3x3? {
            var normal = simd_double3x3(0), right = simd_double3x3(0), count = 0
            for i in camera.indices where keep[i] {
                let c = camera[i], d = SIMD3(Double(developed[i * 4]), Double(developed[i * 4 + 1]), Double(developed[i * 4 + 2]))
                guard d.x.isFinite, d.y.isFinite, d.z.isFinite else { continue }
                normal += simd_double3x3(columns: (c * c.x, c * c.y, c * c.z))
                right += simd_double3x3(columns: (d * c.x, d * c.y, d * c.z))
                count += 1
            }
            guard count >= 200, abs(normal.determinant) > 1e-18 else { return nil }
            return right * normal.inverse
        }
        guard var m = fit(usable) else { throw failed }
        // Once more without the blocks that fit worst: edges a block apart, colours Apple maps into gamut.
        var errors = camera.indices.map { i -> Double in
            guard usable[i] else { return .infinity }
            let d = SIMD3(Double(developed[i * 4]), Double(developed[i * 4 + 1]), Double(developed[i * 4 + 2]))
            return simd_length(m * camera[i] - d) / max(1e-4, simd_length(d))
        }
        let sorted = errors.filter(\.isFinite).sorted()
        let limit = sorted[sorted.count * 3 / 4]
        for i in errors.indices where !usable[i] { errors[i] = .infinity }
        if let refined = fit(errors.map { $0 <= limit }) { m = refined }
        return (0..<3).flatMap { r in (0..<3).map { c in Float(m[c][r]) } }
    }

    // MARK: Preview

    /// The first four shots merged at full size, with what moved. A 16-shot set shows its first four: the same
    /// picture at half the final size.
    public func preview() throws -> PixelShiftPreview {
        if let fusion { return try fusion.preview() }
        guard !offsets.isEmpty, !matrix.isEmpty else { throw PanoramaError.message(L10n.tr("Analyze the photos first.")) }
        let set = try sets()[0], info = infos[0]
        let merged = try merge(set)
        let crop = info.crop, w = info.width
        var raster = PanoramaRaster(width: crop.width, height: crop.height, rgba: [Float](repeating: 1, count: crop.width * crop.height * 4))
        let step = 4, mw = crop.width / step, mh = crop.height / step
        var mask = [Float](repeating: 0, count: mw * mh)
        var moved = 0.0
        merged.withUnsafeBufferPointer { merged in
            raster.rgba.withUnsafeMutableBufferPointer { out in
                let out = out
                DispatchQueue.concurrentPerform(iterations: crop.height) { y in
                    for x in 0..<crop.width {
                        let s = ((y + crop.y) * w + x + crop.x) * 4, o = (y * crop.width + x) * 4
                        out[o] = merged[s]; out[o + 1] = merged[s + 1]; out[o + 2] = merged[s + 2]
                    }
                }
            }
            for y in 0..<mh { for x in 0..<mw {
                var v: Float = 0
                for dy in 0..<step { for dx in 0..<step { v = max(v, merged[((y * step + dy + crop.y) * w + x * step + dx + crop.x) * 4 + 3]) } }
                mask[y * mw + x] = v
                if v > 0.5 { moved += 1 }
            } }
        }
        guard let image = HDRMergeFinishing.picture(raster) else { throw PanoramaError.message(L10n.tr("The preview couldn’t be made.")) }
        let coverage = moved / Double(mw * mh)
        var source: MergePreviewSource?
        if let metadata = try? PanoramaDecoder.metadata(orderedURLs[0]) {
            var writer = PanoramaDNGWriter(metadata: metadata, kind: .pixelShift, source: .merge(orderedURLs[0], process: PanoramaDNGWriter.Kind.pixelShift.rawValue))
            writer.orientation = orientation
            source = MergePreviewSource(raster: raster, writer: ToolResultWriter(dng: writer, source: orderedURLs[0]), base: 0)
        }
        return PixelShiftPreview(image: image, source: source, motion: coverage > 0 ? HDRMergeFinishing.gray(mask, width: mw, height: mh) : nil, motionCoverage: coverage)
    }

    // MARK: Merge

    public func merge(to url: URL, progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) throws {
        let raster = try mergedRaster(progress: progress)
        if Task.isCancelled { throw CancellationError() }
        var metadata = try PanoramaDecoder.metadata(orderedURLs[0])
        metadata.captureTime = PanoramaFrameMetadata.captureTime(after: orderedURLs.map { try? PanoramaDecoder.metadata($0).captureTime }) ?? metadata.captureTime
        var writer = PanoramaDNGWriter(metadata: metadata, kind: .pixelShift, preview: HDRMergeFinishing.picture(raster, maxDimension: 1024),
                                       source: .merge(orderedURLs[0], process: PanoramaDNGWriter.Kind.pixelShift.rawValue))
        writer.orientation = orientation
        let size = "\(raster.width.formatted()) × \(raster.height.formatted())"
        try writer.write(raster, to: url, progress: { progress(0.6 + 0.4 * $0, L10n.tr("Writing \(size) DNG")) }, cancelled: { Task.isCancelled })
        progress(1, L10n.tr("Saved"))
    }

    /// The merge written as a 16-bit TIFF or a full-quality JPEG straight from its pixels, in sRGB and turned upright,
    /// with the first photo's metadata: for a merge too large to develop as a DNG (`developable`).
    public func export(to url: URL, format: ExportFormat, progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) throws {
        guard format == .tiff || format == .jpeg else { throw PanoramaError.message(L10n.tr("The photos couldn’t be merged.")) }
        let raster = try mergedRaster(progress: { progress(0.8 * $0, $1) })
        if Task.isCancelled { throw CancellationError() }
        progress(0.82, L10n.tr("Writing \(raster.width.formatted()) × \(raster.height.formatted()) \(format.rawValue)"))
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CIContext(options: [.workingColorSpace: PanoramaDecoder.space, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
        let rendered: CGImage? = raster.rgba.withUnsafeBytes { bytes in
            // The raster's own memory, not a copy: a 16-shot merge is gigabytes.
            let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: bytes.baseAddress!), count: bytes.count, deallocator: .none)
            let image = CIImage(bitmapData: data, bytesPerRow: raster.width * 16, size: CGSize(width: raster.width, height: raster.height),
                                format: .RGBAf, colorSpace: PanoramaDecoder.space)
                .oriented(CGImagePropertyOrientation(rawValue: UInt32(orientation)) ?? .up)
            return context.createCGImage(image, from: image.extent, format: format == .tiff ? .RGBA16 : .RGBA8, colorSpace: srgb)
        }
        // Opaque: the same pixels without an alpha channel.
        guard let rendered, let provider = rendered.dataProvider,
              let opaque = CGImage(width: rendered.width, height: rendered.height, bitsPerComponent: rendered.bitsPerComponent,
                                   bitsPerPixel: rendered.bitsPerPixel, bytesPerRow: rendered.bytesPerRow, space: srgb,
                                   bitmapInfo: CGBitmapInfo(rawValue: (rendered.bitmapInfo.rawValue & ~CGBitmapInfo.alphaInfoMask.rawValue) | CGImageAlphaInfo.noneSkipLast.rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, format.typeIdentifier as CFString, 1, nil) else {
            throw PanoramaError.message(L10n.tr("Can’t write to \(url.deletingLastPathComponent().path)."))
        }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 1.0]
        if let source = CGImageSourceCreateWithURL(orderedURLs[0] as CFURL, nil),
           let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyGPSDictionary] { properties[key] = original[key] }
            if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] { tiff[kCGImagePropertyTIFFOrientation] = 1; properties[kCGImagePropertyTIFFDictionary] = tiff }
        }
        properties[kCGImagePropertyOrientation] = 1
        CGImageDestinationAddImage(destination, opaque, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PanoramaError.message(L10n.tr("Can’t write to \(url.deletingLastPathComponent().path).")) }
        progress(1, L10n.tr("Saved"))
    }

    /// The full-size merge before it is written, cropped as the camera crops its photos.
    func mergedRaster(progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) throws -> PanoramaRaster {
        if let fusion { return try fusion.mergedRaster(progress: progress) }
        guard !offsets.isEmpty, !matrix.isEmpty else { throw PanoramaError.message(L10n.tr("Analyze the photos first.")) }
        let sets = try sets(), info = infos[0], crop = info.crop, w = info.width, h = info.height
        progress(0.05, L10n.tr("Merging \(samples.count) photos"))
        if sets.count == 1 {
            var merged = try merge(sets[0])
            var raster = PanoramaRaster(width: crop.width, height: crop.height, rgba: [Float](repeating: 1, count: crop.width * crop.height * 4))
            merged.withUnsafeBufferPointer { merged in raster.rgba.withUnsafeMutableBufferPointer { out in
                let out = out
                DispatchQueue.concurrentPerform(iterations: crop.height) { y in
                    for x in 0..<crop.width {
                        let s = ((y + crop.y) * w + x + crop.x) * 4, o = (y * crop.width + x) * 4
                        out[o] = merged[s]; out[o + 1] = merged[s + 1]; out[o + 2] = merged[s + 2]
                    }
                }
            } }
            merged = []
            return raster
        }

        // Sixteen shots: each set merged at the sensor's size and kept in half floats, its fallback mask in alpha.
        var images: [[Float16]] = []
        for (n, set) in sets.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            progress(0.05 + 0.3 * Double(n) / 4, L10n.tr("Merging photos \(n * 4 + 1)–\(n * 4 + 4) of 16"))
            let merged = try merge(set)
            var half = [Float16](repeating: 0, count: merged.count)
            merged.withUnsafeBufferPointer { m in half.withUnsafeMutableBufferPointer { o in
                let o = o
                DispatchQueue.concurrentPerform(iterations: h) { y in for i in (y * w * 4)..<((y + 1) * w * 4) { o[i] = Float16(max(-60000, min(60000, m[i]))) } }
            } }
            images.append(half)
        }
        if Task.isCancelled { throw CancellationError() }
        progress(0.38, L10n.tr("Checking for movement"))
        // One mask at the sensor's size, on the first set's grid: each set's own fallback, and where a set disagrees
        // with the first set's pixels around the same point of the scene. A pixel either side, so the fraction of a
        // pixel the sets drift by isn't read as motion.
        let b0 = sets[0].base
        let sigma = offsets.map(\.sigma).sorted()[offsets.count / 2]
        var mask = [Float](repeating: 0, count: w * h)
        @inline(__always) func luma(_ image: UnsafeBufferPointer<Float16>, _ x: Int, _ y: Int) -> Float {
            let i = (y * w + x) * 4
            return 0.2126 * Float(image[i]) + 0.7152 * Float(image[i + 1]) + 0.0722 * Float(image[i + 2])
        }
        func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float { let t = min(max((x - a) / (b - a), 0), 1); return t * t * (3 - 2 * t) }
        let defaults = PixelShiftParameters()
        images[0].withUnsafeBufferPointer { first in
            for s in sets.indices {
                var own = [Float](repeating: 0, count: w * h)
                let base = sets[s].base
                // Set pixel (px, py) is the first set's pixel (px, py) + shift, to within half a pixel.
                let shiftX = Float(base.x - b0.x) / 2, shiftY = Float(base.y - b0.y) / 2
                images[s].withUnsafeBufferPointer { image in own.withUnsafeMutableBufferPointer { own in
                    let own = own
                    DispatchQueue.concurrentPerform(iterations: h) { py in
                        for px in 0..<w {
                            var m = min(1, Float(image[(py * w + px) * 4 + 3]))
                            if s != 0 {
                                let x0 = Int((Float(px) + shiftX).rounded(.down)), y0 = Int((Float(py) + shiftY).rounded(.down))
                                if x0 >= 1, y0 >= 1, x0 + 2 < w, y0 + 2 < h {
                                    var lo = Float.greatestFiniteMagnitude, hi = -lo
                                    for yy in (y0 - 1)...(y0 + 2) { for xx in (x0 - 1)...(x0 + 2) { let l = luma(first, xx, yy); lo = min(lo, l); hi = max(hi, l) } }
                                    let v = luma(image, px, py)
                                    let z = hi >= 0.95 || v >= 0.95 ? 0 : max(0, max(v - hi, lo - v)) / (sigma * (max(v, 0) + PixelShiftAligner.readFloor).squareRoot() + defaults.tolerance * max(v, 0))
                                    m = max(m, smoothstep(defaults.zLow, defaults.zHigh, z))
                                } else { m = 1 }
                            }
                            own[py * w + px] = m
                        }
                    }
                } }
                let sx = Int(shiftX.rounded()), sy = Int(shiftY.rounded())
                for py in 0..<h {
                    let ty = min(max(py + sy, 0), h - 1)
                    for px in 0..<w {
                        let tx = min(max(px + sx, 0), w - 1)
                        if own[py * w + px] > mask[ty * w + tx] { mask[ty * w + tx] = own[py * w + px] }
                    }
                }
            }
        }
        func pass(_ source: [Float], radius: Int, horizontal: Bool, maximum: Bool) -> [Float] {
            var destination = [Float](repeating: 0, count: w * h)
            destination.withUnsafeMutableBufferPointer { d in source.withUnsafeBufferPointer { s in
                let d = d
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    for x in 0..<w {
                        var v: Float = 0
                        for t in -radius...radius {
                            let xx = horizontal ? min(max(x + t, 0), w - 1) : x, yy = horizontal ? y : min(max(y + t, 0), h - 1)
                            v = maximum ? max(v, s[yy * w + xx]) : v + s[yy * w + xx]
                        }
                        d[y * w + x] = maximum ? v : v / Float(2 * radius + 1)
                    }
                }
            } }
            return destination
        }
        mask = pass(pass(mask, radius: Self.dilate + 1, horizontal: true, maximum: true), radius: Self.dilate + 1, horizontal: false, maximum: true)
        mask = pass(pass(mask, radius: Self.blur, horizontal: true, maximum: false), radius: Self.blur, horizontal: false, maximum: false)

        if Task.isCancelled { throw CancellationError() }
        progress(0.45, L10n.tr("Combining 16 photos"))
        // Interleave: the lattice a pixel of the doubled grid is on picks its set; where the mask says so, the first set
        // enlarged takes over.
        let W = 2 * crop.width, H = 2 * crop.height
        var setForParity = [Int](repeating: 0, count: 4)
        for (s, set) in sets.enumerated() { setForParity[(set.base.y & 1) * 2 + (set.base.x & 1)] = s }
        var raster = PanoramaRaster(width: W, height: H, rgba: [Float](repeating: 1, count: W * H * 4))
        func withPointers(_ k: Int, _ found: [UnsafeBufferPointer<Float16>], _ body: ([UnsafeBufferPointer<Float16>]) -> Void) {
            guard k < images.count else { return body(found) }
            images[k].withUnsafeBufferPointer { withPointers(k + 1, found + [$0], body) }
        }
        withPointers(0, []) { pointers in
            raster.rgba.withUnsafeMutableBufferPointer { out in mask.withUnsafeBufferPointer { mask in
                let out = out, first = pointers[0]
                DispatchQueue.concurrentPerform(iterations: H) { oy in
                    let Y = oy + 2 * crop.y
                    for ox in 0..<W {
                        let X = ox + 2 * crop.x
                        let s = setForParity[(Y & 1) * 2 + (X & 1)], base = sets[s].base
                        let px = min(max((X - base.x) >> 1, 0), w - 1), py = min(max((Y - base.y) >> 1, 0), h - 1)
                        let i = (py * w + px) * 4, o = (oy * W + ox) * 4
                        var rgb = SIMD3(Float(pointers[s][i]), Float(pointers[s][i + 1]), Float(pointers[s][i + 2]))
                        // The same point on the first set's grid.
                        let gx = min(max(Float(X - b0.x) / 2, 0), Float(w - 1)), gy = min(max(Float(Y - b0.y) / 2, 0), Float(h - 1))
                        let x0 = min(Int(gx), w - 2), y0 = min(Int(gy), h - 2), fx = gx - Float(x0), fy = gy - Float(y0)
                        let t = (mask[y0 * w + x0] * (1 - fx) + mask[y0 * w + x0 + 1] * fx) * (1 - fy) + (mask[(y0 + 1) * w + x0] * (1 - fx) + mask[(y0 + 1) * w + x0 + 1] * fx) * fy
                        if t > 0 {
                            let pixel = { (x: Int, y: Int) -> SIMD3<Float> in let j = (y * w + x) * 4; return SIMD3(Float(first[j]), Float(first[j + 1]), Float(first[j + 2])) }
                            let top = pixel(x0, y0) * (1 - fx) + pixel(x0 + 1, y0) * fx, bottom = pixel(x0, y0 + 1) * (1 - fx) + pixel(x0 + 1, y0 + 1) * fx
                            rgb += (top * (1 - fy) + bottom * fy - rgb) * min(1, t)
                        }
                        out[o] = rgb.x; out[o + 1] = rgb.y; out[o + 2] = rgb.z
                    }
                }
            } }
        }
        return raster
    }
}
