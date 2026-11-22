import Foundation
import CoreImage
import CoreML

/// Everything a Remove stroke's AI fill needs, prepared by `RawRenderer.prepareInpaint`: the photo developed up to the
/// stroke, its footprint and surroundings, scaled to the network's pixels, and the cells `InpaintPlan` cuts the stroke
/// into. `run` runs Big-LaMa (advimman/lama, Apache-2.0) on each cell's window, off the renderer, so previews do not
/// wait for it; the first run in a session loads the model onto the Neural Engine, which takes about ten seconds.
public struct InpaintJob: @unchecked Sendable {
    let plan: InpaintPlan
    /// In network pixels of the scaled frame, the frame's corner at the origin: the photo, the stroke's coverage and
    /// `RetouchRenderer.surroundings`.
    let image: CIImage, coverage: CIImage, surroundings: CIImage
    let frame: CGRect
    let reach: Double
    let footprint: String

    /// The hole is every pixel the footprint touches, grown by `grow`, so the soft edge and resampling stay inside it;
    /// the stored ratio reaches `margin` past it.
    static let grow = 3, margin = 2
    /// Windows the fill takes; each runs the network once.
    public var windows: Int { plan.cells.count }

    /// A cell once filled: its pixels, rows top down, and the ratio to store where the hole is.
    private struct Filled {
        var rect: CGRect
        var pixels: [Float]
        var ratio: [Float]
        var hole: (minX: Int, minY: Int, maxX: Int, maxY: Int)?
    }

    /// Fills the cells in order; `progress` hears the windows done and the total. Throws `CancellationError` between
    /// windows once the task is cancelled.
    public func run(on renderer: RawRenderer, progress: @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> RetouchFill {
        let side = InpaintPlan.side, plane = side * side
        let model = try BundledModelCache.shared.model(.inpaint, function: "inpaint\(side)")
        var filled: [Filled] = []
        for (index, cell) in plan.cells.enumerated() {
            try Task.checkCancellation()
            let window = plan.window(cell)
            let planes = try await renderer.inpaintPlanes(self, window: window)
            var image = planes.image
            let coverage = planes.coverage, around = planes.surroundings
            try Task.checkCancellation()
            // Pixel (x, y) of the scaled frame, Core Image coordinates, is row `top - y` of a rectangle whose top row is
            // `top`; windows and cells are whole pixels.
            let left = Int(window.minX), top = Int(window.maxY) - 1
            // Grown by `grow` each way: along the rows, then down the columns.
            var across = [Float](repeating: 0, count: plane), hole = [Float](repeating: 0, count: plane)
            for y in 0..<side { for x in 0..<side where coverage[y * side + x] > 1e-4 {
                for xx in max(0, x - Self.grow)...min(side - 1, x + Self.grow) { across[y * side + xx] = 1 }
            } }
            for y in 0..<side { for x in 0..<side where across[y * side + x] > 0 {
                for yy in max(0, y - Self.grow)...min(side - 1, y + Self.grow) { hole[yy * side + x] = 1 }
            } }
            // Cells filled before are known: their fill goes in and the network keeps it.
            for done in filled where done.rect.intersects(window) {
                let overlap = done.rect.intersection(window), width = Int(done.rect.width), doneTop = Int(done.rect.maxY) - 1, count = width * Int(done.rect.height)
                for y in Int(overlap.minY)..<Int(overlap.maxY) { for x in Int(overlap.minX)..<Int(overlap.maxX) {
                    let i = (top - y) * side + x - left, j = (doneTop - y) * width + x - Int(done.rect.minX)
                    for c in 0..<3 { image[c * plane + i] = done.pixels[c * count + j] }
                    hole[i] = 0
                } }
            }
            let result = hole.contains(1) ? try Self.fill(image: image, hole: hole, model: model) : image
            // Keep the cell: the fill in the hole, the photo elsewhere; the ratio is neutral outside the hole.
            let width = Int(cell.width), height = Int(cell.height), count = width * height, cellTop = Int(cell.maxY) - 1
            var pixels = [Float](repeating: 0, count: count * 3), ratio = [Float](repeating: 1, count: count * 3)
            var bounds: (minX: Int, minY: Int, maxX: Int, maxY: Int)?
            for row in 0..<height { for column in 0..<width {
                let i = (top - (cellTop - row)) * side + Int(cell.minX) + column - left, j = row * width + column
                let inside = hole[i] > 0
                for c in 0..<3 {
                    pixels[c * count + j] = inside ? result[c * plane + i] : image[c * plane + i]
                    if inside {
                        guard result[c * plane + i].isFinite else { throw EditorError.render }
                        ratio[c * count + j] = min(64, result[c * plane + i] / max(around[c * plane + i], 1e-5))
                    }
                }
                if inside { bounds = (min(bounds?.minX ?? column, column), min(bounds?.minY ?? row, row), max(bounds?.maxX ?? column, column), max(bounds?.maxY ?? row, row)) }
            } }
            filled.append(Filled(rect: cell, pixels: pixels, ratio: ratio, hole: bounds))
            progress(index + 1, plan.cells.count)
        }
        // Each cell's hole, and `margin` around it within the cell, is a tile of the stored grid.
        var tiles: [(rect: CGRect, planes: [Float])] = []
        for cell in filled {
            guard let hole = cell.hole else { continue }
            let width = Int(cell.rect.width), height = Int(cell.rect.height), count = width * height
            let x0 = max(0, hole.minX - Self.margin), x1 = min(width - 1, hole.maxX + Self.margin)
            let y0 = max(0, hole.minY - Self.margin), y1 = min(height - 1, hole.maxY + Self.margin)
            var planes: [Float] = []
            planes.reserveCapacity((x1 - x0 + 1) * (y1 - y0 + 1) * 3)
            for c in 0..<3 { for row in y0...y1 { planes.append(contentsOf: cell.ratio[(c * count + row * width + x0)...(c * count + row * width + x1)]) } }
            let rect = CGRect(x: cell.rect.minX + Double(x0), y: cell.rect.maxY - Double(y1 + 1), width: Double(x1 - x0 + 1), height: Double(y1 - y0 + 1))
            tiles.append((rect, planes))
        }
        guard let grid = tiles.map(\.rect).reduce(nil, { (union: CGRect?, rect) in union?.union(rect) ?? rect }) else { throw EditorError.render }
        let raster = try RetouchFillRaster.encode(tiles: tiles.map { tile in
            RetouchFillRaster.Tile(x: Int(tile.rect.minX - grid.minX), y: Int(grid.maxY - tile.rect.maxY), width: Int(tile.rect.width), height: Int(tile.rect.height), planes: tile.planes)
        }, width: Int(grid.width), height: Int(grid.height))
        let scale = plan.scale
        let fill = RetouchFill(x: grid.minX / scale / frame.width, y: grid.minY / scale / frame.height, width: grid.width / scale / frame.width,
                               height: grid.height / scale / frame.height, reach: reach, footprint: footprint, raster: raster)
        try fill.validate()
        return fill
    }

    /// One window through the network: linear red, green and blue planes in and out, rows top down. Also fills
    /// panorama edges (`PanoramaEdgeFill`).
    static func fill(image: [Float], hole: [Float], model: MLModel) throws -> [Float] {
        let side = InpaintPlan.side, plane = side * side
        // The network sees gamma-encoded sRGB in [0, 1], so a window with highlights above SDR white is dimmed by its
        // brightest values outside the hole, and the fill brightened back.
        var bright: [Float] = []
        bright.reserveCapacity(plane)
        for i in 0..<plane where hole[i] < 0.5 { bright.append(max(image[i], image[plane + i], image[2 * plane + i])) }
        bright.sort()
        let peak = bright.isEmpty ? 1 : bright[min(bright.count - 1, Int(Double(bright.count) * 0.995))]
        let gain = 1 / max(1, peak)

        let input = try MLMultiArray(shape: [1, 3, side, side].map { NSNumber(value: $0) }, dataType: .float32)
        let mask = try MLMultiArray(shape: [1, 1, side, side].map { NSNumber(value: $0) }, dataType: .float32)
        let inputStrides = input.strides.map(\.intValue), maskStrides = mask.strides.map(\.intValue)
        let pixels = input.dataPointer.assumingMemoryBound(to: Float.self), holes = mask.dataPointer.assumingMemoryBound(to: Float.self)
        for y in 0..<side {
            for x in 0..<side {
                let i = y * side + x
                for c in 0..<3 { pixels[c * inputStrides[1] + y * inputStrides[2] + x * inputStrides[3]] = NAFNetTiles.encode(image[c * plane + i] * gain) }
                holes[y * maskStrides[2] + x * maskStrides[3]] = hole[i]
            }
        }
        let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": input, "mask": mask]))
        guard let filled = result.featureValue(for: "filled")?.multiArrayValue, filled.shape.map(\.intValue) == [1, 3, side, side] else { throw EditorError.render }
        let strides = filled.strides.map(\.intValue)
        var output = [Float](repeating: 0, count: plane * 3)
        func read<Value: BinaryFloatingPoint>(_ values: UnsafePointer<Value>) {
            for c in 0..<3 { for y in 0..<side { for x in 0..<side {
                output[c * plane + y * side + x] = NAFNetTiles.decode(Float(values[c * strides[1] + y * strides[2] + x * strides[3]])) / gain
            } } }
        }
        switch filled.dataType {
        case .float16: read(UnsafePointer(filled.dataPointer.assumingMemoryBound(to: Float16.self)))
        case .float32: read(UnsafePointer(filled.dataPointer.assumingMemoryBound(to: Float.self)))
        default: throw EditorError.render
        }
        return output
    }
}

extension RawRenderer {
    /// What the AI fill of Remove stroke `id` in `settings` is made from: the photo developed up to the stroke, with the
    /// strokes before it applied, at full resolution, in the cells `InpaintPlan` lays along it (`variant` for Refresh).
    public func prepareInpaint(_ id: UUID, settings: Adjustments, variant: Int = 0) throws -> InpaintJob {
        guard BundledModel.inpaint.isAvailable else {
            throw EditorError.invalidDocument(L10n.tr("The \(BundledModel.inpaint.feature) model is not installed. Install it in Settings › Models."))
        }
        guard let index = settings.retouch.firstIndex(where: { $0.id == id }), settings.retouch[index].mode == .remove else { throw EditorError.render }
        let stroke = settings.retouch[index]
        var earlier = settings
        earlier.retouch = Array(settings.retouch[..<index])
        let (developed, effective, _) = try beforeRetouch(earlier, maxDimension: nil)
        let base = try retouchRenderer.apply(effective.retouch, to: developed)
        let frame = base.extent, shorter = min(frame.width, frame.height)
        let bounds = RetouchRenderer.bounds(of: stroke, in: frame)
        guard !bounds.isEmpty else { throw EditorError.render }
        let footprint = try retouchRenderer.footprint(stroke, in: base)
        // How thick the stroke is, from its coverage at up to 1024 pixels across. Inside the frame only: past its edges
        // nothing is known, which `open` says.
        let coarse = min(1, 1024 / max(bounds.width, bounds.height)), area = bounds.insetBy(dx: -2, dy: -2).intersection(frame)
        let sampled = CGRect(x: floor(area.minX * coarse), y: floor(area.minY * coarse), width: ceil(area.width * coarse), height: ceil(area.height * coarse))
        var coverage = [Float](repeating: 0, count: Int(sampled.width) * Int(sampled.height))
        coverage.withUnsafeMutableBytes { context.render(footprint.transformed(by: CGAffineTransform(scaleX: coarse, y: coarse), highQualityDownsample: coarse < 1),
                                                         toBitmap: $0.baseAddress!, rowBytes: Int(sampled.width) * 4, bounds: sampled, format: .Rf, colorSpace: nil) }
        let thickness = InpaintPlan.thickness(coverage, width: Int(sampled.width), height: Int(sampled.height),
                                              open: (bounds.minX <= frame.minX, bounds.maxX >= frame.maxX, bounds.minY <= frame.minY, bounds.maxY >= frame.maxY)) / coarse
        guard var plan = InpaintPlan.plan(footprint: bounds, thickness: max(1, thickness), frame: frame, variant: variant) else {
            throw EditorError.invalidDocument(L10n.tr("This area is too large for an AI fill."))
        }
        let reach = RetouchRenderer.reach(radius: max(1, stroke.radius * shorter), thickness: thickness)
        let around = try retouchRenderer.surroundings(base, footprint: footprint, reach: reach)
        let place = CGAffineTransform(scaleX: plan.scale, y: plan.scale).translatedBy(x: -frame.minX, y: -frame.minY)
        func scaled(_ image: CIImage) -> CIImage {
            image.clampedToExtent().transformed(by: place, highQualityDownsample: plan.scale < 1)
                .cropped(to: CGRect(x: 0, y: 0, width: plan.width, height: plan.height)).insertingIntermediate(cache: true)
        }
        // Only the cells the stroke reaches into are filled: a diagonal wire crosses few of the cells around it.
        let covered = scaled(footprint), grow = Double(InpaintJob.grow)
        let cellArea = plan.cells.reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -grow, dy: -grow).intersection(CGRect(x: 0, y: 0, width: plan.width, height: plan.height))
        let columns = Int(cellArea.width), rows = Int(cellArea.height)
        var values = [Float](repeating: 0, count: columns * rows)
        values.withUnsafeMutableBytes { context.render(covered, toBitmap: $0.baseAddress!, rowBytes: columns * 4, bounds: cellArea, format: .Rf, colorSpace: nil) }
        plan.cells = plan.cells.filter { cell in
            let near = cell.insetBy(dx: -grow, dy: -grow).intersection(cellArea)
            // Rows top down from the area's top.
            for y in Int(cellArea.maxY - near.maxY)..<Int(cellArea.maxY - near.minY) {
                for x in Int(near.minX - cellArea.minX)..<Int(near.maxX - cellArea.minX) where values[y * columns + x] > 1e-4 { return true }
            }
            return false
        }
        guard !plan.cells.isEmpty else { throw EditorError.render }
        return InpaintJob(plan: plan, image: scaled(base), coverage: covered, surroundings: scaled(around), frame: frame,
                          reach: reach / shorter, footprint: RetouchFill.footprint(of: stroke))
    }

    /// One window of a job's images: the photo and its surroundings as red, green and blue planes, and the coverage, rows
    /// top down. Rendered here, so the job's windows take turns with previews.
    func inpaintPlanes(_ job: InpaintJob, window: CGRect) throws -> (image: [Float], coverage: [Float], surroundings: [Float]) {
        let side = InpaintPlan.side, plane = side * side
        func planes(_ image: CIImage, channels: Int) throws -> [Float] {
            var rgba = [Float](repeating: 0, count: plane * 4)
            rgba.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: side * 16, bounds: window, format: .RGBAf, colorSpace: nil) }
            try Task.checkCancellation()
            var result = [Float](repeating: 0, count: plane * channels)
            for i in 0..<plane { for c in 0..<channels { result[c * plane + i] = rgba[i * 4 + c] } }
            return result
        }
        return (try planes(job.image, channels: 3), try planes(job.coverage, channels: 1), try planes(job.surroundings, channels: 3))
    }
}
