import Foundation
import CevicheCore

/// A photo's saved development as the editor opens it.
struct LoadedDevelopment: Sendable {
    var adjustments: Adjustments
    /// The XMP packet the development came from, kept for XMP export.
    var xmpSource: Data?
    var metadata: CatalogMetadata?
    /// What an imported XMP could not carry over, shown once the photo is open.
    var warnings: String
}

/// How a store reads its development while the original decodes, off the main actor.
struct DevelopmentLoad: Sendable {
    /// Runs before the original is decoded, so a mismatch fails without decoding it.
    var verify: @Sendable (_ image: URL) throws -> Void = { _ in }
    /// The development for the decoded photo: `decoded` is the decoder's own starting point.
    var resolve: @Sendable (_ image: URL, _ decoded: Adjustments, _ info: ImageInfo) throws -> LoadedDevelopment
}

/// Where the open photo's development is kept: its catalog entry, or an XMP sidecar beside the original. The editor
/// autosaves, flushes and saves through it alike.
@MainActor protocol DevelopmentStore: AnyObject {
    /// The catalog and photo, for History, thumbnails and the filmstrip; nil for a sidecar.
    var catalog: CatalogStore? { get }
    var assetID: String? { get }
    /// False when the edits can't be written where they belong (a sidecar in a read-only folder): autosave stops and
    /// the edits stay unsaved until the user picks where to save.
    var canSave: Bool { get }
    func prepareLoad() async throws -> DevelopmentLoad
    /// Saves `settings` and returns the catalog's render key for the thumbnail, nil when there is none.
    func save(_ settings: Adjustments, baseline: Adjustments, metadata: CatalogMetadata?, coalescing: Bool) async throws -> String?
    /// Forgets the imported XMP packet and its compatibility notes; the caller saves the development afterwards.
    func stripSourceXMP() async throws
}

extension DevelopmentStore {
    var catalog: CatalogStore? { nil }
    var assetID: String? { nil }
    var canSave: Bool { true }
}

/// A photo's entry in a catalog.
@MainActor final class CatalogDevelopmentStore: DevelopmentStore {
    let store: CatalogStore
    let asset: CatalogAsset
    init(store: CatalogStore, asset: CatalogAsset) { self.store = store; self.asset = asset }
    var catalog: CatalogStore? { store }
    var assetID: String? { asset.id }
    func prepareLoad() async throws -> DevelopmentLoad {
        let asset = asset
        let saved = try await store.savedAdjustments(of: asset)
        let xmp = try await store.development(asset.id).xmpData
        return DevelopmentLoad(verify: { url in
            if try !CatalogImporter.matches(url, asset) {
                throw EditorError.invalidDocument(L10n.tr("The original's contents have changed. Import it as a new photo to preserve existing edits."))
            }
        }, resolve: { _, decoded, _ in
            LoadedDevelopment(adjustments: saved ?? decoded, xmpSource: xmp, metadata: asset.metadata, warnings: asset.xmpWarnings)
        })
    }
    func save(_ settings: Adjustments, baseline: Adjustments, metadata: CatalogMetadata?, coalescing: Bool) async throws -> String? {
        try await store.saveEdits(settings, assetID: asset.id, baseline: baseline, coalescing: coalescing)
    }
    func stripSourceXMP() async throws { try await store.stripSourceXMP([asset.id]) }
}

/// An XMP sidecar beside the original (see `XMPSidecar`), for a photo edited outside any catalog. It keeps the current
/// development only: no history or snapshots. When the photo's folder can't be written it saves nothing (`canSave`
/// is false) until `saveCopy` moves the photo, with its sidecars, to a folder the user picks.
@MainActor final class SidecarDevelopmentStore: DevelopmentStore {
    private(set) var image: URL
    /// Found when the photo opens.
    private(set) var sidecar: XMPSidecar?
    private(set) var canSave = true
    init(image: URL) { self.image = image }
    func prepareLoad() async throws -> DevelopmentLoad {
        let image = image
        let (sidecar, writable) = try await Task.detached(priority: .userInitiated) {
            (try XMPSidecar.resolve(for: image), XMPSidecar.folderIsWritable(for: image))
        }.value
        self.sidecar = sidecar; canSave = writable
        return DevelopmentLoad(resolve: { _, decoded, info in
            guard let url = sidecar.readURL else { return LoadedDevelopment(adjustments: decoded, warnings: "") }
            let imported = try XMPCodec.apply(XMPPacket(url: url), to: decoded, defaults: info.defaults, profiles: info.profileResolver)
            return LoadedDevelopment(adjustments: imported.adjustments, xmpSource: imported.sourceData, metadata: imported.metadata, warnings: imported.warnings.joined(separator: "\n\n"))
        })
    }
    func save(_ settings: Adjustments, baseline: Adjustments, metadata: CatalogMetadata?, coalescing: Bool) async throws -> String? {
        let found = sidecar, image = image
        do {
            sidecar = try await Task.detached(priority: .userInitiated) {
                let sidecar = try found ?? XMPSidecar.resolve(for: image)
                try sidecar.write(adjustments: settings, metadata: metadata, defaults: baseline)
                return sidecar
            }.value
        } catch where XMPSidecar.isUnwritable(error) {
            canSave = false
            throw error
        }
        return nil
    }
    func stripSourceXMP() async throws { sidecar = sidecar?.withoutPreserved() }
    /// Copies the photo and its sidecars to `destination` and saves there; this store then keeps the copy.
    func saveCopy(to destination: URL, _ settings: Adjustments, baseline: Adjustments, metadata: CatalogMetadata?) async throws {
        let image = image
        sidecar = try await Task.detached(priority: .userInitiated) {
            try XMPSidecar.saveCopy(of: image, to: destination, adjustments: settings, metadata: metadata, defaults: baseline)
        }.value
        self.image = destination; canSave = true
    }
}

extension DevelopmentLoad {
    /// No store: the XMP file opened (`packet`), or else a sidecar beside the photo, is read but never written.
    static func readOnly(packet explicit: URL?) -> DevelopmentLoad { DevelopmentLoad(resolve: { image, decoded, info in
        guard let packet = try explicit.map({ try XMPPacket(url: $0) }) ?? XMPPacket.sidecar(for: image).map({ try XMPPacket(url: $0) }) else { return LoadedDevelopment(adjustments: decoded, warnings: "") }
        let imported = try XMPCodec.apply(packet, to: decoded, defaults: info.defaults, profiles: info.profileResolver)
        return LoadedDevelopment(adjustments: imported.adjustments, xmpSource: imported.sourceData, metadata: imported.metadata, warnings: imported.warnings.joined(separator: "\n\n"))
    }) }
}
