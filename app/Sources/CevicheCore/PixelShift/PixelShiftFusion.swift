import Foundation
import CoreImage
import CameraRaw

/// Fujifilm Pixel Shift Multi Shot: the sensor moves by whole and half pixels, and each shot records where it was. The
/// shots are developed by Apple's decoder (on the GPU, X-Trans and Bayer alike) in linear light with nothing done to
/// their geometry, then interleaved on a grid of twice the size: each point of it averages the shots that sampled it.
final class PixelShiftFusion: @unchecked Sendable {
    /// The sets checked against a real capture; others are refused rather than guessed at.
    static let models: [String: Int] = ["GFX 100": 16]

    let urls: [URL]
    let shots: [FujifilmShot]
    private let context: CIContext
    /// Each shot's place on the doubled grid: twice its offset, right and down.
    private let places: [(x: Int, y: Int)]

    /// `urls` with their shots, in any order: checked to be one complete set and put in its order.
    init(_ items: [(url: URL, shot: FujifilmShot)], context: CIContext) throws {
        let first = items[0]
        let incomplete = PanoramaError.message(L10n.tr("These photos aren’t one complete Pixel Shift set. Choose all \(first.shot.shots) photos of one set."))
        guard let count = Self.models[first.shot.model] else {
            throw PanoramaError.message(L10n.tr("Pixel Shift sets from the \(first.shot.model) aren’t supported yet."))
        }
        for item in items where item.shot.model != first.shot.model || item.shot.serial != first.shot.serial {
            throw PanoramaError.message(L10n.tr("\(item.url.lastPathComponent) is from a different camera or size than \(first.url.lastPathComponent)."))
        }
        for item in items where item.shot.exposure != first.shot.exposure || item.shot.orientation != first.shot.orientation {
            throw PanoramaError.message(L10n.tr("\(item.url.lastPathComponent) has a different exposure than \(first.url.lastPathComponent)."))
        }
        let sorted = items.sorted { $0.shot.sequence < $1.shot.sequence }
        guard first.shot.shots == count, items.count == count, sorted.map(\.shot.sequence) == Array(1...count) else { throw incomplete }
        // Offsets are right and up, in half pixels.
        let places = sorted.map { (x: Int((2 * $0.shot.offset!.x).rounded()), y: Int((-2 * $0.shot.offset!.y).rounded())) }
        guard Set(places.map { $0.x * 1000 + $0.y }).count == count,
              zip(sorted, places).allSatisfy({ abs(2 * $0.shot.offset!.x - Double($1.x)) < 1e-6 && abs(-2 * $0.shot.offset!.y - Double($1.y)) < 1e-6 }) else {
            throw incomplete
        }
        // Every point of the doubled grid has to be reached by as many shots as every other.
        var phases = [Int](repeating: 0, count: 4)
        for p in places { phases[(p.y & 1) * 2 + (p.x & 1)] += 1 }
        guard phases.allSatisfy({ $0 == count / 4 }) else { throw incomplete }
        urls = sorted.map(\.url); shots = sorted.map(\.shot); self.places = places; self.context = context
    }

    /// Apple's development with nothing added: no lens correction (the offsets are the sensor's), no boost, no local
    /// tone mapping. The camera's colour and white balance stay, as in every other merge.
    private func developed(_ url: URL, longEdge: Int? = nil) throws -> CIImage {
        guard let raw = CIRAWFilter(imageURL: url) else { throw PanoramaError.message(L10n.tr("\(url.lastPathComponent) can’t be decoded.")) }
        raw.orientation = .up
        if let longEdge { raw.scaleFactor = Float(min(1, Double(longEdge) / max(raw.nativeSize.width, raw.nativeSize.height))) }
        raw.exposure = 0; raw.boostAmount = 0; raw.boostShadowAmount = 0
        if raw.isLocalToneMapSupported { raw.localToneMapAmount = 0 }
        if raw.isLensCorrectionSupported { raw.isLensCorrectionEnabled = false }
        guard let image = raw.outputImage, image.extent.width > 8, image.extent.height > 8 else {
            throw PanoramaError.message(L10n.tr("\(url.lastPathComponent) can’t be decoded."))
        }
        return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }

    private var size: (width: Int, height: Int)?
    /// The merged size: the area every shot covers, on the doubled grid.
    private func merged(_ width: Int, _ height: Int) -> (width: Int, height: Int, left: Int, top: Int) {
        let left = places.map(\.x).max()!, top = places.map(\.y).max()!
        return ((width - 1) * 2 + 1 + places.map(\.x).min()! - left, (height - 1) * 2 + 1 + places.map(\.y).min()! - top, left, top)
    }

    func analyze(progress: @escaping @Sendable (Double, String) -> Void) throws -> PixelShiftAnalysis {
        progress(0.2, L10n.tr("Reading photos…"))
        let image = try developed(urls[0])
        let width = Int(image.extent.width), height = Int(image.extent.height)
        size = (width, height)
        let out = merged(width, height)
        let shots = self.shots
        return PixelShiftAnalysis(frames: urls.indices.map { k in
            PixelShiftFrameInfo(index: k, filename: urls[k].lastPathComponent, shift: SIMD2(shots[k].offset!.x, shots[k].offset!.y), stops: 0)
        }, width: out.width, height: out.height, orientation: shots[0].orientation, camera: [shots[0].make, shots[0].model].joined(separator: " "))
    }

    /// The first shot developed: a set's shots are a fraction of a pixel apart, so it shows what the merge will.
    func preview() throws -> PixelShiftPreview {
        let image = try developed(urls[0], longEdge: 3000)
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var raster = PanoramaRaster(width: width, height: height, rgba: [Float](repeating: 0, count: width * height * 4))
        raster.rgba.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 16, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           format: .RGBAf, colorSpace: PanoramaDecoder.space)
        }
        for i in stride(from: 3, to: raster.rgba.count, by: 4) { raster.rgba[i] = 1 }
        guard let picture = HDRMergeFinishing.picture(raster) else { throw PanoramaError.message(L10n.tr("The preview couldn’t be made.")) }
        var source: MergePreviewSource?
        if let metadata = try? PanoramaDecoder.metadata(urls[0]) {
            var writer = PanoramaDNGWriter(metadata: metadata, kind: .pixelShift, source: .merge(urls[0], process: PanoramaDNGWriter.Kind.pixelShift.rawValue))
            writer.orientation = shots[0].orientation
            source = MergePreviewSource(raster: raster, writer: ToolResultWriter(dng: writer, source: urls[0]), base: 0)
        }
        return PixelShiftPreview(image: picture, source: source, motion: nil, motionCoverage: 0)
    }

    func mergedRaster(progress: @escaping @Sendable (Double, String) -> Void) throws -> PanoramaRaster {
        guard let size else { throw PanoramaError.message(L10n.tr("Analyze the photos first.")) }
        let out = merged(size.width, size.height), w = size.width, h = size.height
        var raster = PanoramaRaster(width: out.width, height: out.height, rgba: [Float](repeating: 0, count: out.width * out.height * 4))
        var frame = [Float16](repeating: 0, count: w * h * 4)
        for (k, url) in urls.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            progress(0.05 + 0.5 * Double(k) / Double(urls.count), L10n.tr("Developing \(url.lastPathComponent)"))
            let image = try developed(url)
            guard Int(image.extent.width) == w, Int(image.extent.height) == h else {
                throw PanoramaError.message(L10n.tr("\(url.lastPathComponent) is from a different camera or size than \(urls[0].lastPathComponent)."))
            }
            try autoreleasepool {
                try frame.withUnsafeMutableBytes { bytes in
                    try context.startTask(toRender: image, from: CGRect(x: 0, y: 0, width: w, height: h),
                                          to: CIRenderDestination(bitmapData: bytes.baseAddress!, width: w, height: h, bytesPerRow: w * 8, format: .RGBAh),
                                          at: .zero).waitUntilCompleted()
                }
            }
            // Shot pixel (x, y) is at (2x + px, 2y + py) on the doubled grid, (left, top) the merge's corner.
            let px = places[k].x - out.left, py = places[k].y - out.top
            frame.withUnsafeBufferPointer { source in raster.rgba.withUnsafeMutableBufferPointer { target in
                let source = source, target = target
                DispatchQueue.concurrentPerform(iterations: out.height) { Y in
                    let sy = Y - py
                    guard sy & 1 == 0, sy >= 0, sy / 2 < h else { return }
                    let row = (sy / 2) * w, line = Y * out.width
                    var X = (px & 1 == 0) ? 0 : 1
                    while X < out.width {
                        let sx = (X - px) / 2
                        if sx >= 0, sx < w {
                            let s = (row + sx) * 4, t = (line + X) * 4
                            target[t] += Float(source[s]); target[t + 1] += Float(source[s + 1]); target[t + 2] += Float(source[s + 2])
                        }
                        X += 2
                    }
                }
            } }
        }
        if Task.isCancelled { throw CancellationError() }
        progress(0.56, L10n.tr("Combining \(urls.count) photos"))
        let share = 4 / Float(urls.count)
        raster.rgba.withUnsafeMutableBufferPointer { rgba in
            let rgba = rgba
            DispatchQueue.concurrentPerform(iterations: out.height) { Y in
                for i in (Y * out.width * 4)..<((Y + 1) * out.width * 4) { rgba[i] = i & 3 == 3 ? 1 : (rgba[i].isFinite ? rgba[i] * share : 0) }
            }
        }
        return raster
    }
}
