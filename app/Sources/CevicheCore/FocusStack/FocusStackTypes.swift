import Foundation
import CoreGraphics

/// How the sharp regions of the photos are joined.
public enum FocusStackBlending: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Each region comes from the photo that is sharpest there, with transitions that follow the picture's edges.
    case labels
    /// Classic multiscale fusion: every detail scale is blended separately by sharpness. Smoother joins, but it can leave
    /// faint halos beside depth edges and soften detail where photos are equally sharp.
    case multiscale
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .labels: L10n.tr("Edge-Aware")
        case .multiscale: L10n.tr("Multiscale")
        }
    }
}

/// The merge options a person chooses; sharpness and alignment are measured from the photos.
public struct FocusStackSettings: Codable, Equatable, Sendable {
    /// Index of the photo whose framing and exposure the result keeps; nil for the middle one.
    public var reference: Int?
    /// Matches the magnification each photo's focus distance gave it; off, photos are only shifted and turned.
    public var correctBreathing = true
    /// Crops to the area every included photo covers.
    public var cropToCoverage = true
    public var blending: FocusStackBlending = .labels
    /// Indices left out of the merge.
    public var excluded: Set<Int> = []
    /// The layer brush's dabs, in the order painted; later dabs win where they overlap.
    public var strokes: [FocusStackStroke] = []
    public init() {}
}

/// One dab of the layer brush. Its position and radius are in fractions of the alignment frame's width (the photo every
/// other is aligned to), so a painted area stays on the same part of the scene whichever photo is the reference.
public struct FocusStackStroke: Codable, Equatable, Sendable {
    public var x: Double, y: Double, radius: Double
    /// The photo, by index, whose layer the dab changes.
    public var photo: Int
    /// True takes the area from `photo` alone; false keeps `photo` out of it, leaving it to the others.
    public var add: Bool
    /// Dabs that share a number are one smart selection: together they pick the connected area at the depth they
    /// touch (or, without the depth model, of the tone they touch), with edges that follow the picture. Nil paints
    /// just the dab.
    public var selection: Int?
    /// Automatic local halo repair; nil for a layer stroke. Repair strokes need no photo.
    public var repair: Bool?
    public init(x: Double, y: Double, radius: Double, photo: Int, add: Bool, selection: Int? = nil, repair: Bool? = nil) {
        self.x = x; self.y = y; self.radius = radius; self.photo = photo; self.add = add; self.selection = selection; self.repair = repair
    }
}

/// What analysis found about each photo.
public struct FocusStackFrameInfo: Sendable, Identifiable {
    public var id: Int { index }
    public let index: Int
    public let filename: String
    /// Magnification relative to the suggested reference: 1.01 shows the scene 1% larger.
    public let scale: Double?
    /// Movement of the photo's centre and its roll relative to the suggested reference, in full-size pixels and
    /// degrees; nil when alignment couldn't measure them and the photo is used as framed.
    public let shift: SIMD2<Double>?
    public let rotationDegrees: Double?
    /// How well the photo's structure matched its neighbours, 0 to 1.
    public let confidence: Double
    /// A small sRGB picture of the photo as shot.
    public let thumbnail: CGImage?
}

public struct FocusStackAnalysis: Sendable {
    /// In capture order, which is usually focus order.
    public let frames: [FocusStackFrameInfo]
    /// Index of the middle photo, the default reference.
    public let suggestedReference: Int
    /// Full-size dimensions of each photo.
    public let width: Int
    public let height: Int
}

public struct FocusStackPreview: @unchecked Sendable {
    /// GPU focus-position and confidence measurements, independent of blend mode and painted source overrides.
    /// Nil until requested, when the grid changes, or where Metal inspection is unavailable.
    /// This describes focus evidence, not physical distance.
    public var inspection: FocusStackInspection?
    /// sRGB, cropped as the result will be.
    public var image: CGImage
    /// The preview as the result's DNG, for developing it with the base photo's edits.
    public let source: MergePreviewSource
    /// The source-index map: each area in the color of the photo that supplies most of it (`FocusStackPreview.color`).
    public let sources: CGImage
    /// Per photo index, the fraction of the result it supplies most of.
    public let contributions: [Int: Double]
    /// Fraction of the result where no photo is clearly sharp: flat areas, or depths the bracket missed.
    public let uncertainCoverage: Double
    /// Output size at full resolution, after the crop.
    public let outputWidth: Int
    public let outputHeight: Int
    public let settings: FocusStackSettings
    /// Maps a point in the preview, in fractions of its width and height, to brush space (`FocusStackStroke`).
    public let toBrushSpace: CGAffineTransform
    /// A length in fractions of the preview's width, in brush space.
    public let brushScale: Double

    /// Maps a point in brush space back onto the preview, in fractions of its width and height.
    public var fromBrushSpace: CGAffineTransform { toBrushSpace.inverted() }

    /// The color of the photo at `position` among `count` photos in the source map and its legend: hues from warm
    /// (first) to cool (last), so near-to-far order reads as a gradient.
    public static func color(position: Int, count: Int) -> (red: Double, green: Double, blue: Double) {
        let t = count > 1 ? Double(position) / Double(count - 1) : 0
        let hue = 0.02 + 0.68 * t, s = 0.75, v = 0.95
        let h = hue * 6, i = Int(h) % 6, f = h - Double(Int(h))
        let p = v * (1 - s), q = v * (1 - s * f), u = v * (1 - s * (1 - f))
        switch i {
        case 0: return (v, u, p)
        case 1: return (q, v, p)
        case 2: return (p, v, u)
        case 3: return (p, q, v)
        case 4: return (u, p, v)
        default: return (v, p, q)
        }
    }
}

extension LatentImage {
    /// A focus stack's settings, layer brush strokes included; the sharpness analysis is measured again on opening.
    public static let focusStack = "focusStack"
    public init(id: String = UUID().uuidString, catalogID: String, sources: [Source], focusStack: FocusStackSettings, width: Int, height: Int) throws {
        self.init(type: Self.focusStack, id: id, catalogID: catalogID, sources: sources, settings: try JSONEncoder().encode(focusStack),
                  analysisID: "", width: width, height: height, alignedAllSky: false, alignedStrokes: [])
    }
    public func focusStackSettings() throws -> FocusStackSettings {
        guard type == Self.focusStack else { throw Self.invalid() }
        let saved = try JSONDecoder().decode(FocusStackSettings.self, from: settings), photos = 0..<sources.count
        guard saved.reference.map(photos.contains) ?? true, saved.excluded.allSatisfy(photos.contains), saved.excluded.count < sources.count - 1,
              saved.strokes.allSatisfy({ photos.contains($0.photo) && $0.x.isFinite && $0.y.isFinite && $0.radius.isFinite }) else { throw Self.invalid() }
        return saved
    }
}
