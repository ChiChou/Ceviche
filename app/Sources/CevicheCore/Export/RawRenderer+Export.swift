import Foundation
import CoreImage
import ImageIO

extension RawRenderer {
    /// `filters` is the Filters dialog's stack, applied on the way out; nothing of it is kept on the photo. `denoise`
    /// hears how far AI denoise has got, the slow part of an export that has it.
    public func export(to url: URL, adjustments: Adjustments, settings: ExportSettings, overwriteExisting: Bool = true, filters: CreativeFilterStack? = nil,
                       denoise: DenoiseRun? = nil) throws {
        guard url.resolvingSymlinksInPath().standardizedFileURL != sourceURL.resolvingSymlinksInPath().standardizedFileURL else {
            throw EditorError.invalidDocument(L10n.tr("Choose a different export destination; the original image cannot be overwritten."))
        }
        try Task.checkCancellation()
        try settings.validate()
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        // A Save panel grants the selected file, not arbitrary siblings. Foundation's replacement directory
        // supplies writable staging on the destination volume while keeping installation atomic.
        let staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let temporary = staging.appendingPathComponent("Export.\(settings.format.fileExtension)")
        guard !settings.hdr || adjustments.hdr.enabled else { throw EditorError.invalidDocument(L10n.tr("Enable HDR editing before exporting HDR.")) }
        let space = try settings.colorSpace()
        // The file is developed from the decoder itself, at full precision, in a context of its own.
        decodeUse = .off
        defer { decodeUse = .normal }
        let image = try exportImage(adjustments, settings: settings, filters: filters, denoise: denoise)
        let context = Self.makeContext(device, cacheIntermediates: false)
        // Float pixels keep the headroom `HDRRenderer.output` measured; the gain-map encoder needs it to size the map.
        let format: CIFormat = settings.floatingPoint ? .RGBAf : settings.halfFloat ? .RGBAh : settings.depth == 8 ? .RGBA8 : .RGBA16
        guard let cg = context.cgImage(image, from: image.extent, format: format, colorSpace: space, hdr: settings.hdr, calculateHDRStats: nil) else { throw EditorError.render }
        try Task.checkCancellation()
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: 1, kCGImageDestinationLossyCompressionQuality: settings.quality]
        if settings.hdr {
            switch settings.hdrEncoding {
            case .pq, .hlg: properties[kCGImageDestinationEncodeRequest] = kCGImageDestinationEncodeToISOHDR
            case .gainMap, .appleGainMap: properties[kCGImageDestinationEncodeRequest] = kCGImageDestinationEncodeToISOGainmap
            case .linear: break
            }
        }
        var tiff: [String: Any] = [:]
        if settings.includeMetadata, let src = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
           let original = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] {
            // Preserve capture information, never stale dimensions, thumbnails, or RAW processing metadata.
            if settings.includeLocation { properties[kCGImagePropertyGPSDictionary] = original[kCGImagePropertyGPSDictionary as String] }
            if let exif = original[kCGImagePropertyExifDictionary as String] as? [String: Any] {
                let keys: [CFString] = [kCGImagePropertyExifExposureTime, kCGImagePropertyExifFNumber, kCGImagePropertyExifISOSpeedRatings, kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifDateTimeDigitized, kCGImagePropertyExifFocalLength, kCGImagePropertyExifLensModel, kCGImagePropertyExifLensMake]
                var clean: [String: Any] = [:]
                for key in keys { clean[key as String] = exif[key as String] }
                clean[kCGImagePropertyExifPixelXDimension as String] = cg.width
                clean[kCGImagePropertyExifPixelYDimension as String] = cg.height
                properties[kCGImagePropertyExifDictionary] = clean
            }
            if let values = original[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
                for key in [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFDateTime] { tiff[key as String] = values[key as String] }
            }
        }
        // The catalog's location wins over the file's: one placed on the map is written, one removed is left out.
        if settings.includeMetadata && settings.includeLocation, let location = settings.location { properties[kCGImagePropertyGPSDictionary] = location.gps }
        if settings.format == .tiff { tiff[kCGImagePropertyTIFFCompression as String] = 5 }
        properties[kCGImagePropertyTIFFDictionary] = tiff
        if settings.hdr && settings.hdrEncoding == .appleGainMap {
            properties[kCGImagePropertyMakerAppleDictionary] = Self.appleHeadroomTags(cg.contentHeadroom)
        }
        if settings.format == .webp || settings.format == .jxl {
            try ModernImageEncoder.encode(cg, settings: settings, properties: properties).write(to: temporary)
        } else {
            guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, settings.format.typeIdentifier as CFString, 1, nil) else {
                throw EditorError.invalidDocument(L10n.tr("The installed system cannot encode \(settings.format.rawValue)."))
            }
            CGImageDestinationAddImage(destination, cg, properties as CFDictionary)
            if settings.hdr && settings.hdrEncoding == .appleGainMap {
                CGImageDestinationAddAuxiliaryDataInfo(destination, kCGImageAuxiliaryDataTypeHDRGainMap, Self.appleGainMapInfo(headroom: cg.contentHeadroom))
            }
            guard CGImageDestinationFinalize(destination) else { throw EditorError.render }
        }
        guard let encoded = CGImageSourceCreateWithURL(temporary as CFURL, nil),
              let result = CGImageSourceCopyPropertiesAtIndex(encoded, 0, nil) as? [String: Any] else { throw EditorError.render }
        guard (result[kCGImagePropertyDepth as String] as? Int) == settings.depth else {
            throw EditorError.invalidDocument(L10n.tr("The encoder did not preserve the requested \(settings.depth)-bit depth. Choose 16-bit TIFF or PNG for a lossless master."))
        }
        if settings.hdr {
            guard let decoded = CGImageSourceCreateImageAtIndex(encoded, 0, [kCGImageSourceShouldAllowFloat: true] as CFDictionary),
                  let colorSpace = decoded.colorSpace else { throw EditorError.invalidDocument(L10n.tr("The encoder did not preserve the requested HDR encoding.")) }
            let preserved: Bool
            switch settings.hdrEncoding {
            case .linear: preserved = decoded.bitmapInfo.contains(.floatComponents) && CGColorSpaceUsesExtendedRange(colorSpace)
            case .pq: preserved = CGColorSpaceIsPQBased(colorSpace)
            case .hlg: preserved = CGColorSpaceIsHLGBased(colorSpace)
            case .gainMap: preserved = CGImageSourceCopyAuxiliaryDataInfoAtIndex(encoded, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil
            case .appleGainMap: preserved = CGImageSourceCopyAuxiliaryDataInfoAtIndex(encoded, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil
                && CGImageSourceCopyAuxiliaryDataInfoAtIndex(encoded, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil
            }
            guard preserved else { throw EditorError.invalidDocument(L10n.tr("The encoder did not preserve the requested HDR encoding.")) }
        }
        try Task.checkCancellation()
        guard (result[kCGImagePropertyPixelWidth as String] as? Int) == cg.width, (result[kCGImagePropertyPixelHeight as String] as? Int) == cg.height else { throw EditorError.render }
        try Self.installExport(temporary, at: url, overwriteExisting: overwriteExisting)
    }
    private static func installExport(_ temporary: URL, at url: URL, overwriteExisting: Bool) throws {
        if overwriteExisting && FileManager.default.fileExists(atPath: url.path) { _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary) }
        else { try FileManager.default.moveItem(at: temporary, to: url) }
    }
    /// Apple's gain map beside the ISO one. Requested together with the ISO gain map, ImageIO derives the map's pixels from
    /// the ISO map, so only the description and the metadata are ours; the headroom must match the image's own.
    static func appleGainMapInfo(headroom: Float) -> CFDictionary {
        let metadata = CGImageMetadataCreateMutable()
        CGImageMetadataRegisterNamespaceForPrefix(metadata, "http://ns.apple.com/HDRGainMap/1.0/" as CFString, "HDRGainMap" as CFString, nil)
        // Version 2.0, as current iPhones write it: readers take the headroom from here rather than the maker note.
        CGImageMetadataSetValueWithPath(metadata, nil, "HDRGainMap:HDRGainMapVersion" as CFString, 131072 as CFNumber)
        CGImageMetadataSetValueWithPath(metadata, nil, "HDRGainMap:HDRGainMapHeadroom" as CFString, max(1, headroom) as CFNumber)
        return [kCGImageAuxiliaryDataInfoData: Data(count: 4),
                kCGImageAuxiliaryDataInfoDataDescription: ["Width": 2, "Height": 2, "BytesPerRow": 2, "PixelFormat": kCVPixelFormatType_OneComponent8],
                kCGImageAuxiliaryDataInfoMetadata: metadata] as CFDictionary
    }
    /// The maker-note pair older readers turn into the headroom: stops = 3 − 70·[48] when [48] ≤ 0.01, else 2.303 − 0.303·[48],
    /// with [33] ≥ 1. Covers up to 3 stops (8×), the most those readers accept.
    static func appleHeadroomTags(_ headroom: Float) -> [String: Any] {
        let stops = min(3, max(0, Double(log2(max(1, headroom)))))
        return ["33": 1.01, "48": stops >= 2.3 ? (3 - stops) / 70 : (2.303 - stops) / 0.303]
    }
    /// The finished image as export encodes it: the edit graph at source resolution, the service frame, the export size,
    /// the HDR rendition, AI denoise, so the network sees exactly the pixels that are written, and finally the watermark,
    /// which the network never smooths. `maxDimension`
    /// renders a smaller copy of the same graph for the dialog's preview.
    ///
    /// A filter stack comes in twice: its scene filters on the whole developed photo, at the file's size when that is
    /// smaller, before the frame cuts it; its print filters on the picture at its output size. The develop settings its
    /// filters replace are set aside first.
    func exportImage(_ adjustments: Adjustments, settings: ExportSettings, maxDimension: Double? = nil, filters: CreativeFilterStack? = nil,
                     denoise: DenoiseRun? = nil) throws -> CIImage {
        let filters = filters.flatMap { $0.isEmpty ? nil : $0 }
        let adjustments = filters?.developing(adjustments) ?? adjustments
        var image = try pipeline(adjustments, maxDimension: maxDimension)
        try Task.checkCancellation()
        // Fixed-size services get the centered region in their aspect ratio before scaling.
        let crop = settings.sizing.cropRect(for: image.extent.size)
        // A preview keeps the export's proportions and frame, scaled down from the export size rather than the preview's.
        let size = try settings.dimensions(for: maxDimension == nil ? crop.size : try outputSize(adjustments, settings: settings)).size
        let limit: Double = maxDimension.map { min(1, $0 / max(size.width, size.height)) } ?? 1
        let width = max(1, (size.width * limit).rounded()), height = max(1, (size.height * limit).rounded())
        let scaleX = width / crop.width, scaleY = height / crop.height
        if let filters, filters.active.contains(where: { $0.kind.slot == .scene }), scaleX < 1 || scaleY < 1 {
            // The lens filters are sized from the long side, so on a smaller file they run at the file's size, a
            // fraction of the work: the whole frame shrinks with the crop's corner on the origin, the filters see the
            // whole frame (where a placed filter sits, the polarizer's view), and then the frame's region is cut.
            let extent = image.extent
            let shrink = CGAffineTransform(translationX: -extent.minX - crop.minX, y: -extent.minY - crop.minY).concatenating(CGAffineTransform(scaleX: scaleX, y: scaleY))
            let frame = CGRect(x: -crop.minX * scaleX, y: -crop.minY * scaleY, width: extent.width * scaleX, height: extent.height * scaleY)
            image = image.clampedToExtent().transformed(by: shrink, highQualityDownsample: true).cropped(to: frame)
            image = try FilterRenderer.scene(image, stack: filters, photo: FilterRenderer.Photo(focalLength35mm: info.focalLength35mm ?? 28), context: context, denoise: denoise)
                .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        } else {
            if let filters {
                image = try FilterRenderer.scene(image, stack: filters, photo: FilterRenderer.Photo(focalLength35mm: info.focalLength35mm ?? 28), context: context, denoise: denoise)
            }
            if crop.size != image.extent.size {
                image = image.cropped(to: crop.offsetBy(dx: image.extent.origin.x, dy: image.extent.origin.y)).transformed(by: CGAffineTransform(translationX: -crop.origin.x - image.extent.origin.x, y: -crop.origin.y - image.extent.origin.y))
            }
            // Presets cap the long edge even with the Original size, so compare sizes rather than the preset.
            if Int(width) != Int(image.extent.width.rounded()) || Int(height) != Int(image.extent.height.rounded()) {
                // Resample only after all edits, masks and geometry have been applied at source resolution.
                image = Self.resized(image, scaleX: width / image.extent.width, scaleY: height / image.extent.height)
                    .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        // Output Sharpening only at the output's own size: a preview is another size.
        if let filters { image = try FilterRenderer.print(image, stack: filters, sharpens: maxDimension == nil, context: context) }
        if !settings.preserveAlpha || !settings.format.supportsAlpha {
            image = image.composited(over: CIImage(color: .white).cropped(to: image.extent))
        }
        if adjustments.hdr.enabled { image = HDRRenderer.output(image, settings: adjustments.hdr, context: context, sdr: !settings.hdr) }
        image = try NAFNetDenoiseKernel.denoised(image, amount: settings.aiDenoise, run: denoise)
        return try settings.watermark?.composited(over: image) ?? image
    }
    /// The edited image's size before the export frame and size apply.
    private func outputSize(_ adjustments: Adjustments, settings: ExportSettings) throws -> CGSize {
        let a = adjustments.effective(defaults: info.defaults)
        let full = try GeometryPlan(size: CGSize(width: info.width, height: info.height), settings: a.geometry, quarterTurns: a.quarterTurns).outputSize
        return settings.sizing.cropRect(for: full).size
    }
    /// The export at no more than `maxDimension` pixels on the long edge, for the export dialog. `denoise` keeps the
    /// network's tiles from one preview to the next of the same picture.
    public func exportPreview(_ adjustments: Adjustments, settings: ExportSettings, maxDimension: Double = 2200, filters: CreativeFilterStack? = nil,
                              denoise: DenoiseRun? = nil) throws -> CGImage {
        liveDecode = false
        let image = try exportImage(adjustments, settings: settings, maxDimension: maxDimension, filters: filters, denoise: denoise)
        let context = renderContext()
        try Task.checkCancellation()
        let hdr = adjustments.hdr.enabled && settings.hdr
        guard let cg = context.cgImage(image, from: image.extent, format: hdr ? .RGBAh : .RGBA16, colorSpace: hdr ? HDRRenderer.space : try settings.resolvedProfile.colorSpace(),
                                       hdr: hdr) else { throw EditorError.render }
        return cg
    }
    /// Export-resolution pixels for a region of the export (normalized, top-left origin), so the dialog can show the
    /// file's real pixels, denoise included, when zoomed in. Core Image renders only that region and its margins.
    public func prepareExportDetail(_ adjustments: Adjustments, settings: ExportSettings, region: CGRect, maxPixels: Int = 16_000_000,
                                    filters: CreativeFilterStack? = nil) throws -> DetailRender? {
        let image = try exportImage(adjustments, settings: settings, filters: filters)
        let context = Self.makeContext(device, cacheIntermediates: false)
        let full = image.extent
        let bounds = region.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !bounds.isEmpty, full.width > 0, full.height > 0 else { return nil }
        let x = floor(bounds.minX * full.width), top = floor(bounds.minY * full.height)
        let width = min(full.width - x, ceil(bounds.maxX * full.width) - x), height = min(full.height - top, ceil(bounds.maxY * full.height) - top)
        guard width >= 1, height >= 1, Int(width * height) <= maxPixels else { return nil }
        let rect = CGRect(x: full.minX + x, y: full.maxY - top - height, width: width, height: height)
        let hdr = adjustments.hdr.enabled && settings.hdr
        try Task.checkCancellation()
        return DetailRender(context: context, image: image, rect: rect, format: hdr ? .RGBAh : .RGBA16,
                            colorSpace: hdr ? HDRRenderer.space : try settings.resolvedProfile.colorSpace(), hdr: hdr,
                            region: CGRect(x: x / full.width, y: top / full.height, width: width / full.width, height: height / full.height))
    }
}
