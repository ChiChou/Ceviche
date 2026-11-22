import Foundation
import CoreGraphics

/// How the photos' values at each pixel become one.
public enum PhotoStackMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// The middle value: anything that is somewhere in fewer than half the photos disappears.
    case median
    /// The average: smooth water and clouds, lower noise; moving things leave faint ghosts.
    case mean
    /// The average of the values near the median (sigma clipping, as in astrophotography): the mean's low noise without
    /// what passes through only some photos, such as people, birds, planes and hot pixels.
    case clippedMean
    /// The brightest value: light trails, star trails.
    case maximum
    /// The darkest value.
    case minimum
    /// The median as background, and each region where a photo differs clearly from it shown whole from that photo:
    /// a subject moving across a still scene appears once for every photo.
    case sequence
    /// Lighting passes over the base photo: each adds its light where it is brighter, without the noise that the
    /// plain maximum collects.
    case lighten
    /// The same for the darker value.
    case darken
    public var id: String { rawValue }
    /// The modes that blend what moves (clouds, water, lights) and so can keep the ground from the median or one photo.
    public var keepsGround: Bool { self == .mean || self == .clippedMean || self == .maximum || self == .minimum }
    /// Lighten and Darken blend passes over the base photo instead of reducing the photos to one.
    public var blendsOverBase: Bool { self == .lighten || self == .darken }
    public var title: String {
        switch self {
        case .median: L10n.tr("Median")
        case .mean: L10n.tr("Mean")
        case .clippedMean: L10n.tr("Clipped Mean")
        case .maximum: L10n.tr("Maximum")
        case .minimum: L10n.tr("Minimum")
        case .sequence: L10n.tr("Sequence")
        case .lighten: L10n.tr("Lighten")
        case .darken: L10n.tr("Darken")
        }
    }
    /// The menu item that opens Stack in this mode, named for what it does to the picture; nil for Minimum, which is
    /// rare enough to pick in the dialog.
    public var menuTitle: String? {
        switch self {
        case .median: L10n.tr("Remove Moving Objects…")
        case .clippedMean: L10n.tr("Multi-Frame Noise Reduction…")
        case .mean: L10n.tr("Long Exposure…")
        case .maximum: L10n.tr("Light Trails…")
        case .sequence: L10n.tr("Action Sequence…")
        case .lighten: L10n.tr("Lighten Blend…")
        case .minimum, .darken: nil
        }
    }
    /// The tool's name in the inspector's tool list, as `menuTitle` without the ellipsis.
    public var toolTitle: String? {
        switch self {
        case .median: L10n.tr("Remove Moving Objects")
        case .clippedMean: L10n.tr("Multi-Frame Noise Reduction")
        case .mean: L10n.tr("Long Exposure")
        case .maximum: L10n.tr("Light Trails")
        case .sequence: L10n.tr("Action Sequence")
        case .lighten: L10n.tr("Lighten Blend")
        case .minimum, .darken: nil
        }
    }
    /// The Stack menu's items, in order.
    public static let menuItems: [PhotoStackMode] = [.median, .clippedMean, .mean, .maximum, .lighten, .sequence]
    var code: UInt32 {
        switch self {
        case .median: 0
        case .mean: 1
        case .maximum: 2
        case .minimum: 3
        case .clippedMean: 4
        // Reduced as the median; the photos' regions are laid over it afterwards.
        case .sequence: 0
        // Not reduced at all: blended over the base (`PhotoStackBlend`).
        case .lighten, .darken: 0
        }
    }
}

public struct PhotoStackSettings: Codable, Equatable, Sendable {
    public var mode: PhotoStackMode = .median
    /// Indices left out of the stack.
    public var excluded: Set<Int> = []
    /// The frame brush's dabs, in the order painted; later dabs win where they overlap.
    public var strokes: [PhotoStackStroke] = []
    /// Which subject Action Sequence shows where two overlap.
    public var overlap: PhotoStackOverlap = .strongest
    /// Long Exposure and Light Trails: what shows below the sky.
    public var ground: PhotoStackGround = .stack
    /// Lighten and Darken: how much of each photo's light is used, by index, 0…1; 1 where absent.
    public var strengths: [Int: Double] = [:]
    /// Lighten: a photo adds only light clearly above the base, for light painting on black.
    public var strokesOnly = false
    public init() {}
}

/// What a long exposure shows below the sky, which goes on blending. An aligned series is as crisp in the mean as in
/// one photo, so this is about subjects: the median drops the haze of people who walked through, and the base photo
/// keeps one moment.
public enum PhotoStackGround: String, Codable, CaseIterable, Sendable, Identifiable {
    case stack, median, base
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .stack: L10n.tr("Stack")
        case .median: L10n.tr("Median")
        case .base: L10n.tr("Base")
        }
    }
}

/// Where two of Action Sequence's subjects overlap, the one that shows; the other is left out whole.
public enum PhotoStackOverlap: String, Codable, CaseIterable, Sendable, Identifiable {
    /// The one that differs most from the background.
    case strongest
    /// The one from the earlier photo.
    case earliest
    /// The one from the later photo.
    case latest
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .strongest: L10n.tr("Strongest")
        case .earliest: L10n.tr("First", context: "overlapping subject")
        case .latest: L10n.tr("Last", context: "overlapping subject")
        }
    }
}

/// One dab of the frame brush: where the automatic choice fails (someone who stood still, a half-removed car), it
/// shows one photo instead. Its centre and radius are in fractions of the stack's width.
public struct PhotoStackStroke: Codable, Equatable, Sendable {
    public var x: Double, y: Double, radius: Double
    /// The photo, by index, the dab shows; nil gives the area back to the stack.
    public var photo: Int?
    /// In Lighten and Darken a dab works on one photo's light instead: true takes it out there, false brings it
    /// back. nil for the frame brush.
    public var hides: Bool?
    public init(x: Double, y: Double, radius: Double, photo: Int?, hides: Bool? = nil) { self.x = x; self.y = y; self.radius = radius; self.photo = photo; self.hides = hides }
}

public struct PhotoStackFrameInfo: Sendable, Identifiable {
    public var id: Int { index }
    public let index: Int
    public let filename: String
    /// Exposure difference to the reference in stops, measured from the pixels and evened out in the stack.
    public let stops: Double
    /// Movement relative to the reference in full-size pixels; nil when it couldn't be measured and the photo is used as framed.
    public let shift: SIMD2<Double>?
    public let rotationDegrees: Double?
    public let thumbnail: CGImage?
}

public struct PhotoStackAnalysis: Sendable {
    /// In capture order.
    public let frames: [PhotoStackFrameInfo]
    /// The photo the others are aligned to and whose exposure the result keeps.
    public let reference: Int
    public let width: Int
    public let height: Int
}

public struct PhotoStackPreview: @unchecked Sendable {
    public var image: CGImage
    /// Per photo that shows instead of the stack somewhere (brushed in, or one of Action Sequence's regions), where:
    /// white where it shows alone. In Lighten and Darken, where each photo's light is brushed out.
    public let painted: [Int: CGImage]
    /// Action Sequence's subjects left out because another was in their place.
    public let leftOut: Int
    public let settings: PhotoStackSettings
    /// The preview as the result's DNG, for developing it with the Base photo's edits.
    public let source: MergePreviewSource
}
