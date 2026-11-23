import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import ImageIO
import UniformTypeIdentifiers

public struct RenderedPreview: @unchecked Sendable {
    public let image: CGImage
    public let thumbnail: Data
    /// Red, green and blue bins, normalized together so the channels stay comparable.
    public let histogram: [[Double]]
    /// Rec. 709 luma bins on the same axis, normalized on their own for the tone curve backdrop.
    public let luminance: [Double]
    /// The pixels the waveform and vectorscope are measured from, when they are showing.
    public let scopeSource: ScopeSource?
    init(image: CGImage, thumbnail: Data, bins: [[Double]], scopeSource: ScopeSource? = nil) {
        self.image = image; self.thumbnail = thumbnail; self.scopeSource = scopeSource
        histogram = Array(bins.prefix(3)); luminance = bins.count > 3 ? bins[3] : []
    }
}

/// Serial ownership of the mutable RAW filter and the GPU context.
public actor RawRenderer {
    public nonisolated let info: ImageInfo
    public nonisolated let gpuName: String
    public nonisolated let sourceURL: URL
    let context: CIContext
    /// A RAW decoder, or a rendered image (JPEG, HEIC, TIFF and the like).
    enum Source { case raw(CIRAWFilter), bitmap(CIImage) }
    let source: Source
    var raw: CIRAWFilter? { if case .raw(let raw) = source { return raw }; return nil }
    /// Most recent first: the preview, the half-size level and the full frame take turns.
    private var redEyeFiltersCache: [(extent: CGRect, filters: [CIFilter])] = []
    let retouchRenderer: RetouchRenderer
    let skinToneRenderer = SkinToneRenderer()
    let maskRenderer: MaskRenderer
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    /// The last previews, most recent first: the edit and the "original" it is compared with alternate, and one slot
    /// had each evict the other.
    private var cached: [(Adjustments, Bool, RenderedPreview)] = []
    private static let cachedPreviews = 2
    /// Preview-sized decodes of a very large bitmap, by the long side asked for (see `bitmapProxy`).
    private var bitmapProxies: [(limit: Int, image: CIImage)] = []
    /// Above this many pixels a bitmap's previews come from an ImageIO decode at preview size.
    static let proxyPixels = 100_000_000.0
    private let pixelRenderer = PixelRenderer()
    private let lookRenderer = PixelRenderer()
    private let profileRenderer = CameraProfileRenderer()
    private let lutRenderer = LUTRenderer()
    let filmRenderer = FilmSimulationRenderer()
    /// The scene the stock previews share, kept while the edit it was made from is unchanged.
    var filmPreviewScene: (key: Adjustments, size: Double, image: CIImage)?
    /// A second decoder for the camera's own rendering under a film at less than full amount: a `CIRAWFilter`'s output
    /// follows its settings until rendered, so one decoder cannot give both tone responses at once.
    private var cameraRAW: CIRAWFilter?

    /// How far a bitmap's values go above white. Only floating-point samples or a PQ or HLG transfer can exceed it, so
    /// other files are not read for it, and those that can are measured on a small thumbnail: rendering the full
    /// image, even scaled down, pulls every pixel through Core Image, and ImageIO decodes a large TIFF again for each
    /// tile it hands over (a 16-bit Hasselblad pixel shift TIFF took minutes to open).
    static func bitmapHeadroom(_ source: CGImageSource, properties: [String: Any], context: CIContext) -> Float {
        let isFloat = properties[kCGImagePropertyIsFloat as String] as? Bool == true
        let wideTransfer = CGImageSourceCreateImageAtIndex(source, 0, nil)?.colorSpace.map(CGColorSpaceUsesITUR_2100TF) == true
        guard isFloat || wideTransfer else { return 1 }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 256,
                                        kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldAllowFloat: true]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return 1 }
        return HDRRenderer.headroom(CIImage(cgImage: thumbnail, options: [.expandToHDR: true]), context: context)
    }
    /// A TIFF or PNG decoded once into four channels in memory. Left to Core Image, every render re-reads the file
    /// (re-inflating its strips, over the network for a share) and converts 3-channel or big-endian 16-bit pixels
    /// on the CPU: about 30 s per preview for a 385 MB layered TIFF, against 0.1 s from this buffer.
    /// Float, PQ/HLG and non-RGB files stay with Core Image, which expands their HDR.
    static func decodedBitmap(_ source: CGImageSource, type: String?, properties: [String: Any]) -> CIImage? {
        decodedPixels(source, type: type, properties: properties).map { CIImage(cgImage: $0.image).oriented($0.orientation) }
    }
    /// `decodedBitmap`'s pixels, before orientation. Up to `proxyPixels`: a larger image stays with Core Image, which
    /// reads it in tiles, so a 400 MP pixel shift TIFF is never held whole.
    static func decodedPixels(_ source: CGImageSource, type: String?, properties: [String: Any]) -> (image: CGImage, orientation: CGImagePropertyOrientation)? {
        let width = properties[kCGImagePropertyPixelWidth as String] as? Int ?? 0, height = properties[kCGImagePropertyPixelHeight as String] as? Int ?? 0
        guard let type, let format = UTType(type), format.conforms(to: .tiff) || format.conforms(to: .png),
              properties[kCGImagePropertyIsFloat as String] as? Bool != true, Double(width * height) <= proxyPixels,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              let space = image.colorSpace, space.model == .rgb, !CGColorSpaceUsesITUR_2100TF(space) else { return nil }
        let wide = image.bitsPerComponent > 8
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: wide ? 16 : 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | (wide ? CGBitmapInfo.byteOrder16Little.rawValue : 0)) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let pixels = context.makeImage() else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation as String] as? UInt32).flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
        return (pixels, orientation)
    }
    /// `pixels` scaled so their long side is `side`, in the same format.
    static func downsampled(_ pixels: CGImage, side: Int) -> CGImage? {
        let scale = Double(side) / Double(max(pixels.width, pixels.height))
        let width = max(1, Int((Double(pixels.width) * scale).rounded())), height = max(1, Int((Double(pixels.height) * scale).rounded()))
        guard let space = pixels.colorSpace,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: pixels.bitsPerComponent, bytesPerRow: 0,
                                      space: space, bitmapInfo: pixels.bitmapInfo.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(pixels, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
    /// Whether a bitmap opens in HDR: a gain map, or floating-point or PQ/HLG samples that go above white. The
    /// catalog finds this once at import (`CatalogAsset.hdr`) and hands it to the renderer.
    public static func bitmapIsHDR(_ url: URL, source: CGImageSource, properties: [String: Any], context: CIContext? = nil) -> Bool {
        if let image = CIImage(contentsOf: url, options: [.expandToHDR: true]), image.contentHeadroom > 1 { return true }
        return bitmapHeadroom(source, properties: properties, context: context ?? probeContext) > 1.01
    }
    private static let probeContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .workingFormat: CIFormat.RGBAf])
    /// `hdr` is the catalog's answer to `bitmapIsHDR`; nil looks at the file.
    public init(sourceURL: URL, hdr: Bool? = nil) throws {
        let filename = sourceURL.lastPathComponent
        guard let device = MTLCreateSystemDefaultDevice() else { throw EditorError.noGPU }
        gpuName = device.name
        let context = CIContext(mtlDevice: device, options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .workingFormat: CIFormat.RGBAf, .cacheIntermediates: true,
            .name: "Ceviche RAW pipeline"
        ])
        self.context = context
        maskRenderer = MaskRenderer(context: context)
        retouchRenderer = RetouchRenderer(context: context)
        self.sourceURL = sourceURL
        guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any] else { throw EditorError.decode }
        let type = CGImageSourceGetType(imageSource).map { $0 as String }
        // Some Sony ARWs are identified as TIFF when opened from Data. The URL decoder
        // uses the extension and camera metadata to select the correct RAW codec.
        let rawExtensions: Set<String> = ["arw", "srf", "sr2", "dng", "nef", "nrw", "cr2", "cr3", "crw", "raf", "orf", "rw2", "pef", "rwl", "3fr", "iiq"]
        let rawType = type.flatMap { UTType($0) }?.conforms(to: .rawImage) == true || rawExtensions.contains(sourceURL.pathExtension.lowercased())
        // CIRAWFilter also accepts rendered JPEGs; route those through the bitmap pipeline.
        let candidate = rawType ? CIRAWFilter(imageURL: sourceURL) : nil
        let raw = candidate.flatMap { $0.nativeSize.width > 0 && $0.nativeSize.height > 0 ? $0 : nil }
        if rawType && raw == nil { throw EditorError.decode }
        let source: Source
        var defaults = Adjustments()
        if let raw {
            source = .raw(raw)
            defaults = Self.cameraDefaults(raw)
        } else {
            guard let bitmap = CIImage(contentsOf: sourceURL, options: [.applyOrientationProperty: true, .expandToHDR: true]) else { throw EditorError.decode }
            source = .bitmap(bitmap)
            defaults.hdr.enabled = hdr ?? (bitmap.contentHeadroom > 1 || Self.bitmapHeadroom(imageSource, properties: properties, context: context) > 1.01)
        }
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int])?.first
        let aperture = exif[kCGImagePropertyExifFNumber as String] as? Double
        let shutter = exif[kCGImagePropertyExifExposureTime as String] as? Double
        var capture: [String] = []
        if let aperture { capture.append(String(format: "ƒ/%.1f", aperture)) }
        if let shutter, shutter > 0 { capture.append(shutter < 1 ? L10n.tr("1/\(Int((1 / shutter).rounded())) s") : String(format: "%.1f s", shutter)) }
        if let iso { capture.append("ISO \(iso)") }
        let size: CGSize
        switch source {
        case .raw(let raw): size = Self.orientedRAWSize(raw)
        case .bitmap(let bitmap): size = bitmap.extent.size
        }
        var info = ImageInfo(filename: filename, width: Int(size.width), height: Int(size.height),
            camera: tiff[kCGImagePropertyTIFFModel as String] as? String ?? "",
            lens: exif[kCGImagePropertyExifLensModel as String] as? String ?? "",
            capture: capture.joined(separator: "  -  "), isRAW: raw != nil, defaults: defaults, sourceBitDepth: properties[kCGImagePropertyDepth as String] as? Int, lensCorrectionSupported: raw?.isLensCorrectionSupported)
        info.make = tiff[kCGImagePropertyTIFFMake as String] as? String
        info.focalLength = exif[kCGImagePropertyExifFocalLength as String] as? Double
        info.focalLength35mm = exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? Double
        self.info = info
        self.source = source
    }

    /// Where a RAW's development starts: the camera's as-shot white balance and the noise reduction Apple sets for
    /// this camera and ISO. The catalog records these at import (`ImageInfo.defaultsFromImport`).
    public static func cameraDefaults(_ raw: CIRAWFilter) -> Adjustments {
        var defaults = Adjustments()
        defaults.temperature = min(50000, max(2000, Double(raw.neutralTemperature)))
        defaults.tint = min(150, max(-150, Double(raw.neutralTint)))
        if raw.isLuminanceNoiseReductionSupported { defaults.noiseReduction = sliderAmount(raw.luminanceNoiseReductionAmount) }
        if raw.isColorNoiseReductionSupported { defaults.colorNoiseReduction = sliderAmount(raw.colorNoiseReductionAmount) }
        return defaults
    }
    /// A decoder amount (0...1) as a Detail slider value (0...100). Some files report NaN, which starts at 0.
    static func sliderAmount(_ amount: Float) -> Double { amount.isFinite ? min(100, max(0, (Double(amount) * 100).rounded())) : 0 }

    static func orientedRAWSize(_ raw: CIRAWFilter) -> CGSize {
        // nativeSize is sensor-oriented, while outputImage already applies EXIF orientation.
        // All source-space geometry and export dimensions must describe those decoded pixels.
        let size = raw.nativeSize
        switch raw.orientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            return CGSize(width: size.height, height: size.width)
        default:
            return size
        }
    }

    public static func open(_ url: URL, hdr: Bool? = nil) throws -> (RawRenderer, Adjustments) {
        let renderer = try RawRenderer(sourceURL: url, hdr: hdr)
        return (renderer, renderer.info.defaults)
    }

    /// `directDecode` asks the RAW decoder for `maxDimension` itself: about twice as quick for small sizes, but with
    /// the decoder's rings around bright points (see `decodeScale`), so only for Library thumbnails.
    /// With ACES or a film, the edits work on the scene's linear light and the rendering comes after them, as a print
    /// is made from what the camera saw; with the camera's rendering they work on its picture.
    func pipeline(_ settings: Adjustments, maxDimension: Double?, directDecode: Bool = false) throws -> CIImage {
        let (developed, effective, sourceScale) = try beforeRetouch(settings, maxDimension: maxDimension, directDecode: directDecode)
        var a = effective
        let film = a.rendering == .film ? a.film?.rendered : nil
        var image = try retouched(developed, a)
        // The film brings its own grain.
        if film != nil { a.grain.amount = 0 }
        image = try graded(image, a, scale: sourceScale)
        switch a.rendering {
        case .film:
            guard let film else { break }
            image = filmRenderer.apply(film, to: image, key: .init(adjustments: effective, size: maxDimension, direct: directDecode))
            if film.amount < 100 {
                // The camera's own rendering of the same edit, which the film is blended over.
                var own = effective; own.film = nil
                let camera = try beforeRetouch(settings, maxDimension: maxDimension, directDecode: directDecode, cameraRendering: true).image
                let ownImage = try graded(try retouched(camera, own), own, scale: sourceScale)
                image = image.applyingFilter("CIMix", parameters: [kCIInputBackgroundImageKey: ownImage, "inputAmount": film.amount / 100])
            }
        case .aces:
            image = ACESRenderer.apply(to: image)
        case .camera:
            break
        }
        return try finished(image, a, maxDimension: maxDimension)
    }
    /// After the rendering: the LUT, crop and geometry, the post-crop vignette and the scale.
    func finished(_ image: CIImage, _ a: Adjustments, maxDimension: Double?) throws -> CIImage {
        var image = lutRenderer.apply(a.lut, to: image, hdr: a.hdr.enabled)
        if a.geometry != GeometryAdjustments() || a.quarterTurns != 0 {
            image = try GeometryPlan(size: image.extent.size, settings: a.geometry, quarterTurns: a.quarterTurns).apply(to: image)
        }
        image = ExtendedRenderer.vignette(image, settings: a.postCropVignette)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        if let maxDimension { image = Self.scaled(image, limit: maxDimension) }
        return image
    }
    /// The scene the film exposes, graded, at a preview size: what every stock's preview shares.
    func filmScene(_ settings: Adjustments, maxDimension: Double) throws -> CIImage {
        let (developed, effective, sourceScale) = try beforeRetouch(settings, maxDimension: maxDimension)
        var a = effective; a.grain.amount = 0
        return try graded(try retouched(developed, a), a, scale: sourceScale)
    }
    private func retouched(_ image: CIImage, _ a: Adjustments) throws -> CIImage {
        var image = try retouchRenderer.apply(a.retouch, to: image)
        // Even tone after the spots are healed, on the frame the strokes use.
        image = skinToneRenderer.apply(a.skinTone, to: image)
        return a.redEyeCorrection ? applyRedEyeCorrection(to: image) : image
    }
    /// The global and local adjustments.
    private func graded(_ image: CIImage, _ a: Adjustments, scale: Double) throws -> CIImage {
        let image = pixelRenderer.apply(a.pixels, to: image, scale: scale, local: false, hdr: a.hdr.enabled)
        return try maskRenderer.apply(a.masks, to: image, scale: scale, hdr: a.hdr.enabled)
    }
    /// Sample in normalized source coordinates, at the input of the selected Defringe pass.
    public func sampleDefringe(at point: MaskPoint, band: Defringe.Band, adjustments: Adjustments, maskID: UUID? = nil) throws -> ClosedRange<Double>? {
        try Task.checkCancellation()
        let (developed, a, scale) = try beforeRetouch(adjustments, maxDimension: nil)
        let retouched = try retouched(developed, a)
        let input: CIImage
        if let maskID {
            let global = pixelRenderer.apply(a.pixels, to: retouched, scale: scale, local: false, hdr: a.hdr.enabled)
            guard let local = try maskRenderer.defringeInput(maskID, masks: a.masks, source: global, scale: scale, hdr: a.hdr.enabled) else { return nil }
            input = local
        } else {
            input = pixelRenderer.defringeInput(a.pixels, from: retouched, local: false, hdr: a.hdr.enabled)
        }
        return ExtendedRenderer.sampleDefringe(input, at: point, band: band, context: context)
    }
    /// The pipeline up to retouching: the image retouch strokes are drawn on, with the effective settings and the
    /// scale from source pixels. With ACES or a film it is the scene's linear light; `cameraRendering` asks for the
    /// camera's own rendering regardless, from a second decoder.
    func beforeRetouch(_ settings: Adjustments, maxDimension: Double?, directDecode: Bool = false, cameraRendering: Bool = false) throws -> (image: CIImage, settings: Adjustments, sourceScale: Double) {
        assert((try? settings.validated()) != nil, "Adjustments are validated where they enter the app")
        let a = settings.effective(defaults: info.defaults)
        var image: CIImage
        // The scene's linear light, for a rendering after the edits.
        let scene = a.rendering != .camera && !cameraRendering
        switch source {
        case .raw(let raw):
            if cameraRendering, cameraRAW == nil { cameraRAW = CIRAWFilter(imageURL: sourceURL) }
            guard let decoder = cameraRendering ? cameraRAW : raw else { throw EditorError.decode }
            decoder.scaleFactor = maxDimension.map { wanted in
                let scale = wanted / Double(max(info.width, info.height))
                return Float(directDecode ? min(1, scale) : Self.decodeScale(scale))
            } ?? 1
            decoder.neutralTemperature = Float(a.temperature)
            decoder.neutralTint = Float(a.tint)
            decoder.exposure = Float(a.exposure)
            decoder.extendedDynamicRangeAmount = a.hdr.enabled ? 1 : 0
            // Apple's own tone response and noise reduction; nothing here imitates another engine. ACES and the film
            // take the scene's linear light and are their own tone response.
            decoder.boostAmount = a.neutralRAW || scene ? 0 : 1
            if decoder.isLuminanceNoiseReductionSupported { decoder.luminanceNoiseReductionAmount = Float(a.noiseReduction / 100) }
            if decoder.isColorNoiseReductionSupported { decoder.colorNoiseReductionAmount = Float((a.colorNoiseReduction ?? a.noiseReduction) / 100) }
            if decoder.isLensCorrectionSupported { decoder.isLensCorrectionEnabled = a.lensCorrection }
            // A chart profile corrects the decoder's colour in scene-linear light, before the decoder's tone.
            decoder.linearSpaceFilter = a.cameraProfile.flatMap { $0.enabled ? ChartCalibrationFilter(profile: $0) : nil }
            guard let output = decoder.outputImage else { throw EditorError.decode }
            image = maxDimension.map { Self.scaled(output, limit: $0) } ?? output
        case .bitmap(var output):
            if let maxDimension, let proxy = bitmapProxy(output, limit: maxDimension) { output = proxy } else { output = bitmapPixels(output) }
            if !a.hdr.enabled && output.contentHeadroom > 1 { output = HDRRenderer.toneMap(output, source: output.contentHeadroom) }
            if let maxDimension { output = Self.scaled(output, limit: maxDimension) }
            output = output.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: a.temperature, y: a.tint),
                "inputTargetNeutral": CIVector(x: 6500, y: 0)
            ])
            image = output.applyingFilter("CIExposureAdjust", parameters: ["inputEV": a.exposure])
            image = PixelRenderer.noiseReduced(image, luma: a.noiseReduction, chroma: a.colorNoiseReduction, hdr: a.hdr.enabled)
        }
        if raw != nil, let profile = a.cameraProfile, !scene {
            image = profileRenderer.apply(profile, to: image, temperature: a.temperature, hdr: a.hdr.enabled)
        }
        let sourceScale = min(1, image.extent.width / Double(info.width))
        if let look = a.look, look.enabled, look.amount > 0 {
            let developed = lookRenderer.apply(look.adjustments, to: image, scale: sourceScale, local: true, hdr: a.hdr.enabled)
            image = FilmRenderer.blend(developed, over: image, amount: min(1, look.amount))
        }
        // Each face's warp in turn; each moves only its own face.
        for warp in a.faceLiquifies { image = try warp.apply(to: image) }
        return (image, a, sourceScale)
    }
    /// A bitmap at twice `limit`, for `scaled` to finish with its usual averaging: scaled from the pixels decoded once in
    /// memory (`decodedPixels`), or for a very large one decoded by ImageIO at that size. Scaling the full image instead
    /// pulls every pixel through Core Image, which keeps a float copy of the whole picture per render (3 GB for a 26 MP
    /// 16-bit TIFF), and ImageIO decodes a large TIFF again for each tile it hands over: a 400 MP pixel shift TIFF took
    /// minutes to preview. Images with a gain map keep the full decode, which applies it. Nil when the full image is used.
    private func bitmapProxy(_ full: CIImage, limit: Double) -> CIImage? {
        guard full.contentHeadroom <= 1, limit * 2 < max(full.extent.width, full.extent.height) else { return nil }
        let size = Int((limit * 2).rounded(.up))
        if let hit = bitmapProxies.first(where: { $0.limit == size }) { return hit.image }
        // Already decoded for a full-size render: scaled from memory, without reading the file again.
        if let decoded = bitmapDecoded {
            guard let small = Self.downsampled(decoded.image, side: size) else { return nil }
            let image = CIImage(cgImage: small).oriented(decoded.orientation)
            bitmapProxies.insert((size, image), at: 0)
            if bitmapProxies.count > 2 { bitmapProxies.removeLast() }
            return image
        }
        guard rendersBitmapProxies || full.extent.width * full.extent.height > Self.proxyPixels else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: size,
                                        kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldAllowFloat: true]
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = CIImage(cgImage: decoded, options: [.expandToHDR: true])
        bitmapProxies.insert((size, image), at: 0)
        if bitmapProxies.count > 2 { bitmapProxies.removeLast() }
        return image
    }
    /// The bitmap's pixels for a render: decoded once on first use (`decodedBitmap`), or the file-backed image when
    /// Core Image has to read it itself. Opening, and reading the camera defaults, never decode.
    private func bitmapPixels(_ file: CIImage) -> CIImage {
        if let bitmapPixelsCache { return bitmapPixelsCache }
        let decoded = CGImageSourceCreateWithURL(sourceURL as CFURL, nil).flatMap { source in
            (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]).flatMap {
                Self.decodedPixels(source, type: CGImageSourceGetType(source) as String?, properties: $0)
            }
        }
        // The decode has to land where the file-backed image is, or every edit placed on it would shift.
        let image = decoded.map { CIImage(cgImage: $0.image).oriented($0.orientation) }
        if let image, image.extent == file.extent { bitmapDecoded = decoded; bitmapPixelsCache = image }
        else { bitmapPixelsCache = file }
        return bitmapPixelsCache ?? file
    }
    private var bitmapPixelsCache: CIImage?
    private var bitmapDecoded: (image: CGImage, orientation: CGImagePropertyOrientation)?
    /// A TIFF or PNG: its previews come from ImageIO at preview size, so only a full-size render (1:1, export) holds
    /// the whole picture in memory.
    private var rendersBitmapProxies: Bool {
        guard let type = CGImageSourceCreateWithURL(sourceURL as CFURL, nil).flatMap(CGImageSourceGetType).map({ $0 as String }),
              let format = UTType(type) else { return false }
        return format.conforms(to: .tiff) || format.conforms(to: .png)
    }
    /// The eye positions Core Image detects are in the coordinates of the image it looked at, so the detection is
    /// cached per source extent: the preview and the full-resolution export each get their own.
    private func redEyeFilters(for source: CIImage) -> [CIFilter] {
        if let index = redEyeFiltersCache.firstIndex(where: { $0.extent == source.extent }) {
            let hit = redEyeFiltersCache.remove(at: index); redEyeFiltersCache.insert(hit, at: 0)
            return hit.filters
        }
        let filters = source.autoAdjustmentFilters(options: [.redEye: true, .enhance: false]).filter { $0.name == "CIRedEyeCorrection" }
        redEyeFiltersCache.insert((source.extent, filters), at: 0)
        if redEyeFiltersCache.count > 3 { redEyeFiltersCache.removeLast() }
        return filters
    }
    private func applyRedEyeCorrection(to image: CIImage) -> CIImage {
        var result = image
        for filter in redEyeFilters(for: image) {
            filter.setValue(result, forKey: kCIInputImageKey)
            if let output = filter.outputImage { result = output.cropped(to: image.extent) }
        }
        return result
    }
    /// How many red eyes the decoder's output shows at the preview scale.
    public func redEyeCount() -> Int {
        switch source {
        case .raw(let raw): raw.outputImage.map { redEyeFilters(for: $0).count } ?? 0
        case .bitmap(let bitmap): redEyeFilters(for: bitmapPixels(bitmap)).count
        }
    }
    /// Shrinks by averaging the pixels each output pixel covers, so stars and other small bright points keep their
    /// light instead of flickering in and out between frames.
    static func scaled(_ image: CIImage, limit: Double) -> CIImage {
        let scale = min(1, limit / max(image.extent.width, image.extent.height))
        return scale < 1 ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale), highQualityDownsample: true) : image
    }
    /// Resizes a finished image to an output size, starting at the origin. Shrinking averages, as `scaled` does;
    /// Lanczos, whose negative lobes ring around bright points when it shrinks, is kept for enlarging only.
    static func resized(_ image: CIImage, scaleX: Double, scaleY: Double) -> CIImage {
        let size = CGRect(x: 0, y: 0, width: (image.extent.width * scaleX).rounded(), height: (image.extent.height * scaleY).rounded())
        let origin = image.clampedToExtent().transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        if scaleX <= 1 && scaleY <= 1 {
            return origin.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY), highQualityDownsample: true).cropped(to: size)
        }
        return origin.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scaleY, kCIInputAspectRatioKey: scaleX / scaleY]).cropped(to: size)
    }
    /// The size to ask the RAW decoder for. Below half size `CIRAWFilter` shrinks with a Lanczos-like filter whose
    /// negative lobes draw dark rings around stars, lamps and thin bright lines (0.08 next to a star on a 0.22 sky in
    /// a 2200 px preview, against 0.20 at full size), so it decodes at half size at least and `scaled` does the rest.
    static func decodeScale(_ wanted: Double) -> Double { min(1, max(0.5, wanted)) }
    /// HDR previews carry the headroom `HDRRenderer.output` measured (the brightest developed value). Core Image's own
    /// `calculateHDRStats` reports 1.0 for photos whose highlights are small (stars, speculars), and Core Animation then
    /// shows the float pixels as SDR, so the statistic is never used for display images.
    public func preview(_ adjustments: Adjustments, sdr: Bool = false) throws -> RenderedPreview {
        maskRenderer.prune(adjustments.masks)
        if let index = cached.firstIndex(where: { $0.0 == adjustments && $0.1 == sdr }) {
            let hit = cached.remove(at: index); cached.insert(hit, at: 0)
            return hit.2
        }
        filmRenderer.yieldToPreview()
        let image = try pipeline(adjustments, maxDimension: 2200)
        let hdr = adjustments.hdr.enabled
        let output = hdr ? HDRRenderer.output(image, settings: adjustments.hdr, context: context, sdr: sdr) : image
        guard let cg = context.cgImage(output, from: output.extent, format: hdr && !sdr ? .RGBAh : .RGBA16,
            colorSpace: hdr && !sdr ? HDRRenderer.space : try adjustments.colorProfile.colorSpace(), hdr: hdr && !sdr) else { throw EditorError.render }
        // Thumbnails are intentionally SDR, regardless of the editing display mode.
        let smallHDR = Self.scaled(image, limit: Double(CatalogImporter.thumbnailPixelSize))
        let small = hdr ? HDRRenderer.output(smallHDR, settings: adjustments.hdr, context: context, sdr: true) : smallHDR
        guard let jpeg = context.jpegRepresentation(of: small, colorSpace: colorSpace, options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.82]),
              let thumb = context.createCGImage(small, from: small.extent, format: .RGBA16, colorSpace: try adjustments.colorProfile.colorSpace()) else { throw EditorError.render }
        let extended = hdr && !sdr
        let result = RenderedPreview(image: cg, thumbnail: jpeg, bins: extended ? HDRRenderer.histogram(output, context: context, stops: adjustments.hdr.headroom) : Self.histogram(thumb),
                                     scopeSource: ScopeSource(levels: extended ? cg : thumb, colour: thumb, hdrStops: extended ? adjustments.hdr.headroom : nil))
        cached.insert((adjustments, sdr, result), at: 0)
        if cached.count > Self.cachedPreviews { cached.removeLast(cached.count - Self.cachedPreviews) }
        return result
    }
    /// Only the Library thumbnail, developed at its own size and decoded directly at it: about three times quicker
    /// than `preview`, for batches that change many photos' edits without showing them. The editor replaces it with
    /// a ring-free one from its preview once the photo is opened.
    public func thumbnail(_ adjustments: Adjustments) throws -> Data {
        maskRenderer.prune(adjustments.masks)
        let image = try pipeline(adjustments, maxDimension: Double(CatalogImporter.thumbnailPixelSize), directDecode: true)
        let small = adjustments.hdr.enabled ? HDRRenderer.output(image, settings: adjustments.hdr, context: context, sdr: true) : image
        guard let jpeg = context.jpegRepresentation(of: small, colorSpace: colorSpace, options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.82]) else { throw EditorError.render }
        return jpeg
    }
    private static func histogram(_ image: CGImage) -> [[Double]] {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let bitmap = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            bitmap?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var bins = Array(repeating: Array(repeating: 0.0, count: 128), count: 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            for channel in 0..<3 { bins[channel][Int(pixels[index + channel]) / 2] += 1 }
            let luma = 0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1]) + 0.0722 * Double(pixels[index + 2])
            bins[3][min(127, Int(luma) / 2)] += 1
        }
        return normalizedHistogram(bins)
    }
    /// Square-root scaling keeps sparse tones visible; RGB share one peak, luma uses its own.
    static func normalizedHistogram(_ bins: [[Double]]) -> [[Double]] {
        let peak = max(1, bins.prefix(3).flatMap { $0 }.max() ?? 1)
        let lumaPeak = max(1, bins.count > 3 ? bins[3].max() ?? 1 : 1)
        return bins.enumerated().map { channel, values in values.map { sqrt($0 / (channel < 3 ? peak : lumaPeak)) } }
    }
    /// Source-resolution pixels for a region of the developed image, so zoomed views show the file's real pixels
    /// instead of a magnified preview. `region` is normalized with a top-left origin; the result reports the
    /// pixel-aligned region it actually covers. Returns nil when the region exceeds `maxPixels`.
    public func detail(_ adjustments: Adjustments, sdr: Bool = false, region: CGRect, maxPixels: Int = 16_000_000) throws -> (image: CGImage, region: CGRect)? {
        try prepareDetail(adjustments, sdr: sdr, region: region, maxPixels: maxPixels)?.render()
    }
    /// The graph for a source-resolution region, built here where the pipeline state lives, with the render itself
    /// left to the caller. Rendering a large region can take seconds, and running it outside
    /// the actor keeps previews from queueing behind it. With `photoWidth`, the width in pixels the whole photo is
    /// shown at, a region shown smaller than the source is developed at full size and then averaged down to it, so
    /// the fitted view shows the full-resolution development rather than the preview.
    ///
    /// The source is developed at the smallest level that still has a pixel for every pixel shown: half size while
    /// the photo is shown at half its size or less, which is a quarter of the work and memory of the full frame, and
    /// full size once the zoom passes that. Half is as small as the RAW decoder goes cleanly (`decodeScale`).
    public func prepareDetail(_ adjustments: Adjustments, sdr: Bool = false, region: CGRect, photoWidth: Double? = nil, maxPixels: Int = 16_000_000) throws -> DetailRender? {
        // A tile's film development gives way to the next preview (`FilmSimulationRenderer.yieldToPreview`).
        filmRenderer.interruptible = true
        defer { filmRenderer.interruptible = false }
        var level = 1.0
        var image: CIImage
        if let photoWidth, photoWidth <= Double(info.width) * Self.halfLevel {
            image = try pipeline(adjustments, maxDimension: (Double(max(info.width, info.height)) * Self.halfLevel).rounded(.up))
            level = Self.halfLevel
            // A crop leaves fewer pixels than the frame had: the half level may then be too small after all.
            if photoWidth > image.extent.width { image = try pipeline(adjustments, maxDimension: nil); level = 1 }
        } else {
            image = try pipeline(adjustments, maxDimension: nil)
        }
        let full = image.extent
        let bounds = region.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !bounds.isEmpty, full.width > 0, full.height > 0 else { return nil }
        let scale = photoWidth.map { min(1, max(1, $0) / full.width) } ?? 1
        let x = floor(bounds.minX * full.width), top = floor(bounds.minY * full.height)
        let width = min(full.width - x, ceil(bounds.maxX * full.width) - x), height = min(full.height - top, ceil(bounds.maxY * full.height) - top)
        guard width >= 1, height >= 1, Int(width * scale * height * scale) <= maxPixels else { return nil }
        var rect = CGRect(x: full.minX + x, y: full.maxY - top - height, width: width, height: height)
        let hdr = adjustments.hdr.enabled
        var output = hdr ? HDRRenderer.output(image, settings: adjustments.hdr, context: context, sdr: sdr) : image
        if scale < 1 {
            // Clamped so the edges average with their own pixels rather than with the transparency around the region.
            output = output.cropped(to: rect).clampedToExtent()
                // Moved to the origin, then scaled: scaling first would leave the region off by its corner × (1/scale − 1).
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: -rect.minX, y: -rect.minY), highQualityDownsample: true)
            rect = CGRect(x: 0, y: 0, width: max(1, (width * scale).rounded()), height: max(1, (height * scale).rounded()))
        }
        try Task.checkCancellation()
        return DetailRender(context: context, image: output, rect: rect, format: hdr && !sdr ? .RGBAh : .RGBA16,
                            colorSpace: hdr && !sdr ? HDRRenderer.space : try adjustments.colorProfile.colorSpace(), hdr: hdr && !sdr,
                            region: CGRect(x: x / full.width, y: top / full.height, width: width / full.width, height: height / full.height), scale: scale * level)
    }
    static let halfLevel = 0.5
    /// Lets go of finished previews and Core Image's intermediates; the next render makes them again.
    public func releaseCaches() {
        cached.removeAll(); redEyeFiltersCache.removeAll(); filmRenderer.releaseCaches()
        context.clearCaches()
    }
    /// Just the image, at `maxDimension` pixels on the long edge, for transient views such as hover previews:
    /// no histogram, thumbnail or cache entry.
    public func displayImage(_ adjustments: Adjustments, maxDimension: Double, sdr: Bool = false) throws -> CGImage {
        filmRenderer.yieldToPreview()
        let image = try pipeline(adjustments, maxDimension: max(64, min(2200, maxDimension)))
        let hdr = adjustments.hdr.enabled
        let output = hdr ? HDRRenderer.output(image, settings: adjustments.hdr, context: context, sdr: sdr) : image
        try Task.checkCancellation()
        guard let cg = context.cgImage(output, from: output.extent, format: hdr && !sdr ? .RGBAh : .RGBA16,
            colorSpace: hdr && !sdr ? HDRRenderer.space : try adjustments.colorProfile.colorSpace(), hdr: hdr && !sdr) else { throw EditorError.render }
        return cg
    }
    public func export(to url: URL, adjustments: Adjustments, format: ExportFormat) throws {
        var settings = ExportSettings(); settings.select(format); settings.profile.preset = .sRGB
        try export(to: url, adjustments: adjustments, settings: settings)
    }
}

/// A prepared source-resolution render. Core Image contexts and images are immutable and thread-safe, so
/// `render` may run on any thread while the renderer actor goes on serving previews.
public struct DetailRender: @unchecked Sendable {
    let context: CIContext
    let image: CIImage
    let rect: CGRect
    let format: CIFormat
    let colorSpace: CGColorSpace
    let hdr: Bool
    public let region: CGRect
    /// Pixels rendered per source pixel: 1 for the source's own pixels, less when the region is shown smaller.
    public var scale: Double = 1
    public func render() throws -> (image: CGImage, region: CGRect) {
        guard let cg = context.cgImage(image, from: rect, format: format, colorSpace: colorSpace, hdr: hdr) else { throw EditorError.render }
        return (cg, region)
    }
}

extension CIContext {
    /// Renders `rect` of `image` without Core Image's HDR statistics (see `RawRenderer.preview`), which only macOS 26
    /// offers to turn off and macOS 15 never calculates here. On macOS 26 an HDR image carries the headroom
    /// `HDRRenderer.toneMap` tagged it with into the `CGImage`; before that a `CIImage` cannot be tagged, so the
    /// headroom is measured from the rendered pixels and stamped on the `CGImage`, which is what Core Animation
    /// and the export metadata read. `calculateHDRStats` nil keeps Core Image's default on macOS 26.
    func cgImage(_ image: CIImage, from rect: CGRect, format: CIFormat, colorSpace: CGColorSpace, hdr: Bool, calculateHDRStats: Bool? = false) -> CGImage? {
        if #available(macOS 26, *) {
            guard let calculateHDRStats else { return createCGImage(image, from: rect, format: format, colorSpace: colorSpace) }
            return createCGImage(image, from: rect, format: format, colorSpace: colorSpace, deferred: false, calculateHDRStats: calculateHDRStats)
        }
        return legacyCGImage(image, from: rect, format: format, colorSpace: colorSpace, hdr: hdr)
    }
    /// The path before macOS 26, on its own so a test can exercise it on any system.
    func legacyCGImage(_ image: CIImage, from rect: CGRect, format: CIFormat, colorSpace: CGColorSpace, hdr: Bool) -> CGImage? {
        guard let cg = createCGImage(image, from: rect, format: format, colorSpace: colorSpace, deferred: false) else { return nil }
        guard hdr else { return cg }
        // Nil for a color space without headroom (not extended, PQ or HLG); such an image carries none anyway.
        return CGImageCreateCopyWithContentHeadroom(HDRRenderer.headroom(image.cropped(to: rect), context: self), cg) ?? cg
    }
}
