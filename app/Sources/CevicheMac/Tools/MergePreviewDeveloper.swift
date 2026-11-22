import CoreGraphics
import Foundation
import CevicheCore

/// Shows a merge tool's preview as its result will be saved: with the edits of the photo the result is based on. One per
/// tool window; it reads each base photo's edits once.
@MainActor
final class MergePreviewDeveloper {
    weak var catalog: CatalogModel?
    private let assets: [CatalogAsset]
    /// What is placed on the picture and carries too, for a result that keeps the base photo's framing pixel for pixel.
    let placed: Set<EditTransferItem>
    private var edits: [String: Adjustments?] = [:]

    init(assets: [CatalogAsset], placed: Set<EditTransferItem> = []) { self.assets = assets; self.placed = placed }

    /// The catalog's photo for one of the tool's originals; nil for a file made on the way, such as a merged bracket.
    func asset(for url: URL?) -> CatalogAsset? {
        guard let url else { return nil }
        return assets.first { $0.filename == url.lastPathComponent }
    }

    /// `source` developed with the edits of the photo at `base`, as large as `size`; nil when that photo has no edits
    /// or developing fails, and the preview stays as drawn.
    func image(_ source: MergePreviewSource?, base: URL?, size: Int) async -> CGImage? {
        guard let source, let catalog, let asset = asset(for: base) else { return nil }
        let known: Adjustments?? = edits[asset.id].map { .some($0) } ?? nil
        let result = await catalog.developedPreview(source, from: asset, placed: placed, maxDimension: size, known: known)
        if case .some(let edit) = result.edit { edits[asset.id] = edit }
        return result.image
    }
}
