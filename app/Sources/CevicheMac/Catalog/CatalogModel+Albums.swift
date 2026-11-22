import SwiftUI
import CevicheCore

struct AlbumDraft: Identifiable {
    let id = UUID()
    let albumID: String?
    var name: String
    let assetIDs: [String]
}

struct ImportDayNode: Identifiable, Equatable {
    let id: String
    let count: Int
    let batches: [CatalogImportGroup]
    static func tree(_ groups: [CatalogImportGroup]) -> [Self] {
        Dictionary(grouping: groups, by: \.day).sorted { $0.key > $1.key }.map { day, groups in
            Self(id: day, count: groups.reduce(0) { $0 + $1.count }, batches: groups.filter { $0.batchID != nil })
        }
    }
}

extension CatalogModel {
    enum SidebarGroupAction { case select, export, addToAlbum(String), newAlbum, trash }

    enum SidebarPhotoGroup {
        case imports(day: String, batchID: String?), captureDate(String, area: CatalogArea)
        var area: CatalogArea {
            if case .captureDate(_, let area) = self { return area }
            return .library
        }
    }

    /// Resolve the sidebar group independently of the grid's search, selection, paging and folded stacks.
    func actOnSidebarGroup(_ target: SidebarPhotoGroup, action: SidebarGroupAction, editor: EditorModel) async {
        guard let store, !isFolderIndex, canStartJob, !editor.busy, await flushMetadata(), self.store === store else { return }
        var group = CatalogFilter()
        group.everyGroupedPhoto = true; group.area = target.area
        switch target {
        case .imports(let day, let batchID):
            group.recentlyAdded = true; group.importDay = day; group.importBatchID = batchID
            group.sort = .importDate; group.ascending = false
        case .captureDate(let date, _):
            group.captureDay = date; group.sort = filter.sort; group.ascending = filter.ascending
        }
        do {
            let photos = try await store.assets(filter: group)
            guard self.store === store, canStartJob, !editor.busy, !photos.isEmpty else { return }
            switch action {
            case .select:
                if !showingLibrary { await closePhoto(editor: editor) }
                guard self.store === store, showingLibrary, !interactionBusy else { return }
                clearSelection()
                filter = group; refreshTask?.cancel()
                // Seed the complete group before refreshing sidebar counts. A concurrent refresh can supersede
                // this one; it must never leave the previous collection's rows available for selection.
                assets = photos; matchingCount = photos.count; limit = max(Self.pageSize, photos.count)
                groupMembers = [:]
                await refresh()
                guard self.store === store, filter == group, let first = assets.first else { return }
                cancelLibraryKeyboardNavigation()
                selectedIDs = Set(assets.map(\.id)); selectionAnchorID = first.id
                await selectAsset(first, preservingSelection: true)
            case .export: if group.area != .trash { requestExport(photos) }
            case .addToAlbum(let id): if group.area == .library { await addToAlbum(id, photos: photos) }
            case .newAlbum: if group.area == .library { requestAlbum(photos: photos) }
            case .trash: if group.area != .trash { pendingTrash = photos }
            }
        } catch { self.error = error.localizedDescription }
    }

    func requestAlbum(_ album: CatalogAlbum? = nil, photos: [CatalogAsset] = []) {
        guard canStartJob, store != nil else { return }
        albumDraft = AlbumDraft(albumID: album?.id, name: album?.name ?? "", assetIDs: photos.filter { $0.inLibrary }.map(\.id))
    }

    func saveAlbum(_ draft: AlbumDraft) async {
        guard let store, canStartJob else { return }
        do {
            if let id = draft.albumID { try await store.renameAlbum(id, to: draft.name) }
            else { try await store.createAlbum(name: draft.name, assetIDs: draft.assetIDs) }
            guard self.store === store else { return }
            albumDraft = nil
            await refresh()
        } catch { self.failure = Failure(L10n.tr("Couldn’t Save the Album"), error) }
    }

    func addToAlbum(_ id: String, photos: [CatalogAsset]) async { await addToAlbum(id, assetIDs: photos.map(\.id)) }
    func addToAlbum(_ id: String, assetIDs: [String]) async {
        guard let store, canStartJob else { return }
        do {
            try await store.addToAlbum(id, assetIDs: assetIDs)
            guard self.store === store else { return }
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    func removeFromAlbum(_ id: String, photos: [CatalogAsset]) async {
        guard let store, canStartJob, await flushMetadata() else { return }
        do {
            try await store.removeFromAlbum(id, assetIDs: photos.map(\.id))
            guard self.store === store else { return }
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    func deleteAlbum(_ id: String) async {
        guard let store, !catalogBusy, await flushMetadata() else { return }
        do {
            try await store.deleteAlbum(id)
            guard self.store === store else { return }
            if filter.albumID == id { await showCollection(trash: false) }
            else { await refresh() }
        } catch { self.failure = Failure(L10n.tr("Couldn’t Delete the Album"), error) }
    }

    func showAlbum(_ id: String) async {
        await showCatalogGroup(albumID: id)
    }

    func showCatalogGroup(albumID: String? = nil, recentlyAdded: Bool = false, importDay: String? = nil,
                          importBatchID: String? = nil, recentEdits: Bool = false) async {
        guard !interactionBusy, await flushMetadata() else { return }
        clearSelection()
        var value = baseFilter()
        value.albumID = albumID; value.recentlyAdded = recentlyAdded
        value.importDay = importDay; value.importBatchID = importBatchID; value.recentEdits = recentEdits
        if recentlyAdded { value.sort = .importDate; value.ascending = false }
        if recentEdits { value.sort = .edited; value.ascending = false }
        filter = value
    }
}

/// Names a new album, or renames one. A new album of tagged photos gets a name from Apple Intelligence where it is on,
/// put in selected so typing replaces it; nothing changes once the photographer has typed.
struct AlbumNameSheet: View {
    @ObservedObject var model: CatalogModel
    @State var draft: AlbumDraft
    @State private var saving = false
    @State private var suggesting = false
    @State private var selection: TextSelection?
    @FocusState private var nameFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: draft.albumID == nil ? L10n.tr("New Album") : L10n.tr("Rename Album"))
            TextField(L10n.tr("Album name"), text: $draft.name, selection: $selection).textFieldStyle(.formField).focused($nameFocused)
                .overlay(alignment: .trailing) { if suggesting { ProgressView().controlSize(.mini).padding(.trailing, 8) } }
            if draft.albumID == nil && !draft.assetIDs.isEmpty {
                Text(L10n.tr("Add \(draft.assetIDs.count) selected photos.")).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(L10n.tr("Cancel")) { model.albumDraft = nil }.keyboardShortcut(.cancelAction).buttonStyle(.secondaryAction)
                Button(draft.albumID == nil ? L10n.tr("Create") : L10n.tr("Save")) {
                    saving = true
                    Task { await model.saveAlbum(draft); saving = false }
                }.keyboardShortcut(.defaultAction).buttonStyle(.primaryAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 340).background(Theme.panel).disabled(saving)
        .onAppear { nameFocused = true }
        .task { await suggestName() }
    }
    private func suggestName() async {
        guard draft.albumID == nil, draft.name.isEmpty, !draft.assetIDs.isEmpty, AlbumNamer.available, let store = model.store,
              let context = try? await store.albumNameContext(assetIDs: draft.assetIDs), context.tagged else { return }
        suggesting = true
        defer { suggesting = false }
        guard let name = await AlbumNamer.name(for: context), !Task.isCancelled, draft.name.isEmpty else { return }
        draft.name = name
        nameFocused = true
        selection = TextSelection(range: name.startIndex..<name.endIndex)
    }
}
