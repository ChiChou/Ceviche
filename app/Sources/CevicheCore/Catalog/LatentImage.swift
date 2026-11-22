import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Saved tool work, named for film's latent image: it holds what one picture is made from and becomes that picture
/// only when a tool develops it into an output. A versioned package that exists only inside a catalog: its sources are
/// the catalog's own photos, and what analysis found belongs to it.
public struct LatentImage: Codable, Sendable {
    public static let fileExtension = "cevichelatent"
    public static let kind = "Latent Image"
    public var formatVersion = 1
    public var type: String
    public var typeVersion = 1
    public var analysisVersion = 1
    public var id: String
    public var catalogID: String
    public var sources: [Source]
    public var settings: Data
    public var presentation: Data? = nil
    /// UUID of an immutable analysis directory. A manifest is published only after this directory is complete. Empty
    /// for a type that keeps no analysis.
    public var analysisID: String
    public var width: Int
    public var height: Int
    /// The sky corrections a Night Sky analysis aligned with; unused by other types.
    public var alignedAllSky: Bool
    public var alignedStrokes: [NightSkyStroke]

    /// The Night Sky tools' types, each a `NightSkyTool` raw value: several photos and an analysis.
    public static let nightSkyTypes = ["starTrails", "denoise", "meteorShower"]
    /// One photo's Creative Filters stack, applied to its current development; no analysis. Other types are beside
    /// their payloads: `TimelapseLatent`, `PanoramaLatent`,
    /// and for `focusStack` its `FocusStackSettings`.
    public static let creativeFilters = "creativeFilters"

    public struct Source: Codable, Sendable {
        public var assetID: String
        public var filename: String
        public var size: Int?
        public var modified: Date?
        public init(assetID: String, url: URL) throws {
            self.assetID = assetID; filename = url.lastPathComponent
            let stamp = try CatalogImporter.fileStamp(url)
            size = stamp.fileSize; modified = stamp.contentModificationDate
        }
        public func validate(_ url: URL) throws {
            let stamp = try CatalogImporter.fileStamp(url)
            guard stamp.fileSize == size, stamp.contentModificationDate == modified else {
                throw EditorError.invalidDocument(L10n.tr("Source changed: \(filename). Create a new latent image."))
            }
        }
    }
    public init(type: String, id: String = UUID().uuidString, catalogID: String, sources: [Source], settings: Data,
                analysisID: String, width: Int, height: Int, alignedAllSky: Bool, alignedStrokes: [NightSkyStroke]) {
        self.type = type; self.id = id; self.catalogID = catalogID; self.sources = sources; self.settings = settings
        self.analysisID = analysisID; self.width = width; self.height = height
        self.alignedAllSky = alignedAllSky; self.alignedStrokes = alignedStrokes
    }
    /// A Creative Filters stack on one photo, `width` × `height` as developed.
    public init(id: String = UUID().uuidString, catalogID: String, source: Source, stack: CreativeFilterStack, width: Int, height: Int) throws {
        self.init(type: Self.creativeFilters, id: id, catalogID: catalogID, sources: [source], settings: try JSONEncoder().encode(stack),
                  analysisID: "", width: width, height: height, alignedAllSky: false, alignedStrokes: [])
    }
    /// The stack of a Creative Filters latent image.
    public func filterStack() throws -> CreativeFilterStack {
        guard type == Self.creativeFilters else { throw Self.invalid() }
        return try JSONDecoder().decode(CreativeFilterStack.self, from: settings).validated()
    }
    public static func isBundle(_ url: URL) -> Bool { url.pathExtension.lowercased() == fileExtension }
    public static func invalid() -> EditorError { .invalidDocument(L10n.tr("Invalid latent image.")) }
    public static func validatePackage(_ url: URL) throws {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]
        guard try url.resourceValues(forKeys: keys).isDirectory == true,
              try url.resourceValues(forKeys: keys).isSymbolicLink != true,
              let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { throw invalid() }
        for case let file as URL in files {
            let value = try file.resourceValues(forKeys: keys)
            guard value.isSymbolicLink != true, value.isDirectory == true || value.isRegularFile == true else { throw invalid() }
        }
    }
    public static func load(_ url: URL) throws -> Self {
        try validatePackage(url)
        struct Header: Decodable { var formatVersion: Int; var type: String; var typeVersion: Int; var analysisVersion: Int }
        let data = try Data(contentsOf: url.appendingPathComponent("manifest.json"))
        let header = try JSONDecoder().decode(Header.self, from: data)
        guard header.formatVersion == 1, header.typeVersion == 1, header.analysisVersion == 1 else {
            throw EditorError.invalidDocument(L10n.tr("Unsupported latent image version."))
        }
        guard nightSkyTypes.contains(header.type) || [creativeFilters, timelapse, panorama, focusStack].contains(header.type) else {
            throw EditorError.invalidDocument(L10n.tr("Unknown latent image type: \(header.type)."))
        }
        let object = try JSONDecoder().decode(Self.self, from: data)
        guard object.width > 0, object.height > 0, Set(object.sources.map(\.assetID)).count == object.sources.count else { throw invalid() }
        switch object.type {
        case creativeFilters:
            guard object.sources.count == 1, object.analysisID.isEmpty else { throw invalid() }
            _ = try object.filterStack()
            return object
        case timelapse:
            guard object.sources.count >= 2, object.analysisID.isEmpty else { throw invalid() }
            _ = try object.timelapseSettings()
            return object
        case focusStack:
            guard object.sources.count >= 2, object.analysisID.isEmpty else { throw invalid() }
            _ = try object.focusStackSettings()
            return object
        case panorama:
            // An HDR panorama's solution is per position, fewer than its photos.
            guard object.sources.count >= 2, object.analysisID.isEmpty else { throw invalid() }
            if let solved = try object.panoramaSettings().solved { try solved.validate(frames: solved.frameCount) }
            guard try object.panoramaSettings().solved.map({ $0.frameCount <= object.sources.count }) ?? true else { throw invalid() }
            return object
        default: break
        }
        guard UUID(uuidString: object.analysisID) != nil, object.sources.count >= 2 else { throw invalid() }
        let decoder = JSONDecoder(), count = object.sources.count
        var excluded: Set<Int>
        var reference: Int?
        switch object.type {
        case "starTrails":
            let s = try decoder.decode(StarTrailsSettings.self, from: object.settings); excluded = s.excluded; reference = s.skyPhoto
        case "denoise":
            let s = try decoder.decode(NightSkyDenoiseSettings.self, from: object.settings); excluded = s.excluded; reference = s.reference
        default:
            let s = try decoder.decode(MeteorShowerSettings.self, from: object.settings); excluded = s.excluded; reference = s.base
        }
        guard excluded.allSatisfy({ (0..<count).contains($0) }), reference == nil || (0..<count).contains(reference!) else { throw invalid() }
        return object
    }
    public func analysisURL(in bundle: URL) -> URL { bundle.appendingPathComponent(analysisID, isDirectory: true) }
    public func save(to bundle: URL, pictures: Pictures) throws {
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try pictures.thumbnail.write(to: bundle.appendingPathComponent("thumbnail.jpg"), options: .atomic)
        try pictures.preview.write(to: bundle.appendingPathComponent("preview.jpg"), options: .atomic)
        try JSONEncoder().encode(self).write(to: bundle.appendingPathComponent("manifest.json"), options: .atomic)
    }
    /// What a latent image shows in place of pixels of its own: the grid's thumbnail, and the picture Develop shows
    /// while it is open there.
    public struct Pictures: Sendable {
        public var thumbnail: Data
        public var preview: Data
    }
    public static func pictures(_ image: CGImage) throws -> Pictures {
        Pictures(thumbnail: try jpeg(image, longEdge: 320, quality: 0.75), preview: try jpeg(image, longEdge: 2560, quality: 0.85))
    }
    /// Develop's picture of the latent image in `bundle`; packages saved before it had one show their thumbnail.
    public static func previewURL(in bundle: URL) -> URL {
        let preview = bundle.appendingPathComponent("preview.jpg")
        return FileManager.default.fileExists(atPath: preview.path) ? preview : bundle.appendingPathComponent("thumbnail.jpg")
    }
    private static func jpeg(_ image: CGImage, longEdge: Double, quality: Double) throws -> Data {
        let scale = min(1, longEdge / Double(max(image.width, image.height)))
        guard let context = CGContext(data: nil, width: max(1, Int(Double(image.width) * scale)), height: max(1, Int(Double(image.height) * scale)),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw invalid() }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
        guard let small = context.makeImage() else { throw invalid() }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw invalid() }
        CGImageDestinationAddImage(destination, small, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw invalid() }
        return data as Data
    }
}

extension CatalogAsset {
    public var isLatent: Bool { kind == LatentImage.kind }
}
