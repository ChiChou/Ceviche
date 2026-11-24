import Foundation
import CoreImage
import Vision
import CoreML

extension RawRenderer {
    public var hasEmbeddedSkyMatte: Bool { raw?.semanticSegmentationSkyMatte != nil }
    public var hasSkyMatte: Bool { raw?.semanticSegmentationSkyMatte != nil || BundledModel.sky.isAvailable }

    /// Inference is based on a stable as-shot development, before local edits and output rotation.
    public func selection(_ kind: MaskKind, point: MaskPoint? = nil, scene: SceneCategory? = nil, people: PeopleSelection? = nil) async throws -> PhotoMask {
        var mask = PhotoMask(kind: kind)
        mask.feather = 0
        let developed = try pipeline(info.defaults, maxDimension: 3000)
        let source = info.defaults.hdr.enabled ? HDRRenderer.output(developed, settings: info.defaults.hdr, context: context, sdr: true) : developed
        let matte: CIImage
        switch kind {
        case .sky:
            // The matte a RAW carries is laid out as the sensor was held, unlike the decoder's picture, which is already
            // upright: turned the same way here, or a portrait photo's sky mask lies on its side.
            if let raw, let sky = raw.semanticSegmentationSkyMatte { matte = sky.oriented(raw.orientation) }
            else {
                let skyModel = try SkyMaskModel.loadBundled()
                // The model's small probability map, refined against the photo at render time.
                matte = try skyModel.coarseMask(for: source, context: context); mask.refinement = .sky
            }
        case .subject, .background:
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(ciImage: source, options: [:])
            try handler.perform([request])
            guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
                throw EditorError.invalidDocument(L10n.tr("No foreground subject was found. Try Object or Brush selection."))
            }
            matte = CIImage(cvPixelBuffer: try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler))
            mask.selection.inverted = kind == .background
        case .object:
            guard let point, point.isValid else {
                #if os(macOS)
                throw EditorError.invalidDocument(L10n.tr("Click inside the object to select it."))
                #else
                throw EditorError.invalidDocument(L10n.tr("Tap inside the object to select it."))
                #endif
            }
            guard #available(macOS 27, iOS 27, *) else {
                #if os(macOS)
                throw EditorError.invalidDocument(L10n.tr("Object selection needs macOS 27 or later"))
                #else
                throw EditorError.invalidDocument(L10n.tr("Object selection needs iPadOS 27 or later"))
                #endif
            }
            let request = GenerateIterativeSegmentationRequest(seedPoint: NormalizedPoint(x: point.x, y: point.y))
            try await request.downloadAssets()
            try Task.checkCancellation()
            request.qualityLevel = .accurate
            let handler = ImageRequestHandler(source)
            guard let observation = try await handler.perform(request) else { throw EditorError.invalidDocument(L10n.tr("No object was found at that point.")) }
            matte = CIImage(cgImage: try observation.cgImage, options: [.colorSpace: NSNull()])
        case .depth:
            // The model's 518 × 392 output is stored; edges are refined against the photo when rendering.
            matte = try Self.relativeDepth(source, context: context)
            mask.selection.depthRange = [0.5, 1]; mask.selection.tolerance = 0.15; mask.refinement = .edgeAware
        case .scene:
            let category = scene ?? .vegetation
            matte = try Self.sceneMatte(category, source: source, context: context)
            mask.selection.scene = category; mask.name = category.localizedTitle; mask.refinement = .edgeAware
        case .people:
            guard let people, !people.parts.isEmpty else { throw EditorError.invalidDocument(L10n.tr("Choose what to select.")) }
            let made = try peopleMatte(people, source: source)
            matte = made.matte
            mask.selection.people = people; mask.name = people.parts.map(\.localizedTitle).joined(separator: ", ")
            if made.refined { mask.refinement = .edgeAware }
        default: throw EditorError.invalidDocument(L10n.tr("This mask is created directly on the photograph."))
        }
        try Task.checkCancellation()
        mask.raster = try MaskRaster.encode(matte, context: context)
        return mask
    }

    /// Depth Anything V2 Small at its native 518 × 392: relative inverse depth, normalized so the 1st–99th
    /// percentiles span 0 (far) to 1 (near). A portrait photo is turned a quarter to landscape first and its depth turned
    /// back (392 × 518): squeezed into the landscape input instead, its depth was about 45 % less accurate.
    static func relativeDepth(_ source: CIImage, context: CIContext) throws -> CIImage {
        let portrait = source.extent.height > source.extent.width
        let input = portrait ? source.oriented(.right) : source
        let request = VNCoreMLRequest(model: try BundledModelCache.shared.visionModel(.depth))
        request.imageCropAndScaleOption = .scaleFill
        try VNImageRequestHandler(ciImage: input, options: [:]).perform([request])
        guard let observation = request.results?.first as? VNPixelBufferObservation else { throw EditorError.invalidDocument(L10n.tr("Depth estimation returned no result.")) }
        var depth = CIImage(cvPixelBuffer: observation.pixelBuffer)
        if portrait {
            depth = depth.oriented(.left)
            depth = depth.transformed(by: CGAffineTransform(translationX: -depth.extent.minX, y: -depth.extent.minY))
        }
        let width = Int(depth.extent.width), height = Int(depth.extent.height)
        var values = [Float](repeating: 0, count: width * height)
        values.withUnsafeMutableBytes { context.render(depth, toBitmap: $0.baseAddress!, rowBytes: width * 4, bounds: depth.extent, format: .Rf, colorSpace: nil) }
        let sorted = values.filter(\.isFinite).sorted()
        guard sorted.count > 16 else { throw EditorError.invalidDocument(L10n.tr("Depth estimation returned no result.")) }
        let low = Double(sorted[sorted.count / 100]), high = Double(sorted[sorted.count * 99 / 100])
        let scale = 1 / max(1e-6, high - low)
        let normalized = depth.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: scale, y: 0, z: 0, w: 0), "inputBVector": CIVector(x: scale, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: -low * scale, y: -low * scale, z: -low * scale, w: 0)]).applyingFilter("CIColorClamp")
        return normalized
    }
    /// DETR panoptic classes for one scene region at the model's 448 × 448; refined against the photo when rendering.
    static func sceneMatte(_ category: SceneCategory, source: CIImage, context: CIContext) throws -> CIImage {
        let model = try BundledModelCache.shared.model(.scene)
        let request = VNCoreMLRequest(model: try BundledModelCache.shared.visionModel(.scene))
        request.imageCropAndScaleOption = .scaleFill
        try VNImageRequestHandler(ciImage: source, options: [:]).perform([request])
        guard let observation = request.results?.first as? VNCoreMLFeatureValueObservation, let array = observation.featureValue.multiArrayValue, array.shape.count == 2 else {
            throw EditorError.invalidDocument(L10n.tr("Scene segmentation returned no result."))
        }
        let metadata = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String]
        guard let json = metadata?["com.apple.coreml.model.preview.params"]?.data(using: .utf8),
              let labels = (try JSONSerialization.jsonObject(with: json) as? [String: Any])?["labels"] as? [String] else {
            throw EditorError.invalidDocument(L10n.tr("The scene model has no class labels."))
        }
        let wanted = Set(labels.indices.filter { category.labels.contains(labels[$0]) })
        let rows = array.shape[0].intValue, columns = array.shape[1].intValue
        var pixels = [UInt8](repeating: 0, count: rows * columns), found = 0
        let pointer = array.dataPointer.bindMemory(to: Int32.self, capacity: rows * columns)
        for i in 0..<(rows * columns) where wanted.contains(Int(pointer[i])) { pixels[i] = 255; found += 1 }
        guard found > rows * columns / 500 else { throw EditorError.invalidDocument(L10n.tr("No \(category.localizedTitle) was found in this photo.")) }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let coarse = CGImage(width: columns, height: rows, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: columns, space: CGColorSpaceCreateDeviceGray(),
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw EditorError.render }
        return CIImage(cgImage: coarse, options: [.colorSpace: NSNull()])
    }
    /// Small grey pictures of each mask and each of its components, white where it selects, for the Masks list: the
    /// photo is developed once at `side` pixels on its long edge, as framed (crop and rotation applied).
    public func maskThumbnails(_ masks: [PhotoMask], adjustments: Adjustments, side: Double = 160) throws -> [UUID: CGImage] {
        var global = adjustments; global.masks = []; global.quarterTurns = 0; global.geometry = GeometryAdjustments()
        let source = try pipeline(global, maxDimension: side)
        let framed = adjustments.geometry != GeometryAdjustments() || adjustments.quarterTurns != 0
        var out: [UUID: CGImage] = [:]
        func render(_ mask: PhotoMask, id: UUID) throws {
            var matte = try maskRenderer.image(for: mask, source: source, hdr: adjustments.hdr.enabled)
            if framed { matte = try GeometryPlan(size: matte.extent.size, settings: adjustments.geometry, quarterTurns: adjustments.quarterTurns).apply(to: matte) }
            if let image = context.createCGImage(matte, from: matte.extent.integral, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) { out[id] = image }
        }
        for mask in masks {
            try Task.checkCancellation()
            try render(mask, id: mask.id)
            for component in mask.components {
                // A component alone: its selection as a mask of its own.
                var alone = PhotoMask(kind: component.selection.kind); alone.selection = component.selection; alone.selection.inverted = false
                try render(alone, id: component.id)
            }
        }
        return out
    }
    /// The mask tinted over the framed photo: red for the selected mask, or `color` (a part previewed before it is made).
    public func maskOverlay(_ mask: PhotoMask, adjustments: Adjustments, color: CIColor = CIColor(red: 1, green: 0.15, blue: 0.1, alpha: 0.45)) throws -> CGImage {
        var global = adjustments; global.masks = []; global.quarterTurns = 0; global.geometry = GeometryAdjustments()
        let source = try pipeline(global, maxDimension: 2200)
        var matte = try maskRenderer.image(for: mask, source: source, hdr: adjustments.hdr.enabled)
        if adjustments.geometry != GeometryAdjustments() || adjustments.quarterTurns != 0 { matte = try GeometryPlan(size: matte.extent.size, settings: adjustments.geometry, quarterTurns: adjustments.quarterTurns).apply(to: matte) }
        let overlay = CIImage(color: color).cropped(to: matte.extent)
            .applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: matte.extent), kCIInputMaskImageKey: matte])
        guard let image = context.createCGImage(overlay, from: overlay.extent, format: .RGBA8, colorSpace: RGBProfile.sRGB.space) else { throw EditorError.render }
        return image
    }

    /// White balance that makes the picked spot neutral, solved by Apple's RAW decoder (`neutralLocation`).
    /// `point` is normalized source coordinates (bottom-left, before crop and rotation). Nil for rendered images.
    public func neutralWhiteBalance(at point: MaskPoint, adjustments: Adjustments) throws -> (temperature: Double, tint: Double)? {
        guard let raw else { return nil }
        _ = try pipeline(adjustments, maxDimension: nil)
        let size = Self.orientedRAWSize(raw)
        raw.neutralLocation = CGPoint(x: min(size.width - 1, max(0, point.x * size.width)), y: min(size.height - 1, max(0, point.y * size.height)))
        let temperature = Double(raw.neutralTemperature), tint = Double(raw.neutralTint)
        guard temperature.isFinite, tint.isFinite else { return nil }
        return (min(50000, max(2000, temperature)), min(150, max(-150, tint)))
    }
    /// The developed color at a point, averaged over `radius` pixels of the 2200-pixel working image
    /// (radius 0 returns one real pixel). Global adjustments only, in sRGB.
    public func sampleColor(at point: MaskPoint, adjustments: Adjustments, radius: Int = 0) throws -> [Double] {
        var global = adjustments; global.masks = []; global.quarterTurns = 0; global.geometry = GeometryAdjustments()
        let source = try pipeline(global, maxDimension: 2200)
        let sampleSource = adjustments.hdr.enabled ? HDRRenderer.normalized(source) : source
        let side = 2 * max(0, radius) + 1
        let x = min(source.extent.width - Double(side), max(0, floor(point.x * source.extent.width) - Double(radius)))
        let y = min(source.extent.height - Double(side), max(0, floor(point.y * source.extent.height) - Double(radius)))
        var pixels = [Float](repeating: 0, count: side * side * 4)
        pixels.withUnsafeMutableBytes { context.render(sampleSource, toBitmap: $0.baseAddress!, rowBytes: side * 16, bounds: CGRect(x: source.extent.minX + x, y: source.extent.minY + y, width: Double(side), height: Double(side)), format: .RGBAf, colorSpace: RGBProfile.sRGB.space) }
        return (0..<3).map { c in min(1, max(0, stride(from: c, to: pixels.count, by: 4).reduce(0.0) { $0 + Double(pixels[$1]) } / Double(side * side))) }
    }
    /// Auto: all six light sliders set from the photo's tones, conservatively. The luminance histogram
    /// (sRGB-encoded, so percentiles sit where the eye sees them) is nudged halfway toward the levels of a balanced photo,
    /// so a dusk, fog or high-key scene keeps its character. Exposure is set once, from the median and held back from
    /// clipping, and never revisited: letting it answer for what the other sliders do made them fight, with exposure
    /// pulled stops one way and Highlights and Whites pushed to their stops the other. The remaining sliders are then
    /// corrected from renders of the suggestion at 256 px, each within a moderate range. Deterministic, and the other
    /// panels are left as they were.
    public func autoAdjust(_ settings: Adjustments) throws -> Adjustments {
        var result = settings
        result.resetValues(for: .light, to: info.defaults); result.disabledSections.remove(.light)
        guard let start = try toneLevels(result) else { return settings }
        // Most of the way from the median to 18 % gray, but never so far that the brightest tones clip, within ±1.5 stops.
        let median = 0.6 * log2(0.18 / max(0.0005, FilmMath.decode(start.median)))
        let protect = log2(0.98 / max(0.001, FilmMath.decode(start.white))) + 0.35
        result.exposure = (clamp(min(median, protect), -1.5, 1.5) * 100).rounded() / 100
        guard var levels = try toneLevels(result) else { return settings }
        // Where the other levels should go from here: halfway to a balanced photo's.
        func goal(_ from: Double, _ to: Double) -> Double { from + (to - from) * 0.5 }
        let target = ToneLevels(black: goal(levels.black, 0.03), shadow: goal(levels.shadow, 0.16), median: levels.median, spread: goal(levels.spread, 0.36),
                                highlight: goal(levels.highlight, 0.80), white: goal(levels.white, 0.97))
        // One slider at a time, re-measured after each, so the sliders that share tones (whites and highlights on the top,
        // contrast on everything) build on what the previous one did instead of all pulling at once. Each step moves by a
        // damped share of the error; the gains are rough slopes of the controls near zero. Contrast only ever adds: the
        // slider pivots on linear 50 % gray, so a negative value lifts the deepest tones to a floor Blacks cannot get under.
        typealias Step = (key: WritableKeyPath<Adjustments, Double>, range: ClosedRange<Double>, correction: (ToneLevels) -> Double)
        let steps: [Step] = [
            (\.highlights, -75...25, { 250 * (target.highlight - $0.highlight) }),
            (\.shadows, -25...60, { 150 * (target.shadow - $0.shadow) }),
            (\.whites, -40...50, { 250 * (target.white - $0.white) }),
            (\.blacks, -40...30, { 800 * (FilmMath.decode(target.black) - FilmMath.decode($0.black)) }),
            (\.contrast, 0...25, { 100 * (target.spread - $0.spread) / max(0.1, $0.spread) }),
        ]
        passes: for _ in 0..<3 {
            for step in steps {
                let value = clamp(result[keyPath: step.key] + 0.6 * step.correction(levels), step.range.lowerBound, step.range.upperBound)
                // Steps too small to show on the slider are not worth a render.
                guard abs(value - result[keyPath: step.key]) >= 0.5 else { continue }
                result[keyPath: step.key] = value
                guard let next = try toneLevels(result) else { break passes }
                levels = next
            }
        }
        result.exposure = (result.exposure * 100).rounded() / 100
        for key in [\Adjustments.contrast, \.highlights, \.shadows, \.whites, \.blacks] { result[keyPath: key] = result[keyPath: key].rounded() }
        return result
    }
    private func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double { min(high, max(low, value)) }
    /// Luminance levels of the developed photo, sRGB-encoded in 0…1, with masks, crop and HDR left out so they describe
    /// the whole picture in SDR terms. Nil when the picture is too small or empty to measure.
    func toneLevels(_ settings: Adjustments) throws -> ToneLevels? {
        var global = settings; global.masks = []; global.quarterTurns = 0; global.geometry = GeometryAdjustments(); global.hdr.enabled = false
        let source = try pipeline(global, maxDimension: 256)
        let w = Int(source.extent.width), h = Int(source.extent.height)
        guard w > 0, h > 0 else { return nil }
        var pixels = [Float](repeating: 0, count: w * h * 4)
        pixels.withUnsafeMutableBytes { context.render(source, toBitmap: $0.baseAddress!, rowBytes: w * 16, bounds: CGRect(x: source.extent.minX, y: source.extent.minY, width: Double(w), height: Double(h)), format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!) }
        var luma = [Double](); luma.reserveCapacity(w * h)
        for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] > 0.5 {
            let v = Double(pixels[i]) * 0.2126 + Double(pixels[i + 1]) * 0.7152 + Double(pixels[i + 2]) * 0.0722
            if v.isFinite { luma.append(FilmMath.encode(min(1, max(0, v)))) }
        }
        guard luma.count > 10 else { return nil }
        luma.sort()
        func percentile(_ p: Double) -> Double { luma[Int(Double(luma.count - 1) * p)] }
        return ToneLevels(black: percentile(0.005), shadow: percentile(0.10), median: percentile(0.5), spread: percentile(0.75) - percentile(0.25),
                          highlight: percentile(0.90), white: percentile(0.995))
    }
}

/// Percentiles of the sRGB-encoded luminance: the 0.5th (black), 10th (shadow), 50th (median), 90th (highlight) and
/// 99.5th (white), plus the interquartile spread the contrast slider works on.
struct ToneLevels: Equatable {
    var black: Double, shadow: Double, median: Double, spread: Double, highlight: Double, white: Double
}
