import CoreImage
import Foundation
import simd

/// Darkroom tools for the Film section: a test strip of print exposures, a ring-around of color balance and the
/// balance that prints a picked spot neutral.
extension RawRenderer {
    /// The photo as a test strip: side-by-side bands printed at `steps` stops from the current print exposure, at the
    /// preview's size. Nil without a film on a medium that takes an exposure.
    public func filmTestStrip(_ adjustments: Adjustments, steps: [Double]) throws -> CGImage? {
        guard let film = adjustments.film, adjustments.rendering == .film, film.output?.hasExposure == true, !steps.isEmpty else { return nil }
        // Each band is rendered on its own: Core Image would merge the bands' film steps in one graph.
        let space = try adjustments.colorProfile.colorSpace()
        var strip: CIImage?
        var extent = CGRect.zero
        for (index, step) in steps.enumerated() {
            // A strip nobody is waiting for any more (the film under the pointer changed) stops between bands.
            try Task.checkCancellation()
            var settings = adjustments
            settings.film?.printExposure = min(5, max(-5, film.printExposure + step))
            let image = try pipeline(settings, maxDimension: 2200)
            extent = image.extent
            let left = (extent.width * Double(index) / Double(steps.count)).rounded(), right = (extent.width * Double(index + 1) / Double(steps.count)).rounded()
            let area = CGRect(x: extent.minX + left, y: extent.minY, width: right - left, height: extent.height)
            guard let print = context.createCGImage(image, from: area, format: .RGBA16, colorSpace: space) else { throw EditorError.render }
            let band = CIImage(cgImage: print, options: [.colorSpace: space]).transformed(by: CGAffineTransform(translationX: area.minX, y: area.minY))
            strip = strip.map { band.composited(over: $0) } ?? band
        }
        guard let strip else { return nil }
        return context.createCGImage(strip, from: extent, format: .RGBA16, colorSpace: space)
    }

    /// The whole photo printed at each of `exposures` (stops of print exposure), at the preview's size: a test strip
    /// cuts its bands from these, and keeps them as its exposure steps along. Empty without a film on a medium that
    /// takes an exposure.
    public func filmPrints(_ adjustments: Adjustments, exposures: [Double]) throws -> [CGImage] {
        guard adjustments.film != nil, adjustments.rendering == .film, adjustments.film?.output?.hasExposure == true else { return [] }
        let space = try adjustments.colorProfile.colorSpace()
        return try exposures.map { exposure in
            try Task.checkCancellation()
            var settings = adjustments
            settings.film?.printExposure = min(5, max(-5, exposure))
            let image = try pipeline(settings, maxDimension: 2200)
            guard let print = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: space) else { throw EditorError.render }
            return print
        }
    }

    /// The photo printed at each Y and M balance, `size` pixels on the long side, without the grain and halation a
    /// proof this small doesn't show.
    public func filmRingAround(_ adjustments: Adjustments, filtrations: [(yellow: Double, magenta: Double)], size: Double) throws -> [CGImage] {
        guard let film = adjustments.film, adjustments.rendering == .film, film.output?.hasBalance == true else { return [] }
        let space = try adjustments.colorProfile.colorSpace()
        return try filtrations.map { filtration in
            try Task.checkCancellation()
            var settings = adjustments.forThumbnail
            settings.film?.yellow = min(100, max(-100, filtration.yellow))
            settings.film?.magenta = min(100, max(-100, filtration.magenta))
            let image = try pipeline(settings, maxDimension: size)
            guard let print = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: space) else { throw EditorError.render }
            return print
        }
    }

    /// The photo through each of `films`, `size` pixels on the long side, for the Darkroom's stock previews. The
    /// scene is developed once and kept for the next batch; each film exposes, develops and prints it without the
    /// spatial effects, which are finer than a preview's pixels.
    public func filmPreviews(_ adjustments: Adjustments, films: [FilmSimulation], size: Double) throws -> [CGImage?] {
        guard let first = films.first else { return [] }
        try Task.checkCancellation()
        var shared = adjustments.forThumbnail; shared.film = first; shared.film?.enabled = true
        var key = shared; key.film = FilmSimulation()
        let scene: CIImage
        if let cached = filmPreviewScene, cached.key == key, cached.size == size {
            scene = cached.image
        } else {
            scene = try filmScene(shared, maxDimension: size).insertingIntermediate(cache: true)
            filmPreviewScene = (key, size, scene)
        }
        let space = try adjustments.colorProfile.colorSpace()
        return try films.map { film in
            var settings = shared; settings.film = film; settings.film?.enabled = true
            let printed = filmRenderer.apply(film.rendered, to: scene)
            let image = try finished(printed, settings.effective(defaults: info.defaults), maxDimension: size)
            return context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: space)
        }
    }

    /// The photo developed with `adjustments`, `size` pixels on the long side, for a look's thumbnail, without what a
    /// thumbnail is too small to show (`Adjustments.forThumbnail`).
    public func thumbnail(_ adjustments: Adjustments, size: Double, full: Bool = false) throws -> CGImage? {
        let image = try pipeline(full ? adjustments : adjustments.forThumbnail, maxDimension: size)
        return context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: try adjustments.colorProfile.colorSpace())
    }

    /// The Y and M balance that prints the spot at `point` neutral: small proofs of the whole frame, so a scan's own
    /// levels stay the frame's, read at the spot (5 x 5 pixels) and solved by Newton steps on its red and blue against
    /// green. Nil without a film on a medium that takes a color balance.
    public func filmNeutralFiltration(at point: MaskPoint, adjustments: Adjustments) throws -> (yellow: Double, magenta: Double)? {
        guard let film = adjustments.film, adjustments.rendering == .film, film.output?.hasBalance == true else { return nil }
        var global = adjustments.forThumbnail; global.masks = []; global.quarterTurns = 0; global.geometry = GeometryAdjustments()
        global.lut = nil
        var failure: Error?
        func cast(_ yellow: Double, _ magenta: Double) -> SIMD2<Double> {
            var settings = global; settings.film?.yellow = yellow; settings.film?.magenta = magenta
            do {
                let image = try pipeline(settings, maxDimension: 640)
                let side = 5.0
                let x = min(image.extent.width - side, max(0, floor(point.x * image.extent.width) - 2))
                let y = min(image.extent.height - side, max(0, floor(point.y * image.extent.height) - 2))
                var pixels = [Float](repeating: 0, count: 25 * 4)
                pixels.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: 5 * 16, bounds: CGRect(x: image.extent.minX + x, y: image.extent.minY + y, width: side, height: side), format: .RGBAf, colorSpace: nil) }
                let rgb = (0..<3).map { c in max(1e-5, stride(from: c, to: pixels.count, by: 4).reduce(0.0) { $0 + Double(pixels[$1]) } / 25) }
                return SIMD2(log(rgb[0] / rgb[1]), log(rgb[2] / rgb[1]))
            } catch { failure = error; return .zero }
        }
        let (y, m) = FilmBalance.newton(start: (film.yellow, film.magenta), range: -50...50, iterations: 6, step: 4, cast)
        if let failure { throw failure }
        return (y.rounded(), m.rounded())
    }
}

enum FilmBalance {
    /// Y and M within `range` where `cast` is zero, by Newton steps with a finite-difference Jacobian over `step`.
    static func newton(start: (Double, Double), range: ClosedRange<Double>, iterations: Int = 12, step h: Double = 1, _ cast: (Double, Double) -> SIMD2<Double>) -> (Double, Double) {
        var (y, m) = start
        for _ in 0..<iterations {
            let f = cast(y, m)
            guard simd_length(f) > 0.004 else { break }
            let dy = (cast(y + h, m) - f) / h, dm = (cast(y, m + h) - f) / h
            let jacobian = simd_double2x2(columns: (dy, dm))
            guard abs(jacobian.determinant) > 1e-12 else { break }
            let step = jacobian.inverse * f
            y = min(range.upperBound, max(range.lowerBound, y - step.x)); m = min(range.upperBound, max(range.lowerBound, m - step.y))
            if simd_length(step) < 0.5 { break }
        }
        return (y, m)
    }
}

extension Adjustments {
    /// These settings without what a thumbnail is too small to show and still costs time: grain, sharpening, noise
    /// reduction (the RAW decoder's), retouching and red-eye correction, and a film's grain and halation.
    public var forThumbnail: Adjustments {
        var a = self
        a.grain.amount = 0; a.sharpness = 0; a.noiseReduction = 0; a.colorNoiseReduction = 0
        a.retouch = []; a.redEyeCorrection = false
        if a.film != nil { a.film?.grain = 0; a.film?.halation = 0 }
        return a
    }
}
