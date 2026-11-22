import Foundation

/// How a catalog came to be and whether it syncs. Lives in `catalog.json` beside the database.
public enum CatalogKind: String, Codable, CaseIterable, Sendable {
    /// Created implicitly in the app's own container.
    case local
    /// Created where the user chose.
    case file
    /// Synced to the user's Apple ID through iCloud; the local folder is this Mac's replica.
    case cloud
    public var title: String {
        switch self {
        case .local: return L10n.tr("Local")
        case .file: return L10n.tr("Local (chosen location)")
        case .cloud: return "iCloud"
        }
    }
}

public struct CatalogManifest: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var kind: CatalogKind
    public var createdAt: Date
    /// This Mac's path to an iCloud catalog's shared originals folder (`CatalogStore.originalsRoot`), recorded so
    /// processes without iCloud access, such as the index service, find copied originals too.
    public var originals: String?
    /// When the name last changed here; an iCloud catalog keeps whichever name changed last on any Mac.
    public var renamedAt: Date?
    public static let filename = "catalog.json"
    /// The CloudKit container every iCloud catalog shares; catalogs are told apart by `id`. A build sets its own in
    /// Info.plist (`CevicheCloudContainer`, from build.config); its iCloud Drive folder is in the same container.
    public static let cloudContainer = Bundle.main.object(forInfoDictionaryKey: "CevicheCloudContainer") as? String ?? "iCloud.me.chichou.ceviche"
    public init(id: String = UUID().uuidString, name: String, kind: CatalogKind, createdAt: Date = Date()) {
        self.id = id; self.name = name; self.kind = kind; self.createdAt = createdAt
    }
    /// The folder's manifest, or nil when it has none. One that cannot be read throws rather than being replaced, so a
    /// catalog never loses its identity to a newer build's manifest.
    public static func load(root: URL) throws -> CatalogManifest? {
        let url = root.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(CatalogManifest.self, from: Data(contentsOf: url))
    }
    public func save(root: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: root.appendingPathComponent(Self.filename), options: .atomic)
    }
    /// A manifest for a catalog folder that has none: the default one is local, any other was placed by the user.
    public static func inferred(root: URL, defaultRoot: URL) -> CatalogManifest {
        let name = root.deletingPathExtension().lastPathComponent
        let kind: CatalogKind = root.standardizedFileURL.path == defaultRoot.standardizedFileURL.path ? .local : .file
        return CatalogManifest(name: name.isEmpty ? L10n.tr("Library") : name, kind: kind)
    }
    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Ceviche/Library.cevichecatalog")
    }
    /// Where this Mac keeps its replica of an iCloud catalog.
    public static func cloudRoot(id: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Ceviche/iCloud/\(id).cevichecatalog")
    }
}
