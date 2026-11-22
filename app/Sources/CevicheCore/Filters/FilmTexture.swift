import CoreImage
import Foundation

/// What a film picks up between the camera and the print: dust, hairs, scratches, drying marks. Each is a picture of
/// the marks alone, light on black, generated for Ceviche; 1536 × 1024, so on a large file the marks are softer than
/// the photo's own detail.
public struct FilmTexture: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    var image: CIImage? { Bundle.module.url(forResource: "texture-" + id, withExtension: "jpg").flatMap { CIImage(contentsOf: $0) } }

    /// In this order for good: a saved recipe holds a texture by its place in the list, so new ones go at the end.
    public static let all: [FilmTexture] = [
        FilmTexture(id: "dust-fine", title: L10n.tr("Fine Dust")), FilmTexture(id: "dust-heavy", title: L10n.tr("Heavy Dust")),
        FilmTexture(id: "hairs", title: L10n.tr("Hairs")), FilmTexture(id: "scratches-vertical", title: L10n.tr("Transport Scratches")),
        FilmTexture(id: "scratches-random", title: L10n.tr("Handling Scratches")), FilmTexture(id: "scratches-heavy", title: L10n.tr("Worn Film")),
        FilmTexture(id: "water-marks", title: L10n.tr("Drying Marks")), FilmTexture(id: "grit", title: L10n.tr("Grit")),
    ]
}
