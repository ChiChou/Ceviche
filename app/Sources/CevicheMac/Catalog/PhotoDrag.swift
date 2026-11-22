import SwiftUI
import UniformTypeIdentifiers
import CevicheCore

extension UTType {
    /// Photos dragged within Ceviche, and a catalog package; both declared in Info.plist.
    static let cevichePhotos = UTType(exportedAs: "me.chichou.ceviche.photos")
    static let cevicheCatalog = UTType(exportedAs: "me.chichou.ceviche.catalog")
}

/// Photos dragged from the grid, the wall or the filmstrip onto an album: their IDs, and the catalog they belong to.
struct PhotoDrag: Codable, Transferable {
    let catalogID: String
    let assetIDs: [String]
    static var transferRepresentation: some TransferRepresentation { CodableRepresentation(contentType: .cevichePhotos) }
}

extension CatalogModel {
    /// What dragging `asset` carries: the selection when the photo is part of it, as in Finder, otherwise the photo alone
    /// (a folded group with all its photos).
    func photoDrag(for asset: CatalogAsset) -> PhotoDrag {
        let ids = contextAssets(for: asset).map(\.id)
        return PhotoDrag(catalogID: manifest?.id ?? "", assetIDs: ids)
    }
    /// Adds dropped photos to an album. Photos dragged from another catalog's window are ignored.
    func dropPhotos(_ drags: [PhotoDrag], onAlbum id: String) -> Bool {
        let ids = drags.filter { $0.catalogID == manifest?.id }.flatMap(\.assetIDs)
        guard !ids.isEmpty, !catalogBusy else { return false }
        Task { await addToAlbum(id, assetIDs: ids) }
        return true
    }
}

/// Makes a photo cell draggable onto albums. Photos in the Trash cannot be added to albums, so they do not drag.
/// The model is read only when a drag starts, so cells do not redraw on every catalog change.
struct PhotoDragSource: ViewModifier {
    let model: CatalogModel
    let asset: CatalogAsset
    /// The view shows the library, not the Trash or the archive.
    let libraryArea: Bool
    func body(content: Content) -> some View {
        if !libraryArea || !asset.inLibrary { content }
        else {
            content.draggable(model.photoDrag(for: asset)) {
                PhotoDragPreview(asset: asset, previews: model.previews, count: model.photoDrag(for: asset).assetIDs.count)
            }
        }
    }
}

/// The dragged photo, with how many photos the drag carries.
private struct PhotoDragPreview: View {
    let asset: CatalogAsset
    let previews: PreviewStore?
    let count: Int
    var body: some View {
        CatalogThumbnail(asset: asset, previews: previews)
            .frame(width: 96, height: 72).clipped()
            .overlay(alignment: .topTrailing) {
                if count > 1 {
                    Text(count.formatted()).font(.caption.bold()).monospacedDigit().foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.accent, in: Capsule()).offset(x: 6, y: -6)
                }
            }
    }
}
