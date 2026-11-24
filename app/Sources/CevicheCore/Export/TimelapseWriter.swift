import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import CoreGraphics

/// A pixel buffer handed between the renderer and the writer; each one is written by one renderer, then read by the
/// writer, never both at once.
public struct VideoFrameBuffer: @unchecked Sendable {
    public let pixels: CVPixelBuffer
    /// The space its pixels are rendered in, as the video is tagged.
    public var colorSpace = CGColorSpace(name: CGColorSpace.itur_709)!
}

/// Writes frames to a movie file at a fixed rate, one pixel buffer per photo. With more than one pass the encoder asks
/// for the frames again, so the caller renders them in the order `nextPass` gives.
public final class TimelapseWriter: @unchecked Sendable {
    public let url: URL
    public let size: CGSize
    public let frameCount: Int
    private let writer: AVAssetWriter
    private let workspace: URL
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let frameDuration: CMTime
    private let color: VideoColor
    private let pixelFormat: OSType
    /// Pass descriptions as the encoder hands them out; nil marks the end.
    private var passes: AsyncStream<[Range<Int>]?>?
    private var passesLeft: AsyncStream<[Range<Int>]?>.Iterator?
    private var singlePassDone = false
    private var finished = false
    /// How many passes have begun.
    public private(set) var pass = 0

    /// Writes in a replacement directory on the destination volume and moves the movie into place in `finish`, so a stopped or failed video
    /// leaves nothing half-written under the chosen name. The folder also holds the copy AVFoundation makes when it
    /// moves the index to the front.
    public init(url: URL, settings: TimelapseSettings, size: CGSize, frames: Int, metadata: TimelapseMetadata? = nil) throws {
        self.url = url; self.size = size; frameCount = frames
        let container = settings.fileContainer
        workspace = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        do { writer = try AVAssetWriter(outputURL: workspace.appendingPathComponent("video.\(container.fileExtension)"), fileType: container.fileType) }
        catch { try? FileManager.default.removeItem(at: workspace); throw error }
        // The index goes at the front, so a player or a site can start before the whole file arrives.
        writer.shouldOptimizeForNetworkUse = true
        if let metadata { writer.metadata = Self.items(metadata, container: container) }
        let output = settings.outputSettings(size: size)
        guard writer.canApply(outputSettings: output, forMediaType: .video) else {
            throw EditorError.invalidDocument(L10n.tr("This Mac can’t encode \(settings.codec.title) at \(Int(size.width)) × \(Int(size.height))."))
        }
        input = AVAssetWriterInput(mediaType: .video, outputSettings: output)
        input.expectsMediaDataInRealTime = false
        input.performsMultiPassEncodingIfSupported = settings.requestsMultiPass
        color = settings.fileColor
        // Half floats keep ProRes's 10 and 12 bits and HDR's highlights; 8-bit SDR needs no more than BGRA.
        pixelFormat = settings.deepPixels ? kCVPixelFormatType_64RGBAHalf : kCVPixelFormatType_32BGRA
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ])
        guard writer.canAdd(input) else { throw EditorError.render }
        writer.add(input)
        frameDuration = settings.frameRate.frameDuration
        // The movie's own clock ticks in the frame's timescale, so 23.976 fps keeps its exact 1001/24000 s frames.
        writer.movieTimeScale = frameDuration.timescale
        input.mediaTimeScale = frameDuration.timescale
        guard writer.startWriting() else { throw writer.error ?? EditorError.render }
        writer.startSession(atSourceTime: .zero)
        if input.canPerformMultiplePasses {
            let (stream, continuation) = AsyncStream.makeStream(of: [Range<Int>]?.self)
            let input = input, duration = frameDuration, count = frames
            input.respondToEachPassDescription(on: DispatchQueue(label: "Ceviche.TimelapseWriter.passes")) {
                guard let description = input.currentPassDescription else { continuation.yield(nil); continuation.finish(); return }
                continuation.yield(description.sourceTimeRanges.map { Self.frames(in: $0.timeRangeValue, duration: duration, count: count) })
            }
            passes = stream
            passesLeft = stream.makeAsyncIterator()
        }
    }
    private var temporaryURL: URL { writer.outputURL }
    /// Whether the encoder took more than one pass; known once writing has begun.
    public var multiPass: Bool { passes != nil }

    /// The frames to append next, as runs of frame numbers; nil once the encoder has every pass it wants. One pass is
    /// every frame in order.
    public func nextPass() async -> [Range<Int>]? {
        if passes != nil {
            if pass > 0 { input.markCurrentPassAsFinished() }
            guard let ranges = await passesLeft?.next() ?? nil else { return nil }
            pass += 1
            return ranges
        }
        guard !singlePassDone else { return nil }
        singlePassDone = true; pass = 1
        return [0..<frameCount]
    }

    /// A buffer from the writer's pool for the next frame to render into.
    public func makeBuffer() throws -> VideoFrameBuffer {
        var buffer: CVPixelBuffer?
        if let pool = adaptor.pixelBufferPool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) }
        if buffer == nil {
            CVPixelBufferCreate(nil, Int(size.width), Int(size.height), pixelFormat,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &buffer)
        }
        guard let buffer else { throw EditorError.render }
        let tags = color.bufferTags
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, tags.primaries, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, tags.transfer, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, tags.matrix, .shouldPropagate)
        return VideoFrameBuffer(pixels: buffer, colorSpace: color.colorSpace)
    }

    /// Appends frame number `index`, waiting while the encoder catches up.
    public func append(_ frame: VideoFrameBuffer, at index: Int) async throws {
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing else { throw writer.error ?? EditorError.render }
            try await Task.sleep(for: .milliseconds(5))
        }
        let time = CMTimeMultiply(frameDuration, multiplier: Int32(index))
        guard adaptor.append(frame.pixels, withPresentationTime: time) else { throw writer.error ?? EditorError.render }
    }

    public func finish(overwriteExisting: Bool) async throws {
        if !finished { finished = true; input.markAsFinished() }
        writer.endSession(atSourceTime: CMTimeMultiply(frameDuration, multiplier: Int32(frameCount)))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? EditorError.render }
        defer { try? FileManager.default.removeItem(at: workspace) }
        if overwriteExisting && FileManager.default.fileExists(atPath: url.path) { _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL) }
        else { try FileManager.default.moveItem(at: temporaryURL, to: url) }
    }
    public func cancel() {
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: workspace)
    }

    /// The frame numbers a pass's time range covers.
    static func frames(in range: CMTimeRange, duration: CMTime, count: Int) -> Range<Int> {
        // A pass over everything can end at positive infinity.
        func frame(_ time: CMTime) -> Int {
            let value = time.seconds / duration.seconds
            return value.isFinite ? min(count, max(0, Int(value.rounded()))) : (value > 0 ? count : 0)
        }
        let start = frame(range.start), end = range.duration.isIndefinite || range.duration.isPositiveInfinity ? count : frame(range.end)
        return start..<max(start, end)
    }

    /// QuickTime's own keys in a movie. MPEG-4 takes the common keys, and AVFoundation writes only the date, the
    /// location and the software of those there.
    static func items(_ metadata: TimelapseMetadata, container: VideoContainer) -> [AVMetadataItem] {
        func item(_ quickTime: AVMetadataIdentifier, _ common: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = container == .mov ? quickTime : common
            item.value = value as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            return item
        }
        var items: [AVMetadataItem] = []
        if let date = metadata.date {
            // As cameras and iPhones write it, with the offset in ±hhmm.
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            items.append(item(.quickTimeMetadataCreationDate, .commonIdentifierCreationDate, formatter.string(from: date)))
        }
        if let location = metadata.iso6709 { items.append(item(.quickTimeMetadataLocationISO6709, .commonIdentifierLocation, location)) }
        if !metadata.make.isEmpty { items.append(item(.quickTimeMetadataMake, .commonIdentifierMake, metadata.make)) }
        if !metadata.model.isEmpty { items.append(item(.quickTimeMetadataModel, .commonIdentifierModel, metadata.model)) }
        items.append(item(.quickTimeMetadataSoftware, .commonIdentifierSoftware, "Ceviche"))
        return items
    }
}

/// One photo developed and cut to the video's frame, kept in linear light while the frames that show it are made.
/// Half floats in extended linear Rec. 2020 hold any output color and HDR's highlights.
public struct TimelapsePhoto: @unchecked Sendable {
    public let pixels: CVPixelBuffer
    static let space = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
    var image: CIImage { CIImage(cvPixelBuffer: pixels, options: [.colorSpace: Self.space]) }

    static func render(_ image: CIImage, size: CGSize, context: CIContext) throws -> TimelapsePhoto {
        try Task.checkCancellation()
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_64RGBAHalf,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &buffer)
        guard let buffer else { throw EditorError.render }
        context.render(image, to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: space)
        try Task.checkCancellation()
        return TimelapsePhoto(pixels: buffer)
    }
}

/// Makes video frames from developed photos: one photo as it is, or two mixed for a frame between them.
public final class TimelapseCompositor: @unchecked Sendable {
    private let context: CIContext
    public init() {
        let options: [CIContextOption: Any] = [.workingColorSpace: TimelapsePhoto.space, .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false]
        context = CIContext(options: options)
    }
    public func compose(_ frame: TimelapsePlan.Frame, photos: [Int: TimelapsePhoto], into buffer: VideoFrameBuffer) throws {
        guard let first = photos[frame.photo] else { throw EditorError.render }
        var image = first.image
        if let next = frame.next, frame.weight > 0 {
            guard let second = photos[next] else { throw EditorError.render }
            // The working space is linear, so the mix is one of light, as a longer exposure would record.
            image = image.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: second.image, kCIInputTimeKey: frame.weight])
        }
        let size = CGSize(width: CVPixelBufferGetWidth(buffer.pixels), height: CVPixelBufferGetHeight(buffer.pixels))
        context.render(image.cropped(to: CGRect(origin: .zero, size: size)), to: buffer.pixels, bounds: CGRect(origin: .zero, size: size), colorSpace: buffer.colorSpace)
    }
}

extension RawRenderer {
    /// The photo as the video's frames show it, at `size`, for the compositor. With `hdr`, photos edited in HDR keep
    /// their highlights up to their headroom. `steady` moves the photo back to the series' view.
    public func renderTimelapsePhoto(_ adjustments: Adjustments, crop: TimelapseCrop, ratio: Double, size: CGSize, hdr: Bool,
                                     steady: TimelapseStabilization.Frame? = nil) throws -> TimelapsePhoto {
        let image = try timelapseImage(adjustments, crop: crop, ratio: ratio, size: size, hdr: hdr, steady: steady)
        return try TimelapsePhoto.render(image, size: size, context: context)
    }

    /// One video frame: the photo developed with `adjustments`, cut to the crop's frame and scaled to `size`.
    /// The photo is developed from the full source, as an export is, and only the finished frame is shrunk: a smaller
    /// decode would be quicker but rings around stars and lights, and those rings shimmer from frame to frame.
    func timelapseImage(_ adjustments: Adjustments, crop: TimelapseCrop, ratio: Double, size: CGSize, hdr: Bool = false,
                        steady: TimelapseStabilization.Frame? = nil) throws -> CIImage {
        var image = try pipeline(adjustments, maxDimension: nil)
        try Task.checkCancellation()
        let developed = image.extent.size
        var rect = crop.rect(in: developed, aspect: ratio)
        if let steady {
            image = image.transformed(by: Self.steadying(steady.shift, size: developed))
            // The crop is framed inside the margin, so every photo moved back still fills it.
            let inset = CGSize(width: developed.width * steady.margin.width, height: developed.height * steady.margin.height)
            let inner = CGSize(width: developed.width - 2 * inset.width, height: developed.height - 2 * inset.height)
            rect = crop.rect(in: inner, aspect: ratio).offsetBy(dx: inset.width, dy: inset.height)
        }
        // Core Image's origin is at the bottom left.
        let cut = CGRect(x: rect.minX, y: developed.height - rect.maxY, width: rect.width, height: rect.height)
        image = image.cropped(to: cut).transformed(by: CGAffineTransform(translationX: -cut.minX, y: -cut.minY))
        image = Self.resized(image, scaleX: size.width / cut.width, scaleY: size.height / cut.height).cropped(to: CGRect(origin: .zero, size: size))
        if adjustments.hdr.enabled { image = HDRRenderer.output(image, settings: adjustments.hdr, context: context, sdr: !hdr) }
        return image.composited(over: CIImage(color: .black).cropped(to: image.extent))
    }

    /// Takes a photo of `size` back to the series' view, in Core Image's coordinates: the shift's y and the roll turn
    /// over with the axis.
    static func steadying(_ shift: TimelapseShift, size: CGSize) -> CGAffineTransform {
        guard shift != .zero else { return .identity }
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let motion = CGAffineTransform(translationX: centre.x + shift.dx * size.width, y: centre.y - shift.dy * size.height)
            .rotated(by: -shift.angle).translatedBy(x: -centre.x, y: -centre.y)
        return motion.inverted()
    }

    /// Renders one frame into a writer's buffer, in the space the video is tagged with. An HDR video keeps the
    /// highlights of photos edited in HDR, up to their headroom; other photos sit at SDR white in it.
    public func renderTimelapseFrame(_ adjustments: Adjustments, crop: TimelapseCrop, ratio: Double, into frame: VideoFrameBuffer) throws {
        // In a pool of its own: a video is hundreds of these in a row on a thread nothing else drains.
        try autoreleasepool {
            let buffer = frame.pixels
            let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
            let image = try timelapseImage(adjustments, crop: crop, ratio: ratio, size: size, hdr: frame.colorSpace.isHDR)
            try Task.checkCancellation()
            context.render(image, to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: frame.colorSpace)
        }
    }

    /// The frame as the video shows it, at `size`, for the dialog's preview of a paused frame.
    public func timelapsePreview(_ adjustments: Adjustments, crop: TimelapseCrop, ratio: Double, size: CGSize,
                                 steady: TimelapseStabilization.Frame? = nil) throws -> CGImage {
        let image = try timelapseImage(adjustments, crop: crop, ratio: ratio, size: size, steady: steady)
        try Task.checkCancellation()
        guard let cg = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { throw EditorError.render }
        return cg
    }
}

private extension CGColorSpace {
    var isHDR: Bool { CGColorSpaceUsesITUR_2100TF(self) }
}

