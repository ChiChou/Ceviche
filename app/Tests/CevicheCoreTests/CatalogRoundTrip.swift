import Foundation
@testable import CevicheCore

/// Saves `settings` for the renderer's original in a fresh catalog, then reads them back and reopens the original, as the
/// editor does when a photo is opened again.
func reopenThroughCatalog(_ renderer: RawRenderer, _ settings: Adjustments) async throws -> (RawRenderer, Adjustments) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try CatalogStore(root: root)
    let prepared = try CatalogImporter.prepare(renderer.sourceURL)
    let asset = try await store.insert(prepared.0, thumbnail: prepared.1)
    _ = try await store.saveEdits(settings, assetID: asset.id, baseline: renderer.info.defaults)
    let stored = try await store.asset(asset.id)
    let saved = try await store.savedAdjustments(of: stored) ?? { throw EditorError.invalidDocument("No edits were stored.") }()
    let restored = try saved.validated()
    return (try RawRenderer(sourceURL: URL(fileURLWithPath: stored.sourcePath)), restored)
}
