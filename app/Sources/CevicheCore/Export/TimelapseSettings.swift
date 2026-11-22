import Foundation
import AVFoundation
import VideoToolbox

/// The encoders AVFoundation offers on every Mac that runs Ceviche, in menu order.
public enum VideoCodec: String, CaseIterable, Codable, Sendable, Identifiable {
    case h264, hevc, proRes422LT, proRes422, proRes422HQ, proRes4444
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC (H.265)"
        case .proRes422LT: return "Apple ProRes 422 LT"
        case .proRes422: return "Apple ProRes 422"
        case .proRes422HQ: return "Apple ProRes 422 HQ"
        case .proRes4444: return "Apple ProRes 4444"
        }
    }
    var type: AVVideoCodecType {
        switch self {
        case .h264: return .h264
        case .hevc: return .hevc
        case .proRes422LT: return .proRes422LT
        case .proRes422: return .proRes422
        case .proRes422HQ: return .proRes422HQ
        case .proRes4444: return .proRes4444
        }
    }
    /// H.264 is 8-bit only as Apple encodes it; HEVC Main 10 and ProRes carry Rec. 2020 and HDR.
    public var supportsWideColor: Bool { self != .h264 }
    /// ProRes is intra-frame and has no quality setting; its data rate follows from the frame size.
    public var isProRes: Bool { self != .h264 && self != .hevc }
    /// The files that can carry the encoder, the preferred one first. MPEG-4 has no ProRes mapping.
    public var containers: [VideoContainer] { isProRes ? [.mov] : [.mp4, .mov] }
    /// H.264 level 5.2 tops out at 4096 × 2304; the others go to 8K.
    public var maxPixels: (long: Int, short: Int) { self == .h264 ? (4096, 2304) : (8192, 4320) }
}

/// The movie file around the encoded frames.
public enum VideoContainer: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Plays on more devices and sites.
    case mp4
    /// What Final Cut Pro and most editors take as a source, and the only home for ProRes.
    case mov
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .mp4: return L10n.tr("MPEG-4 (.mp4)")
        case .mov: return L10n.tr("QuickTime (.mov)")
        }
    }
    public var fileType: AVFileType { self == .mp4 ? .mp4 : .mov }
    public var fileExtension: String { rawValue }
}

/// The video's color standard: Rec. 709, the HD and UHD default; Rec. 2020's wider primaries in SDR; or HDR in
/// Rec. 2100, Rec. 2020's primaries with one of its two HDR transfer functions.
public enum VideoColor: String, CaseIterable, Codable, Sendable, Identifiable {
    case sdr, rec2020, hlg, pq
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .sdr: return L10n.tr("Rec. 709 - SDR")
        case .rec2020: return L10n.tr("Rec. 2020 - SDR")
        case .hlg: return L10n.tr("Rec. 2100 HLG - HDR")
        case .pq: return L10n.tr("Rec. 2100 PQ - HDR10")
        }
    }
    public var isHDR: Bool { self == .hlg || self == .pq }
    /// What Core Image renders the frames in.
    var colorSpace: CGColorSpace {
        switch self {
        case .sdr: return CGColorSpace(name: CGColorSpace.itur_709)!
        case .rec2020: return CGColorSpace(name: CGColorSpace.itur_2020)!
        case .hlg: return CGColorSpace(name: CGColorSpace.itur_2100_HLG)!
        case .pq: return CGColorSpace(name: CGColorSpace.itur_2100_PQ)!
        }
    }
    /// The tags on each frame, as Core Video names them. Rec. 2020 SDR shares Rec. 709's transfer function.
    var bufferTags: (primaries: CFString, transfer: CFString, matrix: CFString) {
        switch self {
        case .sdr: return (kCVImageBufferColorPrimaries_ITU_R_709_2, kCVImageBufferTransferFunction_ITU_R_709_2, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        case .rec2020: return (kCVImageBufferColorPrimaries_ITU_R_2020, kCVImageBufferTransferFunction_ITU_R_709_2, kCVImageBufferYCbCrMatrix_ITU_R_2020)
        case .hlg: return (kCVImageBufferColorPrimaries_ITU_R_2020, kCVImageBufferTransferFunction_ITU_R_2100_HLG, kCVImageBufferYCbCrMatrix_ITU_R_2020)
        case .pq: return (kCVImageBufferColorPrimaries_ITU_R_2020, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, kCVImageBufferYCbCrMatrix_ITU_R_2020)
        }
    }
    /// The same tags as the encoder's settings name them.
    var colorProperties: [String: Any] {
        let tags = bufferTags
        return [AVVideoColorPrimariesKey: tags.primaries as String, AVVideoTransferFunctionKey: tags.transfer as String, AVVideoYCbCrMatrixKey: tags.matrix as String]
    }
}

/// How H.264 and HEVC spend bits: toward a constant look, or toward a predictable file size.
public enum VideoRateControl: String, CaseIterable, Codable, Sendable, Identifiable {
    case quality, bitrate
    public var id: String { rawValue }
    public var title: String { self == .quality ? L10n.tr("Constant Quality") : L10n.tr("Average Bitrate") }
}

/// A frame rate as the picker offers it: whole, or one of the NTSC rates 1000/1001 slower that broadcast and most
/// editing timelines run at.
public struct VideoFrameRate: Hashable, Sendable {
    public var framesPerSecond: Int
    public var fractional: Bool
    public init(_ framesPerSecond: Int, fractional: Bool = false) { self.framesPerSecond = framesPerSecond; self.fractional = fractional }
    public var rate: Double { fractional ? Double(framesPerSecond) * 1000 / 1001 : Double(framesPerSecond) }
    /// One frame's time, exact: 1001/24000 s at 23.976 fps.
    public var frameDuration: CMTime {
        fractional ? CMTime(value: 1001, timescale: CMTimeScale(framesPerSecond * 1000)) : CMTime(value: 1, timescale: CMTimeScale(max(1, framesPerSecond)))
    }
    public var title: String {
        fractional ? L10n.tr("\(rate.formatted(.number.precision(.fractionLength(2...3)))) fps") : L10n.tr("\(framesPerSecond) fps")
    }
    /// The whole rates that have an NTSC counterpart.
    public static let fractionalBases: Set<Int> = [24, 30, 60]
}

/// How photos become video frames: one frame each, or placed by when they were taken.
public enum TimelapseTiming: String, CaseIterable, Codable, Sendable, Identifiable {
    case perPhoto, captureTime
    public var id: String { rawValue }
    public var title: String { self == .perPhoto ? L10n.tr("One Frame per Photo") : L10n.tr("Follow Capture Time") }
}

/// What a frame that falls between two photos shows.
public enum TimelapseFill: String, CaseIterable, Codable, Sendable, Identifiable {
    /// The photo nearest in time.
    case hold
    /// The two photos mixed in proportion to how near each is, in linear light.
    case blend
    public var id: String { rawValue }
    public var title: String { self == .hold ? L10n.tr("Hold Nearest Photo") : L10n.tr("Blend Neighbors") }
}

/// The video's frame proportions.
public enum VideoAspect: String, CaseIterable, Codable, Sendable, Identifiable {
    case widescreen, standard, flat, scope, original, custom
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .widescreen: return L10n.tr("16:9")
        case .standard: return L10n.tr("4:3")
        case .flat: return L10n.tr("1.85:1 Flat")
        case .scope: return L10n.tr("2.39:1 Scope")
        case .original: return L10n.tr("As Photo")
        case .custom: return L10n.tr("Custom Size")
        }
    }
    /// Width over height; nil for the two that depend on the photo or the typed size.
    public var ratio: Double? {
        switch self {
        case .widescreen: return 16.0 / 9
        case .standard: return 4.0 / 3
        case .flat: return 1.85
        case .scope: return 2.39
        case .original, .custom: return nil
        }
    }
}

/// A size class named after its 16:9 frame. Other proportions fit inside that frame, as cinema's flat and scope
/// frames fit inside the UHD and HD containers.
public enum VideoResolution: Int, CaseIterable, Codable, Sendable, Identifiable {
    case hd720 = 720, hd1080 = 1080, qhd1440 = 1440, uhd2160 = 2160, uhd4320 = 4320
    public var id: Int { rawValue }
    public var title: String {
        switch self {
        case .hd720: return "720p HD"
        case .hd1080: return "1080p Full HD"
        case .qhd1440: return "1440p QHD"
        case .uhd2160: return "4K UHD"
        case .uhd4320: return "8K UHD"
        }
    }
    var box: CGSize { CGSize(width: Double(rawValue) * 16 / 9, height: Double(rawValue)) }
}

/// A Live Photo's still and movie on their long edges. The movie stays at 1080p or less however large the still is,
/// so a Live Photo doesn't bloat.
public enum LivePhotoSize: String, CaseIterable, Codable, Sendable, Identifiable {
    case small, iPhone, large
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .small: return L10n.tr("Small", context: "live photo size")
        case .iPhone: return "iPhone"
        case .large: return L10n.tr("Large", context: "live photo size")
        }
    }
    public var stillLongEdge: Double { switch self { case .small: 2048; case .iPhone: 4032; case .large: 8064 } }
    public var movieLongEdge: Double { self == .small ? 1280 : 1920 }
}

/// Where the video's frame sits in each photo: its center as a fraction of the photo, and its size as a fraction of
/// the largest frame of the video's proportions that fits in the photo. Kept relative so one crop suits a sequence
/// whose photos differ a little in size or proportions.
public struct TimelapseCrop: Codable, Equatable, Sendable {
    public var centerX = 0.5
    public var centerY = 0.5
    public var scale = 1.0
    public init(centerX: Double = 0.5, centerY: Double = 0.5, scale: Double = 1) { self.centerX = centerX; self.centerY = centerY; self.scale = scale }

    /// The frame in a photo of `size`, top-left origin, kept inside the photo.
    public func rect(in size: CGSize, aspect: Double) -> CGRect {
        guard size.width > 0, size.height > 0, aspect > 0 else { return .zero }
        let fit = size.width / size.height > aspect ? CGSize(width: size.height * aspect, height: size.height) : CGSize(width: size.width, height: size.width / aspect)
        let s = min(1, max(Self.minimumScale, scale))
        let width = fit.width * s, height = fit.height * s
        let x = min(max(0, centerX * size.width - width / 2), size.width - width)
        let y = min(max(0, centerY * size.height - height / 2), size.height - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
    /// The crop that frames `rect` (top-left origin) in a photo of `size`.
    public static func framing(_ rect: CGRect, in size: CGSize, aspect: Double) -> TimelapseCrop {
        guard size.width > 0, size.height > 0, aspect > 0 else { return TimelapseCrop() }
        let fitWidth = size.width / size.height > aspect ? size.height * aspect : size.width
        return TimelapseCrop(centerX: rect.midX / size.width, centerY: rect.midY / size.height, scale: min(1, max(minimumScale, rect.width / fitWidth)))
    }
    public static let minimumScale = 0.1
}

public struct TimelapseSettings: Codable, Equatable, Sendable {
    public var codec = VideoCodec.hevc
    /// As chosen; `fileContainer` is what the encoder can go in.
    public var container = VideoContainer.mp4
    public var aspect = VideoAspect.widescreen
    public var resolution = VideoResolution.uhd2160
    /// The typed size for `.custom`.
    public var customWidth = 3840
    public var customHeight = 2160
    public var framesPerSecond = 24
    /// 23.976, 29.97 or 59.94 fps in place of 24, 30 or 60.
    public var fractionalRate = false
    /// Beyond Rec. 709, HEVC and ProRes only; `fileColor` is what the encoder can write.
    public var color = VideoColor.sdr
    /// H.264 and HEVC only.
    public var rateControl = VideoRateControl.quality
    public var quality = 0.8
    /// Megabits per second, for `.bitrate`.
    public var bitrate = 60.0
    /// For `.bitrate`: the encoder reads the whole video before it spends its bits, so fast motion gets more of them and
    /// still frames fewer. Each frame is developed once per pass.
    public var multiPass = false
    /// The first frame's capture date, the series' location and its camera, in the movie's metadata.
    public var includeMetadata = true
    /// macOS only: align nearby starry skies, retaining this photo wherever evidence disagrees. Off for old presets.
    public var temporalDenoise = false
    /// Holds a tripod's view still: each photo is moved back by the drift measured on the steady parts of the scene,
    /// and the frame gives up the margin that takes. Off unless chosen.
    public var stabilize = false
    public var timing = TimelapseTiming.perPhoto
    /// For `.captureTime`: seconds of real time each video frame covers; nil follows the series' usual interval.
    public var frameStep: Double?
    public var fill = TimelapseFill.blend
    /// For `.captureTime`: pauses longer than this many usual intervals are cut to it; nil keeps real time.
    public var pauseLimit: Double? = 3
    public var crop = TimelapseCrop()
    /// For a Live Photo in place of the video's size.
    public var livePhotoSize = LivePhotoSize.iPhone
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case codec, container, aspect, resolution, customWidth, customHeight, framesPerSecond, fractionalRate, color, rateControl, quality, bitrate, multiPass,
             includeMetadata, temporalDenoise, stabilize, timing, frameStep, fill, pauseLimit, crop, livePhotoSize
    }
    /// A missing option decodes with its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        codec = try c.decodeIfPresent(VideoCodec.self, forKey: .codec) ?? codec
        container = try c.decodeIfPresent(VideoContainer.self, forKey: .container) ?? container
        aspect = try c.decodeIfPresent(VideoAspect.self, forKey: .aspect) ?? aspect
        resolution = try c.decodeIfPresent(VideoResolution.self, forKey: .resolution) ?? resolution
        customWidth = try c.decodeIfPresent(Int.self, forKey: .customWidth) ?? customWidth
        customHeight = try c.decodeIfPresent(Int.self, forKey: .customHeight) ?? customHeight
        framesPerSecond = try c.decodeIfPresent(Int.self, forKey: .framesPerSecond) ?? framesPerSecond
        fractionalRate = try c.decodeIfPresent(Bool.self, forKey: .fractionalRate) ?? fractionalRate
        color = try c.decodeIfPresent(VideoColor.self, forKey: .color) ?? color
        rateControl = try c.decodeIfPresent(VideoRateControl.self, forKey: .rateControl) ?? rateControl
        quality = try c.decodeIfPresent(Double.self, forKey: .quality) ?? quality
        bitrate = try c.decodeIfPresent(Double.self, forKey: .bitrate) ?? bitrate
        multiPass = try c.decodeIfPresent(Bool.self, forKey: .multiPass) ?? multiPass
        includeMetadata = try c.decodeIfPresent(Bool.self, forKey: .includeMetadata) ?? includeMetadata
        temporalDenoise = try c.decodeIfPresent(Bool.self, forKey: .temporalDenoise) ?? false
        stabilize = try c.decodeIfPresent(Bool.self, forKey: .stabilize) ?? false
        timing = try c.decodeIfPresent(TimelapseTiming.self, forKey: .timing) ?? timing
        frameStep = try c.decodeIfPresent(Double.self, forKey: .frameStep)
        fill = try c.decodeIfPresent(TimelapseFill.self, forKey: .fill) ?? fill
        // An absent key is the default limit; a saved null is no limit.
        if c.contains(.pauseLimit) { pauseLimit = try c.decodeIfPresent(Double.self, forKey: .pauseLimit) }
        crop = try c.decodeIfPresent(TimelapseCrop.self, forKey: .crop) ?? crop
        livePhotoSize = try c.decodeIfPresent(LivePhotoSize.self, forKey: .livePhotoSize) ?? livePhotoSize
    }

    /// The chosen container when the encoder fits in it, else the encoder's own. Switching to ProRes and back keeps
    /// the choice.
    public var fileContainer: VideoContainer { codec.containers.contains(container) ? container : codec.containers[0] }
    /// The chosen color when the encoder carries it, else Rec. 709; kept the same way as the container.
    public var fileColor: VideoColor { codec.supportsWideColor ? color : .sdr }
    /// Whether to ask the encoder for more than one pass; it may still make one where it can't.
    public var requestsMultiPass: Bool { multiPass && !codec.isProRes && rateControl == .bitrate }
    /// Frames go to the encoder as half floats when it keeps more than 8 bits: ProRes always, HEVC beyond Rec. 709.
    public var deepPixels: Bool { codec.isProRes || fileColor != .sdr }

    public var frameRate: VideoFrameRate {
        get { VideoFrameRate(framesPerSecond, fractional: fractionalRate && VideoFrameRate.fractionalBases.contains(framesPerSecond)) }
        set { framesPerSecond = newValue.framesPerSecond; fractionalRate = newValue.fractional }
    }
    public static let frameRateChoices: [VideoFrameRate] = [12, 15, 24, 25, 30, 48, 50, 60].flatMap { fps in
        VideoFrameRate.fractionalBases.contains(fps) ? [VideoFrameRate(fps, fractional: true), VideoFrameRate(fps)] : [VideoFrameRate(fps)]
    }
    public static let bitrateRange = 1.0...800.0

    public static let frameRateRange = 1...120

    /// Width over height for a sequence whose first photo is `photo`.
    public func ratio(photo: CGSize) -> Double {
        if let ratio = aspect.ratio { return ratio }
        if aspect == .custom { return Double(max(1, customWidth)) / Double(max(1, customHeight)) }
        return photo.height > 0 ? photo.width / photo.height : 16.0 / 9
    }
    /// The encoded frame size, in even pixels as the encoders require.
    public func outputSize(photo: CGSize) -> CGSize {
        func even(_ value: Double) -> Double { max(2, (value / 2).rounded() * 2) }
        if aspect == .custom { return CGSize(width: even(Double(customWidth)), height: even(Double(customHeight))) }
        let ratio = self.ratio(photo: photo), box = resolution.box
        if ratio >= box.width / box.height { return CGSize(width: even(box.width), height: even(box.width / ratio)) }
        return CGSize(width: even(box.height * ratio), height: even(box.height))
    }
    public func duration(frames: Int) -> Double { Double(frames) / max(1, frameRate.rate) }
    /// The file's size at the average bitrate; nil where the encoder sets its own.
    public func estimatedBytes(frames: Int) -> Double? {
        codec.isProRes || rateControl != .bitrate ? nil : bitrate * 1_000_000 / 8 * duration(frames: frames)
    }

    public func validate(photo: CGSize) throws {
        let size = outputSize(photo: photo)
        let long = Int(max(size.width, size.height)), short = Int(min(size.width, size.height))
        guard short >= 16 else { throw EditorError.invalidDocument(L10n.tr("The video must be at least 16 pixels on each side.")) }
        guard long <= codec.maxPixels.long, short <= codec.maxPixels.short else {
            throw EditorError.invalidDocument(L10n.tr("\(codec.title) can’t encode \(long) × \(short). Choose a smaller size or another encoder."))
        }
        guard Self.frameRateRange.contains(framesPerSecond) else {
            throw EditorError.invalidDocument(L10n.tr("Choose a frame rate from \(Self.frameRateRange.lowerBound) to \(Self.frameRateRange.upperBound) fps."))
        }
        guard codec.isProRes || rateControl != .bitrate || Self.bitrateRange.contains(bitrate) else {
            throw EditorError.invalidDocument(L10n.tr("Choose a bitrate from \(Int(Self.bitrateRange.lowerBound)) to \(Int(Self.bitrateRange.upperBound)) Mbps."))
        }
    }

    /// Rec. 709 is the color every player assumes for HD and UHD video without other tags.
    func outputSettings(size: CGSize) -> [String: Any] {
        let color = fileColor, rate = frameRate.rate
        var settings: [String: Any] = [
            AVVideoCodecKey: codec.type,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: color.colorProperties
        ]
        if !codec.isProRes {
            // A key frame each second, so editors and players can seek.
            var compression: [String: Any] = [AVVideoExpectedSourceFrameRateKey: rate, AVVideoMaxKeyFrameIntervalKey: max(1, Int(rate.rounded()))]
            switch rateControl {
            case .quality: compression[AVVideoQualityKey] = min(1, max(0, quality))
            case .bitrate: compression[AVVideoAverageBitRateKey] = Int(min(Self.bitrateRange.upperBound, max(Self.bitrateRange.lowerBound, bitrate)) * 1_000_000)
            }
            if codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
            if codec == .hevc && color != .sdr {
                compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
                // HDR10's mastering display and light level, measured by the encoder.
                if color == .pq { compression[kVTCompressionPropertyKey_HDRMetadataInsertionMode as String] = kVTHDRMetadataInsertionMode_Auto as String }
            }
            settings[AVVideoCompressionPropertiesKey] = compression
        }
        return settings
    }
}
