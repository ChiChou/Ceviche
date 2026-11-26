#if canImport(BackgroundAssets)
import BackgroundAssets
import Foundation
import System

/// The App Store build's models, as Apple-hosted Background Assets: one on-demand asset pack per archive of the pinned
/// model set, `<tag>.<Name>` for the FP16 copy and `<tag>.<Name>-INT8` for the INT8 one, each holding that archive as
/// the GitHub release has it. The set's tag is in the name because a pack isn't tied to a build: a new version of a
/// pack reaches every installed build, so a later set's archives go in packs of their own and older builds keep theirs (`models/package-asset-packs.sh` makes them from `models/package-models.sh`'s output). The archive is
/// verified and installed as a downloaded one is, then the pack is let go: the library keeps the installed copy.
@available(iOS 26, macOS 26, *)
enum ModelAssetPacks {
    /// The pack that holds `asset` of the set tagged `tag`, named after both.
    static func packID(_ asset: ModelSet.Asset, tag: String) -> String { "\(tag).\((asset.file as NSString).deletingPathExtension)" }

    /// Downloads `asset`'s pack if it isn't on the device yet and copies its archive out to a temporary file, which the
    /// caller verifies, installs and removes. `progress` hears the bytes received and expected.
    static func fetch(_ asset: ModelSet.Asset, tag: String, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> URL {
        let manager = AssetPackManager.shared, id = packID(asset, tag: tag)
        let pack = try await manager.assetPack(withID: id)
        let watch = Task {
            for await update in manager.statusUpdates(forAssetPackWithID: id) {
                if case .downloading(_, let done) = update {
                    progress(done.completedUnitCount, done.totalUnitCount > 0 ? done.totalUnitCount : Int64(pack.downloadSize))
                }
            }
        }
        defer { watch.cancel() }
        if #available(iOS 26.4, macOS 26.4, *) {
            try await manager.ensureLocalAvailability(of: pack, requireLatestVersion: false)
        } else {
            try await manager.ensureLocalAvailability(of: pack)
        }
        try Task.checkCancellation()
        let inside = try manager.url(for: FilePath(asset.file))
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(asset.file)")
        try FileManager.default.copyItem(at: inside, to: copy)
        return copy
    }

    /// Lets `asset`'s pack go once its model is installed, so the archive isn't kept twice.
    static func discard(_ asset: ModelSet.Asset, tag: String) async {
        try? await AssetPackManager.shared.remove(assetPackWithID: packID(asset, tag: tag))
    }
}
#endif
