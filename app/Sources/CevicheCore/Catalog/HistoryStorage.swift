import Foundation
import ImageIO
import UniformTypeIdentifiers

/// How developments are stored in the catalog and the iCloud mirror. Stored JSON holds no binary data:
///
/// - A mask raster belongs to its photo: a row in the `blob` table under a UUID and the photo's ID, written as
///   `@blob:<id>`. The photo's current development, History and Snapshots share it; it is deleted as soon as none
///   of them uses it, and with the photo.
/// - A LUT, camera profile or ICC profile is a file that any number of photos use, written as a `resource`
///   reference (`ResourceReference`) beside the settings that belong to the photo, such as its amount.
///
/// Inline data appears only in memory and in exported XMP. Keys are sorted, so two stored developments are equal
/// exactly when their bytes are.
public enum RevisionPayload {
    static let blobPrefix = "@blob:"

    /// A LUT, camera profile or ICC profile `encode` keeps out of the stored development.
    public struct ResourceRequest {
        public let kind: ResourceKind
        public let name: String
        /// The file the development was read from or applied from, if any.
        public let existing: ResourceReference?
        /// Stands for the contents when they are costly to produce (a LUT's samples digest).
        public let key: String?
        /// The file's bytes, produced only when no existing file fits.
        public let contents: () throws -> Data
    }

    /// Stored JSON for a development. Each mask raster goes to `blob`, which returns its blob ID; each LUT, camera
    /// profile and ICC profile goes to `resource`, which returns the file that holds it.
    public static func encode(_ adjustments: Adjustments, blob: @escaping (Data) throws -> String,
                              resource: (ResourceRequest) throws -> ResourceReference) throws -> Data {
        var settings = adjustments
        var references: [String: Any] = [:]
        if let lut = settings.lut {
            let reference = try resource(ResourceRequest(kind: lut.haldPNG == nil ? .lut : .haldLUT, name: lut.name, existing: lut.source, key: (lut.haldPNG == nil ? "lut:" : "hald:") + lut.digest) { lut.haldPNG ?? lut.cubeText })
            references["lut"] = ["name": lut.name, "amount": lut.amount, "enabled": lut.enabled, "space": lut.space.rawValue, "resource": try object(reference)]
            settings.lut = nil
        }
        if let profile = settings.cameraProfile {
            let reference = try resource(ResourceRequest(kind: .cameraProfile, name: profile.camera.isEmpty ? profile.name : "\(profile.name) (\(profile.camera))",
                                                         existing: profile.source, key: nil) { try profile.separatedContents })
            references["cameraProfile"] = ["name": profile.name, "camera": profile.camera, "amount": profile.amount, "enabled": profile.enabled, "resource": try object(reference)]
            settings.cameraProfile = nil
        }
        var colorProfile: Any?
        if let icc = settings.colorProfile.iccData {
            let existing = settings.colorProfile.source
            let reference = try resource(ResourceRequest(kind: .colorProfile, name: settings.colorProfile.name, existing: existing, key: nil) { icc })
            settings.colorProfile.iccData = nil; settings.colorProfile.source = nil
            var stored = try object(settings.colorProfile) as? [String: Any] ?? [:]
            stored["resource"] = try object(reference)
            colorProfile = stored
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.userInfo[Adjustments.sparseKey] = true
        let body = Unchecked(blob)
        // Only mask rasters are left to encode as data.
        encoder.dataEncodingStrategy = .custom { data, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(blobPrefix + body.value(data))
        }
        guard !references.isEmpty || colorProfile != nil else { return try encoder.encode(settings) }
        var stored = try JSONSerialization.jsonObject(with: encoder.encode(settings)) as? [String: Any] ?? [:]
        stored.merge(references) { _, new in new }
        if let colorProfile { stored["colorProfile"] = colorProfile }
        return try JSONSerialization.data(withJSONObject: stored, options: [.sortedKeys])
    }
    /// A development from stored JSON, reading each mask raster through `blob` and each referenced file through
    /// `resource`. Inline base64, as an imported recipe holds it, is accepted as well.
    public static func decode(_ data: Data, blob: @escaping (String) throws -> Data, resource: (ResourceReference) throws -> Data) throws -> Adjustments {
        let decoder = JSONDecoder()
        let body = Unchecked(blob)
        decoder.dataDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if string.hasPrefix(blobPrefix) { return try body.value(String(string.dropFirst(blobPrefix.count))) }
            guard let inline = Data(base64Encoded: string) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: L10n.tr("Expected a blob reference or base64 data."))
            }
            return inline
        }
        guard data.range(of: Data("\"resource\"".utf8)) != nil, var stored = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return try decoder.decode(Adjustments.self, from: data)
        }
        func reference(_ value: Any?) throws -> ResourceReference? {
            guard let value = (value as? [String: Any])?["resource"] else { return nil }
            return try JSONDecoder().decode(ResourceReference.self, from: JSONSerialization.data(withJSONObject: value))
        }
        let lut = stored["lut"] as? [String: Any], lutReference = try reference(lut)
        let profile = stored["cameraProfile"] as? [String: Any], profileReference = try reference(profile)
        if lutReference != nil { stored["lut"] = nil }
        if profileReference != nil { stored["cameraProfile"] = nil }
        // A custom color profile is validated as it decodes, so its data goes back in first.
        if var colorProfile = stored["colorProfile"] as? [String: Any], let iccReference = try reference(colorProfile) {
            colorProfile["iccData"] = try resource(iccReference).base64EncodedString()
            colorProfile["source"] = try object(iccReference); colorProfile["resource"] = nil
            stored["colorProfile"] = colorProfile
        }
        // Decoding validates the rest; the table and profile put back from resources are checked as they go in.
        var settings = try decoder.decode(Adjustments.self, from: JSONSerialization.data(withJSONObject: stored))
        if let lut, let lutReference {
            var table = try ResourceCache.shared.lut(lutReference) { try CreativeLUT(data: resource(lutReference), name: lut["name"] as? String ?? "") }
            table.name = lut["name"] as? String ?? table.name
            table.amount = lut["amount"] as? Double ?? 1; table.enabled = lut["enabled"] as? Bool ?? true
            table.space = (lut["space"] as? String).flatMap(LUTColorSpace.init(rawValue:)) ?? table.space
            table.source = lutReference
            try table.validate()
            settings.lut = table
        }
        if let profile, let profileReference {
            var separated = try ResourceCache.shared.profile(profileReference) { try JSONDecoder().decode(CameraProfile.self, from: resource(profileReference)) }
            separated.amount = profile["amount"] as? Double ?? 1; separated.enabled = profile["enabled"] as? Bool ?? true
            separated.source = profileReference
            try separated.validate()
            settings.cameraProfile = separated
        }
        return settings
    }
    /// A stored development this build can't wholly read, kept apart from what it can't read: the item of a list
    /// each failure sits in (one mask, one face) is taken out, or, outside a list or when taking the item out isn't
    /// enough, its whole setting goes back to `defaults`' (or is left out). `decode` reads stored JSON as `decode`
    /// above does. Gives the parts that went, by place ("skinTone › faces › 1"); nil when the data can't be read at
    /// all or something other than a part of it fails.
    public static func salvage(_ data: Data, defaults: Adjustments? = nil, decode: (Data) throws -> Adjustments) -> (settings: Adjustments, dropped: [String])? {
        guard var tree = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let fallback = defaults.flatMap { (try? JSONSerialization.jsonObject(with: JSONEncoder().encode($0))) as? [String: Any] } ?? [:]
        var dropped: [String] = [], reset: Set<String> = []
        // The last item taken out, to take its whole setting instead when the rest of the setting still fails.
        var lastItem: (before: [String: Any], setting: String)?
        func resetSetting(_ key: String) -> Bool {
            if reset.contains(key) { guard tree[key] != nil else { return false }; tree[key] = nil }
            else { tree[key] = fallback[key]; reset.insert(key) }
            dropped.removeAll { $0 == key || $0.hasPrefix(key + " › ") }; dropped.append(key)
            return true
        }
        for _ in 0..<64 {
            let failure: DecodingError
            do {
                return (try decode(JSONSerialization.data(withJSONObject: tree, options: [.sortedKeys])), dropped)
            } catch let error as DecodingError {
                failure = error
            } catch {
                // A value out of range, a missing mask raster or LUT: the error names no place, so the setting (or
                // list item) whose removal clears it is looked for. Failing that, the item just taken out wasn't
                // enough and its whole setting goes.
                guard let found = culprit(of: error.localizedDescription, in: tree, fallback: fallback, decode: decode) else {
                    guard let item = lastItem else { return nil }
                    tree = item.before; lastItem = nil
                    guard resetSetting(item.setting) else { return nil }
                    continue
                }
                lastItem = nil
                switch found {
                case .item(let setting, let index):
                    guard var list = tree[setting] as? [Any] else { return nil }
                    list.remove(at: index); tree[setting] = list
                    dropped.append(EditorError.place([AnyKey(setting), AnyKey(index)]))
                case .setting(let setting):
                    guard resetSetting(setting) else { return nil }
                }
                continue
            }
            var path: [CodingKey]
            switch failure {
            case .keyNotFound(let key, let context): path = context.codingPath.isEmpty ? [key] : context.codingPath
            case .valueNotFound(_, let context), .typeMismatch(_, let context), .dataCorrupted(let context): path = context.codingPath
            @unknown default: return nil
            }
            guard let setting = path.first, setting.intValue == nil else { return nil }
            lastItem = nil
            if let index = path.firstIndex(where: { $0.intValue != nil }), let edited = removingItem(at: path[...index], in: tree) as? [String: Any] {
                lastItem = (tree, setting.stringValue)
                tree = edited; dropped.append(EditorError.place(Array(path[...index])))
            } else if !resetSetting(setting.stringValue) {
                return nil
            }
        }
        return nil
    }
    private enum Culprit { case item(String, Int), setting(String) }
    /// The first list item, else the first setting, that once taken out (a setting returned to `fallback`'s) lets
    /// `tree` decode; failing that, the first that makes it fail differently from `failure`, when two parts fail.
    private static func culprit(of failure: String, in tree: [String: Any], fallback: [String: Any], decode: (Data) throws -> Adjustments) -> Culprit? {
        for strict in [true, false] {
            func clears(_ candidate: [String: Any]) -> Bool {
                guard let data = try? JSONSerialization.data(withJSONObject: candidate, options: [.sortedKeys]) else { return false }
                do { _ = try decode(data); return true } catch { return !strict && !(error is DecodingError) && error.localizedDescription != failure }
            }
            for key in tree.keys.sorted() {
                if let list = tree[key] as? [Any] {
                    for index in list.indices {
                        var candidate = tree, shorter = list
                        shorter.remove(at: index); candidate[key] = shorter
                        if clears(candidate) { return .item(key, index) }
                    }
                }
                var candidate = tree
                candidate[key] = fallback[key]
                if clears(candidate) { return .setting(key) }
            }
        }
        return nil
    }
    private struct AnyKey: CodingKey {
        let stringValue: String, intValue: Int?
        init(_ string: String) { stringValue = string; intValue = nil }
        init(_ int: Int) { stringValue = String(int); intValue = int }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { self.init(intValue) }
    }
    /// `node` without the list item `path` ends on, or nil when there is none.
    private static func removingItem(at path: ArraySlice<CodingKey>, in node: Any) -> Any? {
        guard let key = path.first else { return nil }
        let rest = path.dropFirst()
        if let index = key.intValue {
            guard var array = node as? [Any], array.indices.contains(index) else { return nil }
            if rest.isEmpty { array.remove(at: index); return array }
            guard let child = removingItem(at: rest, in: array[index]) else { return nil }
            array[index] = child
            return array
        }
        guard var object = node as? [String: Any], let value = object[key.stringValue],
              let child = removingItem(at: rest, in: value) else { return nil }
        object[key.stringValue] = child
        return object
    }
    private static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    /// Blob IDs a stored development refers to, without reading the blobs.
    public static func references(_ json: Data) throws -> Set<String> {
        guard json.range(of: Data(blobPrefix.utf8)) != nil else { return [] }
        var found: Set<String> = []
        func visit(_ object: Any) {
            switch object {
            case let string as String: if string.hasPrefix(blobPrefix) { found.insert(String(string.dropFirst(blobPrefix.count))) }
            case let dictionary as [String: Any]: dictionary.values.forEach(visit)
            case let array as [Any]: array.forEach(visit)
            default: break
            }
        }
        visit(try JSONSerialization.jsonObject(with: json))
        return found
    }

    /// A 160-pixel JPEG for History and Snapshot rows (typically 4–7 KB), made from the catalog thumbnail.
    public static func historyThumbnail(from jpeg: Data, maxPixels: Int = 160) -> Data? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}

/// Lets the `@Sendable` coding strategies call a closure that only ever runs synchronously inside the coder.
private final class Unchecked<Input, Output>: @unchecked Sendable {
    let value: (Input) throws -> Output
    init(_ value: @escaping (Input) throws -> Output) { self.value = value }
}

/// Decides which History entries to fold so long editing sessions stay readable and small.
///
/// Recent work keeps every step. Older steps are thinned like Time Machine: entries older than a day
/// fold into one per hour, older than a week into one per day, always keeping the last entry of each
/// run (it holds the state the user saw). Milestones (Original, Reset, Reverted, Imported) are never
/// folded and runs never cross them. A per-photo cap folds the oldest buckets further if needed.
public enum HistoryCompactor {
    public struct Entry: Equatable, Sendable {
        public let id: String
        public let createdAt: Date
        public let milestone: Bool
        public init(id: String, createdAt: Date, milestone: Bool) { self.id = id; self.createdAt = createdAt; self.milestone = milestone }
    }
    public static let keepAllInterval: TimeInterval = 24 * 3600
    public static let hourlyInterval: TimeInterval = 7 * 24 * 3600
    public static let maximumEntries = 200

    /// Runs of entry IDs, oldest first, each to be folded into its last entry. `entries` must be oldest first.
    public static func plan(_ entries: [Entry], now: Date = Date(), calendar: Calendar = .current) -> [[String]] {
        func bucket(_ entry: Entry, coarse: Bool) -> String? {
            let age = now.timeIntervalSince(entry.createdAt)
            guard age > keepAllInterval else { return nil }
            if coarse || age > hourlyInterval {
                let d = calendar.dateComponents([.year, .month, .day], from: entry.createdAt)
                return "d\(d.year!)-\(d.month!)-\(d.day!)"
            }
            let d = calendar.dateComponents([.year, .month, .day, .hour], from: entry.createdAt)
            return "h\(d.year!)-\(d.month!)-\(d.day!)-\(d.hour!)"
        }
        func runs(coarse: Bool) -> [[String]] {
            var result: [[String]] = [], current: [String] = [], currentBucket: String?
            func close() { if current.count > 1 { result.append(current) }; current = []; currentBucket = nil }
            for entry in entries {
                guard !entry.milestone, let key = bucket(entry, coarse: coarse) else { close(); continue }
                if key != currentBucket { close(); currentBucket = key }
                current.append(entry.id)
            }
            close()
            return result
        }
        var planned = runs(coarse: false)
        let remaining = entries.count - planned.reduce(0) { $0 + $1.count - 1 }
        // Over the cap: fold everything older than a day per day instead of per hour.
        if remaining > maximumEntries { planned = runs(coarse: true) }
        return planned
    }
}
