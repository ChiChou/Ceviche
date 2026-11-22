import Foundation

/// The ID photo templates the user made: specs of their own, kept on this Mac in one JSON file beside the watermarks
/// and shared by every catalog. A template is an `IDPhotoSpec` with no country, named by its `document`.
public struct IDPhotoTemplateLibrary: Sendable {
    public let file: URL
    public init(file: URL) { self.file = file.standardizedFileURL }
    public static var standard: IDPhotoTemplateLibrary {
        IDPhotoTemplateLibrary(file: LookLibrary.localRoot.appendingPathComponent("ID Photo Templates.json"))
    }

    /// In the order they were made; any that can't be read or no longer validate are left out, but kept in the file.
    public func templates() -> [IDPhotoSpec] { stored().items }
    private func stored() -> SavedList<IDPhotoSpec> { SavedList(try? Data(contentsOf: file), keep: \.isValid) }
    /// Adds `template`, or replaces the one with its id in place.
    public func save(_ template: IDPhotoSpec) throws {
        var all = stored()
        if let index = all.items.firstIndex(where: { $0.id == template.id }) { all.items[index] = template } else { all.items.append(template) }
        try all.write(to: file)
    }
    public func delete(_ id: String) throws {
        var all = stored()
        all.items.removeAll { $0.id == id }
        try all.write(to: file)
    }
}

extension IDPhotoSpec {
    /// Made by the user rather than bundled.
    public var isCustom: Bool { country.isEmpty }
    /// A new template that starts as a copy of this spec, under `name`.
    public func template(named name: String) -> IDPhotoSpec {
        var copy = self
        copy.id = "custom-" + UUID().uuidString.lowercased()
        copy.country = ""; copy.document = name; copy.source = nil; copy.notes = nil
        return copy
    }
}
