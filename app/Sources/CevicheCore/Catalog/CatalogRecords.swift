import Foundation
import GRDB
import ImageIO

public enum ReviewState: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case unreviewed, accepted, rejected
}

public struct CatalogMetadata: Codable, Equatable, Sendable {
    public var title = ""
    public var caption = ""
    public var keywords = ""
    public var rating = 0
    public var review = ReviewState.unreviewed
    public var label: CatalogLabel?
    /// Camera-local calendar date, deliberately not converted to this device's timezone.
    public var captureDay = ""
    public var latitude: Double?
    public var longitude: Double?
    /// Where the location came from; nil for one read from the file (the camera's GPS, or an XMP sidecar).
    public var locationSource: CatalogLocationSource?
    public init() {}
    public func validated() throws -> Self {
        guard (0...5).contains(rating), (latitude == nil) == (longitude == nil), locationSource == nil || latitude != nil else {
            throw EditorError.invalidDocument(L10n.tr("Invalid rating or incomplete location."))
        }
        if let latitude, let longitude {
            guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude) else {
                throw EditorError.invalidDocument(L10n.tr("Location must be valid latitude and longitude."))
            }
        }
        if !captureDay.isEmpty {
            let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
            guard let date = formatter.date(from: captureDay), formatter.string(from: date) == captureDay else {
                throw EditorError.invalidDocument(L10n.tr("Capture date must be YYYY-MM-DD, or empty for Unknown Date."))
            }
        }
        return self
    }
}

/// How a photo's location was set when it didn't come from the file.
public enum CatalogLocationSource: String, Codable, Sendable, DatabaseValueConvertible {
    /// Set in Ceviche: placed on the map by hand, or written by an MCP client.
    case assigned
}

public struct CatalogAsset: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "asset"
    public var id: String
    /// The duplicate key: the origin locator string (`AssetLocator`), unique per catalog.
    public var importPath: String
    /// The path the original was last read from; `sourceURL(for:root:)` prefers the catalog copy or the bookmark.
    public var sourcePath: String
    public var bookmark: Data?
    public var filename: String
    public var kind: String
    public var infoData: Data
    public var xmpWarnings: String
    public var title: String
    public var caption: String
    public var keywords: String
    public var rating: Int
    public var review: ReviewState
    public var label: CatalogLabel? = nil
    public var captureDay: String
    public var latitude: Double?
    public var longitude: Double?
    public var locationSource: CatalogLocationSource? = nil
    public var suggestedTags: String
    public var analysisVersion: String?
    public var thumbnailKey: String?
    public var thumbnailRenderKey: String?
    public var renderKey: String
    public var importedAt: Date
    /// When the photo's metadata, place in the Trash, the archive or a group, or the original's location last changed.
    public var updatedAt: Date
    public var trashedAt: Date? = nil
    /// When the photo was archived: out of the library like a trashed photo, but kept, with its file untouched, until the
    /// person moves, removes or unarchives it from the Archived view.
    public var archivedAt: Date? = nil
    /// Neither in the Trash nor archived: a photo the library shows and works on.
    public var inLibrary: Bool { area == .library }
    /// Where the original lives (`AssetLocator`); `sourcePath` and `bookmark` are how it was last resolved.
    public var origin: String
    public var fileSize: Int64? = nil
    /// EXIF capture time as `YYYY-MM-DDTHH:MM:SS`, used with the filename to recognize already-imported photos.
    public var captureTime: String? = nil
    /// The import invocation that added the photo.
    public var importBatchID: String? = nil
    /// Last development change; culling, metadata and cache writes never advance this clock.
    public var lastEditedAt: Date? = nil
    /// When the development (`CatalogDevelopment`) last changed, here or on another Mac.
    public var developmentUpdatedAt = Date.distantPast
    /// When the original's file facts or EXIF last changed: at import, or when a relink or Edit In recorded a new file.
    public var originalUpdatedAt = Date.distantPast
    /// A copy the importer made into the catalog folder, as opposed to a file referenced where it already was.
    public var isCopy = false
    /// Whether the photo opens in HDR (`RawRenderer.bitmapIsHDR`), found at import; nil for photos imported before
    /// the catalog kept it, which the renderer looks at when it opens them.
    public var hdr: Bool? = nil
    /// Where the suggested tags come from: `local` when this Mac analyzes the photo (it imported it, or the person
    /// asked for it here), `remote` when another Mac's result is the source of truth and this Mac never analyzes it.
    public var analysisOrigin = "local"
    /// When the suggested tags were produced; the later result wins if the photo is analyzed again.
    public var analyzedAt: Date? = nil
    /// The group the photo was put in, named by the group's cover: its earliest photo, which stands for the whole
    /// group in the library until the group is expanded.
    public var stackID: String? = nil
    /// Camera and exposure from the original's EXIF, kept as columns so they can be searched and filtered; the full
    /// metadata stays in `extractedMetadata`.
    public var cameraMake: String? = nil
    public var cameraModel: String? = nil
    public var lensMake: String? = nil
    public var lensModel: String? = nil
    /// Who took the photo, for catalogs that mix several photographers' work.
    public var artist: String? = nil
    /// Millimetres, as recorded and as the 35 mm equivalent.
    public var focalLength: Double? = nil
    public var focalLength35mm: Double? = nil
    public var fNumber: Double? = nil
    /// Seconds.
    public var exposureTime: Double? = nil
    public var iso: Int? = nil
    /// Stops; nil when not recorded.
    public var exposureBias: Double? = nil
    /// Nil when the camera did not record whether the flash fired.
    public var flashFired: Bool? = nil
    /// Where the photo was taken, by name, in the language of the Mac that looked it up (`CatalogPlace`).
    public var placeCountry: String? = nil
    public var placeRegion: String? = nil
    public var placeCity: String? = nil
    /// How the place was found (`CatalogPlace.Source`); nil when it has not been looked up.
    public var placeSource: String? = nil
    /// Typed column references for queries.
    public enum Columns {
        public static let id = Column(CodingKeys.id), importPath = Column(CodingKeys.importPath), sourcePath = Column(CodingKeys.sourcePath)
        public static let bookmark = Column(CodingKeys.bookmark), filename = Column(CodingKeys.filename)
        public static let kind = Column(CodingKeys.kind), infoData = Column(CodingKeys.infoData), xmpWarnings = Column(CodingKeys.xmpWarnings)
        public static let title = Column(CodingKeys.title), caption = Column(CodingKeys.caption), keywords = Column(CodingKeys.keywords)
        public static let rating = Column(CodingKeys.rating), review = Column(CodingKeys.review), label = Column(CodingKeys.label), captureDay = Column(CodingKeys.captureDay)
        public static let latitude = Column(CodingKeys.latitude), longitude = Column(CodingKeys.longitude), locationSource = Column(CodingKeys.locationSource)
        public static let suggestedTags = Column(CodingKeys.suggestedTags)
        public static let analysisVersion = Column(CodingKeys.analysisVersion), thumbnailKey = Column(CodingKeys.thumbnailKey)
        public static let thumbnailRenderKey = Column(CodingKeys.thumbnailRenderKey), renderKey = Column(CodingKeys.renderKey)
        public static let importedAt = Column(CodingKeys.importedAt), updatedAt = Column(CodingKeys.updatedAt), trashedAt = Column(CodingKeys.trashedAt)
        public static let archivedAt = Column(CodingKeys.archivedAt)
        /// Photos in `area`.
        public static func area(_ area: CatalogArea) -> SQLExpression {
            switch area {
            case .library: trashedAt == nil && archivedAt == nil
            case .trash: trashedAt != nil
            case .archive: trashedAt == nil && archivedAt != nil
            }
        }
        public static let origin = Column(CodingKeys.origin), fileSize = Column(CodingKeys.fileSize), captureTime = Column(CodingKeys.captureTime)
        public static let importBatchID = Column(CodingKeys.importBatchID), lastEditedAt = Column(CodingKeys.lastEditedAt), isCopy = Column(CodingKeys.isCopy)
        public static let analysisOrigin = Column(CodingKeys.analysisOrigin), analyzedAt = Column(CodingKeys.analyzedAt)
        public static let stackID = Column(CodingKeys.stackID)
        public static let developmentUpdatedAt = Column(CodingKeys.developmentUpdatedAt), originalUpdatedAt = Column(CodingKeys.originalUpdatedAt)
        public static let cameraMake = Column(CodingKeys.cameraMake), cameraModel = Column(CodingKeys.cameraModel), lensModel = Column(CodingKeys.lensModel)
        public static let lensMake = Column(CodingKeys.lensMake), artist = Column(CodingKeys.artist)
        public static let exposureBias = Column(CodingKeys.exposureBias), flashFired = Column(CodingKeys.flashFired)
        public static let focalLength = Column(CodingKeys.focalLength), focalLength35mm = Column(CodingKeys.focalLength35mm)
        public static let fNumber = Column(CodingKeys.fNumber), exposureTime = Column(CodingKeys.exposureTime), iso = Column(CodingKeys.iso)
        public static let placeCountry = Column(CodingKeys.placeCountry), placeRegion = Column(CodingKeys.placeRegion), placeCity = Column(CodingKeys.placeCity)
        public static let placeSource = Column(CodingKeys.placeSource)
    }
    /// The image facts recorded at import. `infoData` is this app's own encoding, and rows from another Mac are checked
    /// on arrival; a row that still can't be read (a damaged catalog, a newer build's encoding) stands in as a photo
    /// with only its name, rather than taking the catalog down with it.
    public var info: ImageInfo {
        (try? JSONDecoder().decode(ImageInfo.self, from: infoData)) ?? ImageInfo(filename: filename, width: 3, height: 2, isRAW: false, defaults: Adjustments())
    }
    /// Size or capture time recorded at import, so a located file can be told apart from a different one.
    public var hasOriginalIdentity: Bool { fileSize != nil || captureTime != nil }
    public var metadata: CatalogMetadata {
        get {
            var m = CatalogMetadata(); m.title = title; m.caption = caption; m.keywords = keywords
            m.rating = rating; m.review = review; m.label = label
            m.captureDay = captureDay; m.latitude = latitude; m.longitude = longitude; m.locationSource = locationSource
            return m
        }
        set {
            title = newValue.title; caption = newValue.caption; keywords = newValue.keywords
            rating = newValue.rating; review = newValue.review; label = newValue.label; captureDay = newValue.captureDay
            latitude = newValue.latitude; longitude = newValue.longitude; locationSource = newValue.locationSource
        }
    }
}

/// The original's properties as ImageIO read them at import. A photo's EXIF doesn't change, so this row is
/// written once, apart from the rows edits rewrite.
public struct CatalogExif: Codable, Equatable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "assetExif"
    public var assetID: String
    /// Every ImageIO property of the original, as a binary property list.
    public var extractedMetadata: Data
    public init(assetID: String, extractedMetadata: Data) { self.assetID = assetID; self.extractedMetadata = extractedMetadata }
}

/// The photo's development and the XMP it came with: what editing rewrites, kept apart from `CatalogAsset` so
/// browsing and filtering never read it.
public struct CatalogDevelopment: Codable, Equatable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "assetDevelopment"
    public var assetID: String
    /// The development (`RevisionPayload`); nil until the photo is edited.
    public var adjustmentsData: Data?
    /// The XMP sidecar read at import, until its settings are applied.
    public var xmpData: Data?
    public init(assetID: String, adjustmentsData: Data? = nil, xmpData: Data? = nil) {
        self.assetID = assetID; self.adjustmentsData = adjustmentsData; self.xmpData = xmpData
    }
}

/// A photo whole: its `asset` row, its EXIF and its development, as the importer prepares one and a view of one
/// photo reads it. The fields of all three are reachable directly (`photo.filename`, `photo.adjustmentsData`).
@dynamicMemberLookup
public struct CatalogPhoto: Sendable {
    public var asset: CatalogAsset
    public var exif: CatalogExif
    public var development: CatalogDevelopment
    public init(asset: CatalogAsset, exif: CatalogExif, development: CatalogDevelopment) {
        self.asset = asset; self.exif = exif; self.development = development
    }
    public subscript<Value>(dynamicMember path: WritableKeyPath<CatalogAsset, Value>) -> Value {
        get { asset[keyPath: path] }
        set { asset[keyPath: path] = newValue }
    }
    public subscript<Value>(dynamicMember path: WritableKeyPath<CatalogExif, Value>) -> Value {
        get { exif[keyPath: path] }
        set { exif[keyPath: path] = newValue }
    }
    public subscript<Value>(dynamicMember path: WritableKeyPath<CatalogDevelopment, Value>) -> Value {
        get { development[keyPath: path] }
        set { development[keyPath: path] = newValue }
    }
    public subscript<Value>(dynamicMember path: KeyPath<CatalogAsset, Value>) -> Value { asset[keyPath: path] }
    /// Keeps the EXIF and development on the photo when the id changes.
    public var id: String {
        get { asset.id }
        set { asset.id = newValue; exif.assetID = newValue; development.assetID = newValue }
    }
}

public struct CatalogRevision: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "revision"
    /// A development step, or a change to the user's metadata.
    public enum Kind: String, Codable, Sendable, DatabaseValueConvertible { case edit, metadata }
    public var id: String
    public var assetID: String
    public var kind: Kind
    public var summary: String
    /// Packed development or metadata JSON; read developments through `CatalogStore.adjustments(of:)`.
    public var payload: Data
    public var createdAt: Date
    /// A 160-pixel JPEG of the development, when one was rendered.
    public var thumbnail: Data? = nil
    /// Original, Reset, Reverted and Imported steps; never folded.
    public var milestone = false
    public enum Columns {
        public static let id = Column(CodingKeys.id), assetID = Column(CodingKeys.assetID), kind = Column(CodingKeys.kind)
        public static let summary = Column(CodingKeys.summary), payload = Column(CodingKeys.payload), createdAt = Column(CodingKeys.createdAt)
        public static let thumbnail = Column(CodingKeys.thumbnail), milestone = Column(CodingKeys.milestone)
    }
}

/// A mask raster one photo's developments refer to by `id` (see `RevisionPayload`). Written once and never changed;
/// deleted when none of the photo's developments uses it, and with the photo.
public struct CatalogBlob: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "blob"
    public var id: String
    public var assetID: String
    public var data: Data
    public enum Columns { public static let id = Column(CodingKeys.id), assetID = Column(CodingKeys.assetID), data = Column(CodingKeys.data) }
}

/// A development the user saved by name; never folded or pruned.
public struct CatalogSnapshot: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    public static let databaseTableName = "snapshot"
    public var id: String
    public var assetID: String
    public var name: String
    public var payload: Data
    public var thumbnail: Data?
    public var createdAt: Date
    public enum Columns {
        public static let id = Column(CodingKeys.id), assetID = Column(CodingKeys.assetID), name = Column(CodingKeys.name)
        public static let payload = Column(CodingKeys.payload), thumbnail = Column(CodingKeys.thumbnail), createdAt = Column(CodingKeys.createdAt)
    }
}

/// How the library grid is ordered. Capture date is the default; ties fall back to capture time and ID.
public enum CatalogSort: String, CaseIterable, Codable, Sendable {
    case captureDate, filename, importDate, rating, edited
    public var title: String {
        switch self {
        case .captureDate: return L10n.tr("Capture Date")
        case .filename: return L10n.tr("File Name")
        case .importDate: return L10n.tr("Import Date")
        case .rating: return L10n.tr("Rating")
        case .edited: return L10n.tr("Last Edited")
        }
    }
    public var ascendingTitle: String { self == .filename ? L10n.tr("A to Z") : self == .rating ? L10n.tr("Lowest First") : L10n.tr("Oldest First") }
    public var descendingTitle: String { self == .filename ? L10n.tr("Z to A") : self == .rating ? L10n.tr("Highest First") : L10n.tr("Newest First") }
    /// Newest, highest or Z first when `ascending` is false (the default).
    public var defaultAscending: Bool { self == .filename }
}

/// Where a photo is: the library, the Trash, or the archive (`CatalogAsset.archivedAt`). A photo both archived and
/// trashed is in the Trash.
public enum CatalogArea: String, Sendable, CaseIterable {
    case library, trash, archive
    /// The same condition as `CatalogAsset.Columns.area`, in SQL, for the photo table named `table`.
    public func sql(_ table: String = "") -> String {
        let prefix = table.isEmpty ? "" : table + "."
        switch self {
        case .library: return "\(prefix)trashedAt IS NULL AND \(prefix)archivedAt IS NULL"
        case .trash: return "\(prefix)trashedAt IS NOT NULL"
        case .archive: return "\(prefix)trashedAt IS NULL AND \(prefix)archivedAt IS NOT NULL"
        }
    }
}

extension CatalogAsset {
    public var area: CatalogArea { trashedAt != nil ? .trash : archivedAt != nil ? .archive : .library }
}

public struct CatalogFilter: Equatable, Sendable {
    public var sort = CatalogSort.captureDate
    public var ascending = false
    /// The library, the Trash or the archive; every other part of the filter narrows the photos there.
    public var area = CatalogArea.library
    public var geotagged = false
    /// True for photos with both coordinates, false for those missing either; nil for any.
    public var hasLocation: Bool?
    /// Whole keywords or automatic tags, compared case-insensitively.
    public var tags: CatalogTagFilter?
    /// The Faces collection: photos background analysis found a face in.
    public var withFaces = false
    /// The photos with a face of this person (`CatalogPerson`).
    public var personID: String?
    /// A place on the Map: the photos whose coordinates fall in this box.
    public var mapArea: CatalogMapArea?
    public var albumID: String?
    /// A folder on disk, by path: the photos whose originals sit directly in it (`CatalogStore.folderCondition`).
    public var folder: String?
    /// With `folder`: the folders below it as well.
    public var subfolders = false
    /// Matches no photo: browsing folders with no folder chosen yet. The index of browsed folders is not a collection
    /// to show by itself.
    public var nothing = false
    public var recentlyAdded = false
    /// Device-local import day (YYYY-MM-DD); independent of the camera capture date.
    public var importDay: String?
    public var importBatchID: String?
    public var recentEdits = false
    public var search = ""
    public var minimumRating = 0
    public var review: ReviewState?
    public var label: CatalogLabel?
    public var kind: String?
    /// Focal lengths in millimetres, each standing for the lengths that round to it.
    public var focalLength: ClosedRange<Int>?
    /// Third stops of each `CatalogExposureScale`.
    public var aperture: ClosedRange<Int>?
    public var shutter: ClosedRange<Int>?
    public var iso: ClosedRange<Int>?
    /// Whether the flash fired; nil for any.
    public var flash: Bool?
    public var orientation: CatalogOrientation?
    public var faces: CatalogFaces?
    /// A day (YYYY-MM-DD), month (YYYY-MM) or year (YYYY); empty matches photos with no date.
    public var captureDay: String?
    /// Groups shown photo by photo; every other group shows only its cover.
    public var expandedStacks: Set<String> = []
    /// Every photo of every group, as if all were expanded: for work on the photos themselves, such as culling.
    public var everyGroupedPhoto = false
    /// Photos found by comparing pictures (Show Similar, Duplicates), shown in the order found.
    public var photoSet: CatalogPhotoSet?
    public init() {}
    public subscript(scale: CatalogExposureScale) -> ClosedRange<Int>? {
        get {
            switch scale {
            case .aperture: aperture
            case .shutter: shutter
            case .iso: iso
            }
        }
        set {
            switch scale {
            case .aperture: aperture = newValue
            case .shutter: shutter = newValue
            case .iso: iso = newValue
            }
        }
    }
    /// True when search, culling, file type, the settings, orientation or capture date narrows the selected collection.
    /// Differs from `old` only in what is typed or dragged (the search, the exposure ranges), which change many times
    /// a second, so their queries are throttled.
    public func changesContinuously(from old: CatalogFilter) -> Bool {
        var a = self, b = old
        guard a.search != b.search || a.focalLength != b.focalLength || a.aperture != b.aperture || a.shutter != b.shutter || a.iso != b.iso else { return false }
        a.search = ""; b.search = ""; a.focalLength = nil; b.focalLength = nil; a.aperture = nil; b.aperture = nil
        a.shutter = nil; b.shutter = nil; a.iso = nil; b.iso = nil
        return a == b
    }
    /// Matches by what background analysis found (tags, faces), so its results can change the photos shown.
    public var followsAnalysis: Bool { !search.isEmpty || faces != nil || withFaces }
    public var isRefined: Bool {
        !search.isEmpty || minimumRating > 0 || review != nil || label != nil || kind != nil || captureDay != nil || focalLength != nil
            || aperture != nil || shutter != nil || iso != nil || flash != nil || orientation != nil || faces != nil
    }
}

/// Photos with every tag in `all`, at least one in `any` (when it isn't empty) and none in `none`, each a whole tag
/// from one of `sources` (keywords, automatic tags or both).
public struct CatalogTagFilter: Equatable, Sendable {
    public var all: [String] = [], any: [String] = [], none: [String] = []
    public var sources: [CatalogTagSource] = [.keyword, .automatic]
    public init(all: [String] = [], any: [String] = [], none: [String] = [], sources: [CatalogTagSource] = [.keyword, .automatic]) {
        self.all = all; self.any = any; self.none = none; self.sources = sources
    }
}

/// A box of latitudes and longitudes: the photos of one pin on the Map.
public struct CatalogMapArea: Equatable, Sendable {
    public var south: Double, north: Double, west: Double, east: Double
    public init(south: Double, north: Double, west: Double, east: Double) {
        self.south = south; self.north = north; self.west = west; self.east = east
    }
    /// The smallest box holding these coordinates, a hair wider so the photos at its edges stay in it.
    public init?(around points: [(latitude: Double, longitude: Double)]) {
        guard let first = points.first else { return nil }
        var box = CatalogMapArea(south: first.latitude, north: first.latitude, west: first.longitude, east: first.longitude)
        for p in points.dropFirst() {
            box.south = min(box.south, p.latitude); box.north = max(box.north, p.latitude)
            box.west = min(box.west, p.longitude); box.east = max(box.east, p.longitude)
        }
        let margin = 1e-6
        box.south -= margin; box.north += margin; box.west -= margin; box.east += margin
        self = box
    }
}

/// Photos found by what they show, in order: those like one photo, nearest first, or duplicates, each photo beside its
/// copies.
public struct CatalogPhotoSet: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case similar(to: String)
        case duplicates
    }
    public var kind: Kind
    public var ids: [String]
    public init(kind: Kind, ids: [String]) { self.kind = kind; self.ids = ids }
    /// The ids as a JSON array, for SQLite's `json_each`.
    var json: String { (try? String(data: JSONEncoder().encode(ids), encoding: .utf8)) ?? "[]" }
}

public struct CatalogGroups: Sendable {
    /// Capture days, newest first; empty for photos with no date.
    public let dates: [String]
    /// Photos per capture day.
    public let dayCounts: [String: Int]
    public let kinds: [String]
    public let total: Int
    public let trash: Int
    public let archive: Int
}

/// Camera and exposure from the original's EXIF, as `CatalogAsset` stores them in columns.
public struct CatalogCamera: Equatable, Sendable {
    public var make: String?
    public var model: String?
    public var lensMake: String?
    public var lens: String?
    public var artist: String?
    public var focalLength: Double?
    public var focalLength35mm: Double?
    public var fNumber: Double?
    public var exposureTime: Double?
    public var iso: Int?
    public var exposureBias: Double?
    public var flashFired: Bool?
    public init() {}
    /// From ImageIO properties of the original.
    public init(properties: [String: Any]) {
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let aux = properties[kCGImagePropertyExifAuxDictionary as String] as? [String: Any] ?? [:]
        func text(_ value: Any?) -> String? {
            guard let value = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)), !value.isEmpty else { return nil }
            return value
        }
        func number(_ value: Any?) -> Double? {
            guard let value = (value as? NSNumber)?.doubleValue, value.isFinite, value > 0 else { return nil }
            return value
        }
        let iptc = properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any] ?? [:]
        make = text(tiff[kCGImagePropertyTIFFMake as String]).map(Self.brand)
        model = text(tiff[kCGImagePropertyTIFFModel as String])
        lensMake = text(exif[kCGImagePropertyExifLensMake as String]).map(Self.brand)
        lens = text(exif[kCGImagePropertyExifLensModel as String]) ?? text(aux[kCGImagePropertyExifAuxLensModel as String])
        artist = text(tiff[kCGImagePropertyTIFFArtist as String]) ?? text((iptc[kCGImagePropertyIPTCByline as String] as? [Any])?.first)
        focalLength = number(exif[kCGImagePropertyExifFocalLength as String])
        focalLength35mm = number(exif[kCGImagePropertyExifFocalLenIn35mmFilm as String])
        fNumber = number(exif[kCGImagePropertyExifFNumber as String])
        exposureTime = number(exif[kCGImagePropertyExifExposureTime as String])
        let speed = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue ?? number(exif[kCGImagePropertyExifRecommendedExposureIndex as String])
        iso = speed.flatMap { $0 > 0 && $0 < 10_000_000 ? Int($0) : nil }
        exposureBias = (exif[kCGImagePropertyExifExposureBiasValue as String] as? NSNumber).map(\.doubleValue).flatMap { $0.isFinite && abs($0) <= 20 ? $0 : nil }
        flashFired = (exif[kCGImagePropertyExifFlash as String] as? NSNumber).map { $0.intValue & 1 == 1 }
    }
    /// The maker's name without its company suffix: "NIKON CORPORATION" is NIKON, "OLYMPUS IMAGING CORP." is OLYMPUS.
    static func brand(_ make: String) -> String {
        let suffix = #"[\s,]+(corporation|corp\.?|imaging|company|camera|co\.?|ltd\.?|inc\.?|ag|gmbh)$"#
        var name = make
        while let range = name.range(of: suffix, options: [.regularExpression, .caseInsensitive]), range.lowerBound > name.startIndex {
            name.removeSubrange(range)
        }
        return name
    }
    /// From a stored `extractedMetadata` property list.
    public init(extracted data: Data) {
        self.init(properties: (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] ?? [:])
    }
}

extension CatalogAsset {
    public var camera: CatalogCamera {
        get {
            var c = CatalogCamera(); c.make = cameraMake; c.model = cameraModel; c.lensMake = lensMake; c.lens = lensModel; c.artist = artist
            c.focalLength = focalLength; c.focalLength35mm = focalLength35mm; c.fNumber = fNumber; c.exposureTime = exposureTime; c.iso = iso
            c.exposureBias = exposureBias; c.flashFired = flashFired
            return c
        }
        set {
            cameraMake = newValue.make; cameraModel = newValue.model; lensMake = newValue.lensMake; lensModel = newValue.lens; artist = newValue.artist
            focalLength = newValue.focalLength; focalLength35mm = newValue.focalLength35mm; fNumber = newValue.fNumber; exposureTime = newValue.exposureTime
            iso = newValue.iso; exposureBias = newValue.exposureBias; flashFired = newValue.flashFired
        }
    }
}
