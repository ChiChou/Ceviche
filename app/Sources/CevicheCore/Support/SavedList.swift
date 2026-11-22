import Foundation

/// A list saved as a JSON array (watermarks, presets, templates, recipes), read entry by entry. An entry this build
/// can't read, damaged or written by a newer build, is left out of `items` but kept as it was, so writing the list
/// back never loses it, and one bad entry never hides the rest.
public struct SavedList<Element: Codable> {
    public var items: [Element]
    /// The entries that didn't decode (or that `keep` refused), as they were stored.
    public let unreadable: [Any]
    /// The data was there but isn't a JSON array at all: writing over it would lose whatever it held.
    public let damaged: Bool

    public init(_ data: Data?, keep: (Element) -> Bool = { _ in true }) {
        guard let data else { items = []; unreadable = []; damaged = false; return }
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { items = []; unreadable = []; damaged = true; return }
        var items: [Element] = [], unreadable: [Any] = []
        for entry in array {
            if let json = try? JSONSerialization.data(withJSONObject: entry, options: [.fragmentsAllowed]),
               let item = try? JSONDecoder().decode(Element.self, from: json), keep(item) {
                items.append(item)
            } else {
                unreadable.append(entry)
            }
        }
        self.items = items; self.unreadable = unreadable; damaged = false
    }
    /// Every entry it read, whole: nothing unreadable was left out.
    public var isComplete: Bool { !damaged && unreadable.isEmpty }
    /// `items` followed by the entries that couldn't be read.
    public func encoded(pretty: Bool = false) throws -> Data {
        let readable = try JSONSerialization.jsonObject(with: JSONEncoder().encode(items)) as? [Any] ?? []
        return try JSONSerialization.data(withJSONObject: readable + unreadable, options: pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys])
    }
    /// Writes the list to `file`. A file that isn't a list at all is first kept beside it as `<name>.damaged.json`.
    public func write(to file: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if damaged, manager.fileExists(atPath: file.path) {
            let kept = file.deletingPathExtension().appendingPathExtension("damaged.json")
            try? manager.removeItem(at: kept)
            try? manager.copyItem(at: file, to: kept)
        }
        try encoded(pretty: true).write(to: file, options: .atomic)
    }
    /// Writes the list to `defaults` under `key`. Data that isn't a list at all is first kept under `<key>.damaged`.
    public func write(to defaults: UserDefaults, key: String) throws {
        if damaged, let old = defaults.data(forKey: key) { defaults.set(old, forKey: key + ".damaged") }
        defaults.set(try encoded(), forKey: key)
    }
}
