import SwiftUI
import CevicheCore

/// Nil represents a mixed selection, never an instruction to clear metadata.
struct InspectorReviewControls: View {
    let rating: Int?
    let review: ReviewState?
    let setRating: (Int) -> Void
    let setReview: (ReviewState) -> Void

    var body: some View {
        InfoSection(L10n.tr("Rating")) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    StarRatingDrag(rating: rating, set: setRating)
                    if rating == nil { Text(L10n.tr("Mixed")).font(.caption2).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 4)
                Picker(L10n.tr("Flag"), selection: Binding<ReviewState?>(get: { review }, set: { if let value = $0 { setReview(value) } })) {
                    if review == nil { Text(L10n.tr("Mixed")).tag(ReviewState?.none).disabled(true) }
                    Label(L10n.tr("Unflagged"), systemImage: "circle.dashed").tag(ReviewState?.some(.unreviewed))
                    Label(L10n.tr("Picked"), systemImage: "checkmark.circle").tag(ReviewState?.some(.accepted))
                    Label(L10n.tr("Rejected"), systemImage: "xmark.circle").tag(ReviewState?.some(.rejected))
                }.labelsHidden().fixedSize().help(L10n.tr("Flag (P pick - X reject - U unflag)"))
            }.buttonStyle(.plain).font(.body)
        }
    }
}

struct InspectorAlbumMenu: View {
    @ObservedObject var model: CatalogModel
    let targets: [CatalogAsset]
    var body: some View {
        if !model.isFolderIndex {
            ActionMenu(L10n.tr("Add to Album")) {
                Button(L10n.tr("New Album…")) { model.requestAlbum(photos: targets) }
                if !model.albums.isEmpty { Divider() }
                ForEach(model.albums) { summary in
                    Button(summary.album.name) { Task { await model.addToAlbum(summary.id, photos: targets) } }
                }
                if let albumID = model.filter.albumID {
                    Divider()
                    Button(L10n.tr("Remove from Album")) { Task { await model.removeFromAlbum(albumID, photos: targets) } }
                }
            }.controlSize(.small).disabled(!model.canStartJob)
        }
    }
}

/// Add to Album with the colour labels beside it.
struct AlbumAndLabelRow: View {
    @ObservedObject var model: CatalogModel
    let targets: [CatalogAsset]
    var body: some View {
        HStack(spacing: 8) {
            InspectorAlbumMenu(model: model, targets: targets)
            Spacer(minLength: 0)
            PhotoLabelControls(catalog: model, targets: targets)
        }
    }
}

struct InspectorHeaderActions: View {
    @ObservedObject var model: CatalogModel
    @ObservedObject var editor: EditorModel
    let targets: [CatalogAsset]
    private var canReveal: Bool {
        targets.contains { if case .available = $0.availability(catalog: model.root) { return true }; return false }
    }
    var body: some View {
        HStack(spacing: 2) {
            IconButton("folder", L10n.tr("Show in Finder")) { model.showInFinder(targets) }.disabled(!canReveal)
            IconButton("trash", L10n.tr("Move to Trash")) { Task { await model.moveToTrash(targets, editor: editor) } }
                .disabled(model.catalogBusy || editor.busy)
            Menu {
                if targets.count == 1, let asset = targets.first {
                    PhotoContextMenu(catalog: model, editor: editor, asset: asset)
                } else {
                    Button(L10n.tr("Export \(targets.count) Originals with XMP…")) { model.exportOriginals(targets) }
                    if !model.isFolderIndex {
                        Divider()
                        Button(L10n.tr("Remove from Library…"), role: .destructive) { Task { await model.requestPermanentDeletion(targets, editor: editor) } }
                            .disabled(model.catalogBusy || editor.busy)
                    }
                }
            } label: { Image(systemName: "ellipsis").font(.system(size: 13)).frame(width: 22, height: 22).contentShape(Rectangle()) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().foregroundStyle(.secondary)
                .help(L10n.tr("More")).accessibilityLabel(L10n.tr("More"))
        }
    }
}
