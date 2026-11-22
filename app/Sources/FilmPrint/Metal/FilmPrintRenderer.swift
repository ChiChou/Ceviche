#if canImport(Metal)
import Foundation
import Metal

/// Develops and prints a frame on the GPU. The frame is worked in tiles of a few megapixels, each with the apron its
/// spatial stages reach, so a frame of any size takes bounded memory; what the whole frame owns (its regional tone
/// measurement and the light its base returns as halation) is gathered over every tile first. A tile is the part of
/// the whole frame it would be in one piece: grain, the diffusing chemistry's grids and the halation grids are all
/// laid on the frame's own coordinates.
public final class FilmPrintRenderer: @unchecked Sendable {
    /// The renderer on this Mac's GPU; nil without one.
    public static let shared: FilmPrintRenderer? = MTLCreateSystemDefaultDevice().flatMap { FilmPrintRenderer(device: $0) }

    public let device: MTLDevice
    private let queue: MTLCommandQueue
    /// One development at a time: they share the working textures.
    private let lock = NSLock()
    private var states: [String: MTLComputePipelineState] = [:]
    private var library: MTLLibrary?
    private var textures: [TextureKey: MTLTexture] = [:]
    private var cubes: [(id: UInt64, exposure: MTLBuffer, film: MTLBuffer, paper: MTLBuffer)] = []

    /// CEVICHE_FILM_TRACE=1 prints where each development's time went.
    private static let traces = ProcessInfo.processInfo.environment["CEVICHE_FILM_TRACE"] != nil
    /// CEVICHE_FILM_TRACE=2 also runs each kernel on its own, for the GPU time each takes.
    private static let profiles = ProcessInfo.processInfo.environment["CEVICHE_FILM_TRACE"] == "2"
    private var spent: [(String, Double)] = []
    private func timed<Result>(_ what: String, _ body: () throws -> Result) rethrows -> Result {
        guard Self.traces else { return try body() }
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            if let index = spent.firstIndex(where: { $0.0 == what }) { spent[index].1 += seconds } else { spent.append((what, seconds)) }
        }
        return try body()
    }
    private func trace(_ width: Int, _ height: Int, tiles: Int) {
        guard Self.traces else { return }
        print("film \(width)x\(height) tiles \(tiles): " + spent.map { String(format: "%@ %.1f ms", $0.0, $0.1 * 1000) }.joined(separator: ", "))
        spent.removeAll()
    }

    /// Pixels a tile holds with its apron, unless a development says otherwise.
    public static let tilePixels = 4 << 20

    public init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.device = device; self.queue = queue
        queue.label = "Film print"
        // The working textures of the last development are kept for the next one, until memory is wanted elsewhere.
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        pressure.setEventHandler { [weak self] in self?.releaseCaches() }
        pressure.resume()
        self.pressure = pressure
    }
    private var pressure: DispatchSourceMemoryPressure?

    /// Compiles the kernels ahead of the first development: half a second the first time this version of them runs
    /// on a Mac, which the system then keeps.
    public func prepare() {
        lock.lock(); defer { lock.unlock() }
        guard (try? state("printKernel")) != nil, let names = library?.functionNames else { return }
        for name in names { _ = try? state(name) }
    }

    /// Gives back the working textures and the films' cubes, unless a development is using them right now.
    public func releaseCaches() {
        guard lock.try() else { return }
        textures.removeAll(); cubes.removeAll()
        lock.unlock()
    }

    // MARK: Developing

    /// Where a frame's pixels are: a texture on this renderer's device, or memory. Either way interleaved RGBA
    /// floats (`rgba32Float`), rows top first, at least the frame's size.
    public enum Pixels {
        case texture(MTLTexture)
        case memory(UnsafeMutableRawPointer, bytesPerRow: Int)
    }

    /// The colors a development is handed and hands back: the scene's linear RGB to linear Rec. 2020, which the film
    /// is exposed in, and the print's linear Display P3 to the picture's linear RGB. Rows of each matrix, in order.
    public struct Colors: Sendable {
        public var sceneToRec2020: [Float], pictureFromDisplayP3: [Float]
        public static let identity = Colors(sceneToRec2020: [1, 0, 0, 0, 1, 0, 0, 0, 1], pictureFromDisplayP3: [1, 0, 0, 0, 1, 0, 0, 0, 1])
        public init(sceneToRec2020: [Float], pictureFromDisplayP3: [Float]) {
            precondition(sceneToRec2020.count == 9 && pictureFromDisplayP3.count == 9)
            self.sceneToRec2020 = sceneToRec2020; self.pictureFromDisplayP3 = pictureFromDisplayP3
        }
    }

    /// Develops a frame of scene light on `stock` and finishes it as `options` say: `scene` to `picture`, which may
    /// not be the same pixels. With `options.stage == .print` the frame is a scanned negative's linear scan instead
    /// (`options.scanReading`), read as it is. Between two textures neither the scene nor the picture crosses to the
    /// CPU. False when the development can't be made or `shouldContinue` stopped it.
    @discardableResult
    public func develop(scene: Pixels, picture: Pixels, width: Int, height: Int, stock: FilmStock, options: FilmOptions,
                        colors: Colors = .identity, tilePixels: Int? = nil, shouldContinue: (() -> Bool)? = nil) -> Bool {
        for case .texture(let texture) in [scene, picture] {
            guard texture.pixelFormat == .rgba32Float, texture.width >= width, texture.height >= height, texture.device === device else { return false }
        }
        if case .texture(let from) = scene, case .texture(let to) = picture, from === to { return false }
        // Metal hands out its command buffers and encoders autoreleased: let go of here, not when the caller's pool
        // happens to drain.
        return autoreleasepool {
            develop(width: width, height: height, stock: stock, options: options, tilePixels: tilePixels, shouldContinue: shouldContinue,
                    transfer: Transfer(scene: scene, picture: picture, colors: colors))
        }
    }

    private struct Transfer {
        let scene: Pixels, picture: Pixels, colors: Colors
        var sceneTexture: MTLTexture? { if case .texture(let texture) = scene { return texture } else { return nil } }
        /// Whether nothing touches the CPU, so tiles can be queued without waiting for each.
        var staysOnGPU: Bool { if case .texture = scene, case .texture = picture { return true } else { return false } }
    }

    private func develop(width: Int, height: Int, stock: FilmStock, options: FilmOptions, tilePixels: Int?,
                         shouldContinue: (() -> Bool)?, transfer: Transfer) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard width > 0, height > 0,
              var plan = timed("plan", { try? FilmPlan(stock: stock, options: options, width: width, height: height) }) else { return false }
        do {
            let stopped = { shouldContinue.map { !$0() } ?? false }
            let budget = max(tilePixels ?? Self.tilePixels, 1 << 16)
            let scans = plan.features & FilmFeature.densityIn != 0
            if plan.sceneMeteringActive, !scans {
                try timed("meter") { try meter(&plan, width: width, height: height, budget: budget, stopped: stopped, transfer: transfer) }
                if stopped() { return false }
            }
            let frame = try timed("tables") { try Frame(plan: plan, width: width, height: height, colors: transfer.colors, renderer: self) }
            let layout = TileLayout(width: width, height: height, apron: frame.apron, budget: budget)
            let work = try timed("textures") { try workingTextures(width: layout.tileWidth, height: layout.tileHeight, frame: frame) }
            defer { trace(width, height, tiles: layout.count) }
            // With textures at both ends nothing waits on the GPU until the last tile is in.
            var pending: MTLCommandBuffer?
            func submit(_ commands: MTLCommandBuffer) throws {
                if transfer.staysOnGPU { commands.commit(); pending = commands } else { try timed("gpu") { try finish(commands) } }
            }
            // The light the film's base returns comes from the whole frame: every tile's light, on the frame's grid.
            var light: MTLTexture?
            if frame.has(FilmFeature.halation), !scans {
                for tile in layout.tiles(apron: frame.lightApron) {
                    if stopped() { break }
                    let commands = try commandBuffer()
                    try load(tile, into: work.scene, transfer: transfer, commands)
                    try encodeLight(tile, frame: frame, work: work, into: commands)
                    try frame.encodeHalationSeed(tile, light: work.scene, renderer: self, into: commands)
                    try submit(commands)
                }
                let commands = try commandBuffer()
                try frame.encodeHalationGrids(renderer: self, into: commands)
                try submit(commands)
                if layout.count == 1 { light = work.scene }
            }
            var complete = true
            for tile in layout.tiles(apron: frame.apron) {
                if stopped() { complete = false; break }
                let commands = try commandBuffer()
                if scans {
                    try load(tile, into: work.scene, transfer: transfer, commands)
                    try encode("scanDensityKernel", commands, textures: [work.scene, work.a], buffers: [frame.uniforms(tile), frame.configuration], size: tile.size)
                } else {
                    if light == nil {
                        try load(tile, into: work.scene, transfer: transfer, commands)
                        try encodeLight(tile, frame: frame, work: work, into: commands)
                    }
                    try encode("logExposureKernel", commands,
                               textures: [work.scene, work.donor ?? work.scene, frame.halation[0], frame.halation[1], frame.halation[2], work.a],
                               buffers: [frame.uniforms(tile), frame.configuration], size: tile.size)
                }
                try frame.encodeDevelopment(tile, work: work, renderer: self, into: commands)
                switch transfer.picture {
                case .texture(let picture):
                    try copy(work.scene, from: (tile.interiorColumns.lowerBound - tile.columns.lowerBound, tile.interiorRows.lowerBound - tile.rows.lowerBound),
                             size: (tile.interiorColumns.count, tile.interiorRows.count), to: picture, at: (tile.interiorColumns.lowerBound, tile.interiorRows.lowerBound), commands)
                    try submit(commands)
                case .memory(let pointer, let bytesPerRow):
                    synchronize(work.scene, commands)
                    try submit(commands)
                    timed("read") {
                        work.scene.getBytes(pointer + tile.interiorRows.lowerBound * bytesPerRow + tile.interiorColumns.lowerBound * 16, bytesPerRow: bytesPerRow,
                                            from: MTLRegionMake2D(tile.interiorColumns.lowerBound - tile.columns.lowerBound, tile.interiorRows.lowerBound - tile.rows.lowerBound,
                                                                  tile.interiorColumns.count, tile.interiorRows.count), mipmapLevel: 0)
                    }
                }
            }
            // A picture the CPU will read back from a discrete GPU is brought across once it is whole.
            if case .texture(let picture) = transfer.picture, picture.storageMode != .shared, complete {
                let commands = try commandBuffer()
                synchronize(picture, commands)
                commands.commit(); pending = commands
            }
            if let pending {
                timed("gpu") { pending.waitUntilCompleted() }
                if pending.status != .completed { return false }
            }
            return complete
        } catch {
            return false
        }
    }

    /// A tile of the scene into the working texture the kernels read it from.
    private func load(_ tile: Tile, into texture: MTLTexture, transfer: Transfer, _ commands: MTLCommandBuffer) throws {
        switch transfer.scene {
        case .texture(let scene):
            try copy(scene, from: (tile.columns.lowerBound, tile.rows.lowerBound), size: tile.size, to: texture, at: (0, 0), commands)
        case .memory(let pointer, let bytesPerRow):
            timed("upload") {
                texture.replace(region: MTLRegionMake2D(0, 0, tile.width, tile.height), mipmapLevel: 0,
                                withBytes: pointer + tile.rows.lowerBound * bytesPerRow + tile.columns.lowerBound * 16, bytesPerRow: bytesPerRow)
            }
        }
    }

    private func copy(_ source: MTLTexture, from origin: (Int, Int), size: (Int, Int), to target: MTLTexture, at point: (Int, Int), _ commands: MTLCommandBuffer) throws {
        guard let blit = commands.makeBlitCommandEncoder() else { throw Failure.commands }
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: origin.0, y: origin.1, z: 0), sourceSize: MTLSize(width: size.0, height: size.1, depth: 1),
                  to: target, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: point.0, y: point.1, z: 0))
        blit.endEncoding()
    }

    /// Scene light to the light on the film: the exposure of each record, then the emulsion's own spread. Leaves it
    /// in the scene's texture.
    private func encodeLight(_ tile: Tile, frame: Frame, work: Working, into commands: MTLCommandBuffer) throws {
        let uniforms = frame.uniforms(tile)
        let exposure = frame.has(FilmFeature.mtf) ? work.a : work.b
        try encode("exposeKernel", commands, textures: [work.scene, exposure, work.donor ?? exposure],
                   buffers: [uniforms, frame.configuration, frame.exposureCube], size: tile.size)
        if frame.has(FilmFeature.mtf) {
            var blur = BlurUniforms(width: Int32(tile.width), height: Int32(tile.height), radius: Int32(frame.spread.radius), vertical: 0, weights: Int32(frame.spread.offset))
            try encode("spreadKernel", commands, textures: [work.a, work.b, work.c], buffers: [bytes(&blur), frame.weights], size: tile.size)
            try encode("spreadMixKernel", commands, textures: [work.b, work.c, work.scene], buffers: [bytes(&blur), frame.weights, uniforms, frame.configuration], size: tile.size)
        } else {
            // The exposure is the light: back into the scene's texture, where the next stage reads it.
            try copy(work.b, from: (0, 0), size: tile.size, to: work.scene, at: (0, 0), commands)
        }
    }

    // MARK: Metering

    /// The whole frame's regional brightness, which Auto Levels, Lab Scan and the tone controls are placed by:
    /// measured on the GPU, in bands where the scene comes from the CPU, and solved into the plan.
    private func meter(_ plan: inout FilmPlan, width: Int, height: Int, budget: Int, stopped: () -> Bool, transfer: Transfer) throws {
        var measurement = plan.toneBaseMeasurement()
        let grid = measurement.gridWidth
        // Bands as wide as the frame where a texture can be; otherwise cut where the grid's columns meet.
        let limit = 16384
        var chunks: [(lanes: Range<Int>, columns: Range<Int>)] = []
        func start(_ lane: Int) -> Int { min((lane * width + grid - 1) / grid, width) }
        var lane = 0
        while lane < grid {
            var end = lane + 1
            while end < grid, start(end + 1) - start(lane) <= limit { end += 1 }
            chunks.append((lane..<end, start(lane)..<start(end)))
            lane = end
        }
        let widest = chunks.map(\.columns.count).max() ?? width
        // A scene already in a texture is measured in place, all its rows at once.
        let bandRows = transfer.sceneTexture == nil ? max(1, min(height, budget / max(widest, 1))) : height
        let band = try transfer.sceneTexture ?? texture(width: widest, height: bandRows, format: .rgba32Float, slot: 0)
        let sums = try texture(width: grid, height: bandRows, format: .rgba32Float, slot: 9)
        let gain = plan.configuration[Slot.exposureGain] / 0.18
        let luma = ColorScience.luminanceWeights
        let m = transfer.colors.sceneToRec2020
        var uniforms = MeterUniforms(width: Int32(width), rows: 0, gridWidth: Int32(grid), firstLane: 0, lanes: 0, firstColumn: 0,
                                     scene: (m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8]),
                                     weights: (luma.0 * gain, luma.1 * gain, luma.2 * gain, gain, 0, 0, 0, gain, 0, 0, 0, gain))
        var lanes = [Float](repeating: 0, count: grid * bandRows * 4), plane = [Float](repeating: 0, count: grid * bandRows)
        var row = 0
        while row < height {
            if stopped() { return }
            let rows = row..<min(height, row + bandRows)
            for chunk in chunks {
                if case .memory(let pointer, let bytesPerRow) = transfer.scene {
                    band.replace(region: MTLRegionMake2D(0, 0, chunk.columns.count, rows.count), mipmapLevel: 0,
                                 withBytes: pointer + rows.lowerBound * bytesPerRow + chunk.columns.lowerBound * 16, bytesPerRow: bytesPerRow)
                }
                uniforms.rows = Int32(rows.count); uniforms.firstLane = Int32(chunk.lanes.lowerBound); uniforms.lanes = Int32(chunk.lanes.count)
                uniforms.firstColumn = transfer.sceneTexture == nil ? Int32(chunk.columns.lowerBound) : 0
                let commands = try commandBuffer()
                try encode("meterKernel", commands, textures: [band, sums], buffers: [bytes(&uniforms)], size: (chunk.lanes.count, rows.count))
                synchronize(sums, commands)
                try finish(commands)
                lanes.withUnsafeMutableBytes {
                    sums.getBytes($0.baseAddress! + chunk.lanes.lowerBound * 16, bytesPerRow: grid * 16,
                                  from: MTLRegionMake2D(chunk.lanes.lowerBound, 0, chunk.lanes.count, rows.count), mipmapLevel: 0)
                }
            }
            for meter in 0..<(measurement.metersColour ? 4 : 1) {
                for i in 0..<(grid * rows.count) { plane[i] = lanes[i * 4 + meter] }
                if meter == 0 { measurement.add(cellRowSums: plane, rows: rows) } else { measurement.add(channel: meter - 1, cellRowSums: plane, rows: rows) }
            }
            row = rows.upperBound
        }
        plan.setToneBase(measurement)
    }

    // MARK: Tiles and transfers

    struct Tile {
        /// What the tile reads, apron included, and the part of it that is delivered, in frame pixels.
        let columns: Range<Int>, rows: Range<Int>, interiorColumns: Range<Int>, interiorRows: Range<Int>
        var width: Int { columns.count }
        var height: Int { rows.count }
        var size: (Int, Int) { (columns.count, rows.count) }
    }

    struct TileLayout {
        let width: Int, height: Int
        /// The interior of a tile, and the most a tile takes with its apron.
        let stepX: Int, stepY: Int, tileWidth: Int, tileHeight: Int
        var count: Int { ((width + stepX - 1) / stepX) * ((height + stepY - 1) / stepY) }

        init(width: Int, height: Int, apron: Int, budget: Int) {
            self.width = width; self.height = height
            if width * height <= budget {
                stepX = width; stepY = height
            } else {
                // Even bands, as wide as the frame where that leaves them rows enough; cut edges fall on a 64-pixel
                // lattice, which every frame-anchored grid divides.
                func even(_ length: Int, parts: Int) -> Int { parts == 1 ? length : min(length, ((length + parts - 1) / parts + 63) / 64 * 64) }
                var across = 1
                while even(width, parts: across) > 64,
                      even(width, parts: across) + 2 * apron > 4096 || budget / (even(width, parts: across) + 2 * apron) < 256 + 2 * apron { across += 1 }
                stepX = even(width, parts: across)
                let rows = max(64, budget / (stepX + 2 * apron) - 2 * apron)
                stepY = even(height, parts: (height + rows - 1) / rows)
            }
            tileWidth = min(width, stepX + 2 * apron); tileHeight = min(height, stepY + 2 * apron)
        }
        func tiles(apron: Int) -> [Tile] {
            var result: [Tile] = []
            for top in stride(from: 0, to: height, by: stepY) {
                for left in stride(from: 0, to: width, by: stepX) {
                    let columns = left..<min(width, left + stepX), rows = top..<min(height, top + stepY)
                    result.append(Tile(columns: max(0, columns.lowerBound - apron)..<min(width, columns.upperBound + apron),
                                       rows: max(0, rows.lowerBound - apron)..<min(height, rows.upperBound + apron), interiorColumns: columns, interiorRows: rows))
                }
            }
            return result
        }
    }

    // MARK: Metal plumbing

    struct Working {
        /// The scene as uploaded; then the light on the film; at the end the picture.
        let scene: MTLTexture
        let a: MTLTexture, b: MTLTexture, c: MTLTexture
        /// A donor layer's exposure, for the stocks that have one.
        let donor: MTLTexture?
        /// The grain's seed field and its mottle, with the scratch each blurs through.
        let grain: [MTLTexture], mottle: [MTLTexture]
    }

    private func workingTextures(width: Int, height: Int, frame: Frame) throws -> Working {
        let float = MTLPixelFormat.rgba32Float, half = MTLPixelFormat.rgba16Float
        return Working(scene: try texture(width: width, height: height, format: float, slot: 0),
                       a: try texture(width: width, height: height, format: float, slot: 1),
                       b: try texture(width: width, height: height, format: float, slot: 2),
                       c: try texture(width: width, height: height, format: float, slot: 3),
                       donor: frame.has(FilmFeature.donorLayer) ? try texture(width: width, height: height, format: .r32Float, slot: 4) : nil,
                       grain: frame.has(FilmFeature.grain) ? [try texture(width: width, height: height, format: half, slot: 5), try texture(width: width, height: height, format: half, slot: 6)] : [],
                       mottle: frame.has(FilmFeature.grainMottle) ? [try texture(width: width, height: height, format: half, slot: 7), try texture(width: width, height: height, format: half, slot: 8)] : [])
    }

    private struct TextureKey: Hashable { let format: UInt, slot: Int }

    /// A working texture of at least this size, kept for the next tile and the next development: the kernels are
    /// told the extent they work in. `slot` tells apart the textures one development holds at once.
    func texture(width: Int, height: Int, format: MTLPixelFormat, slot: Int) throws -> MTLTexture {
        let key = TextureKey(format: format.rawValue, slot: slot)
        if let found = textures[key], found.width >= width, found.height >= height { return found }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: max(width, textures[key]?.width ?? 1), height: max(height, textures[key]?.height ?? 1), mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = storageMode
        textures[key] = nil
        guard let made = device.makeTexture(descriptor: descriptor) else { throw Failure.memory }
        textures[key] = made
        return made
    }

    enum Failure: Error { case kernel(String), memory, commands }

    private func state(_ name: String) throws -> MTLComputePipelineState {
        if let found = states[name] { return found }
        if library == nil {
            let options = MTLCompileOptions()
            // The film's arithmetic as written: densities are differences of large logarithms.
            options.mathMode = .safe
            library = try device.makeLibrary(source: FilmKernels.source, options: options)
        }
        guard let function = library?.makeFunction(name: name) else { throw Failure.kernel(name) }
        let made = try device.makeComputePipelineState(function: function)
        states[name] = made
        return made
    }

    func commandBuffer() throws -> MTLCommandBuffer {
        guard let commands = queue.makeCommandBuffer() else { throw Failure.commands }
        return commands
    }
    func finish(_ commands: MTLCommandBuffer) throws {
        commands.commit(); commands.waitUntilCompleted()
        if commands.status != .completed { throw Failure.commands }
    }
    /// Textures the CPU can fill and read: shared with the GPU where memory is, kept in step with a discrete GPU's
    /// copy otherwise.
    private var storageMode: MTLStorageMode {
        #if os(macOS)
        return device.hasUnifiedMemory ? .shared : .managed
        #else
        return .shared
        #endif
    }
    /// A texture for a whole frame's scene or picture, as `develop` takes them; one that Core Image can draw into.
    public func makeFrameTexture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = storageMode
        return device.makeTexture(descriptor: descriptor)
    }
    /// Brings a texture the CPU is about to read back from a discrete GPU.
    func synchronize(_ texture: MTLTexture, _ commands: MTLCommandBuffer) {
        #if os(macOS)
        guard texture.storageMode == .managed, let blit = commands.makeBlitCommandEncoder() else { return }
        blit.synchronize(resource: texture); blit.endEncoding()
        #endif
    }

    enum Argument { case buffer(MTLBuffer), bytes(Data) }
    func bytes<Value>(_ value: inout Value) -> Argument { .bytes(Data(bytes: &value, count: MemoryLayout<Value>.stride)) }

    /// One kernel over `size` threads: its textures and buffers in the order it declares them.
    func encode(_ name: String, _ commands: MTLCommandBuffer, textures: [MTLTexture], buffers: [Argument], size: (Int, Int)) throws {
        let state = try state(name)
        let alone = Self.profiles ? try commandBuffer() : nil
        guard let encoder = (alone ?? commands).makeComputeCommandEncoder() else { throw Failure.commands }
        encoder.label = name
        encoder.setComputePipelineState(state)
        for (index, texture) in textures.enumerated() { encoder.setTexture(texture, index: index) }
        for (index, argument) in buffers.enumerated() {
            switch argument {
            case .buffer(let buffer): encoder.setBuffer(buffer, offset: 0, index: index)
            case .bytes(let data): data.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: data.count, index: index) }
            }
        }
        let wide = state.threadExecutionWidth, tall = max(1, state.maxTotalThreadsPerThreadgroup / wide)
        encoder.dispatchThreads(MTLSize(width: max(size.0, 1), height: max(size.1, 1), depth: 1), threadsPerThreadgroup: MTLSize(width: wide, height: tall, depth: 1))
        encoder.endEncoding()
        if let alone {
            alone.commit(); alone.waitUntilCompleted()
            let seconds = alone.gpuEndTime - alone.gpuStartTime
            if let index = spent.firstIndex(where: { $0.0 == name }) { spent[index].1 += seconds } else { spent.append((name, seconds)) }
        }
    }

    func buffer(_ values: [Float]) throws -> MTLBuffer {
        guard let made = values.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: max($0.count, 16), options: .storageModeShared) }) else { throw Failure.memory }
        return made
    }

    /// A film's three cubes on the GPU, kept for the developments that follow with the same film and medium.
    func cubeBuffers(_ plan: FilmPlan) throws -> (exposure: MTLBuffer, film: MTLBuffer, paper: MTLBuffer) {
        if let index = cubes.firstIndex(where: { $0.id == plan.spectralCacheID }) {
            let found = cubes.remove(at: index)
            cubes.insert(found, at: 0)
            return (found.exposure, found.film, found.paper)
        }
        let film = try buffer(plan.spectral.filmOutput.values)
        let made = (id: plan.spectralCacheID, exposure: try buffer(plan.spectral.exposure.values), film: film,
                    paper: try plan.spectral.paperOutput.map { try buffer($0.values) } ?? film)
        cubes.insert(made, at: 0)
        if cubes.count > 12 { cubes.removeLast() }
        return (made.exposure, made.film, made.paper)
    }
}

struct BlurUniforms { var width, height, radius, vertical, weights: Int32 }
struct DecimateUniforms { var width, height, targetX, targetY, sourceWidth, sourceHeight, factor, shiftX, shiftY: Int32 }
struct FieldUniforms { var width, height, sourceWidth, sourceHeight, stride, phaseX, phaseY, activation: Int32 }
struct MeterUniforms {
    var width, rows, gridWidth, firstLane, lanes, firstColumn: Int32
    var scene: (Float, Float, Float, Float, Float, Float, Float, Float, Float)
    var weights: (Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float)
}
struct TileUniforms {
    var width, height, originX, originY: Int32
    var features, seed: UInt32
    var halationStride: (Int32, Int32, Int32) = (1, 1, 1), halationWidth: (Int32, Int32, Int32) = (1, 1, 1), halationHeight: (Int32, Int32, Int32) = (1, 1, 1)
    var fieldStride: (Int32, Int32, Int32, Int32) = (1, 1, 1, 1), fieldPhaseX: (Int32, Int32, Int32, Int32) = (0, 0, 0, 0), fieldPhaseY: (Int32, Int32, Int32, Int32) = (0, 0, 0, 0)
    var fieldWidth: (Int32, Int32, Int32, Int32) = (1, 1, 1, 1), fieldHeight: (Int32, Int32, Int32, Int32) = (1, 1, 1, 1)
    var fringeRadius: Int32 = 0
    var grainLambda: Float = 0, mottleLambda: Float = 0
    var sceneMatrix: (Float, Float, Float, Float, Float, Float, Float, Float, Float) = (1, 0, 0, 0, 1, 0, 0, 0, 1)
    var pictureMatrix: (Float, Float, Float, Float, Float, Float, Float, Float, Float) = (1, 0, 0, 0, 1, 0, 0, 0, 1)
}
#endif
