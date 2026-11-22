import CoreImage
import Foundation
import FilmPrint
import Metal
import simd

/// Renders `FilmSimulation` through the film print: the scene is exposed on the film through its spectral
/// sensitivities, developed with its couplers, grain and halation, and finished on the medium. The film works on a
/// whole frame, so it is one step of the Core Image graph that asks for all of its input: grain, halation and a scan's
/// levels are the frame's, whatever part of it is drawn. Its spatial effects are sized on the film from the gauge, so a
/// preview and the export show the same structures. The frame is developed on the GPU and stays there: Core Image is
/// handed the parts of it that it draws. Actor-confined to `RawRenderer`, like the other renderers.
final class FilmSimulationRenderer {
    /// What a developed frame was made from: the photo's whole development and the size it was rendered at.
    struct SceneKey: Equatable { let adjustments: Adjustments; let size: Double?; let direct: Bool }
    /// Developed frames of this photo, most recently used first. A frame is developed once and then serves every
    /// render that asks for the same development: the preview with its thumbnail and histogram, and the detail tiles
    /// of a zoomed view as it pans. Kept to `frameBudget` bytes, the frame in use aside.
    private var frames: [(key: SceneKey, frame: FilmFrame)] = []
    private static let frameBudget = 1536 << 20

    /// The film's exposure, development and print of linear scene light in the working space. The image comes back
    /// unchanged for a stock the catalog lacks or on a Mac without a GPU for it. One render takes one development
    /// of a scene: Core Image merges two film steps over the same input, whatever their settings. With `key`, the
    /// developed frame is kept for the next render of the same development.
    func apply(_ settings: FilmSimulation, to image: CIImage, key: SceneKey? = nil) -> CIImage {
        let extent = image.extent.integral
        guard FilmCatalog.shared.isAvailable, !extent.isEmpty, !extent.isInfinite, let development = FilmCatalog.shared.development(settings) else { return image }
        // Exactly the frame's whole pixels, so the kernel is handed the region it asks for.
        let scene = image.clampedToExtent().cropped(to: extent)
        let frame: FilmFrame
        if let key, let index = frames.firstIndex(where: { $0.key == key && $0.frame.extent == extent }) {
            frame = frames.remove(at: index).frame
            frames.insert((key, frame), at: 0)
        } else {
            frame = FilmFrame(development: development, extent: extent, scene: scene, context: sceneContext, interruptible: interruptible)
            if let key {
                frames.insert((key, frame), at: 0)
                var total = 0
                frames = frames.enumerated().filter { index, entry in total += entry.frame.bytes; return index == 0 || total <= Self.frameBudget }.map(\.element)
            }
        }
        guard let developed = try? FilmFrameKernel.apply(withExtent: extent, inputs: [scene], arguments: ["frame": frame]) else { return image }
        return developed.cropped(to: extent)
    }
    func releaseCaches() { frames.removeAll(); sceneContext?.clearCaches(); FilmPrintRenderer.shared?.releaseCaches() }
    /// Whether the frames made now may be given up for a preview: set while a detail tile's graph is built, never for
    /// an export.
    var interruptible = false
    /// Gives up the interruptible frames still being developed (a detail tile takes a while), so the GPU is free for
    /// the preview that was just asked for. Their renders fail; the next one starts afresh.
    func yieldToPreview() {
        frames.removeAll { entry in
            guard entry.frame.interruptible, !entry.frame.isDeveloped else { return false }
            entry.frame.abandon(); return true
        }
    }
    /// Renders a large frame's scene into a texture for the film, apart from the context that is drawing the picture.
    private lazy var sceneContext: CIContext? = FilmPrintRenderer.shared.map {
        CIContext(mtlDevice: $0.device, options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false,
            .name: "Ceviche film scene"
        ])
    }

    /// A scanned color negative printed on the settings' medium: `scan` is rows of linear RGBA, read as the stock's
    /// densities against the film `base`, and the result is linear Rec. 709 laid out the same. Nil where it can't be
    /// printed.
    static func print(scan: [Float], width: Int, height: Int, base: SIMD3<Float>, settings: FilmSimulation) -> [Float]? {
        guard let renderer = FilmPrintRenderer.shared, let development = FilmCatalog.shared.development(settings),
              let reading = try? ApproximateNegativeScan(stock: development.stock, border: base), scan.count >= width * height * 4 else { return nil }
        // Exposure and development already happened to the scanned film: only its print is made.
        var options = development.options
        options.stage = .print; options.scanReading = reading
        var result = [Float](repeating: 0, count: width * height * 4)
        let done = scan.withUnsafeBytes { source in
            result.withUnsafeMutableBytes { target in
                renderer.develop(scene: .memory(UnsafeMutableRawPointer(mutating: source.baseAddress!), bytesPerRow: width * 16),
                                 picture: .memory(target.baseAddress!, bytesPerRow: width * 16), width: width, height: height, stock: development.stock, options: options, colors: colors)
            }
        }
        return done ? result : nil
    }

    /// The working space's linear Rec. 709 to the film's Rec. 2020 and its print's Display P3 back.
    static let colors = FilmPrintRenderer.Colors(sceneToRec2020: rows(ColorScience.linearSRGBToRec2020), pictureFromDisplayP3: rows(ColorScience.linearDisplayP3ToSRGB))
    private static func rows(_ transform: (SIMD3<Float>) -> SIMD3<Float>) -> [Float] {
        let columns = [transform(SIMD3(1, 0, 0)), transform(SIMD3(0, 1, 0)), transform(SIMD3(0, 0, 1))]
        return (0..<3).flatMap { row in columns.map { $0[row] } }
    }
}

/// One frame's development: what the kernel develops, and the developed frame once it has been asked for, so every
/// part of it and every later render share one development. The picture is a texture in the working space, top row
/// first. A preview-sized frame takes its scene as the kernel's input. A large one renders the scene itself, into a
/// texture on its own context: asked for a large input in one piece, Core Image assembles it from its own tiles and
/// decodes the RAW again and again as they fall out of its cache.
private final class FilmFrame: NSObject, @unchecked Sendable {
    let development: FilmDevelopment
    let extent: CGRect
    private let source: CIImage
    private let context: CIContext?
    private let lock = NSLock()
    private var picture: MTLTexture?
    private var failed = false
    /// Read while developing, without the lock the development holds.
    private let abandoned = ManagedAtomicFlag()
    func abandon() { abandoned.set() }
    let interruptible: Bool
    init(development: FilmDevelopment, extent: CGRect, scene: CIImage, context: CIContext?, interruptible: Bool) {
        self.development = development; self.extent = extent; source = scene; self.context = context; self.interruptible = interruptible
    }

    /// Whether the frame renders its own scene: past 12 megapixels.
    var isLarge: Bool { width * height > 12_000_000 }
    var width: Int { Int(extent.width) }
    var height: Int { Int(extent.height) }
    /// The memory the developed frame takes.
    var bytes: Int { width * height * 16 }
    var isDeveloped: Bool { lock.lock(); defer { lock.unlock() }; return picture != nil }

    /// The developed frame, developed once: from `scene` (rows of RGBA floats, top row first, covering the frame) for
    /// a preview-sized frame, from its own rendering of the scene for a large one.
    func developed(scene: (pixels: UnsafeRawPointer, rowBytes: Int)?) -> MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        if let picture { return picture }
        guard !failed, let renderer = FilmPrintRenderer.shared else { return nil }
        // A large frame's scene is a texture as large as its picture: gone as soon as the film is developed.
        autoreleasepool {
            guard let target = renderer.makeFrameTexture(width: width, height: height) else { failed = true; return }
            let from: FilmPrintRenderer.Pixels
            if isLarge {
                guard let rendered = renderScene(renderer) else { failed = true; return }
                from = .texture(rendered)
            } else if let scene {
                from = .memory(UnsafeMutableRawPointer(mutating: scene.pixels), bytesPerRow: scene.rowBytes)
            } else {
                return
            }
            let done = renderer.develop(scene: from, picture: .texture(target), width: width, height: height, stock: development.stock, options: development.options,
                                        colors: FilmSimulationRenderer.colors, shouldContinue: { [abandoned] in !abandoned.isSet })
            if done { picture = target } else { failed = true }
        }
        return picture
    }

    /// The scene drawn into a texture, top row first.
    private func renderScene(_ renderer: FilmPrintRenderer) -> MTLTexture? {
        guard let context, !abandoned.isSet, let texture = renderer.makeFrameTexture(width: width, height: height) else { return nil }
        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: nil)
        destination.colorSpace = nil
        destination.isFlipped = true
        destination.alphaMode = .none
        guard let task = try? context.startTask(toRender: source, from: extent, to: destination, at: .zero), (try? task.waitUntilCompleted()) != nil, !abandoned.isSet else { return nil }
        return texture
    }
}

/// The film as a Core Image step. Buffers and textures hold their top row first, while regions count from the bottom.
private final class FilmFrameKernel: CIImageProcessorKernel {
    static let traces = ProcessInfo.processInfo.environment["CEVICHE_FILM_TRACE"] != nil
    override class var outputFormat: CIFormat { .RGBAf }
    override class var outputIsOpaque: Bool { true }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAf }
    /// The whole scene for a preview-sized frame, whatever part is drawn; a pixel of it for a large frame, which
    /// renders its own.
    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        guard let frame = arguments?["frame"] as? FilmFrame else { return outputRect }
        return frame.isLarge ? CGRect(x: frame.extent.minX, y: frame.extent.minY, width: 1, height: 1) : frame.extent
    }
    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        guard let input = inputs?.first, let frame = arguments?["frame"] as? FilmFrame else { throw EditorError.render }
        let whole = !frame.isLarge && input.region == frame.extent
        guard let picture = frame.developed(scene: whole ? (input.baseAddress, input.bytesPerRow) : nil) else { throw EditorError.render }
        let region = output.region.integral
        let inside = region.intersection(frame.extent)
        let top = Int(frame.extent.maxY - inside.maxY), left = Int(inside.minX - frame.extent.minX), columns = Int(inside.width), rows = Int(inside.height)
        let rowOffset = Int(region.maxY - inside.maxY), columnOffset = Int(inside.minX - region.minX)
        // Core Image may ask for a pixel or so past the frame; that margin stays clear, which takes the CPU's copy.
        if inside == region, !inside.isEmpty, let target = output.metalTexture, let commands = output.metalCommandBuffer, target.device === picture.device,
           target.pixelFormat == picture.pixelFormat, let blit = commands.makeBlitCommandEncoder() {
            blit.copy(from: picture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: left, y: top, z: 0), sourceSize: MTLSize(width: columns, height: rows, depth: 1),
                      to: target, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
            if FilmFrameKernel.traces { print("film output \(columns)x\(rows) into a \(target.width)x\(target.height) texture") }
            return
        }
        if FilmFrameKernel.traces { print("film output \(columns)x\(rows) into memory") }
        memset(output.baseAddress, 0, output.bytesPerRow * Int(region.height))
        guard !inside.isEmpty else { return }
        picture.getBytes(output.baseAddress + rowOffset * output.bytesPerRow + columnOffset * 16, bytesPerRow: output.bytesPerRow,
                         from: MTLRegionMake2D(left, top, columns, rows), mipmapLevel: 0)
    }
}

/// A flag one thread sets and others read.
private final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
