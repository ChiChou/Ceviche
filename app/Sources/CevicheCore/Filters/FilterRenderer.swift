import CoreImage
import Foundation
import simd

/// Applies a filter stack as Core Image graphs. Scene filters take the developed photo in linear light; print filters
/// take the picture at its output size. Every size is a fraction of the long side, so the preview and the file agree.
enum FilterRenderer {
    /// What a filter needs to know about the photo beyond its pixels.
    struct Photo {
        /// The 35 mm equivalent focal length, for the directions the pixels look in; a moderate wide angle when unknown.
        var focalLength35mm: Double = 28
    }

    /// The scene filters, in the stack's order.
    static func scene(_ image: CIImage, stack: CreativeFilterStack, photo: Photo, context: CIContext, denoise: DenoiseRun? = nil) throws -> CIImage {
        var image = image
        for filter in stack.active where filter.kind.slot == .scene {
            try Task.checkCancellation()
            switch filter.kind {
            case .glow:
                var glow = Glow()
                glow.style = filter.glowStyle; glow.amount = filter.amount; glow.size = filter["size"]; glow.threshold = filter["threshold"]; glow.angle = filter["angle"]
                image = GlowRenderer.apply(glow, to: image)
            case .diffusion:
                if let shape = DiffusionShape.of(filter) { image = diffusion(image, shape: shape, amount: filter.amount / 50) }
                else { image = diffusion(image, amount: filter.amount / 100, size: filter["size"] / 100) }
            case .bloom: image = bloom(image, amount: filter.amount / 100, size: filter["size"] / 100)
            case .polarizer: image = try polarizer(image, filter: filter, photo: photo, context: context)
            case .denoise: image = try rendered(NAFNetDenoiseKernel.denoised(image, amount: filter.amount, run: denoise), context: context)
            case .bokeh: image = bokeh(image, filter: filter)
            case .proContrast, .tonalContrast, .detailExtractor, .bleachBypass, .crossProcess, .center, .fog, .reflector, .lightLeak, .border, .outputSharpen, .dust: break
            }
        }
        return image
    }
    /// `image` drawn once into memory, in half floats. The network is too slow to leave in the graph: Core Image
    /// renders the file in tiles, each asks the filters after it for a margin as wide as their blurs, and every one of
    /// those regions ran the network again (a 2560-pixel export with Diffusion and Glow after it took over ten minutes).
    static func rendered(_ image: CIImage, context: CIContext) throws -> CIImage {
        let extent = image.extent, bounds = extent.integral
        let width = Int(bounds.width), height = Int(bounds.height), rowBytes = width * 8
        guard width > 0, height > 0, let space = context.workingColorSpace else { return image }
        var pixels = Data(count: rowBytes * height)
        pixels.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: rowBytes, bounds: bounds, format: .RGBAh, colorSpace: space) }
        try Task.checkCancellation()
        return CIImage(bitmapData: pixels, bytesPerRow: rowBytes, size: bounds.size, format: .RGBAh, colorSpace: space)
            .transformed(by: CGAffineTransform(translationX: bounds.minX, y: bounds.minY)).cropped(to: extent)
    }

    /// The print filters, in the stack's order. `sharpens` false leaves Output Sharpening out, for a preview that is
    /// not at the output's own size: its radius is 0.7 of an output pixel and means nothing at another scale.
    static func print(_ image: CIImage, stack: CreativeFilterStack, sharpens: Bool = true, context: CIContext) throws -> CIImage {
        var image = image
        for filter in stack.active where filter.kind.slot == .print {
            try Task.checkCancellation()
            switch filter.kind {
            case .proContrast: image = try proContrast(image, filter: filter, context: context)
            case .tonalContrast: image = tonalContrast(image, filter: filter)
            case .detailExtractor: image = detailExtractor(image, filter: filter)
            case .center: image = center(image, filter: filter)
            case .bleachBypass: image = bleachBypass(image, filter: filter)
            case .crossProcess: image = crossProcess(image, filter: filter)
            case .fog: image = fog(image, filter: filter)
            case .reflector: image = reflector(image, filter: filter)
            case .lightLeak: image = lightLeak(image, filter: filter)
            case .dust: image = dust(image, filter: filter)
            case .outputSharpen: if sharpens { image = outputSharpen(image, amount: filter.amount / 100, medium: Int(filter["medium"].rounded())) }
            default: break
            }
        }
        // The border goes round the finished picture, wherever its row is.
        guard let border = stack.active.last(where: { $0.kind == .border }) else { return image }
        switch border.borderChoice {
        case .drawn(let style): return BorderRenderer.apply(image, style: style, width: border.amount / 100, black: border["tone"] >= 0.5)
        case .asset(let asset): return BorderRenderer.apply(image, asset: asset)
        }
    }

    // MARK: Light

    /// A share `k` of the picture's light, to be added to other shares. Its coverage is scaled, which scales the
    /// light with it and leaves the shares summing to an opaque picture: scaling the colours alone left a sum of
    /// layers more than opaque, and the export's white backing then took light away.
    private static func scaled(_ image: CIImage, _ k: Double) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: k)])
    }
    /// `x` with the share `amount` of its light spread by `spread`: light is moved, never added, and there is no
    /// threshold, which is what a filter on the lens does.
    private static func mixed(_ image: CIImage, _ spread: CIImage, amount: Double) -> CIImage {
        spread.cropped(to: image.extent).applyingFilter("CIMix", parameters: [kCIInputBackgroundImageKey: image, kCIInputAmountKey: min(1, max(0, amount))])
    }

    /// A soft-focus filter: a tight core that takes the edge off detail and a wider tail that veils it, from fits to
    /// real filter pairs (core 0.1–0.2 % of the long side, tail 0.8–1.6 %).
    static func diffusion(_ image: CIImage, amount: Double, size: Double) -> CIImage {
        let long = max(image.extent.width, image.extent.height)
        guard amount > 0, long > 8 else { return image }
        let core = long * (0.001 + 0.001 * size), tail = long * (0.008 + 0.008 * size)
        let source = image.clampedToExtent()
        let spread = scaled(source.applyingGaussianBlur(sigma: max(0.3, core)), 0.4)
            .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: scaled(source.applyingGaussianBlur(sigma: max(0.6, tail)), 0.6)])
        return mixed(image, spread, amount: amount)
    }

    /// A measured filter: `(1 − k)·x + k_core·(x ⊛ G_core) + k_tail·(x ⊛ G_tail)`, with the shares scaled by `amount`
    /// (1 is the filter as measured) and kept to all of the light at most.
    static func diffusion(_ image: CIImage, shape: DiffusionShape, amount: Double) -> CIImage {
        let long = max(image.extent.width, image.extent.height)
        guard amount > 0, long > 8 else { return image }
        let scale = min(amount, 1 / (shape.core + shape.tail))
        let core = shape.core * scale, tail = shape.tail * scale
        let source = image.clampedToExtent()
        let moved = scaled(source.applyingGaussianBlur(sigma: max(0.3, long * shape.coreWidth)), core)
            .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: scaled(source.applyingGaussianBlur(sigma: max(0.6, long * shape.tailWidth)), tail)])
        return scaled(source, 1 - core - tail)
            .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: moved]).cropped(to: image.extent)
    }

    /// Veiling glare, as a lens or a mist filter scatters light: a tail falling as r^−2.25 from about 1 % to 18 % of
    /// the long side, built from five equal Gaussians an octave apart on a quarter-size copy.
    static func bloom(_ image: CIImage, amount: Double, size: Double) -> CIImage {
        let extent = image.extent, long = max(extent.width, extent.height)
        guard amount > 0, long > 8 else { return image }
        let quarter = 0.25
        let small = image.clampedToExtent().transformed(by: CGAffineTransform(scaleX: quarter, y: quarter))
        let first = long * quarter * 0.01 * (0.6 + 0.8 * size)
        var spread: CIImage?
        for octave in 0..<5 {
            let layer = scaled(small.applyingGaussianBlur(sigma: max(0.5, first * pow(2, Double(octave)))), 0.2)
            spread = spread.map { layer.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: $0]) } ?? layer
        }
        return mixed(image, spread!.transformed(by: CGAffineTransform(scaleX: 1 / quarter, y: 1 / quarter)), amount: amount)
    }

    // MARK: Polarizer

    /// The direction a point of the picture looks in: x right, y up, z forward, for a camera tilted up by `tilt`.
    static func direction(x: Double, y: Double, focal: Double, tilt: Double) -> SIMD3<Double> {
        let d = simd_normalize(SIMD3(x, y, focal))
        let c = cos(tilt), s = sin(tilt)
        return SIMD3(d.x, d.y * c + d.z * s, -d.y * s + d.z * c)
    }
    /// What a polarizer at `angle` passes of sky light from direction `d` with the sun at `sun`, relative to
    /// unpolarized light: 1 + p cos 2Δ, with p = k sin²γ / (1 + cos²γ) for the angle γ from the sun and Δ the angle
    /// between the filter's axis and the light's own (perpendicular to the plane through the sun and the pixel).
    static func transmission(_ d: SIMD3<Double>, sun: SIMD3<Double>, angle: Double, k: Double) -> Double {
        let cosine = simd_dot(d, sun), sine2 = 1 - cosine * cosine
        let p = k * sine2 / (1 + cosine * cosine)
        let cross = simd_cross(d, sun)
        guard simd_length(cross) > 1e-6 else { return 1 }
        let e = simd_normalize(cross)
        // The filter's axis as it lies in the picture, seen along this pixel's direction.
        let axis = SIMD3(cos(angle), sin(angle), 0)
        let across = axis - simd_dot(axis, d) * d
        guard simd_length(across) > 1e-6 else { return 1 }
        let c = simd_dot(simd_normalize(across), e)
        return 1 + p * (2 * c * c - 1)
    }
    static func sun(azimuth: Double, elevation: Double) -> SIMD3<Double> {
        SIMD3(sin(azimuth) * cos(elevation), sin(elevation), cos(azimuth) * cos(elevation))
    }
    /// The rotation that darkens the frame's sky most on average, as the photographer turns the filter to.
    static func bestAngle(width: Double, height: Double, focal: Double, tilt: Double, sun: SIMD3<Double>, k: Double) -> Double {
        var best = (angle: 0.0, mean: Double.infinity)
        for step in 0..<36 {
            let angle = Double(step) * .pi / 36
            var sum = 0.0
            // The upper half, where the sky is.
            for j in 0..<4 { for i in 0..<9 {
                let x = (Double(i) / 8 - 0.5) * width, y = Double(j) / 3 * height / 2
                sum += transmission(direction(x: x, y: y, focal: focal, tilt: tilt), sun: sun, angle: angle, k: k)
            } }
            if sum < best.mean { best = (angle, sum) }
        }
        return best.angle
    }

    static func polarizer(_ image: CIImage, filter: CreativeFilter, photo: Photo, context: CIContext) throws -> CIImage {
        let extent = image.extent, long = max(extent.width, extent.height)
        guard long > 8 else { return image }
        // 100 % is a clear sky's k of 0.6; haze takes less.
        let k = 0.6 * filter.amount / 100
        // The long side covers 36 mm of a 35 mm frame.
        let focal = photo.focalLength35mm / 36 * long
        let tilt = filter["tilt"] * .pi / 180
        let sun = sun(azimuth: filter["azimuth"] * .pi / 180, elevation: filter["elevation"] * .pi / 180)
        let angle = filter["rotation"] < 0.5 ? bestAngle(width: extent.width, height: extent.height, focal: focal, tilt: tilt, sun: sun, k: k) : filter["angle"] * .pi / 180
        // Only the sky is polarized this way: clouds and the ground stay as they are.
        let coarse = try SkyMaskModel.loadBundled().coarseMask(for: image, context: context)
        let sky = MaskRefinement.sky.apply(coarse, guide: image).applyingFilter("CISRGBToneCurveToLinear")
        let arguments: [Any] = [image, sky, CIVector(x: extent.midX, y: extent.midY, z: focal, w: tilt),
                                CIVector(x: sun.x, y: sun.y, z: sun.z, w: k), CIVector(x: cos(angle), y: sin(angle))]
        guard let output = polarize.apply(extent: extent, roiCallback: { _, rect in rect }, arguments: arguments) else { throw EditorError.render }
        return output
    }

    // MARK: Tonal contrast

    /// Local contrast in the highlights, midtones and shadows: L + g (F − B) on log luminance, the colour scaled by
    /// the same factor. B is an edge-preserving base at the band's radius and F a 5 × 5 one that holds the noise
    /// back. A Gaussian base, as Clarity has, halos skies by 0.2–0.4 stop at these radii; this stays near 0.1.
    static func tonalContrast(_ image: CIImage, filter: CreativeFilter) -> CIImage {
        let scale = filter.amount / 100 * 1.5 / 100
        return localContrast(image, gains: CIVector(x: filter["highs"] * scale, y: filter["mids"] * scale, z: filter["shadows"] * scale), radius: filter["radius"] / 100)
    }
    /// The log luminance's edge-preserving bases: `fine` holds the noise back, `base` is the band at `radius` (a
    /// fraction of the long side).
    private static func bases(_ image: CIImage, radius: Double) -> (fine: CIImage, base: CIImage) {
        let extent = image.extent
        let luminance = logLuminance.apply(extent: extent, arguments: [image])!
        func guided(_ radius: Double, _ epsilon: Double) -> CIImage {
            func box(_ image: CIImage) -> CIImage {
                image.clampedToExtent().applyingFilter("CIBoxBlur", parameters: [kCIInputRadiusKey: 2 * max(1, radius.rounded()) + 1]).cropped(to: extent)
            }
            // The variance from each pixel's distance to the local mean: squares of the log luminance itself (up to
            // 60 in the shadows) lose a texture's variance to half-float rounding.
            let mean = box(luminance)
            let ab = coefficients.apply(extent: extent, arguments: [box(deviation.apply(extent: extent, arguments: [luminance, mean])!), mean, epsilon])!
            return guidedOutput.apply(extent: extent, arguments: [luminance, box(ab)])!
        }
        return (guided(2, 0.01), guided(max(extent.width, extent.height) * radius, 0.16))
    }
    /// Gains for highlights, midtones and shadows (x, y, z) on the detail under `radius`, 0…1 from 0.5 % to 5 % of
    /// the long side.
    static func localContrast(_ image: CIImage, gains: CIVector, radius: Double) -> CIImage {
        let extent = image.extent, long = max(extent.width, extent.height)
        guard long > 16, gains.x != 0 || gains.y != 0 || gains.z != 0 else { return image }
        let radius = long * (0.005 + 0.045 * radius)
        let (floor, base) = bases(image, radius: radius / long)
        return tone.apply(extent: extent, arguments: [image, floor, base, gains])!
    }

    // MARK: Pro contrast

    /// What Pro Contrast reads from the picture: the luminance its darkest and lightest half percent start at, and
    /// the colour of what is nearly neutral (nil when too little is).
    struct Levels { var black: Double, white: Double, neutral: SIMD3<Double>? }
    /// Measured on a copy 256 px long, so a preview and the file read the same picture.
    static func levels(_ image: CIImage, context: CIContext) throws -> Levels {
        let extent = image.extent, long = max(extent.width, extent.height)
        let scale = min(1, 256 / long)
        let small = image.clampedToExtent().applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
        let bounds = CGRect(x: (extent.minX * scale).rounded(.up), y: (extent.minY * scale).rounded(.up), width: max(1, (extent.width * scale).rounded(.down)), height: max(1, (extent.height * scale).rounded(.down)))
        let width = Int(bounds.width), height = Int(bounds.height)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { context.render(small, toBitmap: $0.baseAddress!, rowBytes: width * 16, bounds: bounds, format: .RGBAf, colorSpace: nil) }
        try Task.checkCancellation()
        var luminances: [Double] = []; luminances.reserveCapacity(width * height)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            luminances.append(0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2]))
        }
        let sorted = luminances.sorted()
        let black = max(0, sorted[Int(Double(sorted.count - 1) * 0.005)]), white = sorted[Int(Double(sorted.count - 1) * 0.995)]
        guard white > black + 1e-4 else { return Levels(black: 0, white: 1, neutral: nil) }
        // A cast shows in what should have no colour: the pixels of little saturation, away from both ends.
        var sum = SIMD3<Double>(repeating: 0), count = 0
        for (index, luminance) in luminances.enumerated() where luminance > black + (white - black) * 0.1 && luminance < white {
            let rgb = SIMD3(Double(pixels[index * 4]), Double(pixels[index * 4 + 1]), Double(pixels[index * 4 + 2]))
            guard rgb.max() > 0, (rgb.max() - rgb.min()) / rgb.max() < 0.25 else { continue }
            sum += rgb / luminance; count += 1
        }
        return Levels(black: black, white: white, neutral: count * 50 >= luminances.count ? sum / Double(count) : nil)
    }

    /// Reads the picture and sets it right: the cast taken out of its neutrals, black and white put at the ends of
    /// its own range, and local contrast evened over the tones.
    static func proContrast(_ image: CIImage, filter: CreativeFilter, context: CIContext) throws -> CIImage {
        guard max(image.extent.width, image.extent.height) > 16 else { return image }
        let amount = filter.amount / 100, cast = filter["cast"] / 100 * amount, contrast = filter["contrast"] / 100 * amount
        var output = image
        if cast > 0 || contrast > 0 {
            let levels = try levels(image, context: context)
            var gain = SIMD3<Double>(repeating: 1)
            if cast > 0, let neutral = levels.neutral {
                let wanted = SIMD3<Double>(repeating: 1) / simd_max(neutral, SIMD3(repeating: 0.25))
                // The gains keep the luminance where it was.
                gain = simd_mix(gain, wanted / (0.2126 * wanted.x * neutral.x + 0.7152 * wanted.y * neutral.y + 0.0722 * wanted.z * neutral.z), SIMD3(repeating: cast))
            }
            // Highlights above white are HDR headroom and stay.
            let black = levels.black * contrast, white = levels.white < 1 ? 1 + (levels.white - 1) * contrast : 1
            let k = 1 / (white - black)
            output = output.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: gain.x * k, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: gain.y * k, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: gain.z * k, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: -black * k, y: -black * k, z: -black * k, w: 0)])
                .applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0), "inputMaxComponents": CIVector(x: 64, y: 64, z: 64, w: 1)])
        }
        let dynamic = filter["dynamic"] / 100 * amount * 0.9
        return localContrast(output, gains: CIVector(x: dynamic * 0.7, y: dynamic, z: dynamic * 0.8), radius: 0.6)
    }

    // MARK: Detail extractor

    /// Brings out what the shadows and highlights hold: the tones under the band's radius are drawn toward middle
    /// grey while the detail over them is raised, L − c (B − m) + d (F − B) on log luminance.
    static func detailExtractor(_ image: CIImage, filter: CreativeFilter) -> CIImage {
        let extent = image.extent, long = max(extent.width, extent.height)
        let amount = filter.amount / 100, contrast = filter["contrast"] / 100 * 0.5, saturation = filter["saturation"] / 100
        guard long > 16, amount > 0 || contrast != 0 || saturation != 0 else { return image }
        let (fine, base) = bases(image, radius: [0.015, 0.03, 0.06][min(2, max(0, Int(filter["radius"].rounded())))])
        return extract.apply(extent: extent, arguments: [image, fine, base, CIVector(x: 0.65 * amount, y: 1.2 * amount, z: contrast, w: saturation)])!
    }

    // MARK: Center

    /// Exposure set apart for the middle and the border, around a centre the photographer places: up to 1.5 stops
    /// either way, the change falling smoothly between them.
    static func center(_ image: CIImage, filter: CreativeFilter) -> CIImage {
        let extent = image.extent
        let amount = filter.amount / 100, inner = filter["center"] / 100 * 1.5 * amount, outer = filter["border"] / 100 * 1.5 * amount
        guard extent.width > 8, extent.height > 8, inner != 0 || outer != 0 else { return image }
        let short = min(extent.width, extent.height) / 2, oval = filter["shape"] >= 0.5
        let size = 0.3 + 1.2 * filter["size"] / 100
        // The picture counts rows from the top; Core Image from the bottom.
        let point = CIVector(x: extent.minX + extent.width * filter["x"] / 100, y: extent.minY + extent.height * (1 - filter["y"] / 100))
        let radii = CIVector(x: (oval ? extent.width / 2 : short) * size, y: (oval ? extent.height / 2 : short) * size)
        return centerLight.apply(extent: extent, arguments: [image, point, radii, CIVector(x: inner, y: outer)])!
    }

    // MARK: Bokeh

    /// A lens opened wide: sharp inside a zone placed on the picture, a round zone or a band, and out of focus past
    /// it, to discs up to 3 % of the long side. Highlights weigh more in the blur, as light does through a real
    /// aperture, so bright points grow into discs instead of fading. Two blurs, one at half the radius, stand in for
    /// a blur that grows with distance.
    static func bokeh(_ image: CIImage, filter: CreativeFilter) -> CIImage {
        let extent = image.extent, long = max(extent.width, extent.height), short = min(extent.width, extent.height)
        let radius = long * 0.03 * filter.amount / 100
        guard radius >= 0.5, short > 8 else { return image }
        let lights = highlightWeight.apply(extent: extent, arguments: [image, filter["highlights"] / 100 * 12])!
        let weights = weightOnly.apply(extent: extent, arguments: [lights])!
        func disc(_ image: CIImage, _ radius: Double) -> CIImage {
            image.clampedToExtent().applyingFilter("CIBokehBlur", parameters: [kCIInputRadiusKey: min(500, radius), "inputRingAmount": 0, "inputRingSize": 0.1, "inputSoftness": 1]).cropped(to: extent)
        }
        func defocused(_ radius: Double) -> CIImage { weighted.apply(extent: extent, arguments: [disc(lights, radius), disc(weights, radius)])! }
        let band = filter["shape"] >= 0.5, angle = filter["angle"] * .pi / 180
        let zone = short / 2 * (band ? 0.08 + 0.8 * filter["size"] / 100 : 0.15 + 1.1 * filter["size"] / 100)
        // The picture counts rows from the top; Core Image from the bottom.
        let point = CIVector(x: extent.minX + extent.width * filter["x"] / 100, y: extent.minY + extent.height * (1 - filter["y"] / 100))
        return focus.apply(extent: extent, arguments: [image, defocused(radius / 2), defocused(radius), point,
                                                       CIVector(x: -sin(angle), y: cos(angle), z: band ? 1 : 0, w: zone), 0.15 + 1.6 * filter["falloff"] / 100])!
    }

    // MARK: Dust and scratches

    /// The marks of a `FilmTexture` over the picture: white, as dust on a negative prints, or black, as it shows on a
    /// slide. The texture covers the frame, larger with Size, turned for an upright picture and flipped by Variation
    /// so two photos don't carry the same specks.
    static func dust(_ image: CIImage, filter: CreativeFilter) -> CIImage {
        let extent = image.extent
        let textures = FilmTexture.all
        guard filter.amount > 0, extent.width > 8, extent.height > 8,
              var marks = textures[min(textures.count - 1, max(0, Int(filter["texture"].rounded())))].image else { return image }
        marks = marks.transformed(by: CGAffineTransform(translationX: -marks.extent.minX, y: -marks.extent.minY))
        if extent.height > extent.width {
            marks = marks.transformed(by: CGAffineTransform(rotationAngle: .pi / 2)).transformed(by: CGAffineTransform(translationX: marks.extent.height, y: 0))
        }
        let variation = Int(filter["variation"].rounded())
        let flipX: CGFloat = variation % 2 == 1 ? -1 : 1, flipY: CGFloat = variation >= 2 ? -1 : 1
        marks = marks.transformed(by: CGAffineTransform(scaleX: flipX, y: flipY))
        marks = marks.transformed(by: CGAffineTransform(translationX: -marks.extent.minX, y: -marks.extent.minY))
        let scale = max(extent.width / marks.extent.width, extent.height / marks.extent.height) * (1 + 1.5 * filter["size"] / 100)
        marks = marks.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // Centred, so Size grows the marks about the middle of the frame.
        marks = marks.transformed(by: CGAffineTransform(translationX: extent.midX - marks.extent.midX, y: extent.midY - marks.extent.midY)).cropped(to: extent)
        return speckle.apply(extent: extent, arguments: [image, marks, filter.amount / 100, filter["tone"].rounded()])!
    }

    // MARK: Colour looks

    /// Film developed without the bleach: silver left over the dyes, so less colour and a harder scale. The luminance
    /// is overlaid on itself in the encoded picture, where contrast is judged.
    static func bleachBypass(_ image: CIImage, filter: CreativeFilter) -> CIImage {
        guard filter.amount > 0 else { return image }
        return bleach.apply(extent: image.extent, arguments: [image, CIVector(x: filter.amount / 100, y: filter["contrast"] / 100, z: filter["saturation"] / 100)])!
    }
    /// Film in the other process's chemistry: slide film in C-41 comes out hard, with yellow-green highlights and
    /// blue shadows; negative film in E-6 soft and cool.
    static func crossProcess(_ image: CIImage, filter: CreativeFilter) -> CIImage {
        guard filter.amount > 0 else { return image }
        return cross.apply(extent: image.extent, arguments: [image, filter.amount / 100, filter["method"].rounded()])!
    }

    // MARK: Light on the picture

    /// A veil of scattered light over the whole frame, or thinning down from the top or up from the bottom past
    /// Horizon: the picture loses its blacks and its fine contrast to a soft copy of itself and the fog's own grey.
    static func fog(_ image: CIImage, filter: CreativeFilter) -> CIImage {
        let extent = image.extent, long = max(extent.width, extent.height)
        guard filter.amount > 0, long > 8 else { return image }
        let soft = image.clampedToExtent().applyingGaussianBlur(sigma: long * 0.03).cropped(to: extent)
        // The picture counts rows from the top; Core Image from the bottom.
        let level = extent.minY + extent.height * (1 - filter["level"] / 100)
        return veil.apply(extent: extent, arguments: [image, soft, CIVector(x: filter.amount / 100 * 0.85, y: filter["cover"].rounded(), z: level, w: extent.height * 0.25)])!
    }
    /// A reflector held at one side: fill light that reaches the shadows most and fades across the frame, gold or
    /// plain. Direction 0° is from below, 90° from the right.
    static func reflector(_ image: CIImage, filter: CreativeFilter) -> CIImage {
        let extent = image.extent
        guard filter.amount > 0, extent.width > 8, extent.height > 8 else { return image }
        let angle = filter["direction"] * .pi / 180
        let tint = [CIVector(x: 1.14, y: 1, z: 0.74), CIVector(x: 1.07, y: 1, z: 0.88), CIVector(x: 1, y: 1, z: 1)][min(2, max(0, Int(filter["tone"].rounded())))]
        // Toward the source, in Core Image's upward rows.
        let toward = CIVector(x: sin(angle) / extent.width, y: -cos(angle) / extent.height)
        return fill.apply(extent: extent, arguments: [image, CIVector(x: extent.midX, y: extent.midY), toward, tint,
                                                      CIVector(x: filter.amount / 100 * 2.4, y: 1 - filter["position"] / 100, z: 0.08 + 0.5 * filter["falloff"] / 100)])!
    }
    /// Light through a gap in the camera back: added to the picture from one edge, hot where it enters and deeper
    /// in colour as it thins.
    static func lightLeak(_ image: CIImage, filter: CreativeFilter) -> CIImage {
        let extent = image.extent
        guard filter.amount > 0, extent.width > 8, extent.height > 8 else { return image }
        let tones: [(CIVector, CIVector)] = [(CIVector(x: 1, y: 0.8, z: 0.4), CIVector(x: 1, y: 0.3, z: 0.06)), (CIVector(x: 1, y: 0.45, z: 0.25), CIVector(x: 0.85, y: 0.06, z: 0.04)),
                                             (CIVector(x: 0.7, y: 0.9, z: 1), CIVector(x: 0.15, y: 0.35, z: 1))]
        let tone = tones[min(2, max(0, Int(filter["tone"].rounded())))]
        let size = filter["size"] / 100
        return leak.apply(extent: extent, arguments: [image, CIVector(cgRect: extent), tone.0, tone.1,
                                                      CIVector(x: filter.amount / 100 * 1.6, y: filter["edge"].rounded(), z: filter["position"] / 100, w: 0.1 + 0.5 * size)])!
    }

    // MARK: Output

    /// Sharpening for the medium the file is for, on the encoded picture at its output size: one radius of about
    /// 0.7 px for every size, and an amount by medium. In linear light the dark rim would come out twice as strong.
    static func outputSharpen(_ image: CIImage, amount: Double, medium: Int) -> CIImage {
        let strength = [0.5, 0.8, 1.1][min(2, max(0, medium))] * amount
        guard strength > 0 else { return image }
        return image.applyingFilter("CILinearToSRGBToneCurve")
            .applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 0.7, kCIInputIntensityKey: strength])
            .applyingFilter("CISRGBToneCurveToLinear").cropped(to: image.extent)
    }

    // MARK: Kernels

    private static func kernel(_ name: String, _ signature: String, _ body: String) -> CIColorKernel {
        try! CIKernel.kernels(withMetalString: """
        #include <metal_stdlib>
        #include <CoreImage/CoreImage.h>
        using namespace metal;
        extern "C" [[ stitchable ]] float4 \(name)(\(signature)) { \(body) }
        """)[0] as! CIColorKernel
    }
    /// Log2 luminance, for the guided filter. The luminance is held to what a half-float can carry: a highlight that
    /// overflowed (the sun, after a filter before this one raised it) would otherwise be infinite, and the blurs that
    /// follow would spread it across the picture as a dark patch.
    private static let logLuminance = kernel("filterLogLuminance", "coreimage::sample_t s",
                                             "float l = log2(clamp(dot(s.rgb, float3(0.2126, 0.7152, 0.0722)), 1e-5, 16384.0)); return float4(l, l * l, 0.0, 1.0);")
    private static let deviation = kernel("filterGuidedDeviation", "coreimage::sample_t l, coreimage::sample_t mean",
                                          "float d = l.r - mean.r; return float4(d, d * d, 0.0, 1.0);")
    private static let coefficients = kernel("filterGuidedCoefficients", "coreimage::sample_t m, coreimage::sample_t mean, float epsilon",
                                             "float variance = max(0.0, m.g - m.r * m.r); float a = variance / (variance + epsilon); return float4(a, mean.r * (1.0 - a), 0.0, 1.0);")
    private static let guidedOutput = kernel("filterGuidedOutput", "coreimage::sample_t l, coreimage::sample_t ab", "return float4(ab.r * l.r + ab.g, 0.0, 0.0, 1.0);")
    /// The detail between the two bases, weighed by where the base sits in the tones (mid grey is −2.5 in log2).
    private static let tone = kernel("filterTonalContrast", "coreimage::sample_t s, coreimage::sample_t fine, coreimage::sample_t base, float3 gains", """
        float t = base.r;
        float shadows = 1.0 - smoothstep(-5.0, -2.5, t), highs = smoothstep(-2.5, -0.5, t);
        float gain = gains.z * shadows + gains.x * highs + gains.y * (1.0 - shadows - highs);
        return float4(min(s.rgb * exp2(clamp(gain * (fine.r - base.r), -3.0, 3.0)), float3(16384.0)), s.a);
        """)
    /// Tones compressed toward middle grey, detail raised, then contrast about middle grey and saturation.
    private static let extract = kernel("filterDetailExtractor", "coreimage::sample_t s, coreimage::sample_t fine, coreimage::sample_t base, float4 p", """
        float l = log2(clamp(dot(s.rgb, float3(0.2126, 0.7152, 0.0722)), 1e-5, 16384.0));
        float change = -p.x * (base.r + 2.5) + p.y * (fine.r - base.r);
        change += p.z * (l + change + 2.5);
        float3 rgb = s.rgb * exp2(clamp(change, -4.0, 4.0));
        float y = dot(rgb, float3(0.2126, 0.7152, 0.0722));
        return float4(clamp(mix(float3(y), rgb, 1.0 + p.w), 0.0, 16384.0), s.a);
        """)
    /// Exposure by distance from the centre, in units of the radii.
    private static let centerLight = kernel("filterCenter", "coreimage::sample_t s, float2 point, float2 radii, float2 stops, coreimage::destination dest", """
        float d = length((dest.coord() - point) / radii);
        return float4(s.rgb * exp2(mix(stops.x, stops.y, smoothstep(0.25, 1.25, d))), s.a);
        """)
    /// The light with its weight beside it: highlights count for more in an out-of-focus disc.
    private static let highlightWeight = kernel("filterBokehWeight", "coreimage::sample_t s, float boost", """
        float y = dot(max(s.rgb, 0.0), float3(0.2126, 0.7152, 0.0722));
        float w = 1.0 + boost * smoothstep(0.5, 1.2, y);
        return float4(s.rgb * w, w);
        """)
    private static let weightOnly = kernel("filterBokehWeightOnly", "coreimage::sample_t s", "return float4(s.a, s.a, s.a, 1.0);")
    private static let weighted = kernel("filterBokehWeighted", "coreimage::sample_t light, coreimage::sample_t weight",
                                         "return float4(light.rgb / max(weight.r, 1e-4), 1.0);")
    /// zone: the band's normal (x, y), 1 for a band or 0 for a round zone, and the sharp zone's half size.
    private static let focus = kernel("filterBokehFocus", "coreimage::sample_t s, coreimage::sample_t near, coreimage::sample_t far, float2 point, float4 zone, float falloff, coreimage::destination dest", """
        float2 p = dest.coord() - point;
        float d = (zone.z > 0.5 ? abs(dot(p, zone.xy)) : length(p)) / zone.w;
        float m = smoothstep(1.0, 1.0 + falloff, d);
        float3 rgb = m < 0.5 ? mix(s.rgb, near.rgb, m * 2.0) : mix(near.rgb, far.rgb, m * 2.0 - 1.0);
        return float4(rgb, s.a);
        """)
    /// The texture's marks back in the tones they were drawn in, less the scan's floor, laid over the picture.
    private static let speckle = kernel("filterDust", "coreimage::sample_t s, coreimage::sample_t marks, float amount, float dark", """
        float m = clamp((pow(max(marks.r, 0.0), 1.0 / 2.2) - 0.08) / 0.8, 0.0, 1.0) * amount;
        float y = dot(s.rgb, float3(0.2126, 0.7152, 0.0722));
        float3 rgb = dark > 0.5 ? s.rgb * (1.0 - 0.94 * m) : mix(s.rgb, float3(max(1.0, y)) * s.a, m);
        return float4(rgb, s.a);
        """)
    private static let bleach = kernel("filterBleachBypass", "coreimage::sample_t s, float3 p", """
        float y = max(dot(s.rgb, float3(0.2126, 0.7152, 0.0722)), 1e-5);
        float e = pow(y, 1.0 / 2.2);
        float o = e < 0.5 ? 2.0 * e * e : 1.0 - 2.0 * (1.0 - e) * (1.0 - e);
        o = e < 1.0 ? mix(e, o, p.y) : e;
        float3 rgb = mix(float3(y), s.rgb, p.z) * pow(max(o, 0.0), 2.2) / y;
        return float4(mix(s.rgb, rgb, p.x), s.a);
        """)
    private static let cross = kernel("filterCrossProcess", "coreimage::sample_t s, float amount, float method", """
        float3 e = pow(clamp(s.rgb, 0.0, 1.0), float3(1.0 / 2.2));
        float3 curve = e * e * (3.0 - 2.0 * e);
        float3 o = method < 0.5
            ? float3(mix(e.r, curve.r, 0.7), mix(e.g, curve.g, 0.4) * 0.94 + 0.06 * e.g * e.g + 0.02, 0.14 + 0.68 * e.b)
            : float3(pow(e.r, 1.25), mix(e.g, curve.g, 0.2), 0.07 + 0.9 * pow(e.b, 0.8));
        float3 rgb = pow(clamp(o, 0.0, 1.0), float3(2.2));
        // Headroom above white passes as it is.
        rgb += max(s.rgb - 1.0, 0.0);
        return float4(mix(s.rgb, rgb, amount), s.a);
        """)
    /// p: amount, cover (0 all, 1 top, 2 bottom), the level's row, the fade's height.
    private static let veil = kernel("filterFog", "coreimage::sample_t s, coreimage::sample_t soft, float4 p, coreimage::destination dest", """
        float above = smoothstep(p.z - p.w, p.z + p.w, dest.coord().y);
        float cover = p.y < 0.5 ? 1.0 : (p.y < 1.5 ? above : 1.0 - above);
        float3 fog = mix(soft.rgb, float3(0.62, 0.64, 0.66), 0.65);
        return float4(mix(s.rgb, fog * s.a, p.x * cover), s.a);
        """)
    /// p: strength, where the light has fallen to half (0 at the source's edge … 1 at the far one), the fade's width.
    private static let fill = kernel("filterReflector", "coreimage::sample_t s, float2 center, float2 toward, float3 tint, float3 p, coreimage::destination dest", """
        float t = 0.5 - dot(dest.coord() - center, toward);
        float reach = 1.0 - smoothstep(p.y - p.z, p.y + p.z, t);
        float y = dot(s.rgb, float3(0.2126, 0.7152, 0.0722));
        float lift = p.x * reach * pow(1.0 - clamp(pow(max(y, 0.0), 1.0 / 2.2), 0.0, 1.0), 1.5);
        return float4(s.rgb * (1.0 + lift) * mix(float3(1.0), tint, clamp(lift, 0.0, 1.0)), s.a);
        """)
    /// p: strength, edge (0 left, 1 top, 2 right, 3 bottom), place along it, depth.
    private static let leak = kernel("filterLightLeak", "coreimage::sample_t s, float4 frame, float3 hot, float3 deep, float4 p, coreimage::destination dest", """
        float2 q = (dest.coord() - frame.xy) / frame.zw;
        q.y = 1.0 - q.y;
        float d = max(0.0, p.y < 0.5 ? q.x : (p.y < 1.5 ? q.y : (p.y < 2.5 ? 1.0 - q.x : 1.0 - q.y)));
        float u = (p.y < 0.5 || (p.y > 1.5 && p.y < 2.5)) ? q.y : q.x;
        float along = (u - p.z) / (0.2 + 0.5 * p.w);
        float light = exp(-pow(d / p.w, 1.3)) * (0.3 + 0.7 * exp(-along * along));
        float3 color = mix(deep, hot, exp(-d / (0.35 * p.w)));
        return float4(s.rgb + color * light * p.x * s.a, s.a);
        """)
    /// The Rayleigh pattern over the sky mask; see `transmission`.
    private static let polarize = kernel("filterPolarizer", "coreimage::sample_t s, coreimage::sample_t sky, float4 camera, float4 sun, float2 axis, coreimage::destination dest", """
        float2 p = dest.coord() - camera.xy;
        float3 d = normalize(float3(p.x, p.y, camera.z));
        float c = cos(camera.w), sn = sin(camera.w);
        d = float3(d.x, d.y * c + d.z * sn, -d.y * sn + d.z * c);
        float cosine = dot(d, sun.xyz), sine2 = 1.0 - cosine * cosine;
        float pol = sun.w * sine2 / (1.0 + cosine * cosine);
        float3 e = cross(d, sun.xyz);
        float3 a = float3(axis.x, axis.y, 0.0);
        float3 across = a - dot(a, d) * d;
        float factor = 1.0;
        if (length(e) > 1e-6 && length(across) > 1e-6) { float k = dot(normalize(across), normalize(e)); factor = 1.0 + pol * (2.0 * k * k - 1.0); }
        return float4(s.rgb * mix(1.0, factor, clamp(sky.r, 0.0, 1.0)), s.a);
        """)
}
