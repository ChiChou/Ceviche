#if canImport(Metal)
import Foundation
import Metal

extension FilmPrintRenderer {
    /// What one development holds on the GPU for every tile of its frame: the packed configuration, the film's
    /// cubes and tabulated curves, the weights of every blur, and the whole frame's halation grids.
    final class Frame {
        let features: UInt32, seed: UInt32
        let configuration: Argument, exposureCube: Argument, filmCube: Argument, paperCube: Argument
        let filmCurves: Argument, paperCurves: Argument, weights: Argument
        /// Pixels of surrounding frame a tile needs for its interior to develop as it does in the whole frame, and
        /// what the light alone needs.
        let apron: Int, lightApron: Int

        struct Kernel { let offset: Int, radius: Int }
        /// The emulsion's spread: its primary weights, then its second scale's, each `2 * radius + 1` taps.
        let spread: Kernel
        private let grainBlur: Kernel, mottleBlur: Kernel, printBlur: Kernel
        private let halationBlur: [Kernel]
        private let halationStride: [Int], halationSize: [(Int, Int)]
        /// The light the base returns, at the three scales it spreads over: the frame's light on grids of the
        /// frame, blurred.
        private(set) var halation: [MTLTexture] = []
        private var halationScratch: [MTLTexture] = []

        /// A diffusing field of the development: what it blurs on, by how much, and which of the tile's field
        /// slots it fills.
        private struct Field { let index: Int, stride: Int, activation: Bool, blur: Kernel }
        private let fields: [Field]
        private let fringeRadius: Int
        private let grainLambda: Float, mottleLambda: Float
        private let colors: Colors

        func has(_ feature: UInt32) -> Bool { features & feature != 0 }

        init(plan: FilmPlan, width: Int, height: Int, colors: Colors, renderer: FilmPrintRenderer) throws {
            self.colors = colors
            let cfg = plan.configuration
            features = plan.features; seed = plan.seed
            let features = features
            func on(_ feature: UInt32) -> Bool { features & feature != 0 }
            configuration = .buffer(try renderer.buffer(cfg))
            let cubes = try renderer.cubeBuffers(plan)
            exposureCube = .buffer(cubes.exposure); filmCube = .buffer(cubes.film); paperCube = .buffer(cubes.paper)
            filmCurves = .buffer(try renderer.buffer(Self.filmCurveTable(cfg)))
            paperCurves = .buffer(try renderer.buffer(Self.paperCurveTable(cfg)))
            apron = plan.spatialSupportSansHalation + 1; lightApron = plan.lightSupport + 1

            func sigma(_ slot: Int) -> Float { max(cfg[slot], 0.151) }
            func radius(_ slot: Int) -> Int { max(0, Int(cfg[slot])) }
            var table: [Float] = []
            func add(_ taps: [SIMD4<Float>], radius: Int) -> Kernel {
                let kernel = Kernel(offset: table.count / 4, radius: radius)
                for tap in taps { table += [tap.x, tap.y, tap.z, tap.w] }
                return kernel
            }

            // The emulsion's spread: each record at its own width with their neutral at the luminance width inside
            // its own window, then the records at their second widths.
            let mtfRadius = max(radius(Slot.mtfRadius), radius(Slot.mtfRadius + 1), radius(Slot.mtfRadius + 2))
            let lumaRadius = max(radius(Slot.mtfLumaRadius), radius(Slot.mtfSecondaryRadius), radius(Slot.mtfSecondaryRadius + 1), radius(Slot.mtfSecondaryRadius + 2))
            let profile = on(FilmFeature.mtfLuma)
            let spreadRadius = profile ? max(mtfRadius, lumaRadius) : mtfRadius
            let primary = Self.gaussian(sigmas: [sigma(Slot.mtfSigma), sigma(Slot.mtfSigma + 1), sigma(Slot.mtfSigma + 2), sigma(Slot.mtfLumaSigma)],
                                        windows: [mtfRadius, mtfRadius, mtfRadius, profile ? lumaRadius : mtfRadius], radius: spreadRadius)
            let secondary = Self.gaussian(sigmas: (0..<3).map { sigma(Slot.mtfSecondarySigma + $0) } + [1], windows: [lumaRadius, lumaRadius, lumaRadius, 0], radius: spreadRadius)
            spread = add(primary + secondary, radius: spreadRadius)

            // Halation rides a pyramid of box-averaged grids, each blurred by three passes of a box.
            let halationRadii = (0..<3).map { radius(Slot.halationRadius + $0) }
            let strides = halationRadii.map { Int(GridGeometry.halationStride(Int32($0))) }
            halationStride = strides
            halationSize = strides.map { ((width + $0 - 1) / $0, (height + $0 - 1) / $0) }
            var boxes: [Kernel] = []
            for scale in 0..<3 {
                let reach = Int(GridGeometry.halationStridedRadius(Int32(halationRadii[scale]), Int32(strides[scale])))
                boxes.append(add(Self.tripleBox(radius: reach), radius: 3 * reach))
            }
            halationBlur = boxes

            // The chemistry that diffuses over many pixels blurs on grids anchored to the frame.
            func field(_ index: Int, sigma: Float, radius: Int, activation: Bool) -> Field {
                let stride = Int(GridGeometry.fieldStride(sigma))
                let gridSigma = stride == 1 ? sigma : max(sigma * sigma / Float(stride * stride) - 0.25, 0.0625).squareRoot()
                let gridRadius = max((radius + stride - 1) / stride, 1)
                return Field(index: index, stride: stride, activation: activation,
                             blur: add(Self.gaussian(sigmas: [gridSigma, gridSigma, gridSigma, gridSigma], windows: [gridRadius, gridRadius, gridRadius, gridRadius], radius: gridRadius), radius: gridRadius))
            }
            var fields: [Field] = []
            let fringe = radius(Slot.chromaticFringeRadius)
            if on(FilmFeature.couplerDiffusion), on(FilmFeature.couplers) || on(FilmFeature.donorLayer) {
                fields.append(field(0, sigma: sigma(Slot.couplerSigma), radius: radius(Slot.couplerRadius), activation: false))
                if on(FilmFeature.couplers), fringe > 0 { fields.append(field(1, sigma: sigma(Slot.chromaticFringeSigma), radius: fringe, activation: false)) }
            }
            if on(FilmFeature.adjacency) {
                fields.append(field(2, sigma: sigma(Slot.adjacencySigma), radius: radius(Slot.adjacencyRadius), activation: true))
                if cfg[Slot.adjacencyModel] > 0.5 {
                    fields.append(field(3, sigma: sigma(Slot.adjacencySecondarySigma), radius: radius(Slot.adjacencySecondaryRadius), activation: true))
                }
            }
            self.fields = fields
            fringeRadius = fringe

            // Grain: one seed field a layer (one in all for black-and-white), each blurred to its clump size.
            let mono = on(FilmFeature.monochrome)
            func layers(_ slot: Int) -> [Float] { (0..<3).map { cfg[slot + (mono ? 0 : $0)] } + [1] }
            let grainRadius = radius(Slot.grainRadius), mottleRadius = radius(Slot.mottleRadius)
            grainBlur = add(Self.gaussian(sigmas: layers(Slot.grainSigmaLayer), windows: [Int](repeating: grainRadius, count: 4), radius: grainRadius), radius: grainRadius)
            mottleBlur = add(Self.gaussian(sigmas: layers(Slot.mottleSigmaLayer), windows: [Int](repeating: mottleRadius, count: 4), radius: mottleRadius), radius: mottleRadius)
            grainLambda = cfg[Slot.grainLambda]; mottleLambda = cfg[Slot.mottleLambda]

            let printRadius = radius(Slot.printMtfRadius), printSigma = cfg[Slot.printMtfSigma]
            printBlur = add(Self.gaussian(sigmas: [Float](repeating: printSigma, count: 4), windows: [Int](repeating: printRadius, count: 4), radius: printRadius), radius: printRadius)
            weights = .buffer(try renderer.buffer(table))

            let scans = on(FilmFeature.densityIn)
            if on(FilmFeature.halation), !scans {
                for scale in 0..<3 {
                    halation.append(try renderer.texture(width: halationSize[scale].0, height: halationSize[scale].1, format: .rgba32Float, slot: 20 + scale))
                    halationScratch.append(try renderer.texture(width: halationSize[scale].0, height: halationSize[scale].1, format: .rgba32Float, slot: 23 + scale))
                }
            } else {
                let unused = try renderer.texture(width: 1, height: 1, format: .rgba32Float, slot: 20)
                halation = [unused, unused, unused]
            }
        }

        /// The tile's uniforms: where it sits, and how each grid it reads lies over it.
        func uniforms(_ tile: Tile) -> Argument {
            var u = TileUniforms(width: Int32(tile.width), height: Int32(tile.height), originX: Int32(tile.columns.lowerBound), originY: Int32(tile.rows.lowerBound),
                                 features: features, seed: seed)
            u.halationStride = (Int32(halationStride[0]), Int32(halationStride[1]), Int32(halationStride[2]))
            u.halationWidth = (Int32(halationSize[0].0), Int32(halationSize[1].0), Int32(halationSize[2].0))
            u.halationHeight = (Int32(halationSize[0].1), Int32(halationSize[1].1), Int32(halationSize[2].1))
            var stride = [Int32](repeating: 1, count: 4), phaseX = [Int32](repeating: 0, count: 4), phaseY = phaseX, gridWidth = stride, gridHeight = stride
            for field in fields {
                let size = Self.grid(tile, stride: field.stride)
                stride[field.index] = Int32(field.stride)
                phaseX[field.index] = Int32(tile.columns.lowerBound % field.stride); phaseY[field.index] = Int32(tile.rows.lowerBound % field.stride)
                gridWidth[field.index] = Int32(size.0); gridHeight[field.index] = Int32(size.1)
            }
            u.fieldStride = (stride[0], stride[1], stride[2], stride[3])
            u.fieldPhaseX = (phaseX[0], phaseX[1], phaseX[2], phaseX[3]); u.fieldPhaseY = (phaseY[0], phaseY[1], phaseY[2], phaseY[3])
            u.fieldWidth = (gridWidth[0], gridWidth[1], gridWidth[2], gridWidth[3]); u.fieldHeight = (gridHeight[0], gridHeight[1], gridHeight[2], gridHeight[3])
            u.fringeRadius = Int32(fringeRadius)
            u.grainLambda = grainLambda; u.mottleLambda = mottleLambda
            let s = colors.sceneToRec2020, p = colors.pictureFromDisplayP3
            u.sceneMatrix = (s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7], s[8]); u.pictureMatrix = (p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7], p[8])
            return .bytes(Data(bytes: &u, count: MemoryLayout<TileUniforms>.stride))
        }

        /// The cells of a grid of `stride` anchored to the frame that a tile touches.
        private static func grid(_ tile: Tile, stride: Int) -> (Int, Int) {
            ((tile.width + tile.columns.lowerBound % stride + stride - 1) / stride, (tile.height + tile.rows.lowerBound % stride + stride - 1) / stride)
        }

        // MARK: Halation

        /// A tile's light box-averaged into the frame's finest halation grid: the cells of its interior.
        func encodeHalationSeed(_ tile: Tile, light: MTLTexture, renderer: FilmPrintRenderer, into commands: MTLCommandBuffer) throws {
            let stride = halationStride[0]
            let first = (tile.interiorColumns.lowerBound / stride, tile.interiorRows.lowerBound / stride)
            let end = ((tile.interiorColumns.upperBound + stride - 1) / stride, (tile.interiorRows.upperBound + stride - 1) / stride)
            var uniforms = DecimateUniforms(width: Int32(end.0 - first.0), height: Int32(end.1 - first.1), targetX: Int32(first.0), targetY: Int32(first.1),
                                            sourceWidth: Int32(tile.width), sourceHeight: Int32(tile.height), factor: Int32(stride),
                                            shiftX: Int32(tile.columns.lowerBound), shiftY: Int32(tile.rows.lowerBound))
            try renderer.encode("decimateKernel", commands, textures: [light, halationScratch[0]], buffers: [renderer.bytes(&uniforms)], size: (end.0 - first.0, end.1 - first.1))
        }

        /// The coarser grids from the finest, and each one's blur.
        func encodeHalationGrids(renderer: FilmPrintRenderer, into commands: MTLCommandBuffer) throws {
            // The seed sits in the first scratch; each coarser level is averaged from the one before it.
            var levels: [MTLTexture] = [halationScratch[0]]
            for scale in 1..<3 {
                var uniforms = DecimateUniforms(width: Int32(halationSize[scale].0), height: Int32(halationSize[scale].1), targetX: 0, targetY: 0,
                                                sourceWidth: Int32(halationSize[scale - 1].0), sourceHeight: Int32(halationSize[scale - 1].1),
                                                factor: Int32(halationStride[scale] / halationStride[scale - 1]), shiftX: 0, shiftY: 0)
                try renderer.encode("decimateKernel", commands, textures: [levels[scale - 1], halationScratch[scale]], buffers: [renderer.bytes(&uniforms)], size: halationSize[scale])
                levels.append(halationScratch[scale])
            }
            // Blurred coarsest first, since each level's unblurred grid feeds the next: across into the grid's own
            // texture, then down into a texture of its own.
            for scale in (0..<3).reversed() {
                let size = halationSize[scale], kernel = halationBlur[scale]
                let across = try renderer.texture(width: size.0, height: size.1, format: .rgba32Float, slot: 26 + scale)
                var blur = BlurUniforms(width: Int32(size.0), height: Int32(size.1), radius: Int32(kernel.radius), vertical: 0, weights: Int32(kernel.offset))
                try renderer.encode("blurKernel", commands, textures: [levels[scale], across], buffers: [renderer.bytes(&blur), weights], size: size)
                blur.vertical = 1
                try renderer.encode("blurKernel", commands, textures: [across, halation[scale]], buffers: [renderer.bytes(&blur), weights], size: size)
            }
        }

        // MARK: Development and print

        /// From the tile's log exposure (or a scan's densities) in `work.a` to the picture in `work.scene`.
        func encodeDevelopment(_ tile: Tile, work: Working, renderer: FilmPrintRenderer, into commands: MTLCommandBuffer) throws {
            let uniforms = uniforms(tile)
            let scans = has(FilmFeature.densityIn)
            var grids = [MTLTexture](repeating: work.a, count: 4)
            if !scans {
                for field in fields {
                    let size = Self.grid(tile, stride: field.stride)
                    let grid = try renderer.texture(width: size.0, height: size.1, format: .rgba32Float, slot: 30 + field.index)
                    let scratch = try renderer.texture(width: size.0, height: size.1, format: .rgba32Float, slot: 34 + field.index)
                    var seed = FieldUniforms(width: Int32(size.0), height: Int32(size.1), sourceWidth: Int32(tile.width), sourceHeight: Int32(tile.height), stride: Int32(field.stride),
                                             phaseX: Int32(tile.columns.lowerBound % field.stride), phaseY: Int32(tile.rows.lowerBound % field.stride), activation: field.activation ? 1 : 0)
                    try renderer.encode("fieldKernel", commands, textures: [work.a, grid], buffers: [renderer.bytes(&seed), uniforms, configuration, filmCurves], size: size)
                    var blur = BlurUniforms(width: Int32(size.0), height: Int32(size.1), radius: Int32(field.blur.radius), vertical: 0, weights: Int32(field.blur.offset))
                    try renderer.encode("blurKernel", commands, textures: [grid, scratch], buffers: [renderer.bytes(&blur), weights], size: size)
                    blur.vertical = 1
                    try renderer.encode("blurKernel", commands, textures: [scratch, grid], buffers: [renderer.bytes(&blur), weights], size: size)
                    grids[field.index] = grid
                }
            }
            var grain = work.a, mottle = work.a
            if has(FilmFeature.grain) {
                let coarse = has(FilmFeature.grainMottle)
                try renderer.encode("grainSeedKernel", commands, textures: [work.grain[0], coarse ? work.mottle[0] : work.grain[0]], buffers: [uniforms, configuration], size: tile.size)
                func blur(_ textures: [MTLTexture], _ kernel: Kernel) throws {
                    var blur = BlurUniforms(width: Int32(tile.width), height: Int32(tile.height), radius: Int32(kernel.radius), vertical: 0, weights: Int32(kernel.offset))
                    try renderer.encode("blurKernel", commands, textures: [textures[0], textures[1]], buffers: [renderer.bytes(&blur), weights], size: tile.size)
                    blur.vertical = 1
                    try renderer.encode("blurKernel", commands, textures: [textures[1], textures[0]], buffers: [renderer.bytes(&blur), weights], size: tile.size)
                }
                try blur(work.grain, grainBlur); grain = work.grain[0]
                if coarse { try blur(work.mottle, mottleBlur); mottle = work.mottle[0] }
            }
            try renderer.encode("developKernel", commands, textures: [work.a, grids[0], grids[1], grids[2], grids[3], grain, mottle, work.b],
                                buffers: [uniforms, configuration, filmCurves], size: tile.size)
            var blur = BlurUniforms(width: Int32(tile.width), height: Int32(tile.height), radius: Int32(printBlur.radius), vertical: 0, weights: Int32(printBlur.offset))
            if has(FilmFeature.printMTF) {
                try renderer.encode("blurKernel", commands, textures: [work.b, work.c], buffers: [renderer.bytes(&blur), weights], size: tile.size)
            }
            try renderer.encode("printKernel", commands, textures: [work.b, work.c, work.scene],
                                buffers: [uniforms, renderer.bytes(&blur), weights, configuration, paperCurves, filmCube, paperCube], size: tile.size)
        }

        // MARK: Tables

        /// A Gaussian's taps for four channels, each inside its own window and summing to one there.
        private static func gaussian(sigmas: [Float], windows: [Int], radius: Int) -> [SIMD4<Float>] {
            var taps = [SIMD4<Float>](repeating: .zero, count: 2 * radius + 1)
            for channel in 0..<4 {
                let denominator = 2 * sigmas[channel] * sigmas[channel]
                var total: Float = 0
                for k in -radius...radius where abs(k) <= windows[channel] { total += exp(-Float(k * k) / denominator) }
                for k in -radius...radius where abs(k) <= windows[channel] { taps[k + radius][channel] = exp(-Float(k * k) / denominator) / total }
            }
            return taps
        }

        /// Three passes of a box of `radius` as one kernel.
        private static func tripleBox(radius: Int) -> [SIMD4<Float>] {
            let scale = 1 / Float(2 * radius + 1)
            return (-3 * radius...3 * radius).map { k in
                var count = 0
                for i in -radius...radius { for j in -radius...radius where abs(k - i - j) <= radius { count += 1 } }
                return SIMD4(repeating: Float(count) * scale * scale * scale)
            }
        }

        private static func softplus(_ v: Float) -> Float { v > 20 ? v : (v < -20 ? exp(v) : log(1 + exp(v))) }
        /// A characteristic curve from the configuration: six parameters, or five without a base for a film record's
        /// second population, which has no minimum density of its own.
        private static func curve(_ cfg: [Float], at slot: Int, hasBase: Bool, _ x: Float) -> Float {
            let o = hasBase ? slot + 1 : slot
            let gamma = cfg[o], toe = cfg[o + 1], toeWidth = max(cfg[o + 2], 1e-6), shoulder = cfg[o + 3], shoulderWidth = max(cfg[o + 4], 1e-6)
            let rise = toeWidth * softplus((x - toe) / toeWidth) - shoulderWidth * softplus((x - shoulder) / shoulderWidth)
            return (hasBase ? cfg[slot] : 0) + gamma * min(max(rise, 0), shoulder - toe)
        }
        /// A film record's measured curve where it has one: a monotone cubic through its knots.
        private static func measured(_ cfg: [Float], channel: Int, _ x: Float) -> Float? {
            let base = Slot.sampledCurves + channel * Slot.sampledCurveStride
            guard cfg[base] >= 2 else { return nil }
            let count = min(Int(cfg[base]), Slot.sampledCurveMaxSamples)
            func knot(_ index: Int, _ field: Int) -> Float { cfg[base + 1 + index * 3 + field] }
            if x <= knot(0, 0) { return knot(0, 1) }
            if x >= knot(count - 1, 0) { return knot(count - 1, 1) }
            var low = 0, high = count - 1
            while high - low > 1 {
                let middle = (low + high) / 2
                if knot(middle, 0) <= x { low = middle } else { high = middle }
            }
            let h = max(knot(high, 0) - knot(low, 0), 1e-12), t = min(max((x - knot(low, 0)) / h, 0), 1)
            let y0 = knot(low, 1), y1 = knot(high, 1), a = h * knot(low, 2), b = h * knot(high, 2), delta = y1 - y0
            return y0 + t * (a + t * (3 * delta - 2 * a - b + t * (-2 * delta + a + b)))
        }
        private static func logExposure(_ index: Int, of samples: Int) -> Float {
            FilmKernels.curveMin + (FilmKernels.curveMax - FilmKernels.curveMin) * (Float(index) / Float(samples - 1))
        }
        /// The film's three curves, and a donor layer's in the fourth channel.
        static func filmCurveTable(_ cfg: [Float]) -> [Float] {
            let samples = FilmKernels.filmCurveSamples
            var table = [Float](repeating: 0, count: samples * 4)
            for channel in 0..<3 {
                let sampled = cfg[Slot.sampledCurves + channel * Slot.sampledCurveStride] >= 2
                for index in 0..<samples {
                    let x = logExposure(index, of: samples)
                    table[index * 4 + channel] = (sampled ? measured(cfg, channel: channel, x) : nil)
                        ?? curve(cfg, at: Slot.curves + channel * 6, hasBase: true, x) + curve(cfg, at: Slot.curveSecondary + channel * 5, hasBase: false, x)
                }
            }
            for index in 0..<samples { table[index * 4 + 3] = curve(cfg, at: Slot.donorCurve, hasBase: true, logExposure(index, of: samples)) }
            return table
        }
        /// The paper's three records.
        static func paperCurveTable(_ cfg: [Float]) -> [Float] {
            let samples = FilmKernels.paperCurveSamples
            var table = [Float](repeating: 0, count: samples * 4)
            for (channel, slot) in [Slot.paperRed, Slot.paper, Slot.paperBlue].enumerated() {
                for index in 0..<samples { table[index * 4 + channel] = curve(cfg, at: slot, hasBase: true, logExposure(index, of: samples)) }
            }
            return table
        }
    }
}
#endif
