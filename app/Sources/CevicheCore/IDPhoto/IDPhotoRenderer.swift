import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Develops a photo with its edits, but without its crop, so the ID frame can reach past it, and renders the print and
/// sheets from it at the spec's resolution. Output is sRGB, the space print labs and upload forms expect.
public final class IDPhotoRenderer: Sendable {
    public let sourceURL: URL
    private let renderer: RawRenderer
    /// The photo's development as the tool renders it: without its crop or the tool's layout.
    public let adjustments: Adjustments
    /// The developed photo's size in pixels at full resolution.
    public let size: CGSize
    public static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    public init(url: URL, adjustments: Adjustments?) async throws {
        sourceURL = url
        let renderer = try RawRenderer(sourceURL: url)
        var edit = adjustments ?? renderer.info.defaults
        edit.geometry.crop = .full
        edit.geometry.aspect = .free
        self.renderer = renderer; self.adjustments = edit
        size = try await renderer.idPhotoSize(edit)
    }
    private init(_ other: IDPhotoRenderer, adjustments: Adjustments, size: CGSize? = nil) {
        sourceURL = other.sourceURL; renderer = other.renderer; self.size = size ?? other.size
        var edit = adjustments
        edit.geometry.crop = .full; edit.geometry.aspect = .free
        self.adjustments = edit
    }
    /// The same photo developed with other settings (white balance from the tool), without decoding it again.
    public func with(_ adjustments: Adjustments) -> IDPhotoRenderer { IDPhotoRenderer(self, adjustments: adjustments) }
    /// The same photo turned `turns` quarter turns clockwise, for a head that lies on its side; only the tool sees it.
    public func turned(_ turns: Int) async throws -> IDPhotoRenderer {
        var edit = adjustments
        edit.quarterTurns = (edit.quarterTurns + turns) % 4
        return IDPhotoRenderer(self, adjustments: edit, size: try await renderer.idPhotoSize(edit))
    }

    /// White balance that makes `region` (fractions of the developed photo from the top left) neutral: a spot the user
    /// picked. Nil when the photo's balance doesn't respond.
    public func neutralize(_ region: CGRect) async throws -> Adjustments? {
        try await renderer.idPhotoBalance(adjustments, region: region, target: .zero)
    }

    /// Cheeks lit by daylight on compliant photos measure about this red over blue (sRGB); tungsten casts reach 2.2.
    public static let skinRedOverBlue = 1.45...1.95, skinRedOverBlueCentre = 1.7
    /// Auto: the wall made neutral when that leaves the skin looking like skin; a wall that is itself coloured (brick,
    /// cream, sky) would cast its opposite on the face, so then the skin decides, or the photo is left as shot when its
    /// skin already looks right. Nil when the balance doesn't respond.
    public func autoBalance(wall: CGRect?, skin: CGRect) async throws -> Adjustments? {
        let range = Self.skinRedOverBlue
        guard let asShot = try await renderer.idPhotoCast(adjustments, region: skin) else { return nil }
        func redOverBlue(_ cast: SIMD2<Double>) -> Double { exp(cast.x) }
        var greenMagenta = asShot.y
        if let wall, let byWall = try await renderer.idPhotoBalance(adjustments, region: wall, target: .zero),
           let skinByWall = try await renderer.idPhotoCast(byWall, region: skin) {
            if range.contains(redOverBlue(skinByWall)) { return byWall }
            greenMagenta = (skinByWall.y + asShot.y) / 2
        }
        if range.contains(redOverBlue(asShot)) { return adjustments }
        return try await renderer.idPhotoBalance(adjustments, region: skin, target: SIMD2(log(Self.skinRedOverBlueCentre), greenMagenta))
    }

    /// The developed photo at no more than `maxDimension` pixels on its long side, for the dialog and the checks.
    public func preview(maxDimension: Double = 2400) async throws -> CGImage {
        try await renderer.idPhotoPreview(adjustments, maxDimension: maxDimension)
    }
    /// The print at `pixelsPerMM` (the spec's resolution unless given).
    /// `matte` (from `IDPhotoMatte.make`, any size) is needed when the layout replaces the background.
    public func renderPrint(_ layout: IDPhotoLayout, matte: CGImage? = nil, pixelsPerMM: Double? = nil) async throws -> CGImage {
        try await renderer.idPhotoPrint(adjustments, layout: layout, matte: matte, pixelsPerMM: pixelsPerMM)
    }
    /// `region` of the developed photo (fractions from the top left) at `size` pixels, from the full-resolution
    /// photo, for the canvas when zoomed past the preview's resolution. With `background`, the person is put on it
    /// through `matte`, as in the print.
    public func detail(_ region: CGRect, size: CGSize, background: IDPhotoBackground?, matte: CGImage?) async throws -> CGImage {
        try await renderer.idPhotoDetail(adjustments, region: region, size: size, background: background, matte: matte)
    }

    /// The print sized for an upload form: within its pixel limits, otherwise at print resolution.
    public func renderDigital(_ layout: IDPhotoLayout, matte: CGImage? = nil) async throws -> CGImage {
        try await renderPrint(layout, matte: matte, pixelsPerMM: Self.digitalWidth(layout.spec) / layout.spec.widthMM)
    }
    static func digitalWidth(_ spec: IDPhotoSpec) -> Double {
        var width = Double(spec.pixelSize.width)
        guard let digital = spec.digital else { return width }
        if let max = digital.maxPx, max.count == 2 { width = min(width, Double(max[0]), Double(max[1]) * spec.widthMM / spec.heightMM) }
        if let min = digital.minPx, min.count == 2 { width = Swift.max(width, Double(min[0]), Double(min[1]) * spec.widthMM / spec.heightMM) }
        return width.rounded()
    }

    /// The whole sheet at the spec's resolution: white paper, the copies, and grey cut guides in the gaps and margins.
    public func renderSheet(_ layout: IDPhotoLayout, matte: CGImage? = nil) async throws -> CGImage {
        let photo = try await renderPrint(layout, matte: matte)
        return try Self.sheet(photo, layout: layout)
    }
    /// `photo` (the print, any resolution) laid out on the paper at `pixelsPerMM`, the spec's resolution unless given.
    public static func sheet(_ photo: CGImage, layout: IDPhotoLayout, pixelsPerMM: Double? = nil) throws -> CGImage {
        guard let arrangement = layout.sheet.arrangement(for: layout.spec) else { return photo }
        return try sheet(Array(repeating: photo, count: arrangement.origins.count), layout: layout, pixelsPerMM: pixelsPerMM)
    }
    /// Several photos' prints, all of the layout's spec, over as many sheets as `copies` (one count per print) needs.
    public static func sheets(_ prints: [CGImage], copies: [Int], layout: IDPhotoLayout, pixelsPerMM: Double? = nil) throws -> [CGImage] {
        try layout.sheet.pages(copies: copies, spec: layout.spec).map { page in try sheet(page.map { prints[$0] }, layout: layout, pixelsPerMM: pixelsPerMM) }
    }
    /// `places` in the order of the sheet's places, the rest left blank.
    static func sheet(_ places: [CGImage], layout: IDPhotoLayout, pixelsPerMM: Double?) throws -> CGImage {
        var full = layout.sheet; full.copies = nil
        guard let arrangement = full.arrangement(for: layout.spec) else { throw EditorError.render }
        let ppm = pixelsPerMM ?? layout.spec.printDPI / 25.4
        let width = Int((arrangement.paper.width * ppm).rounded()), height = Int((arrangement.paper.height * ppm).rounded())
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw EditorError.render }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .none
        let w = (layout.spec.widthMM * ppm).rounded(), h = (layout.spec.heightMM * ppm).rounded()
        context.interpolationQuality = .high
        let rects = arrangement.origins.prefix(places.count).map { CGRect(x: ($0.x * ppm).rounded(), y: Double(height) - ($0.y * ppm).rounded() - h, width: w, height: h) }
        for (rect, photo) in zip(rects, places) { context.draw(photo, in: rect) }
        // Edge to edge leaves no room for guides; the photos' own edges are the cut.
        if layout.sheet.cutGuides && layout.sheet.spacing == .lab { drawCutGuides(rects, in: context, ppm: ppm) }
        guard let sheet = context.makeImage() else { throw EditorError.render }
        return sheet
    }

    /// The print drawn from an already developed `image` (the preview), `height` pixels tall, for the dialog's live
    /// view. Quick enough to redraw while a marker is dragged.
    public static func quickPrint(from image: CGImage, matte: CGImage?, layout: IDPhotoLayout, height: Int) -> CGImage? {
        let print = placePrint(CIImage(cgImage: image), matte: matte, layout: layout, pixelsPerMM: Double(height) / layout.spec.heightMM)
        return quickContext.createCGImage(print, from: print.extent, format: .RGBA8, colorSpace: space)
    }
    private static let quickContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .cacheIntermediates: false])

    /// The developed photo `source` (origin at zero) placed on the print at `pixelsPerMM`, white past its edges, on
    /// the layout's background colour when it has one.
    static func placePrint(_ source: CIImage, matte: CGImage?, layout: IDPhotoLayout, pixelsPerMM ppm: Double) -> CIImage {
        let spec = layout.spec
        let width = (spec.widthMM * ppm).rounded(), height = (spec.heightMM * ppm).rounded()
        let frame = layout.frame(in: source.extent.size)
        let toPrint = frame.printToPhoto(pixelsPerMM: width / spec.widthMM, printHeight: height).inverted()
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        // Downsampling by a large factor needs the high-quality path, or fine hair and edges alias.
        let placed = source.clampedToExtent().transformed(by: toPrint, highQualityDownsample: true).cropped(to: bounds)
        // Past the photo's edges there is nothing: the background colour, or white.
        let inside = CIImage(color: .white).cropped(to: source.extent).transformed(by: toPrint).composited(over: CIImage(color: .black)).cropped(to: bounds)
        let fill = layout.background?.ciColor ?? CIColor(red: 1, green: 1, blue: 1)
        var image = placed
        if let background = layout.background, let matte {
            let person = CIImage(cgImage: matte)
            let scaled = person.transformed(by: CGAffineTransform(scaleX: source.extent.width / person.extent.width, y: source.extent.height / person.extent.height))
            let alpha = scaled.clampedToExtent().transformed(by: toPrint, highQualityDownsample: true).cropped(to: bounds)
            image = IDPhotoMatte.composite(placed, matte: alpha, color: background.ciColor, radius: max(2, height * 0.012))
        }
        return image.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage(color: fill), kCIInputMaskImageKey: inside]).cropped(to: bounds)
    }

    /// The developed preview with the layout's background in place, for the canvas.
    public static func replacingBackground(_ image: CGImage, matte: CGImage, background: IDPhotoBackground) -> CGImage? {
        let source = CIImage(cgImage: image), person = CIImage(cgImage: matte)
        let alpha = person.transformed(by: CGAffineTransform(scaleX: source.extent.width / person.extent.width, y: source.extent.height / person.extent.height))
        let result = IDPhotoMatte.composite(source, matte: alpha, color: background.ciColor, radius: max(4, source.extent.height * 0.01))
        return quickContext.createCGImage(result, from: source.extent, format: .RGBA8, colorSpace: space)
    }

    /// Short hairlines out from each print's corners, stopping clear of the photos, as a print lab's.
    static func drawCutGuides(_ rects: [CGRect], in context: CGContext, ppm: Double) {
        let length = 2.0 * ppm, clearance = 0.5 * ppm
        context.setStrokeColor(CGColor(gray: 0.55, alpha: 1)); context.setLineWidth(max(1, 0.1 * ppm))
        for rect in rects {
            for corner in [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)] {
                let horizontal = corner.x == rect.minX ? -1.0 : 1.0, vertical = corner.y == rect.minY ? -1.0 : 1.0
                for (dx, dy) in [(horizontal, 0.0), (0.0, vertical)] {
                    let start = CGPoint(x: corner.x + dx * clearance, y: corner.y + dy * clearance)
                    let end = CGPoint(x: corner.x + dx * (clearance + length), y: corner.y + dy * (clearance + length))
                    let middle = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
                    // A guide that would cross a neighbouring print is left out.
                    guard !rects.contains(where: { $0.insetBy(dx: -clearance / 2, dy: -clearance / 2).contains(middle) }) else { continue }
                    context.move(to: start); context.addLine(to: end)
                }
            }
        }
        context.strokePath()
    }

    /// Writes `image` with its resolution, so a print dialog or lab prints it at its physical size. A JPEG with
    /// `maxKB` is compressed until it fits.
    public static func write(_ image: CGImage, to url: URL, type: UTType, dpi: Double, maxKB: Int? = nil) throws {
        var quality = 0.95
        while true {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { throw EditorError.render }
            let properties: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi,
                                               kCGImageDestinationLossyCompressionQuality: quality,
                                               kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFXDensity: Int(dpi.rounded()), kCGImagePropertyJFIFYDensity: Int(dpi.rounded()), kCGImagePropertyJFIFDensityUnit: 1]]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw EditorError.render }
            if let maxKB, type == .jpeg, data.length > maxKB * 1024, quality > 0.35 { quality -= 0.07; continue }
            try (data as Data).write(to: url, options: .atomic)
            return
        }
    }

}

extension RawRenderer {
    private static var idPhotoSettings: ExportSettings {
        var settings = ExportSettings()
        settings.format = .jpeg; settings.depth = 8; settings.hdr = false; settings.preserveAlpha = false
        return settings
    }
    private func idPhotoDeveloped(_ adjustments: Adjustments, maxDimension: Double? = nil) throws -> CIImage {
        let image = try exportImage(adjustments, settings: Self.idPhotoSettings, maxDimension: maxDimension)
        return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }
    func idPhotoSize(_ adjustments: Adjustments) throws -> CGSize { try idPhotoDeveloped(adjustments).extent.size }

    func idPhotoPreview(_ adjustments: Adjustments, maxDimension: Double) throws -> CGImage {
        let image = try idPhotoDeveloped(adjustments, maxDimension: maxDimension)
        guard let cg = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: IDPhotoRenderer.space) else { throw EditorError.render }
        return cg
    }

    /// How far `region` (fractions from the top left) is from neutral in a small render: log red over blue (warm/cool)
    /// and log green over the mean of the two (green/magenta), in sRGB.
    func idPhotoCast(_ adjustments: Adjustments, region: CGRect) throws -> SIMD2<Double>? {
        let image = try idPhotoDeveloped(adjustments, maxDimension: 600)
        let e = image.extent
        let rect = CGRect(x: region.minX * e.width, y: (1 - region.maxY) * e.height, width: region.width * e.width, height: region.height * e.height)
            .integral.intersection(e)
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        var pixel = [Float](repeating: 0, count: 4)
        let mean = image.cropped(to: rect).applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: rect)])
        pixel.withUnsafeMutableBytes { context.render(mean, toBitmap: $0.baseAddress!, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: IDPhotoRenderer.space) }
        let r = max(1e-3, Double(pixel[0])), g = max(1e-3, Double(pixel[1])), b = max(1e-3, Double(pixel[2]))
        return SIMD2(log(r / b), log(g / (r * b).squareRoot()))
    }

    /// Solves white balance from small renders rather than the decoder, so it works for every kind of photo and
    /// whatever its geometry: how far `region` is from `target` (as `idPhotoCast` measures; zero is neutral) is
    /// measured, the two controls' effect on that is measured once, and a few Newton steps follow. Temperature (a
    /// RAW's decoder setting, a bitmap's neutral) moves in mireds, which respond evenly across the range; Warmth only
    /// works inside masks, so it isn't used.
    func idPhotoBalance(_ adjustments: Adjustments, region: CGRect, target: SIMD2<Double>) throws -> Adjustments? {
        func get(_ a: Adjustments) -> SIMD2<Double> { SIMD2(1e6 / max(1, a.temperature), a.tint) }
        func set(_ a: inout Adjustments, _ value: SIMD2<Double>) {
            a.temperature = (1e6 / min(500, max(20, value.x))).rounded()
            a.tint = min(150, max(-150, value.y)).rounded()
        }
        func cast(_ a: Adjustments) throws -> SIMD2<Double>? { try idPhotoCast(a, region: region).map { $0 - target } }
        var current = adjustments
        guard var error = try cast(current) else { return nil }
        let start = get(current), step = SIMD2<Double>(15, 10)
        var nudged = current; set(&nudged, start + SIMD2(step.x, 0)); guard let ex = try cast(nudged) else { return nil }
        nudged = current; set(&nudged, start + SIMD2(0, step.y)); guard let ey = try cast(nudged) else { return nil }
        let a = (ex - error) / step.x, b = (ey - error) / step.y   // columns of the Jacobian
        let determinant = a.x * b.y - b.x * a.y
        guard abs(determinant) > 1e-9 else { return nil }
        for _ in 0..<4 {
            guard abs(error.x) > 0.004 || abs(error.y) > 0.004 else { break }
            let delta = SIMD2((-error.x * b.y + b.x * error.y) / determinant, (-a.x * error.y + a.y * error.x) / determinant)
            set(&current, get(current) + delta)
            guard let next = try cast(current) else { break }
            error = next
        }
        return current
    }

    func idPhotoDetail(_ adjustments: Adjustments, region: CGRect, size: CGSize, background: IDPhotoBackground?, matte: CGImage?) throws -> CGImage {
        let source = try idPhotoDeveloped(adjustments)
        let full = source.extent
        let rect = CGRect(x: region.minX * full.width, y: (1 - region.maxY) * full.height, width: region.width * full.width, height: region.height * full.height)
        guard rect.width >= 1, rect.height >= 1, size.width >= 1, size.height >= 1 else { throw EditorError.render }
        let toOutput = CGAffineTransform(translationX: -rect.minX, y: -rect.minY).concatenating(CGAffineTransform(scaleX: size.width / rect.width, y: size.height / rect.height))
        let bounds = CGRect(origin: .zero, size: size)
        var image = source.clampedToExtent().transformed(by: toOutput, highQualityDownsample: true).cropped(to: bounds)
        if let background, let matte {
            let person = CIImage(cgImage: matte)
            let alpha = person.transformed(by: CGAffineTransform(scaleX: full.width / person.extent.width, y: full.height / person.extent.height))
                .clampedToExtent().transformed(by: toOutput).cropped(to: bounds)
            image = IDPhotoMatte.composite(image, matte: alpha, color: background.ciColor, radius: max(2, size.height * 0.01))
        }
        try Task.checkCancellation()
        guard let cg = context.createCGImage(image, from: bounds, format: .RGBA8, colorSpace: IDPhotoRenderer.space) else { throw EditorError.render }
        return cg
    }

    func idPhotoPrint(_ adjustments: Adjustments, layout: IDPhotoLayout, matte: CGImage?, pixelsPerMM: Double?) throws -> CGImage {
        let source = try idPhotoDeveloped(adjustments)
        let image = IDPhotoRenderer.placePrint(source, matte: matte, layout: layout, pixelsPerMM: pixelsPerMM ?? layout.spec.printDPI / 25.4)
        try Task.checkCancellation()
        guard let cg = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: IDPhotoRenderer.space) else { throw EditorError.render }
        return cg
    }
}
