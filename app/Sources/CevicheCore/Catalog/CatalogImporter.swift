import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision
import CoreImage

public enum CatalogImporter {
    public static let rawExtensions: Set<String> = ["arw", "srf", "sr2", "dng", "nef", "nrw", "cr2", "cr3", "crw", "raf", "orf", "rw2", "pef", "rwl", "3fr", "iiq"]
    public static func supported(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["jpg", "jpeg", "tif", "tiff", "heic", "heif", "png", "avif", "webp", "gif", "bmp"].contains(ext) || rawExtensions.contains(ext) || decodable(ext)
    }
    /// Any other image type the system can decode into pixels. Being an image is not enough: drawings such as SVG are
    /// images to the system, and nothing here can develop them.
    private static let decodableTypes = Set((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])
    private static func decodable(_ ext: String) -> Bool {
        guard let type = UTType(filenameExtension: ext), type.conforms(to: .image), !type.conforms(to: .svg) else { return false }
        return decodableTypes.contains(type.identifier)
    }
    public static func files(in urls: [URL]) throws -> [URL] {
        var result = Set<URL>()
        var explicit: [URL: URL] = [:]
        for url in urls {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            // Saved tool work exists only inside a catalog: never imported from files, never looked into.
            if LatentImage.isBundle(url) { continue }
            if values.isDirectory == true {
                guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                for case let file as URL in enumerator {
                    if LatentImage.isBundle(file) { enumerator.skipDescendants(); continue }
                    if supported(file), (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { result.insert(file.standardizedFileURL) }
                }
            } else if url.pathExtension.lowercased() == "xmp" {
                let original = try XMPPacket(url: url).originalURL(beside: url).standardizedFileURL
                if let previous = explicit[original], previous != url.standardizedFileURL {
                    throw EditorError.invalidDocument(L10n.tr("Select only one XMP sidecar per photo."))
                }
                explicit[original] = url.standardizedFileURL
            } else if supported(url) { result.insert(url.standardizedFileURL) }
        }
        for (original, sidecar) in explicit { result.remove(original); result.insert(sidecar) }
        return result.sorted { $0.path < $1.path }
    }
    /// Size and modification date read from disk. URL caches resource values, so reading twice
    /// from the same URL instance would never notice a file that changed in between.
    public static func fileStamp(_ url: URL) throws -> URLResourceValues {
        var fresh = url; fresh.removeAllCachedResourceValues()
        return try fresh.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    }
    /// Whether the file at `url` is still the imported original: the same size, and the same capture time when
    /// one was recorded. Rows from catalogs that recorded neither cannot be checked and always match.
    public static func matches(_ url: URL, fileSize: Int64?, captureTime: String?) throws -> Bool {
        guard fileSize != nil || captureTime != nil else { return true }
        let found = try fingerprint(url)
        if let fileSize, found.size != fileSize { return false }
        if let captureTime, found.captureTime != captureTime { return false }
        return true
    }
    public static func matches(_ url: URL, _ asset: CatalogAsset) throws -> Bool {
        try matches(url, fileSize: asset.fileSize, captureTime: asset.captureTime)
    }
    /// The best local URL for an original right now. Copies inside the catalog and remote caches need
    /// `root`; external volumes and SMB shares resolve through their current mount point.
    public static func sourceURL(for asset: CatalogAsset, root: URL? = nil) -> URL {
        sourceURL(locator: asset.locator, sourcePath: asset.sourcePath, bookmark: asset.bookmark, root: root)
    }
    /// The local URL of an original: a catalog copy under the catalog root, else its bookmark, a mounted
    /// volume or share, else the path recorded at import.
    public static func sourceURL(locator: AssetLocator, sourcePath: String, bookmark: Data?, root: URL?) -> URL {
        if case .catalog(let relative) = locator, let root { return catalogCopyURL(relative, root: root) }
        if let bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: .securityScopedResolution, relativeTo: nil, bookmarkDataIsStale: &stale) {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        switch locator {
        case .volume(let uuid, let relative):
            if let volume = FileSystemAssetProvider.mountedVolume(uuid: uuid) { return volume.appendingPathComponent(relative) }
        case .smb(let host, let share, let path):
            if let mount = SMBAssetProvider.mountPoint(host: host, share: share) { return mount.appendingPathComponent(path) }
        case .file, .catalog: break
        }
        return URL(fileURLWithPath: sourcePath)
    }
    /// Where the copied originals (`catalog:` locators) of the catalog at `root` live: the catalog folder, or for an
    /// iCloud catalog its folder in iCloud Drive, so every Mac reads the same files. Set when the catalog opens.
    public static func originalsRoot(for root: URL) -> URL {
        originalsLock.withLock { originalsRoots[root.standardizedFileURL.path] } ?? root
    }
    static func setOriginalsRoot(_ originals: URL, for root: URL) {
        originalsLock.withLock { originalsRoots[root.standardizedFileURL.path] = originals.standardizedFileURL }
    }
    private static let originalsLock = NSLock()
    nonisolated(unsafe) private static var originalsRoots: [String: URL] = [:]
    /// A catalog copy: in the originals root, or still in the catalog folder if it was copied before the catalog
    /// kept its originals in iCloud Drive and has not moved yet.
    public static func catalogCopyURL(_ relative: String, root: URL) -> URL {
        let shared = originalsRoot(for: root).appendingPathComponent(relative)
        guard !FileManager.default.fileExists(atPath: shared.path) else { return shared }
        let local = root.appendingPathComponent(relative)
        return FileManager.default.fileExists(atPath: local.path) ? local : shared
    }
    /// False for a file in iCloud Drive whose contents are not on this Mac yet; reading it would download it first.
    public static func isDownloaded(_ url: URL) -> Bool {
        // A URL caches resource values, so one being polled would otherwise never see the download finish.
        var url = url; url.removeAllCachedResourceValues()
        guard let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus else { return true }
        return status == .current
    }
    /// Reference leaves originals where they are; copy places them in the catalog's Originals folder.
    public enum ImportMode: String, Codable, CaseIterable, Sendable {
        case reference, copy
        public var title: String { self == .reference ? L10n.tr("Reference originals in place") : L10n.tr("Copy originals into the catalog") }
    }
    public struct ImportOptions: Sendable {
        public var mode = ImportMode.reference
        /// Required for `.copy`.
        public var catalogRoot: URL?
        /// The origin of a file that was downloaded from remote storage before import.
        public var locator: AssetLocator?
        /// Take the thumbnail from the preview the camera embedded, when it is large enough, instead of decoding
        /// the photo: some ten times faster for a RAW, which is what makes browsing a folder for the first time quick.
        public var embeddedPreview = false
        /// False reads the header only and leaves the thumbnail to be made later: a folder lists at once and its
        /// thumbnails arrive behind it.
        public var thumbnail = true
        /// With `.copy`: the folder the copy goes into, as it is, instead of the catalog's own originals. For imports
        /// made while browsing a folder, whose photos stay ordinary files there.
        public var copyFolder: URL?
        /// For a latent image, which has no capture time of its own: the day of its sources, which files it by month.
        public var objectCaptureDay: String?
        /// Counts development read from a sidecar (another raw editor's, say) as an edit, as Import XMP does, so the photo shows
        /// as Edited. Off for the Folders index, where an edit is written back to the sidecar beside the original.
        public var marksSidecarEdits = false
        public init(mode: ImportMode = .reference, catalogRoot: URL? = nil, locator: AssetLocator? = nil, embeddedPreview: Bool = false, thumbnail: Bool = true) {
            self.mode = mode; self.catalogRoot = catalogRoot; self.locator = locator; self.embeddedPreview = embeddedPreview; self.thumbnail = thumbnail
        }
    }
    /// `sidecar` names the XMP to read instead of the one found beside the photo.
    public static func prepare(_ input: URL, sidecar: URL? = nil, options: ImportOptions = ImportOptions()) throws -> (CatalogPhoto, Data?) {
        if input.pathExtension.lowercased() == "xmp" { return try prepareImage(XMPPacket(url: input).originalURL(beside: input), sidecar: input, options: options) }
        return try prepareImage(input, sidecar: sidecar, options: options)
    }
    /// Files a package a tool just saved into the catalog's originals. The only way one enters a catalog: packages are
    /// never imported from files.
    public static func prepareLatent(_ input: URL, options: ImportOptions) throws -> (CatalogPhoto, Data?) {
        let object = try LatentImage.load(input)
        // Always own the package: editing an imported object must not write to a source drive.
        guard let root = options.catalogRoot else { throw LatentImage.invalid() }
        let day = options.objectCaptureDay ?? ""
        let (url, relative) = try copyIntoCatalog(input, sidecar: nil, root: root, captureDay: day)
        do {
            var prepared = try prepareImage(url.appendingPathComponent("thumbnail.jpg"), sidecar: nil, options: ImportOptions())
            let locator = AssetLocator.catalog(relativePath: relative)
            prepared.0.importPath = locator.string; prepared.0.origin = locator.string
            prepared.0.sourcePath = url.path; prepared.0.bookmark = nil
            prepared.0.filename = input.lastPathComponent; prepared.0.kind = LatentImage.kind
            prepared.0.fileSize = nil; prepared.0.isCopy = true
            if !day.isEmpty { prepared.0.captureDay = day }
            var info = prepared.0.info; info.width = object.width; info.height = object.height
            prepared.0.infoData = try info.storedData()
            return prepared
        } catch { try? FileManager.default.removeItem(at: url); throw error }
    }
    /// Copies an original (and its sidecar) into `Originals/<capture month>/` inside the catalog, never overwriting.
    public static func copyIntoCatalog(_ url: URL, sidecar: URL?, root: URL, captureDay: String) throws -> (URL, String) {
        let month = captureDay.count >= 7 ? String(captureDay.prefix(7)) : "Undated"
        let folder = root.appendingPathComponent("Originals").appendingPathComponent(month)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = try copy(url, sidecar: sidecar, into: folder)
        return (destination, "Originals/\(month)/\(destination.lastPathComponent)")
    }
    /// Copies an original (and its sidecar) into `folder` under a free name, never overwriting.
    static func copy(_ url: URL, sidecar: URL?, into folder: URL) throws -> URL {
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var name = url.lastPathComponent, suffix = 2
        // The copy and its sidecar both need free names.
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
                || (sidecar != nil && XMPPacket.sidecarNames(for: folder.appendingPathComponent(name)).contains { FileManager.default.fileExists(atPath: $0.path) }) {
            name = ext.isEmpty ? "\(base) \(suffix)" : "\(base) \(suffix).\(ext)"; suffix += 1
        }
        let destination = folder.appendingPathComponent(name)
        try FileManager.default.copyItem(at: url, to: destination)
        if let sidecar {
            let sidecarName = sidecar.lastPathComponent.lowercased() == (url.deletingPathExtension().lastPathComponent + ".xmp").lowercased()
                ? destination.deletingPathExtension().appendingPathExtension("xmp") : destination.appendingPathExtension("xmp")
            try FileManager.default.copyItem(at: sidecar, to: sidecarName)
        }
        return destination
    }
    private static func prepareImage(_ input: URL, sidecar explicitSidecar: URL?, options: ImportOptions) throws -> (CatalogPhoto, Data?) {
        if options.mode == .copy, let folder = options.copyFolder {
            let access = input.startAccessingSecurityScopedResource(); defer { if access { input.stopAccessingSecurityScopedResource() } }
            var options = options; options.mode = .reference; options.copyFolder = nil; options.locator = nil
            // Already there: the file itself is the import.
            if CatalogFolders.path(input.deletingLastPathComponent()) == CatalogFolders.path(folder) { return try prepareImage(input, sidecar: explicitSidecar, options: options) }
            let copied = try copy(input, sidecar: try explicitSidecar ?? XMPPacket.sidecar(for: input), into: folder)
            do { return try prepareImage(copied, sidecar: nil, options: options) }
            catch { try? FileManager.default.removeItem(at: copied); throw error }
        }
        if options.mode == .copy {
            guard let root = options.catalogRoot else { throw EditorError.invalidDocument(L10n.tr("Copying originals needs an open catalog.")) }
            let access = input.startAccessingSecurityScopedResource(); defer { if access { input.stopAccessingSecurityScopedResource() } }
            let day = (try? captureDay(of: input)) ?? ""
            let (copied, relative) = try copyIntoCatalog(input, sidecar: try explicitSidecar ?? XMPPacket.sidecar(for: input), root: root, captureDay: day)
            do {
                var options = options; options.mode = .reference; options.locator = .catalog(relativePath: relative)
                var result = try prepareImage(copied, sidecar: nil, options: options)
                // The copy is the import; the card or server it came from is remembered for duplicate checks only.
                result.0.importPath = AssetLocator.catalog(relativePath: relative).string
                result.0.isCopy = true
                return result
            } catch { try? FileManager.default.removeItem(at: copied); throw error }
        }
        let url = input
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] } ?? [:]
        guard source != nil else { throw EditorError.decode }
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]
        let ext = url.pathExtension.lowercased()
        let raw = rawExtensions.contains(ext) || (source.flatMap { CGImageSourceGetType($0) }.flatMap { UTType($0 as String) }?.conforms(to: .rawImage) == true)
        // The decoded photo is upright, so a frame shot on its side is taller than wide, as the renderer reports it.
        let sideways = [5, 6, 7, 8].contains(properties[kCGImagePropertyOrientation as String] as? Int ?? 1)
        let pixelWidth = properties[kCGImagePropertyPixelWidth as String] as? Int ?? 0, pixelHeight = properties[kCGImagePropertyPixelHeight as String] as? Int ?? 0
        // The development's starting point, read once here so editing tools never open the file for it.
        let decoder = raw ? CIRAWFilter(imageURL: url) : nil
        let hdr = !raw && source.map { RawRenderer.bitmapIsHDR(url, source: $0, properties: properties) } == true
        var defaults = decoder.map(RawRenderer.cameraDefaults) ?? Adjustments()
        defaults.hdr.enabled = hdr
        var info = ImageInfo(filename: url.lastPathComponent,
            width: sideways ? pixelHeight : pixelWidth,
            height: sideways ? pixelWidth : pixelHeight,
            camera: tiff[kCGImagePropertyTIFFModel as String] as? String ?? "",
            lens: exif[kCGImagePropertyExifLensModel as String] as? String ?? "", isRAW: raw, defaults: defaults,
            lensCorrectionSupported: decoder?.isLensCorrectionSupported)
        info.defaultsFromImport = true
        let capture = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String ?? tiff[kCGImagePropertyTIFFDateTime as String] as? String ?? ""
        var metadata = CatalogMetadata()
        let day = String(capture.prefix(10)).replacingOccurrences(of: ":", with: "-")
        metadata.captureDay = day
        if (try? metadata.validated()) == nil { metadata.captureDay = "" }
        if let latitude = gps[kCGImagePropertyGPSLatitude as String] as? Double, let longitude = gps[kCGImagePropertyGPSLongitude as String] as? Double {
            metadata.latitude = latitude * ((gps[kCGImagePropertyGPSLatitudeRef as String] as? String) == "S" ? -1 : 1)
            metadata.longitude = longitude * ((gps[kCGImagePropertyGPSLongitudeRef as String] as? String) == "W" ? -1 : 1)
            if (try? metadata.validated()) == nil { metadata.latitude = nil; metadata.longitude = nil }
        }
        let extracted = try PropertyListSerialization.data(fromPropertyList: properties, format: .binary, options: 0)
        let exists = FileManager.default.fileExists(atPath: url.path)
        let bookmark = exists ? try? url.bookmarkData(options: .securityScoped, includingResourceValuesForKeys: nil, relativeTo: nil) : nil
        let locator = options.locator ?? AssetLocator.describing(url)
        // The locator is the duplicate key: one origin, one row.
        var asset = CatalogAsset(id: UUID().uuidString, importPath: locator.string,
            sourcePath: url.path, bookmark: bookmark, filename: info.filename,
            kind: raw ? "RAW" : ext.uppercased(), infoData: try info.storedData(),
            xmpWarnings: "",
            title: "", caption: "", keywords: "", rating: 0, review: .unreviewed,
            captureDay: "", latitude: nil, longitude: nil,
            suggestedTags: "", analysisVersion: nil, thumbnailKey: nil, thumbnailRenderKey: nil, renderKey: UUID().uuidString, importedAt: Date(), updatedAt: Date(), origin: locator.string)
        asset.metadata = metadata
        asset.captureTime = captureTime(exif: exif, tiff: tiff)
        asset.hdr = hdr
        asset.fileSize = exists ? (try? fileStamp(url))?.fileSize.map { Int64($0) } : nil
        asset.camera = CatalogCamera(properties: properties)
        asset.developmentUpdatedAt = asset.importedAt; asset.originalUpdatedAt = asset.importedAt
        var photo = CatalogPhoto(asset: asset, exif: CatalogExif(assetID: asset.id, extractedMetadata: extracted),
                                 development: CatalogDevelopment(assetID: asset.id, adjustmentsData: nil))
        if let sidecar = try explicitSidecar ?? XMPPacket.sidecar(for: url) {
            let imported = try XMPCodec.apply(XMPPacket(url: sidecar), to: defaults, metadata: metadata, defaults: defaults, profiles: info.profileResolver)
            photo.adjustmentsData = try JSONEncoder().encode(imported.adjustments)
            if options.marksSidecarEdits, imported.adjustments != defaults { photo.asset.lastEditedAt = photo.asset.importedAt }
            photo.metadata = imported.metadata; photo.xmpData = imported.sourceData; photo.xmpWarnings = imported.warnings.joined(separator: "\n\n")
        }
        return (photo, options.thumbnail ? source.flatMap { thumbnail(source: $0, preferEmbedded: options.embeddedPreview) } : nil)
    }
    /// `YYYY-MM-DDTHH:MM:SS` from EXIF, or nil. Camera-local, like `captureDay`.
    static func captureTime(exif: [String: Any], tiff: [String: Any]) -> String? {
        guard let raw = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String ?? exif[kCGImagePropertyExifDateTimeDigitized as String] as? String ?? tiff[kCGImagePropertyTIFFDateTime as String] as? String,
              raw.count >= 19 else { return nil }
        let day = String(raw.prefix(10)).replacingOccurrences(of: ":", with: "-"), time = String(raw.dropFirst(11).prefix(8))
        var probe = CatalogMetadata(); probe.captureDay = day
        guard (try? probe.validated()) != nil, time.count == 8 else { return nil }
        return day + "T" + time
    }
    /// Reads only the header: name, size and capture time, for duplicate checks before a full import.
    public static func fingerprint(_ url: URL) throws -> ImportFingerprint {
        let stamp = try fileStamp(url)
        var time: String?
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
            time = captureTime(exif: properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:], tiff: properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:])
        }
        return ImportFingerprint(name: url.lastPathComponent, size: stamp.fileSize.map { Int64($0) }, captureTime: time)
    }
    /// The capture time of an already opened image, for listings that read EXIF only when a photo is on screen.
    public static func captureTime(source: CGImageSource) -> String? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return nil }
        return captureTime(exif: properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:], tiff: properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:])
    }
    static func captureDay(of url: URL) throws -> String {
        try fingerprint(url).captureTime.map { String($0.prefix(10)) } ?? ""
    }
    /// Where a photo's development starts: recorded at import, or for photos imported before the catalog kept it,
    /// read from the original.
    public static func developmentDefaults(for url: URL, info: ImageInfo) -> Adjustments {
        if info.defaultsFromImport == true { return info.defaults }
        var defaults = info.defaults
        if info.isRAW, let raw = CIRAWFilter(imageURL: url) {
            defaults.temperature = min(50000, max(2000, Double(raw.neutralTemperature)))
            defaults.tint = min(150, max(-150, Double(raw.neutralTint)))
        }
        return defaults
    }
    /// Long edge of library thumbnails from every producer: the first size the largest grid tile does not upscale.
    public static let thumbnailPixelSize = 640
    /// An embedded preview shorter than this on its long edge (the 160-pixel EXIF thumbnail of a JPEG) is not used.
    static let embeddedPreviewMinimum = 480
    /// `preferEmbedded` takes the preview the camera stored in the file when it has one of a useful size; otherwise,
    /// and by default, the thumbnail is made from the photo itself.
    /// `embeddedOnly` gives nil rather than decoding the photo when the file has no such preview.
    public static func thumbnail(source: CGImageSource, preferEmbedded: Bool = false, embeddedOnly: Bool = false) -> Data? {
        func make(_ key: CFString) -> CGImage? {
            ImageDecode.thumbnail(source, 0, [key: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: thumbnailPixelSize] as CFDictionary)
        }
        let embedded = preferEmbedded || embeddedOnly ? make(kCGImageSourceCreateThumbnailFromImageIfAbsent).flatMap { max($0.width, $0.height) >= embeddedPreviewMinimum ? $0 : nil } : nil
        guard let image = embedded ?? (embeddedOnly ? nil : make(kCGImageSourceCreateThumbnailFromImageAlways)) else { return nil }
        return encodeThumbnail(image)
    }
    /// JPEG, or HEIC when the image has transparency: JPEG flattens it onto white, which shows as a white frame around
    /// a window screenshot's shadow on the dark canvas. HEIC keeps the alpha and is smaller still.
    public static func encodeThumbnail(_ image: CGImage) -> Data? {
        let opaque: Set<CGImageAlphaInfo> = [.none, .noneSkipFirst, .noneSkipLast]
        let type = opaque.contains(image.alphaInfo) ? UTType.jpeg : UTType.heic
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
    /// The thumbnail of the photo at `url`, for a record listed without one.
    public static func thumbnail(of url: URL, embeddedOnly: Bool) -> Data? {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return thumbnail(source: source, preferEmbedded: true, embeddedOnly: embeddedOnly)
    }
    public static var analysisVersion: String { "vision-classification-\(VNClassifyImageRequest.defaultRevision)-faces-\(VNDetectFaceRectanglesRequest.defaultRevision)-landmarks-\(VNDetectFaceLandmarksRequest.defaultRevision)-oriented-1600-v3" }
    /// Source analysis is independent of ratings and development changes.
    static func classify(_ url: URL, cancellation: CatalogAnalysisCancellation?) throws -> (String, String) {
        let result = try classifyLabels(url, cancellation: cancellation)
        return (result.labels.map(\.label).joined(separator: ", "), result.version)
    }
    /// Faces narrower than this share of the photo (about 16 pixels of the 1600 analysed) are mostly patterns that
    /// look like one, and not a person anyone would search the photo for.
    static let minimumFaceWidth = 0.01
    /// The labels with Vision's confidence in each, 0 to 1, and the faces Vision finds left to right, from the same
    /// decode. Each face's eyes and capture quality are measured on the box already found, at a few milliseconds a photo.
    static func classifyLabels(_ url: URL, cancellation: CatalogAnalysisCancellation?) throws -> (labels: [(label: String, confidence: Double)], faces: [CatalogFace], print: CatalogPrint?, version: String) {
        try cancellation?.check()
        // Labels need far fewer pixels than 1600: a camera preview of 1024 or more labels like the photo itself. Face
        // boxes are proportions of the photo, so a preview framed differently (letterboxed, another aspect) is not used.
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              var image = ImageDecode.analysisImage(source, url: url, pixelSize: 1600, minimum: 1024) else { throw EditorError.decode }
        if let aspect = uprightAspect(source), abs(Double(image.width) / Double(image.height) / aspect - 1) > 0.02,
           let decoded = ImageDecode.analysisImage(source, url: url, pixelSize: 1600, minimum: 1024, usesPreview: false) {
            image = decoded
        }
        let request = VNClassifyImageRequest()
        request.preferBackgroundProcessing = true
        let faces = VNDetectFaceRectanglesRequest()
        faces.preferBackgroundProcessing = true
        // The feature print for Show Similar and Find Duplicates, from the same decode: about 5 ms a photo.
        let printing = VNGenerateImageFeaturePrintRequest()
        printing.preferBackgroundProcessing = true
        try cancellation?.addRequest(request)
        defer { cancellation?.removeRequest(request) }
        try cancellation?.addRequest(faces)
        defer { cancellation?.removeRequest(faces) }
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request, faces, printing])
        let print = printing.results?.first.flatMap { CatalogPrint($0, revision: printing.revision) }
        let labels = (request.results ?? []).filter { $0.confidence >= 0.2 }.prefix(12).map { (label: $0.identifier.replacingOccurrences(of: "_", with: " "), confidence: Double($0.confidence)) }
        let found = (faces.results ?? []).filter { $0.boundingBox.width >= minimumFaceWidth }.sorted { $0.boundingBox.midX < $1.boundingBox.midX }
        var measured = found.map { CatalogFace(bounds: PhotoQualityAnalyzer.flipped($0.boundingBox)) }
        var landmarkRevision = VNDetectFaceLandmarksRequest.defaultRevision
        if !found.isEmpty {
            try cancellation?.check()
            let landmarks = VNDetectFaceLandmarksRequest()
            landmarks.preferBackgroundProcessing = true
            landmarks.inputFaceObservations = found
            let capture = VNDetectFaceCaptureQualityRequest()
            capture.preferBackgroundProcessing = true
            capture.inputFaceObservations = found
            // A request that cannot run leaves its measures out, not the faces.
            try? handler.perform([landmarks, capture])
            landmarkRevision = landmarks.revision
            let size = CGSize(width: image.width, height: image.height)
            if let results = landmarks.results, results.count == found.count {
                for (index, face) in results.enumerated() {
                    measured[index].landmarks = face.landmarks.map { Double($0.confidence) }
                    measured[index].leftEye = face.landmarks?.leftEye.flatMap { PhotoQualityAnalyzer.openness($0.pointsInImage(imageSize: size)) }
                    measured[index].rightEye = face.landmarks?.rightEye.flatMap { PhotoQualityAnalyzer.openness($0.pointsInImage(imageSize: size)) }
                }
            }
            if let results = capture.results, results.count == found.count {
                for (index, face) in results.enumerated() { measured[index].quality = face.faceCaptureQuality.map(Double.init) }
            }
        }
        return (Array(labels), measured, print, "vision-classification-\(request.revision)-faces-\(faces.revision)-landmarks-\(landmarkRevision)-oriented-1600-v3")
    }
    /// Width over height of the photo as it stands upright, from its header.
    private static func uprightAspect(_ source: CGImageSource) -> Double? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int, let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              width > 0, height > 0 else { return nil }
        let sideways = [5, 6, 7, 8].contains(properties[kCGImagePropertyOrientation as String] as? Int ?? 1)
        return sideways ? Double(height) / Double(width) : Double(width) / Double(height)
    }
}
