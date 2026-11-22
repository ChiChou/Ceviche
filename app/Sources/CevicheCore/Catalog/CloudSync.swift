import Foundation
import SwiftData
import CoreData
import CloudKit
import Network
import os

// The iCloud mirror. SwiftData with CloudKit moves these rows between a person's Macs; the GRDB catalog
// stays the store the app reads. CloudKit rules shape the models: no unique constraints, every attribute
// has a default, no required relationships.

@Model public final class SyncedCatalog {
    public var catalogID: String = ""
    public var name: String = ""
    public var updatedAt: Date = Date()
    /// Set when the catalog is deleted on any Mac. The row stays so a Mac that still has the catalog open stops
    /// instead of uploading it again.
    public var deletedAt: Date?
    public init(catalogID: String, name: String) { self.catalogID = catalogID; self.name = name }
}

/// What a photo's original is: written once, again only when another app saved a new file in its place (Edit In).
@Model public final class SyncedOriginal {
    public var catalogID: String = ""
    public var assetID: String = ""
    public var filename: String = ""
    public var kind: String = ""
    public var fileSize: Int64?
    public var captureTime: String?
    @Attribute(.externalStorage) public var infoData: Data?
    @Attribute(.externalStorage) public var extractedMetadata: Data?
    public var importedAt: Date = Date()
    public var importBatchID: String?
    public var updatedAt: Date = Date()
    public init(catalogID: String, original: CatalogSyncOriginal) { self.catalogID = catalogID; assetID = original.assetID; apply(original) }
    func apply(_ original: CatalogSyncOriginal) {
        filename = original.filename; kind = original.kind; fileSize = original.fileSize; captureTime = original.captureTime
        infoData = original.infoData; extractedMetadata = original.extractedMetadata; importedAt = original.importedAt
        importBatchID = original.importBatchID; updatedAt = original.updatedAt
    }
    var original: CatalogSyncOriginal? {
        guard let infoData, let extractedMetadata else { return nil }
        return CatalogSyncOriginal(assetID: assetID, filename: filename, kind: kind, fileSize: fileSize, captureTime: captureTime, infoData: infoData,
                                   extractedMetadata: extractedMetadata, importedAt: importedAt, importBatchID: importBatchID, updatedAt: updatedAt)
    }
}

/// A photo's metadata, place in the Trash or a group, and where its original lives. Its `deletedAt` is how every Mac
/// learns the photo was deleted; the photo's other rows go then.
@Model public final class SyncedPhoto {
    public var catalogID: String = ""
    public var assetID: String = ""
    public var origin: String = ""
    public var isCopy: Bool = false
    public var title: String = ""
    public var caption: String = ""
    public var keywords: [String] = []
    public var rating: Int = 0
    public var review: String = "unreviewed"
    /// A `CatalogLabel`; empty for none.
    public var label: String = ""
    public var captureDay: String = ""
    public var latitude: Double?
    public var longitude: Double?
    /// A `CatalogLocationSource`; empty for a location read from the file.
    public var locationSource: String = ""
    public var trashedAt: Date?
    public var archivedAt: Date?
    public var stackID: String?
    public var updatedAt: Date = Date()
    public var deletedAt: Date?
    public init(catalogID: String, assetID: String) { self.catalogID = catalogID; self.assetID = assetID }
    func apply(_ state: CatalogSyncState) {
        origin = state.origin; isCopy = state.isCopy
        title = state.metadata.title; caption = state.metadata.caption; keywords = state.metadata.keywordList; rating = state.metadata.rating
        review = state.metadata.review.rawValue; label = state.metadata.label?.rawValue ?? ""; captureDay = state.metadata.captureDay; latitude = state.metadata.latitude; longitude = state.metadata.longitude
        locationSource = state.metadata.locationSource?.rawValue ?? ""
        trashedAt = state.trashedAt; archivedAt = state.archivedAt; stackID = state.stackID; updatedAt = state.updatedAt; deletedAt = nil
    }
    var state: CatalogSyncState {
        var metadata = CatalogMetadata()
        metadata.title = title; metadata.caption = caption; metadata.keywords = keywords.joined(separator: ", "); metadata.rating = rating
        metadata.review = ReviewState(rawValue: review) ?? .unreviewed; metadata.label = CatalogLabel(rawValue: label); metadata.captureDay = captureDay; metadata.latitude = latitude; metadata.longitude = longitude
        metadata.locationSource = latitude == nil ? nil : CatalogLocationSource(rawValue: locationSource)
        return CatalogSyncState(assetID: assetID, origin: origin, isCopy: isCopy, metadata: metadata, trashedAt: trashedAt, archivedAt: archivedAt, stackID: stackID, updatedAt: updatedAt)
    }
}

/// A photo's development and the XMP it came with.
@Model public final class SyncedDevelopment {
    public var catalogID: String = ""
    public var assetID: String = ""
    @Attribute(.externalStorage) public var adjustmentsData: Data?
    @Attribute(.externalStorage) public var xmpData: Data?
    public var xmpWarnings: String = ""
    /// The development's identity (`CatalogAsset.renderKey`), which previews name.
    public var renderKey: String = ""
    public var lastEditedAt: Date?
    public var updatedAt: Date = Date()
    public init(catalogID: String, development: CatalogSyncDevelopment) { self.catalogID = catalogID; assetID = development.assetID; apply(development) }
    func apply(_ development: CatalogSyncDevelopment) {
        adjustmentsData = development.adjustmentsData; xmpData = development.xmpData; xmpWarnings = development.xmpWarnings
        renderKey = development.renderKey; lastEditedAt = development.lastEditedAt; updatedAt = development.updatedAt
    }
    var development: CatalogSyncDevelopment {
        CatalogSyncDevelopment(assetID: assetID, adjustmentsData: adjustmentsData, xmpData: xmpData, xmpWarnings: xmpWarnings,
                               renderKey: renderKey, lastEditedAt: lastEditedAt, updatedAt: updatedAt)
    }
}

@Model public final class SyncedSnapshot {
    public var catalogID: String = ""
    public var snapshotID: String = ""
    public var assetID: String = ""
    public var name: String = ""
    @Attribute(.externalStorage) public var adjustmentsJSON: Data?
    public var createdAt: Date = Date()
    public var deletedAt: Date?
    public init(catalogID: String, snapshot: CatalogSyncSnapshot) {
        self.catalogID = catalogID; snapshotID = snapshot.snapshotID; assetID = snapshot.assetID; name = snapshot.name; adjustmentsJSON = snapshot.adjustmentsJSON; createdAt = snapshot.createdAt
    }
}

/// A mask raster one photo's synced developments refer to by ID (see `RevisionPayload`). Written once and never
/// changed, so it never conflicts; a Mac applies a development only once every blob it names has arrived, and the
/// Mac that pushes a photo's development or snapshots removes the photo's blobs neither of them uses any more.
@Model public final class SyncedBlob {
    public var catalogID: String = ""
    public var assetID: String = ""
    public var blobID: String = ""
    @Attribute(.externalStorage) public var data: Data?
    public init(catalogID: String, assetID: String, blobID: String, data: Data) {
        self.catalogID = catalogID; self.assetID = assetID; self.blobID = blobID; self.data = data
    }
}

/// A photo's grid preview, so a Mac that has not downloaded the original still shows it. One per photo, replaced when
/// the photo's development changes.
@Model public final class SyncedPreview {
    public var catalogID: String = ""
    public var assetID: String = ""
    /// The development the preview shows (`CatalogAsset.renderKey`); empty for the camera's embedded preview of an
    /// edited photo that no Mac has rendered yet.
    public var renderKey: String = ""
    @Attribute(.externalStorage) public var data: Data?
    public init(catalogID: String, assetID: String, renderKey: String, data: Data) {
        self.catalogID = catalogID; self.assetID = assetID; self.renderKey = renderKey; self.data = data
    }
}

/// A photo's suggested tags, produced once by the Mac that imported it and the source of truth for every other Mac.
/// One per photo; if someone analyzes the photo again, the later `analyzedAt` wins.
@Model public final class SyncedAnalysis {
    public var catalogID: String = ""
    public var assetID: String = ""
    public var tags: [String] = []
    /// The analysis version that produced `tags` (`CatalogImporter.analysisVersion`).
    public var version: String = ""
    public var analyzedAt: Date = Date()
    /// Faces found; nil from a version that didn't look.
    public var faces: Int?
    /// Where they are, as JSON `[CatalogFace]`; nil from a version that only counted them.
    public var faceBoxes: Data?
    public init(catalogID: String, assetID: String, result: CatalogStore.AnalysisResult) {
        self.catalogID = catalogID; self.assetID = assetID; tags = CatalogMetadata.list(result.tags); version = result.version; analyzedAt = result.analyzedAt
        faces = result.faces; faceBoxes = Self.encode(result.faceBoxes)
    }
    var result: CatalogStore.AnalysisResult {
        CatalogStore.AnalysisResult(tags: tags.joined(separator: ", "), version: version, analyzedAt: analyzedAt, faces: faces,
                                    faceBoxes: faceBoxes.flatMap { try? JSONDecoder().decode([CatalogFace].self, from: $0) })
    }
    static func encode(_ boxes: [CatalogFace]?) -> Data? { boxes.flatMap { try? JSONEncoder().encode($0) } }
}

/// An album. Renames and deletions resolve to the latest `updatedAt`; a deleted album keeps its row with `deletedAt`
/// so every Mac learns of it.
@Model public final class SyncedAlbum {
    public var catalogID: String = ""
    public var albumID: String = ""
    public var name: String = ""
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var deletedAt: Date?
    public init(catalogID: String, album: CatalogSyncAlbum) {
        self.catalogID = catalogID; albumID = album.id; name = album.name; createdAt = album.createdAt; updatedAt = album.updatedAt
    }
    var album: CatalogSyncAlbum { CatalogSyncAlbum(id: albumID, name: name, createdAt: createdAt, updatedAt: updatedAt) }
}

/// One photo in one album; a removal keeps the row with `deletedAt`.
@Model public final class SyncedAlbumEntry {
    public var catalogID: String = ""
    public var albumID: String = ""
    public var assetID: String = ""
    public var position: Int = 0
    public var updatedAt: Date = Date()
    public var deletedAt: Date?
    public init(catalogID: String, entry: CatalogSyncAlbumEntry) {
        self.catalogID = catalogID; albumID = entry.albumID; assetID = entry.assetID; position = entry.position; updatedAt = entry.updatedAt
    }
    var entry: CatalogSyncAlbumEntry { CatalogSyncAlbumEntry(albumID: albumID, assetID: assetID, position: position, updatedAt: updatedAt) }
}

public enum CloudSyncState: Equatable, Sendable {
    case idle
    case syncing
    case waiting
    case upToDate(Date)
    /// The mirror works locally but nothing reaches iCloud (no entitlement, not signed in).
    case unavailable(String)
    case failed(String)
    /// Deleted from iCloud on another Mac; this replica no longer syncs.
    case removed
    public var isHealthy: Bool {
        switch self {
        case .unavailable, .failed, .removed: return false
        default: return true
        }
    }
}

/// Mirrors one catalog into SwiftData and back. A photo is three rows, its original, state and development, each with
/// the clock of its part (`CatalogSyncClocks`): pull applies the parts the mirror has newer, push writes the parts
/// newer here, and a conflict within one part resolves to the latest `updatedAt`.
public actor CloudSyncEngine {
    static let logger = Logger(subsystem: "me.chichou.ceviche", category: "CloudSync")
    public let store: CatalogStore
    public let catalogID: String
    public private(set) var state = CloudSyncState.idle
    private let container: ModelContainer
    private let mirrorURL: URL
    private let cloudContainerID: String?
    private var cloudEnabled = false
    private var configurationIssue: String?
    private var accountIssue: String?
    private var cloudIssue: String?
    private var offline = false
    private var networkMonitor: NWPathMonitor?
    private var cloudEvents: Set<UUID> = []
    private var lastCloudSync: Date?
    private var pendingCloudChanges = false
    private var reconciling = false, syncAgain = false
    private var removed = false
    private var observers: [NSObjectProtocol] = []
    private var scheduled: Task<Void, Never>?
    private var onChange: (@Sendable (CloudSyncState, Bool) -> Void)?
    public static let schema = Schema([SyncedCatalog.self, SyncedOriginal.self, SyncedPhoto.self, SyncedDevelopment.self, SyncedSnapshot.self, SyncedBlob.self, SyncedPreview.self, SyncedAlbum.self, SyncedAlbumEntry.self, SyncedAnalysis.self])
    /// `cloudContainer` nil keeps the mirror local (tests, or a build without the iCloud entitlement).
    public init(store: CatalogStore, mirrorURL: URL? = nil, cloudContainer: String? = CatalogManifest.cloudContainer) throws {
        self.store = store; catalogID = store.manifest.id
        let url = mirrorURL ?? store.root.appendingPathComponent("CloudMirror.store")
        self.mirrorURL = url; cloudContainerID = cloudContainer
        var unavailable: String?
        var built: ModelContainer?
        if let cloudContainer {
            if Self.entitledContainers.contains(cloudContainer) {
                let configuration = ModelConfiguration("mirror", schema: Self.schema, url: url, cloudKitDatabase: .private(cloudContainer))
                do { built = try ModelContainer(for: Self.schema, configurations: [configuration]); cloudEnabled = true }
                catch { unavailable = L10n.tr("iCloud sync is unavailable on this Mac: \(error.localizedDescription) Changes stay local until iCloud is available.") }
            } else {
                unavailable = L10n.tr("This copy of Ceviche is not signed for iCloud. Your catalog and edits are saved on this Mac. A signed build is needed to sync them.")
            }
        }
        if built == nil {
            built = try ModelContainer(for: Self.schema, configurations: [ModelConfiguration("mirror", schema: Self.schema, url: url, cloudKitDatabase: .none)])
        }
        container = built!
        configurationIssue = unavailable
        if let unavailable { state = .unavailable(unavailable) }
    }
    /// CloudKit containers this process is entitled to use; empty for an ad-hoc build.
    public static var entitledContainers: [String] { Entitlements.containers("com.apple.developer.icloud-container-identifiers") }
    public func observe(_ handler: @escaping @Sendable (CloudSyncState, Bool) -> Void) { onChange = handler }
    public var needsRestart: Bool { configurationIssue != nil }
    public func retry() async {
        await checkAccount()
        _ = await sync()
    }
    /// Starts reacting to remote changes; call `stop` before releasing.
    public func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .NSPersistentStoreRemoteChange, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            Task { await self.syncSoon() }
        })
        let mirrorURL = self.mirrorURL
        observers.append(center.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: nil) { [weak self] notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event,
                  let owner = notification.object as? NSPersistentCloudKitContainer,
                  owner.persistentStoreCoordinator.persistentStores.contains(where: { $0.identifier == event.storeIdentifier && $0.url?.standardizedFileURL == mirrorURL.standardizedFileURL }) else { return }
            let id = event.identifier, finished = event.endDate != nil, success = event.succeeded
            let exported = event.type == .export, issue = event.error?.localizedDescription
            Task { await self?.recordCloudEvent(id: id, finished: finished, succeeded: success, exported: exported, issue: issue) }
        })
        if cloudEnabled {
            observers.append(center.addObserver(forName: .CKAccountChanged, object: nil, queue: nil) { [weak self] _ in
                Task { await self?.checkAccount(); await self?.syncSoon() }
            })
            let monitor = NWPathMonitor(); networkMonitor = monitor
            monitor.pathUpdateHandler = { [weak self] path in
                let connected = path.status == .satisfied
                Task { await self?.networkChanged(connected: connected) }
            }
            monitor.start(queue: DispatchQueue(label: "me.chichou.ceviche.cloud-network"))
            Task { await checkAccount() }
        }
        syncSoon(delay: .milliseconds(200))
        // Develop autosaves write straight to the store; a periodic pass picks them up.
        periodic = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { break }
                await self?.checkAccount()
                await self?.sync()
            }
        }
    }
    private var periodic: Task<Void, Never>?
    public func stop() {
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        scheduled?.cancel(); scheduled = nil
        periodic?.cancel(); periodic = nil
        networkMonitor?.cancel(); networkMonitor = nil
        onChange = nil
    }
    /// Coalesces bursts of local edits or remote notifications into one pass.
    public func syncSoon(delay: Duration = .seconds(2)) {
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }
    private func publish(_ state: CloudSyncState, changedLocally: Bool = false) {
        self.state = state; onChange?(state, changedLocally)
    }
    private func cloudState() -> CloudSyncState {
        if removed { return .removed }
        if let configurationIssue { return .unavailable(configurationIssue) }
        if offline { return .unavailable(L10n.tr("You’re offline. Your catalog and edits are saved on this Mac. Sync resumes automatically when a connection is available.")) }
        if let accountIssue { return .unavailable(accountIssue) }
        if let cloudIssue { return .unavailable(L10n.tr("iCloud is temporarily unavailable: \(cloudIssue) Your changes are saved on this Mac and will sync when iCloud is available.")) }
        if !cloudEvents.isEmpty { return .syncing }
        if cloudEnabled {
            if pendingCloudChanges || lastCloudSync == nil { return .waiting }
            return .upToDate(lastCloudSync!)
        }
        return .upToDate(Date())
    }
    func networkChanged(connected: Bool) async {
        offline = !connected
        if connected { await checkAccount() }
        publish(cloudState())
        if connected { syncSoon(delay: .milliseconds(200)) }
    }
    private func checkAccount() async {
        guard cloudEnabled, let cloudContainerID else { return }
        do {
            let status = try await CKContainer(identifier: cloudContainerID).accountStatus()
            switch status {
            case .available: accountIssue = nil
            case .noAccount: accountIssue = L10n.tr("Sign in to iCloud in System Settings to resume sync. Your catalog and edits are saved on this Mac.")
            case .restricted: accountIssue = L10n.tr("iCloud access is restricted. You can continue working with this catalog on this Mac.")
            default: accountIssue = L10n.tr("iCloud is temporarily unavailable. Your changes are saved on this Mac and sync will resume automatically.")
            }
        } catch { accountIssue = L10n.tr("iCloud is temporarily unavailable. Your changes are saved on this Mac. \(error.localizedDescription)") }
        publish(cloudState())
    }
    func recordCloudEvent(id: UUID, finished: Bool, succeeded: Bool, exported: Bool, issue: String?) {
        if finished {
            cloudEvents.remove(id)
            if succeeded {
                cloudIssue = nil
                if exported { lastCloudSync = Date(); pendingCloudChanges = false }
                syncSoon(delay: .milliseconds(200))
            } else { cloudIssue = issue ?? L10n.tr("Sync will be retried automatically.") }
        } else { cloudEvents.insert(id) }
        publish(cloudState())
    }
    /// One full pass. Returns true when local rows changed (the library should refresh).
    @discardableResult
    public func sync() async -> Bool {
        guard !removed else { return false }
        // A request that arrives during a pass runs once more after it, so a change made meanwhile is not left to the
        // periodic pass.
        guard !reconciling else { syncAgain = true; return false }
        reconciling = true
        defer { reconciling = false }
        var changedAny = false
        repeat {
            syncAgain = false
            do {
                let changed = try await run()
                publish(cloudState(), changedLocally: changed)
                changedAny = changedAny || changed
            } catch {
                publish(.failed(error.localizedDescription))
                return changedAny
            }
        } while syncAgain && !removed
        return changedAny
    }
    private func run() async throws -> Bool {
        let context = ModelContext(container); context.autosaveEnabled = false
        let id = catalogID
        let catalogs = try context.fetch(FetchDescriptor<SyncedCatalog>(predicate: #Predicate { $0.catalogID == id }))
        // Deleted on another Mac: nothing more goes up, so the catalog cannot come back.
        if catalogs.contains(where: { $0.deletedAt != nil }) { removed = true; return false }
        var changed = false
        // The name: whichever Mac renamed last wins.
        let manifest = store.manifest
        if let latest = catalogs.max(by: { $0.updatedAt < $1.updatedAt }) {
            if let renamedAt = manifest.renamedAt, renamedAt >= latest.updatedAt {
                for row in catalogs where row.name != manifest.name || row.updatedAt != renamedAt { row.name = manifest.name; row.updatedAt = renamedAt }
            } else if latest.name != manifest.name {
                try store.rename(to: latest.name, at: latest.updatedAt); changed = true
            }
        } else {
            let row = SyncedCatalog(catalogID: id, name: manifest.name); row.updatedAt = manifest.renamedAt ?? .distantPast
            context.insert(row)
        }
        // Pull: the parts of each photo newer than this Mac's, and deletions.
        let clocks = try await store.syncClocks()
        var photos = newest(try context.fetch(FetchDescriptor<SyncedPhoto>(predicate: #Predicate { $0.catalogID == id })), \.assetID, \.updatedAt, context)
        var originals = newest(try context.fetch(FetchDescriptor<SyncedOriginal>(predicate: #Predicate { $0.catalogID == id })), \.assetID, \.updatedAt, context)
        var developments = newest(try context.fetch(FetchDescriptor<SyncedDevelopment>(predicate: #Predicate { $0.catalogID == id })), \.assetID, \.updatedAt, context)
        for assetID in Set(photos.keys).union(originals.keys).union(developments.keys) {
            if let deletedAt = photos[assetID]?.deletedAt {
                if clocks[assetID] != nil {
                    do { try await store.applyRemoteDeletion(assetID, deletedAt: deletedAt); changed = true }
                    catch { Self.logger.error("Skipped the deletion of \(assetID, privacy: .public): \(error.localizedDescription, privacy: .public)") }
                }
                continue
            }
            let local = clocks[assetID]
            var photo = CatalogSyncPhoto(assetID: assetID)
            if let row = originals[assetID], local.map({ row.updatedAt > $0.original }) ?? true { photo.original = row.original }
            if let row = photos[assetID], local.map({ row.updatedAt > $0.state }) ?? true { photo.state = row.state }
            if let row = developments[assetID], local.map({ row.updatedAt > $0.development }) ?? true { photo.development = row.development }
            guard photo.original != nil || photo.state != nil || photo.development != nil else { continue }
            // A development whose blobs have not arrived yet stays pending until a later pass. One this build can't
            // apply (edits from a newer build, a damaged row) stays in the mirror, and the rest of the pass goes on.
            do {
                let blobs = try await missingBlobs(for: [photo.development?.adjustmentsData], context: context)
                if try await store.applyRemote(photo, blobs: blobs) { changed = true }
            } catch {
                Self.logger.error("Skipped \(assetID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        // Photos whose development or snapshots this pass writes to the mirror; their blobs follow below. Only
        // those writes remove blobs: the check once per launch only uploads missing ones.
        var touched: Set<String> = [], written: Set<String> = []
        // Once per launch, every photo this Mac is in step with, so blobs the mirror lost come back from here.
        if !checkedMirrorBlobs {
            for (assetID, row) in developments where photos[assetID]?.deletedAt == nil && clocks[assetID]?.development == row.updatedAt { touched.insert(assetID) }
            checkedMirrorBlobs = true
        }
        // Push: the parts changed here since the mirror's copy (or that it lacks), and local permanent deletions.
        func newer(_ local: Date, than row: Date?) -> Bool { row.map { local > $0 } ?? true }
        let pushOriginals = clocks.filter { newer($0.value.original, than: originals[$0.key]?.updatedAt) }.map(\.key)
        let pushStates = clocks.filter { newer($0.value.state, than: photos[$0.key]?.updatedAt) }.map(\.key)
        let pushDevelopments = clocks.filter { newer($0.value.development, than: developments[$0.key]?.updatedAt) }.map(\.key)
        for original in try await store.syncOriginals(pushOriginals) {
            if let row = originals[original.assetID] { row.apply(original) }
            else { let row = SyncedOriginal(catalogID: id, original: original); context.insert(row); originals[original.assetID] = row }
        }
        for state in try await store.syncStates(pushStates) {
            let row = photos[state.assetID] ?? { let row = SyncedPhoto(catalogID: id, assetID: state.assetID); context.insert(row); return row }()
            row.apply(state); photos[state.assetID] = row
        }
        for development in try await store.syncDevelopments(pushDevelopments) {
            if let row = developments[development.assetID] { row.apply(development) }
            else { let row = SyncedDevelopment(catalogID: id, development: development); context.insert(row); developments[development.assetID] = row }
            touched.insert(development.assetID); written.insert(development.assetID)
        }
        let tombstones = try await store.tombstones()
        for tombstone in tombstones {
            let row = photos[tombstone.id] ?? { let row = SyncedPhoto(catalogID: id, assetID: tombstone.id); context.insert(row); return row }()
            row.deletedAt = tombstone.deletedAt; row.updatedAt = tombstone.deletedAt; photos[tombstone.id] = row
            // The photo's row is how every Mac learns of the deletion; its original and development can go.
            if let original = originals.removeValue(forKey: tombstone.id) { context.delete(original) }
            if let development = developments.removeValue(forKey: tombstone.id) { context.delete(development) }
            touched.insert(tombstone.id); written.insert(tombstone.id)
        }
        // Snapshots: union by ID; removals travel as tombstoned rows.
        let localSnapshots = try await store.snapshotRecords()
        let localIDs = Set(localSnapshots.map(\.snapshotID))
        let localByID = Dictionary(localSnapshots.map { ($0.snapshotID, $0) }, uniquingKeysWith: { a, _ in a })
        let remoteSnapshots = try context.fetch(FetchDescriptor<SyncedSnapshot>(predicate: #Predicate { $0.catalogID == id }))
        var toApply: [CatalogSyncSnapshot] = []
        var deletedRemotely: Set<String> = []
        for item in remoteSnapshots {
            if item.deletedAt != nil {
                if localIDs.contains(item.snapshotID) { deletedRemotely.insert(item.snapshotID) }
                continue
            }
            guard let json = item.adjustmentsJSON else { continue }
            let record = CatalogSyncSnapshot(snapshotID: item.snapshotID, assetID: item.assetID, name: item.name, adjustmentsJSON: json, createdAt: item.createdAt)
            if let local = localByID[item.snapshotID] {
                if local.name != record.name { toApply.append(record) }
            } else if syncedSnapshotIDs.contains(item.snapshotID) {
                // Present after the last pass and gone from this Mac now: deleted here.
                item.deletedAt = Date(); item.adjustmentsJSON = nil
                touched.insert(item.assetID); written.insert(item.assetID)
            } else { toApply.append(record) }
        }
        var applied: Set<String> = []
        if !toApply.isEmpty {
            let blobs = try await missingBlobs(for: toApply.filter { !localIDs.contains($0.snapshotID) }.map(\.adjustmentsJSON), context: context)
            applied = try await store.applyRemoteSnapshots(toApply, blobs: blobs)
            if !applied.isEmpty { changed = true }
        }
        if !deletedRemotely.isEmpty { try await store.removeSnapshotsMissing(from: localIDs.subtracting(deletedRemotely), knownBefore: localIDs); changed = true }
        let remoteSnapshotIDs = Set(remoteSnapshots.map(\.snapshotID))
        var mirroredSnapshots = remoteSnapshots
        for snapshot in localSnapshots where !remoteSnapshotIDs.contains(snapshot.snapshotID) {
            let item = SyncedSnapshot(catalogID: id, snapshot: snapshot)
            context.insert(item); mirroredSnapshots.append(item)
            touched.insert(snapshot.assetID); written.insert(snapshot.assetID)
        }
        if !touched.isEmpty {
            try await reconcileBlobs(of: touched, removingStale: written, photos: photos, developments: developments, snapshots: Dictionary(grouping: mirroredSnapshots, by: \.assetID), context: context)
        }
        if try await syncPreviews(photos: photos, developments: developments, context: context) { changed = true }
        if try await syncAnalysis(photos: photos, context: context) { changed = true }
        let albums = try await syncAlbums(context: context)
        if albums.changed { changed = true }
        syncedSnapshotIDs = localIDs.union(applied).subtracting(deletedRemotely)
        if context.hasChanges {
            try context.save()
            if cloudEnabled { pendingCloudChanges = true }
        }
        try await store.removeTombstones(tombstones.map(\.id))
        try await store.markAlbumsSynced(albums.pushed.albums, entries: albums.pushed.entries)
        try await store.removeTombstones(albums.tombstones)
        return changed
    }
    /// One row per photo: a second row two Macs created for the same photo before either saw the other's goes, keeping the later.
    private func newest<Row: PersistentModel>(_ rows: [Row], _ key: KeyPath<Row, String>, _ date: KeyPath<Row, Date>, _ context: ModelContext) -> [String: Row] {
        var kept: [String: Row] = [:]
        for row in rows {
            if let other = kept[row[keyPath: key]] {
                if other[keyPath: date] >= row[keyPath: date] { context.delete(row); continue }
                context.delete(other)
            }
            kept[row[keyPath: key]] = row
        }
        return kept
    }
    /// Suggested tags: applies results other Macs produced, and uploads this Mac's where they are newer than the
    /// mirror's. Returns true when tags changed here.
    private func syncAnalysis(photos: [String: SyncedPhoto], context: ModelContext) async throws -> Bool {
        let id = catalogID
        var mirrored = newest(try context.fetch(FetchDescriptor<SyncedAnalysis>(predicate: #Predicate { $0.catalogID == id })), \.assetID, \.analyzedAt, context)
        for (assetID, row) in mirrored where photos[assetID]?.deletedAt != nil { context.delete(row); mirrored[assetID] = nil }
        let changed = try await store.applyRemoteAnalysis(mirrored.mapValues(\.result))
        for (assetID, result) in try await store.localAnalysisResults() {
            guard let item = photos[assetID], item.deletedAt == nil else { continue }
            if let row = mirrored[assetID] {
                guard result.analyzedAt > row.analyzedAt else { continue }
                row.tags = CatalogMetadata.list(result.tags); row.version = result.version; row.analyzedAt = result.analyzedAt; row.faces = result.faces; row.faceBoxes = SyncedAnalysis.encode(result.faceBoxes)
            } else { context.insert(SyncedAnalysis(catalogID: id, assetID: assetID, result: result)) }
        }
        return changed
    }
    /// Albums and the photos in them: applies the mirror's newer rows here, then writes this Mac's changes and
    /// deletions to the mirror. Returns what was pushed, to mark as synced once the mirror is saved.
    private func syncAlbums(context: ModelContext) async throws -> (changed: Bool, pushed: (albums: [CatalogSyncAlbum], entries: [CatalogSyncAlbumEntry]), tombstones: [String]) {
        let id = catalogID
        // Two Macs can create the same row before either sees the other's; keep the newest.
        var albums = newest(try context.fetch(FetchDescriptor<SyncedAlbum>(predicate: #Predicate { $0.catalogID == id })), \.albumID, \.updatedAt, context)
        var entries = newest(try context.fetch(FetchDescriptor<SyncedAlbumEntry>(predicate: #Predicate { $0.catalogID == id })), \.entry.key, \.updatedAt, context)
        // Pull.
        let live = albums.values.filter { $0.deletedAt == nil }
        let changed = try await store.applyRemoteAlbums(
            live.map(\.album),
            deletedAlbums: Dictionary(albums.values.compactMap { row in row.deletedAt.map { (row.albumID, $0) } }, uniquingKeysWith: max),
            entries: entries.values.filter { $0.deletedAt == nil && albums[$0.albumID]?.deletedAt == nil }.map(\.entry),
            removedEntries: Dictionary(entries.values.compactMap { row in row.deletedAt.map { (row.entry.key, $0) } }, uniquingKeysWith: max))
        // Push.
        let pending = try await store.albumsNeedingSync()
        for album in pending.albums {
            if let row = albums[album.id] {
                guard album.updatedAt >= row.updatedAt else { continue }
                row.name = album.name; row.updatedAt = album.updatedAt; row.deletedAt = nil
            } else { let row = SyncedAlbum(catalogID: id, album: album); context.insert(row); albums[album.id] = row }
        }
        for entry in pending.entries {
            if let row = entries[entry.key] {
                guard entry.updatedAt >= row.updatedAt else { continue }
                row.position = entry.position; row.updatedAt = entry.updatedAt; row.deletedAt = nil
            } else { let row = SyncedAlbumEntry(catalogID: id, entry: entry); context.insert(row); entries[entry.key] = row }
        }
        let deletedAlbums = try await store.tombstones(kind: "album"), removedEntries = try await store.tombstones(kind: "albumAsset")
        for tombstone in deletedAlbums {
            if let row = albums[tombstone.id] { row.deletedAt = tombstone.deletedAt; row.updatedAt = tombstone.deletedAt }
            else {
                let row = SyncedAlbum(catalogID: id, album: CatalogSyncAlbum(id: tombstone.id, name: "", createdAt: tombstone.deletedAt, updatedAt: tombstone.deletedAt))
                row.deletedAt = tombstone.deletedAt; context.insert(row)
            }
            // The album's photos go with it.
            for row in entries.values where row.albumID == tombstone.id { context.delete(row) }
        }
        for tombstone in removedEntries {
            let parts = tombstone.id.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            if let row = entries[tombstone.id] { row.deletedAt = tombstone.deletedAt; row.updatedAt = tombstone.deletedAt }
            else {
                let row = SyncedAlbumEntry(catalogID: id, entry: CatalogSyncAlbumEntry(albumID: parts[0], assetID: parts[1], position: 0, updatedAt: tombstone.deletedAt))
                row.deletedAt = tombstone.deletedAt; context.insert(row)
            }
        }
        return (changed, pending, (deletedAlbums + removedEntries).map(\.id))
    }
    /// Blobs that `developments` refer to and the catalog lacks, from the mirror. Any the mirror does not have yet
    /// are left out, so the store defers the development that needs them.
    private func missingBlobs(for developments: [Data?], context: ModelContext) async throws -> [String: Data] {
        var ids: Set<String> = []
        for development in developments.compactMap({ $0 }) { ids.formUnion((try? RevisionPayload.references(development)) ?? []) }
        let wanted = Array(try await store.missingBlobs(ids))
        guard !wanted.isEmpty else { return [:] }
        let id = catalogID
        let rows = try context.fetch(FetchDescriptor<SyncedBlob>(predicate: #Predicate { $0.catalogID == id && wanted.contains($0.blobID) }))
        return Dictionary(rows.compactMap { row in row.data.map { (row.blobID, $0) } }, uniquingKeysWith: { a, _ in a })
    }
    /// Makes each photo's blobs in the mirror match what its mirrored development and live snapshots use: missing
    /// ones are uploaded from this Mac, and for the photos in `written` (rows this pass wrote) ones nothing uses any
    /// more are deleted. If another Mac pushes the same photo at the same moment with a development that still uses a
    /// deleted blob, that Mac uploads it again the next time it launches.
    private func reconcileBlobs(of assetIDs: Set<String>, removingStale written: Set<String>, photos: [String: SyncedPhoto], developments: [String: SyncedDevelopment],
                                snapshots: [String: [SyncedSnapshot]], context: ModelContext) async throws {
        let id = catalogID, wanted = Array(assetIDs)
        let rows = Dictionary(grouping: try context.fetch(FetchDescriptor<SyncedBlob>(predicate: #Predicate { $0.catalogID == id && wanted.contains($0.assetID) })), by: \.assetID)
        assets: for assetID in assetIDs {
            var used: Set<String> = []
            var payloads = snapshots[assetID, default: []].filter { $0.deletedAt == nil }.compactMap(\.adjustmentsJSON)
            if photos[assetID]?.deletedAt == nil, let development = developments[assetID]?.adjustmentsData { payloads.append(development) }
            for payload in payloads {
                // One that can't be parsed may use any of them: this photo's blobs are left as they are.
                guard let references = try? RevisionPayload.references(payload) else { continue assets }
                used.formUnion(references)
            }
            var present: Set<String> = []
            for row in rows[assetID] ?? [] {
                // A second copy two Macs uploaded before either saw the other's, or one nothing uses any more.
                if used.contains(row.blobID) ? !present.insert(row.blobID).inserted : written.contains(assetID) { context.delete(row) }
            }
            for (blobID, data) in try await store.blobs(used.subtracting(present)) {
                context.insert(SyncedBlob(catalogID: id, assetID: assetID, blobID: blobID, data: data))
            }
        }
    }
    private var checkedMirrorBlobs = false
    /// Installs previews other Macs rendered for photos whose preview here is missing or older, and uploads this Mac's
    /// for photos whose mirrored development it shows. Returns true when a preview was installed.
    private func syncPreviews(photos: [String: SyncedPhoto], developments: [String: SyncedDevelopment], context: ModelContext) async throws -> Bool {
        let id = catalogID
        var descriptor = FetchDescriptor<SyncedPreview>(predicate: #Predicate { $0.catalogID == id })
        descriptor.propertiesToFetch = [\.assetID, \.renderKey]
        var mirrored: [String: SyncedPreview] = [:]
        for row in try context.fetch(descriptor) {
            // A second row two Macs uploaded for the same photo before either saw the other's.
            if let other = mirrored[row.assetID] { context.delete(other) }
            mirrored[row.assetID] = row
        }
        let local = try await store.previewStates()
        var installed = false
        for (assetID, row) in mirrored {
            if photos[assetID]?.deletedAt != nil { context.delete(row); continue }
            guard let state = local[assetID], !state.current, let data = row.data else { continue }
            // A preview that can't be installed is only a missing thumbnail; the photo renders its own.
            if state.renderKey == row.renderKey { if (try? await store.installThumbnail(data, assetID: assetID, renderKey: row.renderKey)) != nil { installed = true } }
            // An undeveloped preview only fills a gap, and keeps the photo marked to update when it is opened.
            else if row.renderKey.isEmpty, !state.present { if (try? await store.installPreviewThumbnail(data, assetID: assetID)) != nil { installed = true } }
        }
        for (assetID, state) in local where state.present {
            guard let photo = photos[assetID], photo.deletedAt == nil, developments[assetID]?.renderKey == state.renderKey else { continue }
            let key = state.current ? state.renderKey : ""
            // A developed preview replaces any other; an undeveloped one is only offered when the mirror has none.
            guard state.current ? mirrored[assetID]?.renderKey != key : mirrored[assetID] == nil,
                  let data = try? await store.previewData(assetID) else { continue }
            if let row = mirrored[assetID] { row.renderKey = key; row.data = data }
            else { context.insert(SyncedPreview(catalogID: id, assetID: assetID, renderKey: key, data: data)) }
        }
        return installed
    }
    /// Blob IDs in the mirror for this catalog, for tests and diagnostics.
    public func mirroredBlobIDs() throws -> Set<String> {
        let context = ModelContext(container); let id = catalogID
        return Set(try context.fetch(FetchDescriptor<SyncedBlob>(predicate: #Predicate { $0.catalogID == id })).map(\.blobID))
    }
    /// Snapshot IDs known at the end of the previous pass, to tell local deletions from new remote rows.
    private var syncedSnapshotIDs: Set<String> = []
    /// Everything in the mirror for this catalog, for tests and diagnostics.
    public func mirroredAssetIDs() throws -> Set<String> {
        let context = ModelContext(container); let id = catalogID
        return Set(try context.fetch(FetchDescriptor<SyncedPhoto>(predicate: #Predicate { $0.catalogID == id && $0.deletedAt == nil })).map(\.assetID))
    }
}

/// An iCloud catalog this Apple ID has, as another Mac named it.
public struct CloudCatalogListing: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

/// The iCloud catalogs this Apple ID has, so any Mac can open one by name. The list comes from a mirror of its own
/// that CloudKit fills in the background: on a Mac that has never synced it is empty at first, so keep the directory
/// open and read it again as `NSPersistentStoreRemoteChange` arrives.
public final class CloudCatalogDirectory: @unchecked Sendable {
    private let container: ModelContainer
    /// False when this build cannot reach iCloud, so the list only holds catalogs this Mac created.
    public let reachesCloud: Bool
    public init(mirrorURL: URL, cloudContainer: String? = CatalogManifest.cloudContainer) throws {
        var built: ModelContainer?
        if let cloudContainer, CloudSyncEngine.entitledContainers.contains(cloudContainer) {
            built = try? ModelContainer(for: CloudSyncEngine.schema, configurations: [ModelConfiguration("mirror", schema: CloudSyncEngine.schema, url: mirrorURL, cloudKitDatabase: .private(cloudContainer))])
        }
        reachesCloud = built != nil
        container = try built ?? ModelContainer(for: CloudSyncEngine.schema, configurations: [ModelConfiguration("mirror", schema: CloudSyncEngine.schema, url: mirrorURL, cloudKitDatabase: .none)])
    }
    /// By name. Two Macs that open a new catalog before syncing each record it, so a catalog is listed once, under
    /// the name it was given last. Deleted catalogs are left out.
    public func catalogs() throws -> [CloudCatalogListing] {
        let rows = try ModelContext(container).fetch(FetchDescriptor<SyncedCatalog>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse), SortDescriptor(\.catalogID)]))
        let deleted = Set(rows.filter { $0.deletedAt != nil }.map(\.catalogID))
        var seen: Set<String> = []
        return rows.filter { !deleted.contains($0.catalogID) && seen.insert($0.catalogID).inserted }
            .map { CloudCatalogListing(id: $0.catalogID, name: $0.name) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    /// Catalogs deleted on any Mac, so this one can forget them and remove its replicas.
    public func deletedCatalogIDs() throws -> Set<String> {
        Set(try ModelContext(container).fetch(FetchDescriptor<SyncedCatalog>(predicate: #Predicate { $0.deletedAt != nil })).map(\.catalogID))
    }
    /// Renames a catalog for every Mac. A Mac with the catalog open takes the name on its next sync.
    public func rename(_ id: String, to name: String, at date: Date = Date()) throws {
        let context = ModelContext(container); context.autosaveEnabled = false
        let rows = try context.fetch(FetchDescriptor<SyncedCatalog>(predicate: #Predicate { $0.catalogID == id }))
        guard !rows.contains(where: { $0.deletedAt != nil }) else { throw EditorError.invalidDocument(L10n.tr("This catalog was deleted from iCloud.")) }
        if rows.isEmpty { context.insert(SyncedCatalog(catalogID: id, name: name)) }
        for row in rows { row.name = name; row.updatedAt = date }
        try context.save()
    }
    /// Deletes a catalog's photos, edits, albums and previews from iCloud for every Mac, keeping a marker so Macs
    /// that still have it open stop syncing it. Originals are not touched.
    public func delete(_ id: String, at date: Date = Date()) throws {
        let context = ModelContext(container); context.autosaveEnabled = false
        let rows = try context.fetch(FetchDescriptor<SyncedCatalog>(predicate: #Predicate { $0.catalogID == id }))
        if rows.isEmpty { let row = SyncedCatalog(catalogID: id, name: ""); row.deletedAt = date; context.insert(row) }
        for row in rows where row.deletedAt == nil { row.deletedAt = date; row.updatedAt = date }
        try Self.removeContents(of: [id], context: context)
        try context.save()
    }
    /// Rows a Mac uploaded for a deleted catalog before it learned of the deletion.
    public func removeLeftovers() throws {
        let deleted = try deletedCatalogIDs()
        guard !deleted.isEmpty else { return }
        let context = ModelContext(container); context.autosaveEnabled = false
        try Self.removeContents(of: deleted, context: context)
        if context.hasChanges { try context.save() }
    }
    private static func removeContents(of ids: Set<String>, context: ModelContext) throws {
        func remove<T: PersistentModel>(_ rows: [T]) { rows.forEach(context.delete) }
        remove(try context.fetch(FetchDescriptor<SyncedOriginal>(predicate: #Predicate { ids.contains($0.catalogID) })))
        remove(try context.fetch(FetchDescriptor<SyncedPhoto>(predicate: #Predicate { ids.contains($0.catalogID) })))
        remove(try context.fetch(FetchDescriptor<SyncedDevelopment>(predicate: #Predicate { ids.contains($0.catalogID) })))
        remove(try context.fetch(FetchDescriptor<SyncedSnapshot>(predicate: #Predicate { ids.contains($0.catalogID) })))
        remove(try context.fetch(FetchDescriptor<SyncedBlob>(predicate: #Predicate { ids.contains($0.catalogID) })))
        remove(try context.fetch(FetchDescriptor<SyncedPreview>(predicate: #Predicate { ids.contains($0.catalogID) })))
        remove(try context.fetch(FetchDescriptor<SyncedAnalysis>(predicate: #Predicate { ids.contains($0.catalogID) })))
        remove(try context.fetch(FetchDescriptor<SyncedAlbum>(predicate: #Predicate { ids.contains($0.catalogID) })))
        remove(try context.fetch(FetchDescriptor<SyncedAlbumEntry>(predicate: #Predicate { ids.contains($0.catalogID) })))
    }
}
