import Foundation
import CoreGraphics

/// How strongly the merge keeps moving things from a single photo instead of averaging the brackets.
public enum HDRDeghosting: String, Codable, CaseIterable, Sendable, Identifiable {
    case off, low, medium, high
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .off: L10n.tr("Off")
        case .low: L10n.tr("Low")
        case .medium: L10n.tr("Medium")
        case .high: L10n.tr("High")
        }
    }
    /// The difference in log radiance at which a bracket is half trusted against the reference; nil merges everything.
    var tolerance: Float? {
        switch self {
        case .off: nil
        case .low: 0.45
        case .medium: 0.25
        case .high: 0.14
        }
    }
}

/// The merge options a person chooses; exposures and alignment are measured from the photos.
public struct HDRMergeSettings: Codable, Equatable, Sendable {
    /// Index of the photo that moving things are taken from and whose exposure the result keeps; nil for the middle one.
    public var reference: Int?
    public var deghosting: HDRDeghosting = .medium
    /// Indices left out of the merge.
    public var excluded: Set<Int> = []
    /// The layer brush's dabs, in the order painted; later dabs win where they overlap.
    public var strokes: [HDRMergeStroke] = []
    public init() {}
}

/// One dab of the layer brush. Its centre and radius are in fractions of the merge's width (every photo is aligned to the
/// same frame, so a painted area stays on the same part of the scene whichever photo is the reference).
public struct HDRMergeStroke: Codable, Equatable, Sendable {
    public var x: Double, y: Double, radius: Double
    /// The photo, by index, whose layer the dab changes.
    public var photo: Int
    /// True takes the area from `photo` alone, clipped or noisy as it is there; false keeps `photo` out of it, leaving it
    /// to the others wherever they have usable light.
    public var add: Bool
    public init(x: Double, y: Double, radius: Double, photo: Int, add: Bool) {
        self.x = x; self.y = y; self.radius = radius; self.photo = photo; self.add = add
    }
}

/// What analysis found about each photo.
public struct HDRMergeFrameInfo: Sendable, Identifiable {
    public var id: Int { index }
    public let index: Int
    public let filename: String
    /// Exposure relative to the darkest photo, in stops, measured from the pixels.
    public let stops: Double
    /// Exposure the camera recorded relative to the darkest photo, when every photo has shutter, aperture and ISO.
    public let recordedStops: Double?
    /// Movement found by alignment relative to the reference, in full-size pixels and degrees; nil when it couldn't be
    /// measured and the photo is used as framed.
    public let shift: SIMD2<Double>?
    public let rotationDegrees: Double?
    /// A small sRGB picture of the photo as shot.
    public let thumbnail: CGImage?
}

public struct HDRMergeAnalysis: Sendable {
    /// In brightness order, darkest first.
    public let frames: [HDRMergeFrameInfo]
    /// Index of the middle exposure, the default reference.
    public let suggestedReference: Int
    /// Full-size output dimensions.
    public let width: Int
    public let height: Int
    /// Stops between the darkest and brightest photo.
    public var range: Double { (frames.map(\.stops).max() ?? 0) - (frames.map(\.stops).min() ?? 0) }
}

public struct HDRMergePreview: @unchecked Sendable {
    /// sRGB, highlights compressed so the merged range is visible.
    public var image: CGImage
    /// The preview as the result's DNG, for developing it with the base exposure's edits.
    public let source: MergePreviewSource
    /// Grayscale, white where moving areas were taken from the reference alone; nil with deghosting off.
    public let motion: CGImage?
    /// Fraction of the picture taken from the reference alone.
    public let motionCoverage: Double
    /// Per included photo, its share of each pixel of the result, white where the result comes from it alone.
    public let layers: [Int: CGImage]
    /// Per included photo, its share of the whole result.
    public let contributions: [Int: Double]
    public let settings: HDRMergeSettings
}
