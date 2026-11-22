import Foundation
import GRDB

/// A photo's color label: the five Lightroom and Bridge offer, so a label reads the same in their XMP (`xmp:Label`).
public enum CatalogLabel: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case red, yellow, green, blue, purple
    /// The name XMP stores, as Lightroom writes it.
    public var xmpName: String { rawValue.capitalized }
    /// A label from its XMP name, in any case; nil for a name Lightroom doesn't give a color.
    public init?(xmpName: String) {
        self.init(rawValue: xmpName.trimmingCharacters(in: .whitespaces).lowercased())
    }
}
