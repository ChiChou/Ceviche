import Foundation
import GRDB

/// A photo's color label: the five standard `xmp:Label` names, so a label reads the same in other editors' sidecars.
public enum CatalogLabel: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case red, yellow, green, blue, purple
    /// The name XMP stores, as other editors write it.
    public var xmpName: String { rawValue.capitalized }
    /// A label from its XMP name, in any case; nil for a name that has no standard color.
    public init?(xmpName: String) {
        self.init(rawValue: xmpName.trimmingCharacters(in: .whitespaces).lowercased())
    }
}
