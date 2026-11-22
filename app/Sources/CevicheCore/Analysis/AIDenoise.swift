import Foundation
import CoreImage
import CoreML

/// NAFNet-SIDD (megvii-research/NAFNet, MIT) over an image of any size, in the network's 512-pixel tiles.
/// The network's channel attention averages each tile as a whole (the converted model leaves out the paper's local
/// averaging, TLC), so every tile comes out with its own slight cast, which shows as blocks once a dark, flat sky is
/// brightened. So the tiles lie on one grid fixed to the image whatever region is rendered, overlap by an eighth and
/// cross-fade, and only the finer part of each tile's change is kept: the change less its blur over about 50 pixels.
/// Noise averages out over that distance, so what the network changes there on average is its cast, not the noise.
/// With the cast taken out that way, a 64-pixel overlap left no seam a quarter's did not, on night skies developed dark
/// and brightened 3 stops after (under 1 level in 8 bits at 99 % of pixels), for 28 % fewer tiles.
/// The network was trained on gamma-encoded sRGB, so linear working-space values are clamped and encoded on the way in
/// and decoded on the way out. Only the network's change is added back, so colors outside sRGB keep their saturation;
/// pixels brighter than SDR white keep their original values.
enum NAFNetTiles {
    static let tile = 512, overlap = 64
    /// Pixels at each edge of a tile that are left out: they see the padding past it.
    static let margin = 16
    /// The box blur, three times over, that finds the coarse part of the change: σ ≈ 48 pixels, wide enough to leave
    /// the network the blotches of colour noise and narrow enough to take out a cast that varies with the tile's content.
    static let blurRadius = 48
    static var step: Int { tile - overlap }
    typealias Network = (MLMultiArray) throws -> MLMultiArray

    /// RGBA pixels in memory, rows top down, placed on the tile grid: x to the right, y down.
    struct Pixels<Element> {
        var base: UnsafeMutablePointer<Element>
        /// Elements from one row to the next.
        var rowLength: Int
        var x: Int, y: Int, width: Int, height: Int
        /// The pixel at (x, y) on the grid, or the nearest edge pixel.
        func pixel(_ x: Int, _ y: Int) -> UnsafeMutablePointer<Element> {
            base + min(height - 1, max(0, y - self.y)) * rowLength + min(width - 1, max(0, x - self.x)) * 4
        }
    }

    /// A tile's weight along one axis: none in the margins, rising and falling over the rest of the overlap so that two
    /// neighbouring tiles' weights add up to one.
    static let weights: UnsafePointer<Float> = {
        // Kept for the life of the process: the loops read it from every core, which an array's reference count slows.
        let weights = UnsafeMutablePointer<Float>.allocate(capacity: tile)
        for t in 0..<tile {
            let ramp = Float(overlap - 2 * margin)
            let rising = (Float(t - margin) + 0.5) / ramp, falling = (Float(tile - margin - t) - 0.5) / ramp
            let s = sin(Float.pi / 2 * min(1, rising, falling))
            weights[t] = t < margin || t >= tile - margin ? 0 : s * s
        }
        return UnsafePointer(weights)
    }()

    /// The tiles along one axis whose weights reach into `pixels`; tile k starts at k × step.
    static func tiles(_ pixels: Range<Int>) -> ClosedRange<Int> {
        func floor(_ a: Int) -> Int { Int((Double(a) / Double(step)).rounded(.down)) }
        func ceil(_ a: Int) -> Int { Int((Double(a) / Double(step)).rounded(.up)) }
        return (floor(pixels.lowerBound - tile + margin) + 1)...(ceil(pixels.upperBound - margin) - 1)
    }
    /// The pixels those tiles read.
    static func reach(_ pixels: Range<Int>) -> Range<Int> {
        let tiles = tiles(pixels)
        return tiles.lowerBound * step ..< tiles.upperBound * step + tile
    }

    /// The installed model as `Network`s to run side by side: one on the Neural Engine (or whatever Core ML picks) and
    /// one on the GPU, which together get through the tiles about half again as fast as either alone.
    static func networks() throws -> [Network] {
        try [BundledModelCache.shared.model(.denoise), BundledModelCache.shared.gpuModel(.denoise)].map { model in
            { input in
                let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(multiArray: input)]))
                guard let denoised = result.featureValue(for: "denoised")?.multiArrayValue else { throw EditorError.render }
                return denoised
            }
        }
    }

    /// One tile on the grid: tile (column, row) covers x from column × step and y from row × step, `tile` pixels each way.
    struct Tile: Hashable, Sendable { let column: Int, row: Int }

    /// Denoises `target`'s pixels from `source`'s, which are read past their edges as the nearest edge pixel; `target`'s
    /// alpha is `source`'s. Each of `networks` takes the next tile when it is free, nearest `center` first when that is
    /// given, and `cache` keeps and supplies the tiles' changes. `tileDone` hears the tiles done and the total, and may
    /// throw to stop; until the end `target` holds the weighted sums, which `resolve` reads.
    static func run<Source: BinaryFloatingPoint>(_ source: Pixels<Source>, into target: Pixels<Float>, networks: [Network],
                                                 center: (x: Int, y: Int)? = nil, cache: NAFNetTileCache? = nil,
                                                 tileDone: (Int, Int) throws -> Void = { _, _ in }) throws {
        let columns = tiles(target.x ..< target.x + target.width), rows = tiles(target.y ..< target.y + target.height)
        var queue = rows.flatMap { row in columns.map { Tile(column: $0, row: row) } }
        if let center {
            func distance(_ tile: Tile) -> Int {
                let half = NAFNetTiles.tile / 2, dx = tile.column * step + half - center.x, dy = tile.row * step + half - center.y
                return dx * dx + dy * dy
            }
            queue.sort { distance($0) < distance($1) }
        }
        // Weighted sums of the tiles, with the weight in alpha until the end.
        for y in 0..<target.height { (target.base + y * target.rowLength).update(repeating: 0, count: target.width * 4) }
        // Lanes take tiles in turn; adding a tile to the sums and reporting it happen one at a time.
        let lock = NSLock(), total = queue.count
        var next = 0, done = 0, failure: Error?
        let lanes = min(networks.count, total)
        DispatchQueue.concurrentPerform(iterations: max(1, lanes)) { lane in
            do {
                let scratch = try Scratch()
                while let tile = lock.withLock({ () -> Tile? in
                    guard failure == nil, next < total else { return nil }
                    next += 1
                    return queue[next - 1]
                }) {
                    let change: [Float]
                    if let cached = cache?.change(tile) {
                        change = cached
                    } else {
                        change = try self.change(tile, source: source, network: networks[lane], scratch: scratch)
                        cache?.store(change, for: tile)
                    }
                    try lock.withLock {
                        guard failure == nil else { return }
                        change.withUnsafeBufferPointer { accumulate($0.baseAddress!, tile: tile, source: source, into: target) }
                        done += 1
                        try tileDone(done, total)
                    }
                }
            } catch {
                lock.withLock { if failure == nil { failure = error } }
            }
        }
        if let failure { throw failure }
        resolve(target, source: source, into: target)
    }

    /// The buffers a run reuses from tile to tile.
    final class Scratch {
        let input: MLMultiArray
        /// The change and the pixels counted in it, blurred: four planes.
        let coarse = UnsafeMutablePointer<Float>.allocate(capacity: 4 * tile * tile)
        /// Pixels brighter than white, which keep their values.
        let kept = UnsafeMutablePointer<Bool>.allocate(capacity: tile * tile)
        init() throws { input = try MLMultiArray(shape: [1, 3, NSNumber(value: tile), NSNumber(value: tile)], dataType: .float32) }
        deinit { coarse.deallocate(); kept.deallocate() }
    }

    /// The finer part of what the network changes in one tile: three planes of linear values over the tile, zero where
    /// pixels keep their values.
    static func change<Source: BinaryFloatingPoint>(_ tile: Tile, source: Pixels<Source>, network: Network, scratch: Scratch) throws -> [Float] {
        let left = tile.column * step, top = tile.row * step, plane = self.tile * self.tile, size = self.tile
        let values = scratch.input.dataPointer.assumingMemoryBound(to: Float.self)
        concurrentRows(size) { ty in
            for tx in 0..<size {
                let p = source.pixel(left + tx, top + ty), i = ty * size + tx
                values[i] = encode(Float(p[0])); values[plane + i] = encode(Float(p[1])); values[2 * plane + i] = encode(Float(p[2]))
            }
        }
        let output = try network(scratch.input)
        var change = [Float](repeating: 0, count: 3 * plane)
        let coarse = scratch.coarse, kept = scratch.kept
        try change.withUnsafeMutableBufferPointer { change in
            let change = change.baseAddress!
            // The network's output as decoded linear values, first into `coarse`.
            try decoded(output, into: coarse)
            // The change, and its blur; pixels the network leaves alone count for nothing in it.
            concurrentRows(size) { ty in
                for tx in 0..<size {
                    let p = source.pixel(left + tx, top + ty), i = ty * size + tx
                    let bright = p[0] > 1 || p[1] > 1 || p[2] > 1
                    for c in 0..<3 {
                        let d = bright ? 0 : coarse[c * plane + i] - min(1, max(0, Float(p[c])))
                        change[c * plane + i] = d; coarse[c * plane + i] = d
                    }
                    coarse[3 * plane + i] = bright ? 0 : 1; kept[i] = bright
                }
            }
            for c in 0..<4 { blur(coarse + c * plane) }
            concurrentRows(size) { ty in
                for i in (ty * size)..<((ty + 1) * size) {
                    let share = coarse[3 * plane + i]
                    for c in 0..<3 { change[c * plane + i] = kept[i] || share <= 0 ? 0 : change[c * plane + i] - coarse[c * plane + i] / share }
                }
            }
        }
        return change
    }

    /// Adds one tile's pixels, weighted, to the sums in `target`.
    static func accumulate<Source: BinaryFloatingPoint>(_ change: UnsafePointer<Float>, tile: Tile, source: Pixels<Source>, into target: Pixels<Float>) {
        let left = tile.column * step, top = tile.row * step, plane = self.tile * self.tile, size = self.tile
        let ys = max(target.y, top + margin)..<min(target.y + target.height, top + size - margin)
        let xs = max(target.x, left + margin)..<min(target.x + target.width, left + size - margin)
        guard !ys.isEmpty, !xs.isEmpty else { return }
        concurrentRows(ys.count) { row in
            let y = ys.lowerBound + row, ty = y - top, wy = weights[ty]
            let line = target.base + (y - target.y) * target.rowLength
            for x in xs {
                let tx = x - left, w = wy * weights[tx], i = ty * size + tx
                let p = source.pixel(x, y), out = line + (x - target.x) * 4
                for c in 0..<3 { out[c] += w * (Float(p[c]) + change[c * plane + i]) }
                out[3] += w
            }
        }
    }

    /// The pixels `run`'s sums in `target` stand for so far, written to `output` (which may be `target`): the weighted mean
    /// of the tiles done, or the source where none has reached yet, with the source's alpha.
    static func resolve<Source: BinaryFloatingPoint>(_ target: Pixels<Float>, source: Pixels<Source>, into output: Pixels<Float>) {
        concurrentRows(target.height) { y in
            let line = target.base + y * target.rowLength, outLine = output.base + y * output.rowLength
            for x in 0..<target.width {
                let sum = line + x * 4, out = outLine + x * 4, p = source.pixel(target.x + x, target.y + y), weight = sum[3]
                for c in 0..<3 { out[c] = weight > 0 ? sum[c] / weight : Float(p[c]) }
                out[3] = Float(p[3])
            }
        }
    }

    /// Runs `body` for each of `count` rows, spread over the cores in bands.
    static func concurrentRows(_ count: Int, _ body: (Int) -> Void) {
        let bands = min(count, ProcessInfo.processInfo.activeProcessorCount * 2)
        guard bands > 1 else { for row in 0..<count { body(row) }; return }
        DispatchQueue.concurrentPerform(iterations: bands) { band in
            for row in (count * band / bands)..<(count * (band + 1) / bands) { body(row) }
        }
    }

    /// Blurs a tile-sized plane in place, as if zero past its edges: a box `blurRadius` each way, three times, across
    /// and then down.
    private static func blur(_ plane: UnsafeMutablePointer<Float>) {
        let r = blurRadius, size = tile
        for (stride, lineStride) in [(1, size), (size, 1)] {
            concurrentRows(size) { line in
                let start = plane + line * lineStride
                withUnsafeTemporaryAllocation(of: Float.self, capacity: size) { scratch in
                    for _ in 0..<3 {
                        var sum: Float = 0
                        for i in 0..<r { sum += start[i * stride] }
                        for i in 0..<size {
                            if i + r < size { sum += start[(i + r) * stride] }
                            if i - r - 1 >= 0 { sum -= scratch[i - r - 1] }
                            scratch[i] = start[i * stride]
                            start[i * stride] = sum
                        }
                    }
                }
            }
        }
    }

    /// The network's [1, 3, tile, tile] output, whatever its type and strides, decoded to linear planes.
    private static func decoded(_ array: MLMultiArray, into planes: UnsafeMutablePointer<Float>) throws {
        let strides = array.strides.map(\.intValue), size = tile, plane = tile * tile
        let channelStride = strides[1], rowStride = strides[2], columnStride = strides[3]
        func copy<Value: BinaryFloatingPoint>(_ values: UnsafePointer<Value>) {
            concurrentRows(3 * size) { line in
                let c = line / size, y = line % size, row = values + c * channelStride + y * rowStride, out = planes + c * plane + y * size
                for x in 0..<size { out[x] = decode(Float(row[x * columnStride])) }
            }
        }
        switch array.dataType {
        case .float16: copy(UnsafePointer(array.dataPointer.assumingMemoryBound(to: Float16.self)))
        case .float32: copy(UnsafePointer(array.dataPointer.assumingMemoryBound(to: Float.self)))
        default: throw EditorError.render
        }
    }
    @inline(__always) static func encode(_ linear: Float) -> Float {
        let v = min(1, max(0, linear))
        return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }
    @inline(__always) static func decode(_ encoded: Float) -> Float {
        let v = min(1, max(0, encoded))
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
}

/// Tiles' changes kept while one photo is previewed, so moving the preview runs only the tiles it has not seen. The
/// changes depend on the pixels the tiles read, so a cache serves one image only. Kept as half floats, the oldest
/// forgotten first.
final class NAFNetTileCache: @unchecked Sendable {
    private let lock = NSLock()
    private var changes: [NAFNetTiles.Tile: [Float16]] = [:]
    private var order: [NAFNetTiles.Tile] = []
    /// About 1.5 MB a tile.
    let limit: Int
    init(limit: Int = 48) { self.limit = limit }
    func change(_ tile: NAFNetTiles.Tile) -> [Float]? {
        lock.withLock { changes[tile] }.map { $0.map(Float.init) }
    }
    func store(_ change: [Float], for tile: NAFNetTiles.Tile) {
        let half = change.map(Float16.init)
        lock.withLock {
            if changes.updateValue(half, forKey: tile) == nil { order.append(tile) }
            while order.count > limit { changes[order.removeFirst()] = nil }
        }
    }
}

/// `NAFNetTiles` as a Core Image processor: Core Image asks only for the region it renders, and gets the same pixels
/// there whichever regions it splits the image into.
final class NAFNetDenoiseKernel: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .RGBAf }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAf }
    override class var synchronizeInputs: Bool { true }
    /// A rect's columns and rows on the tile grid, which counts rows down from Core Image's y = 0.
    private static func grid(_ rect: CGRect) -> (x: Range<Int>, y: Range<Int>) {
        (Int(rect.minX.rounded(.down))..<Int(rect.maxX.rounded(.up)), -Int(rect.maxY.rounded(.up))..<(-Int(rect.minY.rounded(.down))))
    }
    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        let region = grid(outputRect)
        let x = NAFNetTiles.reach(region.x), y = NAFNetTiles.reach(region.y)
        return CGRect(x: x.lowerBound, y: -y.upperBound, width: x.count, height: y.count)
    }
    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        guard let input = inputs?.first else { return }
        // Both buffers run top down: their first row is the region's maxY.
        let from = grid(input.region), to = grid(output.region)
        let source = NAFNetTiles.Pixels(base: UnsafeMutablePointer(mutating: input.baseAddress.assumingMemoryBound(to: Float.self)), rowLength: input.bytesPerRow / 4,
                                        x: from.x.lowerBound, y: from.y.lowerBound, width: from.x.count, height: from.y.count)
        let target = NAFNetTiles.Pixels(base: output.baseAddress.assumingMemoryBound(to: Float.self), rowLength: output.bytesPerRow / 4,
                                        x: to.x.lowerBound, y: to.y.lowerBound, width: to.x.count, height: to.y.count)
        let run = arguments?[DenoiseRun.key] as? DenoiseRun
        try NAFNetTiles.run(source, into: target, networks: NAFNetTiles.networks(), cache: run?.cache) { _, _ in run?.tileDone() }
    }
    /// The denoised image, lazily evaluated by region.
    static func apply(to image: CIImage, run: DenoiseRun? = nil) throws -> CIImage {
        let region = grid(image.extent)
        run?.expect(NAFNetTiles.tiles(region.x).count * NAFNetTiles.tiles(region.y).count)
        return try apply(withExtent: image.extent, inputs: [image.clampedToExtent()], arguments: run.map { [DenoiseRun.key: $0] }).cropped(to: image.extent)
    }
}

/// What a render hands the network besides the pixels: the tiles kept from earlier renders of the same image, and
/// someone to hear how far it has got.
public final class DenoiseRun: @unchecked Sendable {
    static let key = "run"
    let cache: NAFNetTileCache?
    private let report: (@Sendable (Double) -> Void)?
    private let lock = NSLock()
    private var done = 0, total = 0
    /// `keepsTiles` keeps the tiles for the next render of the same image, as a preview wants; the caller makes a new
    /// run once the pixels going in change. `progress` hears the share of the tiles done, from any thread.
    public init(keepsTiles: Bool = false, progress: (@Sendable (Double) -> Void)? = nil) {
        // About 1.5 MB a tile: a 2200-pixel preview needs some 30.
        cache = keepsTiles ? NAFNetTileCache(limit: 160) : nil
        report = progress
    }
    func expect(_ tiles: Int) { lock.withLock { total += tiles } }
    func tileDone() {
        guard let report else { return }
        // Core Image may ask for a tile twice, for neighbouring regions.
        report(lock.withLock { done += 1; return total > 0 ? min(1, Double(done) / Double(total)) : 0 })
    }
}

extension NAFNetDenoiseKernel {
    /// Blends `amount` (0–100) of the NAFNet result over `image`; Core Image evaluates only the regions it renders.
    static func denoised(_ image: CIImage, amount: Double, run: DenoiseRun? = nil) throws -> CIImage {
        guard amount > 0, BundledModel.denoise.isAvailable else { return image }
        let denoised = try apply(to: image, run: run)
        let blend = min(1, amount / 100)
        return blend >= 1 ? denoised : image.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: denoised, kCIInputTimeKey: blend])
    }
}
