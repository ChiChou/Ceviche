import CoreGraphics
import CoreImage
import Foundation

/// A border that is a picture of the real thing: a film scan, a frame, a paper edge, with the place for the photo cut
/// out of it. The pictures were generated for Ceviche and keyed to transparency with `scripts/border-key.swift`, which
/// also measured the openings below; each is 1536 × 1024, so on a large file its texture is softer than the photo.
public struct BorderAsset: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    /// Everything the border leaves clear, in the picture's own proportions (0…1 from its top left, landscape): the
    /// photo fills it, running under a ragged edge where there is one.
    public let opening: CGRect
    /// False for a border with a foot (an instant print): it is stretched to an upright photo, not turned onto its side.
    public let turns: Bool

    init(_ id: String, _ title: String, _ left: Double, _ top: Double, _ right: Double, _ bottom: Double, turns: Bool = true) {
        self.id = id; self.title = title; opening = CGRect(x: left, y: top, width: right - left, height: bottom - top); self.turns = turns
    }
    /// The opening once the border is turned for an upright photo.
    var uprightOpening: CGRect { CGRect(x: opening.minY, y: 1 - opening.maxX, width: opening.height, height: opening.width) }
    var image: CIImage? { Bundle.module.url(forResource: "border-" + id, withExtension: "heic").flatMap { CIImage(contentsOf: $0) } }

    /// In this order for good: a saved recipe holds a border by its place in the list, so new ones go at the end.
    public static let all: [BorderAsset] = [
        BorderAsset("film-35mm", L10n.tr("35 mm Scan"), 0.0228, 0.1299, 0.9779, 0.8691),
        BorderAsset("film-120", L10n.tr("120 Film"), 0.0397, 0.0518, 0.9596, 0.9443),
        BorderAsset("film-4x5", L10n.tr("4×5 Sheet Film"), 0.0417, 0.0586, 0.9577, 0.9395),
        BorderAsset("carrier-filed", L10n.tr("Carrier Print"), 0.0781, 0.1016, 0.9219, 0.8984),
        BorderAsset("instant", L10n.tr("Instant Print"), 0.0384, 0.0605, 0.9616, 0.7744, turns: false),
        BorderAsset("wet-plate", L10n.tr("Wet Plate"), 0.0579, 0.0869, 0.9414, 0.9131),
        BorderAsset("frame-gallery-black", L10n.tr("Gallery Frame"), 0.1035, 0.1582, 0.8965, 0.8418),
        BorderAsset("frame-oak", L10n.tr("Oak Frame"), 0.1035, 0.1553, 0.8965, 0.8457),
        BorderAsset("frame-walnut", L10n.tr("Walnut Frame"), 0.1126, 0.1689, 0.8874, 0.8320),
        BorderAsset("frame-gilded", L10n.tr("Gilded Frame"), 0.0885, 0.1377, 0.9121, 0.8643),
        BorderAsset("frame-aluminium", L10n.tr("Aluminium Frame"), 0.0612, 0.0938, 0.9388, 0.9062),
        BorderAsset("frame-white-shadowbox", L10n.tr("Shadow Box"), 0.1406, 0.1709, 0.8594, 0.8291),
        BorderAsset("frame-double-mat", L10n.tr("Double Mat"), 0.1133, 0.1670, 0.8867, 0.8320),
        BorderAsset("deckle-print", L10n.tr("Deckle Edge"), 0.0391, 0.0654, 0.9609, 0.9346),
        BorderAsset("torn-paper", L10n.tr("Torn Paper"), 0.0651, 0.1016, 0.9349, 0.8984),
        BorderAsset("stamp-perforated", L10n.tr("Stamp"), 0.0462, 0.0713, 0.9544, 0.9287),
        BorderAsset("brush-edge", L10n.tr("Brush Edge"), 0.0085, 0.0137, 0.9909, 0.9863),
        BorderAsset("ink-roller", L10n.tr("Ink Roller"), 0.0547, 0.0869, 0.9460, 0.9160),
        BorderAsset("photo-corners", L10n.tr("Photo Corners"), 0.0514, 0.0693, 0.9505, 0.9307),
        BorderAsset("tape-corners", L10n.tr("Tape Corners"), 0.0534, 0.0840, 0.9460, 0.9160),
        BorderAsset("slide-mount", L10n.tr("Slide Mount"), 0.0671, 0.1016, 0.9336, 0.9023),
        BorderAsset("emulsion-lift", L10n.tr("Emulsion Lift"), 0.0286, 0.0371, 0.9694, 0.9639),
    ]
}
