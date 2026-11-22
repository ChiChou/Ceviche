import CoreImage
import Foundation

public enum ChartProfileError: LocalizedError {
    case unreadable(String), noChart, tooFewPatches(Int), noFit
    public var errorDescription: String? {
        switch self {
        case .unreadable(let name): L10n.tr("\(name) can’t be read as a RAW photo.")
        case .noChart: L10n.tr("No 24-patch colour chart found in this photo.")
        case .tooFewPatches(let count): L10n.tr("Only \(count) of 24 patches are usable. Shoot the chart evenly lit, without glare, and not overexposed.")
        case .noFit: L10n.tr("The chart’s colours couldn’t be fitted.")
        }
    }
}

/// One patch of the chart as measured.
public struct ChartProfilePatch: Sendable, Identifiable {
    public var id: Int { number }
    /// 1…24, from dark skin to black.
    public let number: Int
    /// Its centre in the photo, in fractions of the width and height from the top left.
    public let centre: CGPoint
    /// ΔE2000 from the chart's reference as the decoder renders it, and with the profile; nil for a patch left out.
    public let before: Double?, after: Double?
    /// Why it was left out: clipped or too bright to trust, glare or uneven light, or outside the photo.
    public let usable: Bool
}

public struct ChartProfileResult: @unchecked Sendable {
    public var profile: CameraProfile
    /// The white balance that makes the chart's greys neutral.
    public let temperature: Double, tint: Double
    public let patches: [ChartProfilePatch]
    /// Mean ΔE2000 over the usable patches: as decoded, with the profile, and with the profile on patches it was
    /// fitted without (each patch predicted by a fit that left it out).
    public let before: Double, after: Double, heldOut: Double
    /// The hue/saturation map folded or went to extremes, or didn't beat the matrix held out: the profile is the
    /// matrix alone.
    public let matrixOnly: Bool
    /// Patches left out because they are too bright for the decoder to render linearly. A chart shot about a stop
    /// darker keeps them, and with all 24 the profile holds better.
    public let tooBright: Int
    /// The chart photo, for showing where the patches were found: as the camera's own colour renders it, and with
    /// the profile.
    public let preview: CGImage?, corrected: CGImage?
}

/// Makes a camera profile from a photo of a 24-patch colour chart: finds the chart, balances on its greys, and fits a
/// correction of the decoder's colour to the chart's reference values.
///
/// The fit sits on Apple's decode, not on the sensor's own colour, so it needs no other RAW reader. It is a
/// white-preserving 3 × 3 plus a 90 × 30 hue/saturation map sampled from a root-polynomial fit (R, G, B, √RG, √GB,
/// √RB): on held-out shots that beats the matrix by 0.2–1.3 ΔE, where a free table fitted to 24 patches never does.
public enum ChartProfiler {
    /// The decoder is not linear near the top: once a channel passes about 80 % of saturation its colour drifts, so
    /// brighter patches are left out.
    static let brightest: Float = 0.8
    static let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    /// A chart photo read: the decoder set to scene-linear light and balanced on the chart's greys, and where the
    /// chart is.
    final class Reading {
        let raw: CIRAWFilter, context: CIContext, name: String
        var detection: ChartDetection!
        var temperature = 0.0, tint = 0.0, width = 0, height = 0, tooBright = 0
        /// Where the chart was looked for, when the photographer framed it: in pixels, rows top down.
        var frame: CGRect?
        init(raw: CIRAWFilter, context: CIContext, name: String) { self.raw = raw; self.context = context; self.name = name }

        func image() throws -> CIImage {
            guard let output = raw.outputImage else { throw ChartProfileError.unreadable(name) }
            return output.transformed(by: CGAffineTransform(translationX: -output.extent.minX, y: -output.extent.minY))
        }
        /// Rows top down, as the detector counts them.
        func pixels(_ image: CIImage, _ rect: CGRect) -> [Float] {
            let width = Int(rect.width), height = Int(rect.height)
            var values = [Float](repeating: 0, count: width * height * 4)
            values.withUnsafeMutableBytes {
                context.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 16,
                               bounds: CGRect(x: rect.minX, y: image.extent.height - rect.maxY, width: rect.width, height: rect.height), format: .RGBAf, colorSpace: space)
            }
            return values
        }
        func whole() throws -> ChartImage {
            let image = try image()
            let width = Int(image.extent.width), height = Int(image.extent.height)
            var values = pixels(image, CGRect(x: 0, y: 0, width: width, height: height))
            for i in 0..<(width * height) { values[i * 4 + 3] = max(values[i * 4], values[i * 4 + 1], values[i * 4 + 2]) > brightest ? 1 : 0 }
            return ChartImage(width: width, height: height, pixels: values)
        }
        /// The 24 patches as XYZ (D50), decoded through `filter` when there is one.
        func measurement(through filter: CIFilter? = nil) throws -> ChartMeasurement {
            raw.linearSpaceFilter = filter
            defer { raw.linearSpaceFilter = nil }
            let samples = chartSamplePatches(try whole(), detection)
            if filter == nil { tooBright = samples.filter { $0.rejection == .clipped }.count }
            let toXYZ = ChartColour.d65ToD50 * ChartColour.srgbToXYZ65
            return ChartMeasurement(rgb: samples.map { toXYZ * SIMD3($0.rgb[0], $0.rgb[1], $0.rgb[2]) }, valid: samples.map(\.valid))
        }
    }

    /// `image` with everything outside `frame` flat, at its own size: the detector works at a scale set by the
    /// picture's size, so a cropped copy would place the chart a few pixels off. The fill is the frame's own average,
    /// which leaves the detector's sense of light and dark where the frame's content puts it; black would not.
    static func only(_ image: ChartImage, _ frame: CGRect) -> ChartImage {
        var out = image
        let x0 = Int(frame.minX), x1 = Int(frame.maxX), y0 = Int(frame.minY), y1 = Int(frame.maxY)
        var sum = SIMD3<Double>(0, 0, 0), count = 0.0
        for y in stride(from: y0, to: y1, by: 4) { for x in stride(from: x0, to: x1, by: 4) {
            let c = image.rgb(x, y); sum += SIMD3(Double(c.x), Double(c.y), Double(c.z)); count += 1
        } }
        let fill = count > 0 ? sum / count : SIMD3<Double>(0, 0, 0)
        for y in 0..<image.height {
            let inside = y >= y0 && y < y1
            for x in 0..<image.width where !inside || x < x0 || x >= x1 {
                let i = (y * image.width + x) * 4
                out.pixels[i] = Float(fill.x); out.pixels[i + 1] = Float(fill.y); out.pixels[i + 2] = Float(fill.z); out.pixels[i + 3] = 0
            }
        }
        return out
    }

    /// `region`: the chart's surroundings as the photographer framed them, four corners in fractions of the photo
    /// from its top left. The chart is looked for inside first, and in the whole photo when it isn't found there.
    static func read(_ url: URL, region: [CGPoint]? = nil, progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) throws -> Reading {
        let context = CIContext(options: [.workingColorSpace: space, .cacheIntermediates: false])
        guard let raw = CIRAWFilter(imageURL: url) else { throw ChartProfileError.unreadable(url.lastPathComponent) }
        // Scene-linear, as the calibration will meet it: no tone, and no lens correction so nothing is resampled.
        raw.exposure = 0; raw.boostAmount = 0; raw.boostShadowAmount = 0
        if raw.isLocalToneMapSupported { raw.localToneMapAmount = 0 }
        if raw.isLensCorrectionSupported { raw.isLensCorrectionEnabled = false }
        let long = Double(max(raw.nativeSize.width, raw.nativeSize.height))
        raw.scaleFactor = Float(min(1, 3600 / max(long, 1)))
        let reading = Reading(raw: raw, context: context, name: url.lastPathComponent)

        progress(0.05, L10n.tr("Finding the chart"))
        let asShot = try reading.whole()
        var framed: ChartDetection?
        if let region, region.count == 4 {
            // The corners' bounding box and half as much again around it: the detector tells the black patch from the
            // chart's own body by what surrounds the chart, and a frame drawn tight on the patches leaves it none. The
            // chart is looked for in that part alone.
            let xs = region.map { Double($0.x) * Double(asShot.width) }, ys = region.map { Double($0.y) * Double(asShot.height) }
            let padX = (xs.max()! - xs.min()!) * 0.5, padY = (ys.max()! - ys.min()!) * 0.5
            let search = CGRect(x: xs.min()! - padX, y: ys.min()! - padY, width: xs.max()! - xs.min()! + 2 * padX, height: ys.max()! - ys.min()! + 2 * padY)
                .integral.intersection(CGRect(x: 0, y: 0, width: asShot.width, height: asShot.height))
            // What is shown is the frame as drawn, with a little air.
            let airX = (xs.max()! - xs.min()!) * 0.04, airY = (ys.max()! - ys.min()!) * 0.04
            let shown = CGRect(x: xs.min()! - airX, y: ys.min()! - airY, width: xs.max()! - xs.min()! + 2 * airX, height: ys.max()! - ys.min()! + 2 * airY)
                .integral.intersection(CGRect(x: 0, y: 0, width: asShot.width, height: asShot.height))
            // The whole photo places the grid best, so its chart is taken when it lies where the corners say. A chart
            // found elsewhere, or none, and the search is the corners' surroundings alone.
            let everywhere = try? ChartDetector(image: asShot).detect()
            let centre = everywhere.map { $0.grid.map(SIMD2(2.5, 1.5)) }
            if let everywhere, let centre, shown.contains(CGPoint(x: centre.x, y: centre.y)) {
                framed = everywhere; reading.frame = shown
            } else if search.width >= 64, search.height >= 64, let found = try? ChartDetector(image: only(asShot, search)).detect() {
                framed = found; reading.frame = shown
            } else {
                framed = everywhere
            }
        }
        let detection = try framed ?? ChartDetector(image: asShot).detect()
        reading.detection = detection; reading.width = asShot.width; reading.height = asShot.height
        if Task.isCancelled { throw CancellationError() }

        // White balance: the decoder's temperature and tint, by Newton, until neutral 6.5 comes out grey. Only that
        // patch is rendered while solving.
        progress(0.35, L10n.tr("Balancing on the greys"))
        let grey = SIMD2<Double>(2, 3)
        let corners = [SIMD2<Double>(-0.12, -0.12), SIMD2(0.12, -0.12), SIMD2(0.12, 0.12), SIMD2(-0.12, 0.12)].map { detection.grid.map(grey + $0) }
        let x0 = corners.map(\.x).min()!.rounded(.down), x1 = corners.map(\.x).max()!.rounded(.up), y0 = corners.map(\.y).min()!.rounded(.down), y1 = corners.map(\.y).max()!.rounded(.up)
        let patch = CGRect(x: x0, y: y0, width: max(2, x1 - x0), height: max(2, y1 - y0)).intersection(CGRect(x: 0, y: 0, width: asShot.width, height: asShot.height))
        func ratios(_ temperature: Double, _ tint: Double) throws -> (Double, Double) {
            raw.neutralTemperature = Float(temperature); raw.neutralTint = Float(tint)
            let values = reading.pixels(try reading.image(), patch)
            var sum = SIMD3<Double>(0, 0, 0)
            for i in stride(from: 0, to: values.count, by: 4) { sum += SIMD3(Double(values[i]), Double(values[i + 1]), Double(values[i + 2])) }
            guard sum.y > 0, sum.x > 0, sum.z > 0 else { throw ChartProfileError.noFit }
            return (log(sum.x / sum.y), log(sum.z / sum.y))
        }
        var mired = 1e6 / Double(max(raw.neutralTemperature, 1000)), tint = Double(raw.neutralTint)
        for _ in 0..<5 {
            let f = try ratios(1e6 / mired, tint)
            if abs(f.0) < 0.002 && abs(f.1) < 0.002 { break }
            let a = try ratios(1e6 / (mired + 5), tint), b = try ratios(1e6 / mired, tint + 2)
            guard let step = chartSolveLinear([(a.0 - f.0) / 5, (b.0 - f.0) / 2, (a.1 - f.1) / 5, (b.1 - f.1) / 2], [-f.0, -f.1], 2) else { break }
            mired = min(1e6 / 1800, max(1e6 / 20_000, mired + step[0])); tint = min(150, max(-150, tint + step[1]))
        }
        reading.temperature = 1e6 / mired; reading.tint = tint
        raw.neutralTemperature = Float(reading.temperature); raw.neutralTint = Float(tint)
        return reading
    }

    /// The decoder's own colour, for comparison: its XYZ taken as it is.
    private static let decoded = ChartMatrixModel(name: "decoded", forward: .diagonal(ChartColour.d50))
    /// Mean ΔE2000 over the usable patches, and every patch's.
    private static func mean(_ model: ChartColourModel, _ m: ChartMeasurement) -> (Double, [Double])? {
        guard let predicted = chartPredict(model, m) else { return nil }
        let errors = chartDeltaEs(predicted), usable = (0..<24).filter { m.valid[$0] }
        return (usable.reduce(0) { $0 + errors[$1] } / Double(max(1, usable.count)), errors)
    }

    /// How far another photo of a chart is from the chart's reference colours, as decoded and through `profile`:
    /// mean ΔE2000 over its usable patches.
    static func score(_ profile: CameraProfile, on url: URL) throws -> (before: Double, after: Double) {
        let reading = try read(url)
        let plain = try reading.measurement()
        let corrected = try reading.measurement(through: ChartCalibrationFilter(profile: profile))
        guard let before = mean(decoded, plain), let after = mean(decoded, ChartMeasurement(rgb: corrected.rgb, valid: plain.valid)) else { throw ChartProfileError.noFit }
        return (before.0, after.0)
    }

    public static func profile(_ url: URL, camera: String, region: [CGPoint]? = nil, progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) throws -> ChartProfileResult {
        let reading = try read(url, region: region, progress: progress)
        let raw = reading.raw, detection = reading.detection!, temperature = reading.temperature, tint = reading.tint
        if Task.isCancelled { throw CancellationError() }

        progress(0.6, L10n.tr("Fitting the profile"))
        let measurement = try reading.measurement()
        let tooBright = reading.tooBright
        let use = (0..<24).filter { measurement.valid[$0] }
        guard use.count >= 16, ColorChecker.balanceNeutrals.allSatisfy(use.contains) else { throw ChartProfileError.tooFewPatches(use.count) }
        guard let matrix = ChartFitter.matrix(measurement, use: use, refine: true), let polynomial = ChartFitter.rootPolynomial(measurement, use: use),
              let neutral = chartNeutral(measurement), let before = mean(decoded, measurement) else { throw ChartProfileError.noFit }
        /// Each patch predicted by a fit that never saw it.
        func heldOut(_ fit: ([Int]) -> ChartColourModel?) -> Double {
            var sum = 0.0, count = 0.0
            for k in use {
                guard let model = fit(use.filter { $0 != k }), let predicted = chartPredict(model, measurement, excluding: [k]) else { continue }
                sum += ChartColour.deltaE2000(ChartColour.lab(predicted[k]), ColorChecker.lab[k]); count += 1
            }
            return count > 0 ? sum / count : .infinity
        }
        let matrixHeldOut = heldOut { ChartFitter.matrix(measurement, use: $0, refine: true) }
        let polynomialHeldOut = heldOut { ChartFitter.rootPolynomial(measurement, use: $0) }
        if Task.isCancelled { throw CancellationError() }

        // The map, unless it folds, goes to extremes, or doesn't beat the matrix on patches it hasn't seen.
        let map = chartBake(polynomial, base: matrix.forward, patches: use.map { measurement.rgb[$0] / neutral })
        let stats = map.stats
        let safe = stats["hueFolds"] == 0 && (stats["maxHueShift"] ?? 0) <= 30 && (stats["maxSatScale"] ?? 1) <= 3 && (stats["minValScale"] ?? 1) >= 0.5
        let matrixOnly = !safe || polynomialHeldOut >= matrixHeldOut

        var profile = CameraProfile(name: "\(camera.isEmpty ? L10n.tr("Chart") : camera) \(Int((temperature / 50).rounded()) * 50) K", camera: camera)
        profile.calibrationMatrix = (ChartColour.xyz50ToProphoto * matrix.forward * ChartMatrix.diagonal(SIMD3(1 / neutral.x, 1 / neutral.y, 1 / neutral.z)) * ChartColour.prophotoToXYZ50).m
        if !matrixOnly { profile.calibrationDimensions = [map.hueDivisions, map.satDivisions, 1]; profile.calibrationMap = CameraProfile.data(map.data) }
        profile.calibrationTemperature = temperature
        try profile.validate()

        // What the profile does where it will run: the chart decoded again through it.
        progress(0.85, L10n.tr("Checking the profile"))
        let corrected = try reading.measurement(through: ChartCalibrationFilter(profile: profile))
        guard let after = mean(decoded, ChartMeasurement(rgb: corrected.rgb, valid: measurement.valid)) else { throw ChartProfileError.noFit }

        // The chart as the photographer sees it, for the dialog.
        raw.boostAmount = 1
        let shown = try reading.image()
        // Framed by the photographer, the picture is that frame.
        let frame = reading.frame.flatMap { $0.width > 8 && $0.height > 8 ? $0 : nil } ?? CGRect(x: 0, y: 0, width: reading.width, height: reading.height)
        let scale = min(1, 1800 / max(frame.width, frame.height))
        func picture(_ image: CIImage) -> CGImage? {
            let part = image.cropped(to: CGRect(x: frame.minX, y: image.extent.height - frame.maxY, width: frame.width, height: frame.height))
                .transformed(by: CGAffineTransform(translationX: -frame.minX, y: -(image.extent.height - frame.maxY)))
            return reading.context.createCGImage(part.transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
                                                 from: CGRect(x: 0, y: 0, width: (frame.width * scale).rounded(.down), height: (frame.height * scale).rounded(.down)),
                                                 format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        let preview = picture(shown)
        raw.linearSpaceFilter = ChartCalibrationFilter(profile: profile)
        let profiled = picture(try reading.image())
        raw.linearSpaceFilter = nil
        let patches = (0..<24).map { k -> ChartProfilePatch in
            let centre = detection.grid.map(SIMD2(Double(k % 6), Double(k / 6)))
            let usable = measurement.valid[k]
            return ChartProfilePatch(number: k + 1, centre: CGPoint(x: (centre.x + 0.5 - frame.minX) / frame.width, y: (centre.y + 0.5 - frame.minY) / frame.height),
                                     before: usable ? before.1[k] : nil, after: usable ? after.1[k] : nil, usable: usable)
        }
        progress(1, "")
        return ChartProfileResult(profile: profile, temperature: temperature, tint: tint, patches: patches, before: before.0, after: after.0,
                                  heldOut: matrixOnly ? matrixHeldOut : polynomialHeldOut, matrixOnly: matrixOnly, tooBright: tooBright, preview: preview, corrected: profiled)
    }
}
