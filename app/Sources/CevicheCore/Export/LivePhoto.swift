import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

/// A Live Photo as an iPhone saves one: a HEIC still and a QuickTime movie that share a content identifier, the movie
/// marking the moment the still was taken. Photos and iOS pair the two files by that identifier.
public enum LivePhoto {
    /// An iPhone's 12-megapixel still and its Live Photo movie, on the long edge.
    public static let stillLongEdge = 4032.0
    public static let videoLongEdge = 1920.0

    /// `size` shrunk to `longEdge`, never enlarged, in even pixels as video encoders want.
    public static func fit(_ size: CGSize, longEdge: Double) -> CGSize {
        let scale = min(1, longEdge / max(size.width, size.height, 1))
        func even(_ value: Double) -> Double { max(2, (value * scale / 2).rounded() * 2) }
        return CGSize(width: even(size.width), height: even(size.height))
    }

    /// How long a Live Photo made from a sequence plays, and its fastest pace.
    public static let movieSeconds = 3.0
    public static let movieFrameRate = 30.0

    /// Which of `count` frames a 3-second movie shows, spread evenly from the first to the last; all of them when
    /// there are fewer than 90.
    public static func sample(_ count: Int) -> [Int] {
        let shown = min(count, Int(movieSeconds * movieFrameRate))
        guard shown > 1 else { return Array(0..<max(0, count)) }
        return (0..<shown).map { Int((Double($0) * Double(count - 1) / Double(shown - 1)).rounded()) }
    }
    /// Each of `frames` frames' time, so they fill 3 seconds.
    public static func sampleDuration(_ frames: Int) -> CMTime {
        CMTime(value: CMTimeValue((600 * movieSeconds / Double(max(1, frames))).rounded()), timescale: 600)
    }

    /// A picture of `ratio` proportions, `longEdge` pixels on its long edge or `limit` when that is smaller, in even
    /// pixels.
    public static func size(ratio: Double, longEdge: Double, limit: Double? = nil) -> CGSize {
        let long = min(longEdge, limit ?? longEdge), ratio = max(0.01, ratio)
        return fit(ratio >= 1 ? CGSize(width: long, height: long / ratio) : CGSize(width: long * ratio, height: long), longEdge: long)
    }

    /// Writes `still` as an 8-bit HEIC carrying the Live Photo identifier, with the capture tags of `source` kept.
    public static func writeStill(_ still: CGImage, to url: URL, identifier: String, source: URL?) throws {
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: 1, kCGImageDestinationLossyCompressionQuality: 0.9,
                                          // Apple's maker note tag 17 is the identifier the movie repeats.
                                          kCGImagePropertyMakerAppleDictionary: ["17": identifier]]
        if let source, let file = CGImageSourceCreateWithURL(source as CFURL, nil),
           let original = CGImageSourceCopyPropertiesAtIndex(file, 0, nil) as? [String: Any] {
            if let exif = original[kCGImagePropertyExifDictionary as String] as? [String: Any] {
                let keys: [CFString] = [kCGImagePropertyExifExposureTime, kCGImagePropertyExifFNumber, kCGImagePropertyExifISOSpeedRatings,
                                        kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifDateTimeDigitized, kCGImagePropertyExifSubsecTimeOriginal,
                                        kCGImagePropertyExifOffsetTimeOriginal, kCGImagePropertyExifFocalLength, kCGImagePropertyExifLensModel, kCGImagePropertyExifLensMake]
                var clean: [String: Any] = [:]
                for key in keys { clean[key as String] = exif[key as String] }
                clean[kCGImagePropertyExifPixelXDimension as String] = still.width
                clean[kCGImagePropertyExifPixelYDimension as String] = still.height
                properties[kCGImagePropertyExifDictionary] = clean
            }
            if let tiff = original[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
                var clean: [String: Any] = [:]
                for key in [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFDateTime] { clean[key as String] = tiff[key as String] }
                properties[kCGImagePropertyTIFFDictionary] = clean
            }
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            throw EditorError.invalidDocument(L10n.tr("The installed system cannot encode HEIF."))
        }
        CGImageDestinationAddImage(destination, still, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw EditorError.render }
    }
}

/// The movie half of a Live Photo: HEVC frames at a fixed rate, the content identifier, and the still's moment as
/// timed metadata.
public final class LivePhotoWriter: @unchecked Sendable {
    public let size: CGSize
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let frameDuration: CMTime
    private var frames = 0

    public init(url: URL, size: CGSize, frameDuration: CMTime, stillFrame: Int, identifier: String) throws {
        self.size = size; self.frameDuration = frameDuration
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let identity = AVMutableMetadataItem()
        identity.key = "com.apple.quicktime.content.identifier" as NSString
        identity.keySpace = .quickTimeMetadata
        identity.value = identifier as NSString
        identity.dataType = kCMMetadataBaseDataType_UTF8 as String
        writer.metadata = [identity]
        let rate = Double(frameDuration.timescale) / Double(frameDuration.value)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
            AVVideoCompressionPropertiesKey: [AVVideoExpectedSourceFrameRateKey: rate, AVVideoQualityKey: 0.7]
        ])
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ])
        guard writer.canAdd(input) else { throw EditorError.render }
        writer.add(input)
        // The still's moment, as the timed metadata track an iPhone writes.
        let key = "mdta/com.apple.quicktime.still-image-time"
        let spec: [String: Any] = [kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: key,
                                   kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: kCMMetadataBaseDataType_SInt8 as String]
        var format: CMFormatDescription?
        CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed,
                                                                     metadataSpecifications: [spec] as CFArray, formatDescriptionOut: &format)
        let metadata = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: format)
        metadata.expectsMediaDataInRealTime = false
        guard writer.canAdd(metadata) else { throw EditorError.render }
        writer.add(metadata)
        let still = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadata)
        writer.movieTimeScale = 600
        guard writer.startWriting() else { throw writer.error ?? EditorError.render }
        writer.startSession(atSourceTime: .zero)
        let item = AVMutableMetadataItem()
        item.identifier = AVMetadataIdentifier(rawValue: key)
        item.value = 0 as NSNumber
        item.dataType = kCMMetadataBaseDataType_SInt8 as String
        let time = CMTimeRange(start: CMTimeMultiply(frameDuration, multiplier: Int32(stillFrame)), duration: frameDuration)
        guard still.append(AVTimedMetadataGroup(items: [item], timeRange: time)) else { throw writer.error ?? EditorError.render }
        metadata.markAsFinished()
    }

    /// A frame to render into, tagged Rec. 709.
    public func makeBuffer() throws -> VideoFrameBuffer {
        var buffer: CVPixelBuffer?
        if let pool = adaptor.pixelBufferPool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) }
        guard let buffer else { throw EditorError.render }
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return VideoFrameBuffer(pixels: buffer)
    }

    public func append(_ frame: VideoFrameBuffer) async throws {
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing else { throw writer.error ?? EditorError.render }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard adaptor.append(frame.pixels, withPresentationTime: CMTimeMultiply(frameDuration, multiplier: Int32(frames))) else { throw writer.error ?? EditorError.render }
        frames += 1
    }

    public func finish() async throws {
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTimeMultiply(frameDuration, multiplier: Int32(frames)))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? EditorError.render }
    }

    public func cancel() {
        if writer.status == .writing { writer.cancelWriting() }
    }
}

extension RawRenderer {
    /// The photo developed with `adjustments`, cut to `crop` in `ratio` proportions and scaled to `size`, as an 8-bit
    /// Display P3 picture: the still that ends a movie rendered with `renderTimelapseFrame` and the same cut.
    public func livePhotoStill(_ adjustments: Adjustments, crop: TimelapseCrop, ratio: Double, size: CGSize,
                               steady: TimelapseStabilization.Frame? = nil) throws -> CGImage {
        let image = try timelapseImage(adjustments, crop: crop, ratio: ratio, size: size, steady: steady)
        try Task.checkCancellation()
        guard let cg = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!) else { throw EditorError.render }
        return cg
    }
}
