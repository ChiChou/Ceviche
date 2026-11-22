import Foundation

/// The kinds of reusable looks kept as ordinary files, organized in Finder or in Ceviche.
public enum LookKind: String, CaseIterable, Identifiable, Sendable {
    case presets = "Presets", profiles = "Camera Profiles", luts = "LUTs"
    public var id: String { rawValue }
    public var localizedTitle: String { L10n.key(rawValue) }
    public var extensions: Set<String> {
        switch self {
        case .presets: return ["xmp", "lrtemplate"]
        case .profiles: return ["dcp"]
        case .luts: return ["cube", "png"]
        }
    }
    public init?(file: URL) {
        let ext = file.pathExtension.lowercased()
        guard let kind = Self.allCases.first(where: { $0.extensions.contains(ext) }) else { return nil }
        self = kind
    }
}

public struct LookNode: Identifiable, Hashable, Sendable {
    public let url: URL
    public let name: String
    /// Nil for files; folders always have an array, possibly empty.
    public var children: [LookNode]?
    public var id: URL { url }
    public var isFolder: Bool { children != nil }
}

public struct LookImportSummary: Sendable, Equatable {
    public var copied: [LookKind: Int] = [:]
    public var skipped: [String] = []
    public var total: Int { copied.values.reduce(0, +) }
}

/// A folder per kind below one root. Files stay where users put them; Ceviche only
/// reads, copies in, renames, moves within a kind, and moves items to the Trash.
public struct LookLibrary: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root.standardizedFileURL }
    /// The library a catalog's resources are kept in (`CatalogStore.resources`); `localRoot` when they are in its database.
    public init(resources: ResourceStorage) { self.init(root: resources.folder?.root ?? Self.localRoot) }
    /// The build's library for iCloud catalogs: iCloud Drive in a build signed for it, otherwise `localRoot`.
    public static var standard: LookLibrary { LookLibrary(resources: .shared) }
    /// Where camera profiles are indexed from, so sidecars can name them: both libraries, and each camera's Adobe Standard.
    public static var profileFolders: [URL] {
        var roots = [localRoot.standardizedFileURL]
        if !roots.contains(standard.root) { roots.append(standard.root) }
        return roots.flatMap { [LookLibrary(root: $0).folder(.profiles), LookLibrary(root: $0).folder(.presets)] } + CameraProfileLibrary.baseProfileFolders
    }
    public static var localRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Ceviche", isDirectory: true)
    }

    public func folder(_ kind: LookKind) -> URL { root.appendingPathComponent(kind.rawValue, isDirectory: true) }

    /// Presets that ship in the app (`Contents/Resources/Presets`, filled by `app/scripts/xcode-phase.sh` from `presets/`):
    /// listed first in Presets as one read-only folder. Nil when the build has none, as in tests.
    public static var builtInPresets: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Presets", isDirectory: true),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
    /// Whether `url` is one of the app's own presets, which are never renamed, moved or trashed.
    public static func isBuiltIn(_ url: URL) -> Bool {
        guard let base = builtInPresets?.standardizedFileURL.resolvingSymlinksInPath().pathComponents else { return false }
        return url.standardizedFileURL.resolvingSymlinksInPath().pathComponents.starts(with: base)
    }

    @discardableResult
    public func prepare(_ kind: LookKind) throws -> URL {
        let url = folder(kind)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The kind whose folder contains the item, if any.
    public func kind(containing url: URL) -> LookKind? {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return LookKind.allCases.first { path.starts(with: folder($0).resolvingSymlinksInPath().pathComponents) }
    }

    /// Folders first, then files, both in Finder order. Hidden files and brush presets are skipped. Presets start with
    /// the app's built-in folder.
    public func tree(_ kind: LookKind) throws -> [LookNode] {
        let base = try prepare(kind)
        var budget = 100_000
        func list(_ directory: URL, depth: Int) -> [LookNode] {
            guard depth < 32, let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
            var folders: [LookNode] = [], files: [LookNode] = []
            for url in items where budget > 0 {
                budget -= 1
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    folders.append(LookNode(url: url, name: url.lastPathComponent, children: list(url, depth: depth + 1)))
                } else if kind.extensions.contains(url.pathExtension.lowercased()), !DevelopPreset.isBrushPreset(url) {
                    files.append(LookNode(url: url, name: url.deletingPathExtension().lastPathComponent, children: nil))
                }
            }
            let order: (LookNode, LookNode) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return folders.sorted(by: order) + files.sorted(by: order)
        }
        let builtIn = kind == .presets ? Self.builtInPresets.map { LookNode(url: $0, name: L10n.tr("Built-in"), children: list($0, depth: 1)) } : nil
        return (builtIn.map { [$0] } ?? []) + list(base, depth: 0)
    }

    /// Every file of a kind, for indexing.
    public func files(_ kind: LookKind) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: folder(kind), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { kind.extensions.contains($0.pathExtension.lowercased()) }
    }

    /// Copies files or whole folders in. Folder structure is kept; each supported file is
    /// routed to its own kind (a film pack's profiles go to Camera Profiles, presets to Presets).
    /// `destination` must be a folder of `kind`; other kinds use their root.
    public func importItems(_ sources: [URL], kind: LookKind, into destination: URL? = nil) throws -> LookImportSummary {
        for k in LookKind.allCases { try prepare(k) }
        let target = destination ?? folder(kind)
        guard self.kind(containing: target) == kind, isDirectory(target) else { throw EditorError.invalidDocument(L10n.tr("Choose a folder inside \(kind.rawValue).")) }
        var summary = LookImportSummary()
        for source in sources {
            let source = source.standardizedFileURL
            guard self.kind(containing: source) == nil else { summary.skipped.append(L10n.tr("\(source.lastPathComponent): already in the library")); continue }
            if isDirectory(source) {
                guard let walker = FileManager.default.enumerator(at: source, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
                for case let file as URL in walker where !isDirectory(file) {
                    guard let fileKind = LookKind(file: file) else { continue }
                    let base = source.resolvingSymlinksInPath().pathComponents, directory = file.deletingLastPathComponent().resolvingSymlinksInPath().pathComponents
                    let relative = directory.starts(with: base) ? Array(directory.dropFirst(base.count)) : []
                    var folderURL = (fileKind == kind ? target : folder(fileKind)).appendingPathComponent(source.lastPathComponent, isDirectory: true)
                    for part in relative { folderURL.appendPathComponent(part, isDirectory: true) }
                    copy(file, kind: fileKind, into: folderURL, summary: &summary)
                }
            } else if let fileKind = LookKind(file: source) {
                copy(source, kind: fileKind, into: fileKind == kind ? target : folder(fileKind), summary: &summary)
            } else {
                summary.skipped.append(L10n.tr("\(source.lastPathComponent): not a preset, camera profile or LUT"))
            }
        }
        return summary
    }

    private func copy(_ file: URL, kind: LookKind, into folder: URL, summary: inout LookImportSummary) {
        do {
            try Self.verify(file, kind: kind)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: file, to: Self.available(file.lastPathComponent, in: folder))
            summary.copied[kind, default: 0] += 1
        } catch { summary.skipped.append("\(file.lastPathComponent): \(error.localizedDescription)") }
    }

    /// Rejects files Ceviche cannot use, so the library only lists working items.
    static func verify(_ file: URL, kind: LookKind) throws {
        switch kind {
        case .presets:
            if DevelopPreset.isBrushPreset(file) { throw EditorError.invalidDocument(L10n.tr("local adjustment brush presets are not supported.")) }
            _ = try DevelopPreset.packet(file)
        case .profiles: _ = try CameraProfile.identity(file)
        case .luts: _ = try CreativeLUT(contentsOf: file)
        }
    }

    public func newFolder(in parent: URL, name: String = L10n.tr("New Folder")) throws -> URL {
        guard kind(containing: parent) != nil, isDirectory(parent) else { throw EditorError.invalidDocument(L10n.tr("Folders can only be created inside the library.")) }
        let url = Self.available(try Self.validName(name), in: parent)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// Renames in place. A file keeps its extension so it remains usable.
    public func rename(_ url: URL, to name: String) throws -> URL {
        guard let kind = kind(containing: url), url.standardizedFileURL != folder(kind).standardizedFileURL else { throw EditorError.invalidDocument(L10n.tr("Only library items can be renamed.")) }
        var newName = try Self.validName(name)
        if !isDirectory(url), !url.pathExtension.isEmpty, (newName as NSString).pathExtension.lowercased() != url.pathExtension.lowercased() {
            newName += "." + url.pathExtension
        }
        let destination = url.deletingLastPathComponent().appendingPathComponent(newName)
        if destination.lastPathComponent == url.lastPathComponent { return url }
        // Case-only renames are allowed on case-insensitive volumes.
        if FileManager.default.fileExists(atPath: destination.path), destination.lastPathComponent.lowercased() != url.lastPathComponent.lowercased() {
            throw EditorError.invalidDocument(L10n.tr("An item named “\(newName)” already exists."))
        }
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    /// Moves items into another folder of the same kind, never into themselves.
    @discardableResult
    public func move(_ urls: [URL], into folderURL: URL) throws -> [URL] {
        guard let kind = kind(containing: folderURL), isDirectory(folderURL) else { throw EditorError.invalidDocument(L10n.tr("Choose a library folder.")) }
        let target = folderURL.standardizedFileURL.resolvingSymlinksInPath()
        var moved: [URL] = []
        for url in urls {
            guard self.kind(containing: url) == kind else { throw EditorError.invalidDocument(L10n.tr("Items can only be moved within \(kind.rawValue).")) }
            let path = url.standardizedFileURL.resolvingSymlinksInPath()
            guard url.standardizedFileURL != folder(kind).standardizedFileURL, !target.pathComponents.starts(with: path.pathComponents) else {
                throw EditorError.invalidDocument(L10n.tr("A folder cannot be moved into itself."))
            }
            if url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path == target.path { moved.append(url); continue }
            let destination = Self.available(url.lastPathComponent, in: folderURL)
            try FileManager.default.moveItem(at: url, to: destination)
            moved.append(destination)
        }
        return moved
    }

    /// Moves items to the Trash, where Finder can restore them.
    public func trash(_ urls: [URL]) throws {
        for url in urls {
            guard let kind = kind(containing: url), url.standardizedFileURL != folder(kind).standardizedFileURL else { throw EditorError.invalidDocument(L10n.tr("Only library items can be removed.")) }
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    static func validName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 200, !trimmed.hasPrefix("."), !trimmed.contains("/"), !trimmed.contains(":"),
              !trimmed.unicodeScalars.contains(where: { $0.value < 0x20 }) else { throw EditorError.invalidDocument(L10n.tr("Enter a name without “/”, “:” or a leading period.")) }
        return trimmed
    }

    /// Finder-style unique name: "Name 2.ext".
    static func available(_ name: String, in folder: URL) -> URL {
        var candidate = folder.appendingPathComponent(name)
        let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"); n += 1
        }
        return candidate
    }

    private func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }
}
