import SwiftUI
import CevicheCore

/// Collections, file types and the Capture Date outline, or folders on disk, drawn in the inspector's style rather than
/// as a system source list. A footer holds what applies to the whole window.
struct CatalogSidebar: View {
    @ObservedObject var model: CatalogModel
    @ObservedObject var editor: EditorModel
    @ObservedObject private var folders: FolderBrowser
    init(model: CatalogModel, editor: EditorModel) { self.model = model; self.editor = editor; folders = model.folders }
    @State private var expandedDates: Set<String> = []
    @State private var expandedImports: Set<String> = []
    @State private var importsExpanded = true
    /// The album photos are being dragged over.
    @State private var dropAlbum: String?
    /// The album awaiting confirmation before it is deleted.
    @State private var albumToDelete: CatalogAlbumSummary?
    @State private var trashAlbumPhotos = false
    @State private var renamingAlbum: String?
    @FocusState private var focused: Bool

    enum Item: Hashable {
        case allPhotos, map, faces, duplicates, similar, archive, trash, kind(String), date(String), album(String), recentEdits, recentlyAdded
        case importDay(String), importBatch(day: String, id: String)
        /// A folder on disk, under one root of the outline.
        case folder(String, root: String)
        /// The line under a folder the system would not let the app read.
        case folderDenied(String, root: String)
    }

    /// Rows that open and close; the outline state behind each lives in the sets above.
    private enum Disclosure: Hashable { case imports, importDay(String), date(String), folder(FolderBrowser.Node) }

    private struct Row: Identifiable {
        let item: Item
        let title: String
        var icon: String?
        var count: Int?
        var depth = 0
        var disclosure: Disclosure?
        var help: String?
        var id: Item { item }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                ImportSplitButton(catalog: model).disabled(!model.canImport)
                    .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
                tabs
                Rule()
                ScrollViewReader { proxy in
                    ScrollView {
                        if model.sidebarTab == .folders { folderSections } else { catalogSections }
                    }
                    .onChange(of: selected) { _, item in if focused, let item { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(item) } } }
                    // A photo opened from the Finder: its folder's row appears once each level above it is read.
                    .onChange(of: folders.contents) { revealFolder(proxy) }
                    .onChange(of: model.folderScrollTarget) { revealFolder(proxy) }
                }
            }
            .focusable().focused($focused).focusEffectDisabled()
            .onMoveCommand(perform: move)
            .disabled(model.interactionBusy || editor.busy)
            SidebarFooter(model: model)
        }
        .background(Theme.panel)
        // Nothing on disk is looked at until the Folders tab shows.
        .onChange(of: model.sidebarTab, initial: true) { _, tab in if tab == .folders { folders.activate() } }
        .alert(albumToDelete.map { L10n.tr("Delete “\($0.album.name)”?") } ?? "",
               isPresented: Binding(get: { albumToDelete != nil }, set: { if !$0 { albumToDelete = nil } })) {
            Button(trashAlbumPhotos ? L10n.tr("Trash Photos and Delete Album") : L10n.tr("Delete Album"), role: .destructive) {
                if let id = albumToDelete?.id {
                    let trashPhotos = trashAlbumPhotos
                    Task {
                        if trashPhotos { await model.trashPhotosAndDeleteAlbum(id, editor: editor) }
                        else { await model.deleteAlbum(id) }
                    }
                }
                albumToDelete = nil
            }
            Button(L10n.tr("Cancel"), role: .cancel) { albumToDelete = nil }
        } message: {
            Text(trashAlbumPhotos
                 ? L10n.tr("All photos in this album will move to Trash, including photos in other albums. The album will be deleted.")
                 : L10n.tr("Photos stay in the catalog."))
        }
        .onChange(of: model.filter.importDay, initial: true) { _, day in
            if let day { importsExpanded = true; expandedImports.insert(day) }
        }
        // Reveal the active period, and open the newest year the first time dates appear.
        .onChange(of: model.filter.captureDay, initial: true) { _, day in expandedDates.formUnion(CaptureDateNode.ancestors(of: day ?? "")) }
        .onChange(of: model.dates.first?.id, initial: true) { _, year in if expandedDates.isEmpty, let year { expandedDates.insert(year) } }
    }

    private var catalogSections: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(libraryRows) { rowView($0) }
            // A single file type is not a useful filter.
            if model.kinds.count > 1 {
                sectionTitle(L10n.tr("File Type"))
                ForEach(kindRows) { rowView($0) }
            }
            if !model.dates.isEmpty {
                sectionTitle(L10n.tr("Capture Date"))
                ForEach(dateRows) { rowView($0) }
            }
            sectionTitle(L10n.tr("Albums")) {
                Button { model.requestAlbum() } label: { Image(systemName: "plus").font(.system(size: 11, weight: .medium)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(L10n.tr("New Album")).accessibilityLabel(L10n.tr("New Album"))
                    .disabled(model.catalogBusy)
            }
            VStack(spacing: 4) { ForEach(model.albums) { albumRow($0) } }.padding(.top, 2)
            if model.albums.isEmpty {
                Text(L10n.tr("No albums yet")).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 4)
            }
        }.padding(.horizontal, 8).padding(.vertical, 8)
    }

    /// Places, the home folder and connected volumes; each opens a level at a time.
    private var folderSections: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(folderRows(folders.places + [folders.home])) { rowView($0) }
            if !folders.volumes.isEmpty {
                sectionTitle(L10n.tr("Volumes"))
                ForEach(folderRows(folders.volumes)) { rowView($0) }
            }
        }.padding(.horizontal, 8).padding(.vertical, 8)
    }

    /// The open catalog, with a cloud for ones that sync, beside the folders on disk.
    private var tabs: some View {
        HStack(spacing: 2) {
            // A fixed word: a catalog's own name can be any length. The name is in the tip, with where it is.
            if model.hasLibrary {
                tab(.catalog, title: L10n.tr("Library"), icon: model.manifest?.kind == .cloud ? "icloud" : "books.vertical")
                    .help([model.manifest?.name, model.root.map { ($0.path as NSString).abbreviatingWithTildeInPath }].compactMap { $0 }.joined(separator: "\n"))
                    .contextMenu { catalogMenu }
            }
            tab(.folders, title: L10n.tr("Folders"), icon: "folder").layoutPriority(1)
            Spacer(minLength: 0)
        }.padding(.horizontal, 10).frame(height: 42)
    }

    private func tab(_ value: CatalogModel.SidebarTab, title: String, icon: String) -> some View {
        let on = model.sidebarTab == value
        return Button { model.sidebarTab = value } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11))
                Text(title).textCase(.uppercase).font(.system(size: 10, weight: .semibold)).tracking(1.2).lineLimit(1)
            }
            .foregroundStyle(on ? .primary : .tertiary)
            .padding(.horizontal, 8).frame(height: 26)
            .background(on ? Theme.ink.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
    }

    /// The catalog items of the File menu.
    @ViewBuilder private var catalogMenu: some View {
        Group {
            Button(model.hasLibrary ? L10n.tr("Close Catalog") : L10n.tr("Close Folders")) { Task { await model.closeCatalog(editor: editor) } }
                .disabled(model.catalogWideBusy || editor.busy)
            Divider()
            Button(L10n.tr("Catalog Info")) { model.showCatalogOverview(editor: editor) }
            Button(L10n.tr("Back Up Catalog…"), action: model.backup).disabled(model.catalogWideBusy)
            Button(L10n.tr("Back Up Catalog with Originals…"), action: model.backupWithOriginals).disabled(model.catalogWideBusy)
            Button(L10n.tr("Show in Finder")) { if let root = model.root { NSWorkspace.shared.showInFinder([root]) } }
        }
    }

    private func sectionTitle(_ title: String) -> some View { sectionTitle(title) { EmptyView() } }

    private func sectionTitle<Accessory: View>(_ title: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack {
            Text(title).textCase(.uppercase).font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
            Spacer()
            accessory()
        }.padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 4)
    }

    // MARK: Rows

    private var libraryRows: [Row] {
        var rows = [Row(item: .allPhotos, title: L10n.tr("All Photos"), icon: "photo.on.rectangle", count: model.total),
                    Row(item: .recentlyAdded, title: L10n.tr("Recently Added"), icon: "clock", disclosure: recentImportDays.isEmpty ? nil : .imports,
                        help: L10n.tr("Show all imported photos. The tree lists the five most recent import groups."))]
        if importsExpanded {
            for day in recentImportDays {
                rows.append(Row(item: .importDay(day.id), title: CaptureDateNode.title(for: day.id, full: true), count: day.count, depth: 1,
                                disclosure: day.batches.isEmpty ? nil : .importDay(day.id)))
                guard !day.batches.isEmpty, expandedImports.contains(day.id) else { continue }
                for batch in day.batches {
                    if let id = batch.batchID {
                        rows.append(Row(item: .importBatch(day: day.id, id: id), title: batch.startedAt.localized(date: .omitted, time: .standard),
                                        count: batch.count, depth: 2, help: L10n.tr("Import batch - ") + batch.startedAt.formatted()))
                    }
                }
            }
        }
        rows += [Row(item: .recentEdits, title: L10n.tr("Recent Edits"), icon: "slider.horizontal.3", count: model.recentEditsCount),
                 Row(item: .map, title: L10n.tr("Map"), icon: "map"),
                 Row(item: .faces, title: L10n.tr("People"), icon: "person.2")]
        rows.append(Row(item: .duplicates, title: L10n.tr("Duplicates"), icon: "square.on.square", count: model.duplicateCount))
        // Show Similar Photos' results, while they are shown.
        if case .similar = model.filter.photoSet?.kind {
            rows.append(Row(item: .similar, title: L10n.tr("Similar Photos"), icon: "rectangle.stack", count: model.matchingCount))
        }
        // The archive shows once something is in it, or while it is open.
        if model.archiveCount > 0 || model.filter.area == .archive {
            rows.append(Row(item: .archive, title: L10n.tr("Archived"), icon: "archivebox", count: model.archiveCount))
        }
        rows.append(Row(item: .trash, title: L10n.tr("Trash"), icon: "trash", count: model.trashCount))
        return rows
    }

    private var kindRows: [Row] { model.kinds.map { Row(item: .kind($0), title: $0, icon: "doc") } }

    private var dateRows: [Row] {
        var rows: [Row] = []
        func add(_ node: CaptureDateNode, depth: Int) {
            // Months and days are indented by the outline; only years and Unknown Date carry an icon.
            let icon = node.id.isEmpty ? "questionmark.circle" : node.id.count == 4 ? "calendar" : nil
            rows.append(Row(item: .date(node.id), title: node.title, icon: icon, count: node.count, depth: depth,
                            disclosure: node.children == nil ? nil : .date(node.id)))
            if let children = node.children, expandedDates.contains(node.id) { children.forEach { add($0, depth: depth + 1) } }
        }
        model.dates.forEach { add($0, depth: 0) }
        return rows
    }

    /// The outline under `roots`. A folder keeps its chevron until it has been opened and found to hold no folders:
    /// looking ahead would read folders the person never asked for, and macOS asks permission for some of them.
    private func folderRows(_ roots: [FolderBrowser.Root]) -> [Row] {
        var rows: [Row] = []
        func add(_ path: String, root: FolderBrowser.Root, title: String, icon: String, depth: Int) {
            let node = FolderBrowser.Node(root: root.id, path: path)
            let contents = folders.contents[path]
            let leaf = contents == .folders([]) || contents == .missing
            rows.append(Row(item: .folder(path, root: root.id), title: title, icon: icon, depth: depth, disclosure: leaf ? nil : .folder(node)))
            guard folders.isExpanded(node) else { return }
            switch contents {
            case .folders(let children): for child in children { add(CatalogFolders.path(child), root: root, title: child.lastPathComponent, icon: "folder", depth: depth + 1) }
            case .denied: rows.append(Row(item: .folderDenied(path, root: root.id), title: L10n.tr("No Access"), icon: "lock", depth: depth + 1))
            case .loading, .missing, nil: break
            }
        }
        for root in roots { add(root.path, root: root, title: root.title, icon: root.icon, depth: 0) }
        return rows
    }

    /// Every visible row in display order, for the arrow keys.
    private var allRows: [Row] {
        if model.sidebarTab == .folders {
            return folderRows(folders.roots).filter { if case .folderDenied = $0.item { return false } else { return true } }
        }
        return libraryRows + (model.kinds.count > 1 ? kindRows : []) + dateRows + model.albums.map { Row(item: .album($0.id), title: $0.album.name) }
    }

    private func rowView(_ row: Row) -> some View {
        SidebarRow(title: row.title, count: row.count, depth: row.depth, selected: selected == row.item,
                   expanded: row.disclosure.map(isExpanded), toggle: { row.disclosure.map(toggle) }, select: { choose(row.item) }) {
            if let icon = row.icon { Image(systemName: icon) }
        }
        .help(row.help ?? "")
        .id(row.item)
        .contextMenu {
            if case .importDay(let day) = row.item { photoGroupMenu(.imports(day: day, batchID: nil)) }
            if case .importBatch(let day, let id) = row.item { photoGroupMenu(.imports(day: day, batchID: id)) }
            if case .date(let date) = row.item { photoGroupMenu(.captureDate(date, area: model.filter.area)) }
            if row.item == .trash {
                Button(L10n.tr("Empty Trash…")) { Task { await model.requestEmptyTrash(editor: editor) } }.disabled(model.trashCount == 0 || model.catalogBusy)
            }
            if case .folder(let path, _) = row.item {
                Button(L10n.tr("Show in Finder")) { NSWorkspace.shared.showInFinder([URL(fileURLWithPath: path)]) }
                // Not for the places themselves (Pictures, the home folder, a volume): only what is inside them.
                if !folders.roots.contains(where: { $0.path == path }) {
                    Divider()
                    Button(L10n.tr("Move to Trash…")) { model.trashFolder(URL(fileURLWithPath: path, isDirectory: true)) }
                }
            }
            if case .folderDenied(let path, _) = row.item {
                Button(L10n.tr("Privacy Settings…")) { CatalogModel.openPrivacySettings() }
                Button(L10n.tr("Try Again")) { folders.retry(path) }
            }
        }
    }

    private func photoGroupMenu(_ group: CatalogModel.SidebarPhotoGroup) -> some View {
        Group {
            Button(L10n.tr("Select Photos")) { photoGroupAction(.select, group: group) }
            Button(L10n.tr("Export…")) { photoGroupAction(.export, group: group) }
                .disabled(group.area == .trash)
            Menu(L10n.tr("Add to Album")) {
                ForEach(model.albums) { album in
                    Button(album.album.name) { photoGroupAction(.addToAlbum(album.id), group: group) }
                }
                if !model.albums.isEmpty { Divider() }
                Button(L10n.tr("New Album…")) { photoGroupAction(.newAlbum, group: group) }
            }.disabled(group.area != .library)
            Divider()
            Button(L10n.tr("Move to Trash…"), role: .destructive) { photoGroupAction(.trash, group: group) }
                .disabled(group.area == .trash)
        }.disabled(!model.canStartJob || editor.busy)
    }

    private func photoGroupAction(_ action: CatalogModel.SidebarGroupAction, group: CatalogModel.SidebarPhotoGroup) {
        Task { await model.actOnSidebarGroup(group, action: action, editor: editor) }
    }

    private func albumRow(_ summary: CatalogAlbumSummary) -> some View {
        SidebarRow(title: summary.album.name, count: summary.count, selected: selected == .album(summary.id), dropTarget: dropAlbum == summary.id, height: 52,
                   renameEditing: Binding(get: { renamingAlbum == summary.id }, set: { renamingAlbum = $0 ? summary.id : nil }),
                   rename: { name in Task { await model.saveAlbum(AlbumDraft(albumID: summary.id, name: name, assetIDs: [])) } },
                   select: { choose(.album(summary.id)) }) {
            CatalogThumbnail(assetID: summary.coverAssetID ?? "", thumbnailKey: summary.thumbnailKey, previews: model.store?.previews, fillsFrame: true)
                .id(summary.coverAssetID)
                .frame(width: 40, height: 40).clipped()
                .padding(.trailing, 4)
        }
        .disabled(model.catalogBusy)
        .help(summary.album.name)
        .id(Item.album(summary.id))
        // Photos dragged from the grid, the wall or the filmstrip join the album.
        .dropDestination(for: PhotoDrag.self) { drags, _ in model.dropPhotos(drags, onAlbum: summary.id) } isTargeted: { over in
            if over { dropAlbum = summary.id } else if dropAlbum == summary.id { dropAlbum = nil }
        }
        .contextMenu {
            Button(L10n.tr("Add Selected Photos")) { Task { await model.addToAlbum(summary.id, photos: model.selectedAssets) } }
                .disabled(model.selectedIDs.isEmpty || model.filter.area != .library)
            Button(L10n.tr("Rename Album…")) { renamingAlbum = summary.id }.disabled(model.catalogBusy)
            Divider()
            Button(L10n.tr("Delete Album…"), role: .destructive) { trashAlbumPhotos = false; albumToDelete = summary }
            Button(L10n.tr("Trash Photos and Delete Album…"), role: .destructive) { trashAlbumPhotos = true; albumToDelete = summary }
                .disabled(summary.count == 0)
        }
    }

    // MARK: Outline and keyboard

    private func isExpanded(_ disclosure: Disclosure) -> Bool {
        switch disclosure {
        case .imports: importsExpanded
        case .importDay(let day): expandedImports.contains(day)
        case .date(let id): expandedDates.contains(id)
        case .folder(let node): folders.isExpanded(node)
        }
    }

    private func toggle(_ disclosure: Disclosure) { setExpanded(disclosure, !isExpanded(disclosure)) }

    private func setExpanded(_ disclosure: Disclosure, _ open: Bool) {
        withAnimation(.easeInOut(duration: 0.15)) {
            switch disclosure {
            case .imports: importsExpanded = open
            case .importDay(let day): if open { expandedImports.insert(day) } else { expandedImports.remove(day) }
            case .date(let id): if open { expandedDates.insert(id) } else { expandedDates.remove(id) }
            case .folder(let node): folders.setExpanded(node, open)
            }
        }
    }

    private func choose(_ item: Item) {
        if case .folderDenied = item { CatalogModel.openPrivacySettings(); return }
        focused = true
        selection.wrappedValue = item
    }

    private func move(_ direction: MoveCommandDirection) {
        let rows = allRows
        let index = rows.firstIndex { $0.item == selected }
        switch direction {
        case .up: if let index, index > 0 { selection.wrappedValue = rows[index - 1].item } else if index == nil, let first = rows.first { selection.wrappedValue = first.item }
        case .down: if let index, index + 1 < rows.count { selection.wrappedValue = rows[index + 1].item } else if index == nil, let first = rows.first { selection.wrappedValue = first.item }
        case .left: if let index, let disclosure = rows[index].disclosure { setExpanded(disclosure, false) }
        case .right: if let index, let disclosure = rows[index].disclosure { setExpanded(disclosure, true) }
        @unknown default: break
        }
    }

    private var selected: Item? { selection.wrappedValue }
    private func revealFolder(_ proxy: ScrollViewProxy) {
        guard let path = model.folderScrollTarget, let root = model.folderRoot else { return }
        let node = FolderBrowser.Node(root: root, path: (path as NSString).deletingLastPathComponent)
        // The parent is open and read: the row is in the outline.
        guard path == folders.roots.first(where: { $0.id == root })?.path || (folders.isExpanded(node) && folders.contents[node.path] != .loading && folders.contents[node.path] != nil) else { return }
        model.folderScrollTarget = nil
        DispatchQueue.main.async { proxy.scrollTo(Item.folder(path, root: root), anchor: .center) }
    }

    /// The five most recent batches, under their days; a day's count still describes all photos imported that day.
    private var recentImportDays: [ImportDayNode] {
        var remaining = 5
        var days: [ImportDayNode] = []
        for day in model.importDays {
            guard remaining > 0 else { break }
            let batches = Array(day.batches.prefix(remaining))
            remaining -= batches.count
            days.append(ImportDayNode(id: day.id, count: day.count, batches: batches))
        }
        return days
    }

    private var selection: Binding<Item?> {
        Binding(get: {
            let filter = model.filter
            if let id = filter.albumID { return .album(id) }
            if let folder = filter.folder { return .folder(folder, root: model.folderRoot ?? "") }
            if filter.recentEdits { return .recentEdits }
            if let set = filter.photoSet { return set.kind == .duplicates ? .duplicates : .similar }
            if let day = filter.importDay {
                if let id = filter.importBatchID { return .importBatch(day: day, id: id) }
                return .importDay(day)
            }
            if filter.recentlyAdded { return .recentlyAdded }
            if filter.geotagged { return .map }
            if filter.withFaces { return .faces }
            if let day = filter.captureDay { return .date(day) }
            if let kind = filter.kind { return .kind(kind) }
            return filter.area == .trash ? .trash : filter.area == .archive ? .archive : .allPhotos
        }, set: { item in
            guard let item else { return }
            // The sidebar is shared by every view; choosing a collection browses it in the grid.
            Task {
                if !model.showingLibrary { await model.closePhoto(editor: editor); guard model.showingLibrary else { return } }
                switch item {
                case .album(let id): await model.showAlbum(id)
                case .folder(let path, let root): await model.showFolder(URL(fileURLWithPath: path, isDirectory: true), root: root)
                case .folderDenied: break
                case .recentEdits: await model.showCatalogGroup(recentEdits: true)
                case .recentlyAdded: await model.showCatalogGroup(recentlyAdded: true)
                case .importDay(let day): await model.showCatalogGroup(recentlyAdded: true, importDay: day)
                case .importBatch(let day, let id): await model.showCatalogGroup(recentlyAdded: true, importDay: day, importBatchID: id)
                case .allPhotos: await model.showCollection(trash: false)
                case .map: await model.showCollection(trash: false, geotagged: true)
                case .faces: await model.showCollection(area: .library, faces: true)
                case .duplicates: await model.showDuplicates(editor: editor)
                case .similar: break
                case .archive: await model.showCollection(area: .archive)
                case .trash: await model.showCollection(trash: true)
                case .kind(let kind): model.showSubset(kind: kind)
                case .date(let day): model.showSubset(captureDay: day)
                }
            }
        })
    }
}

/// One sidebar line: an outline chevron, an icon or thumbnail, the title and a count, with the accent marking the selection.
private struct SidebarRow<Icon: View>: View {
    let title: String
    var count: Int?
    var depth = 0
    let selected: Bool
    var dropTarget = false
    var height: CGFloat = 28
    var renameEditing: Binding<Bool> = .constant(false)
    var rename: ((String) -> Void)?
    /// Nil for rows without children.
    var expanded: Bool?
    var toggle: () -> Void = {}
    let select: () -> Void
    @ViewBuilder let icon: Icon
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 6) {
            Group {
                if let expanded {
                    Button(action: toggle) {
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(expanded ? 90 : 0))
                            .frame(width: 12, height: 18).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(.tertiary).accessibilityLabel(expanded ? L10n.tr("Collapse \(title)") : L10n.tr("Expand \(title)"))
                } else { Color.clear.frame(width: 12, height: 1) }
            }.padding(.leading, CGFloat(depth) * 14)
            // Selecting is the action of everything but the chevron, which keeps its own: expand. A stack, not a Group:
            // a Group hands its accessibility modifiers to each child, leaving the icon, title and count apart.
            HStack(spacing: 6) {
                icon.font(.system(size: 12)).foregroundStyle(selected ? Theme.accent : .secondary).frame(minWidth: 16).accessibilityHidden(true)
                if let rename {
                    InlineRenameLabel(name: title, editing: renameEditing, semibold: selected, select: select, commit: rename)
                } else {
                    Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular)).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if let count, count > 0 {
                    Text(L10n.tr("\(count)")).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            // One element per row (title, then count), not a button for each of the icon, title and count.
            .accessibilityElement(children: renameEditing.wrappedValue ? .contain : .combine)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { select() }
        }
        .padding(.leading, 2).padding(.trailing, 8).frame(minHeight: height).contentShape(Rectangle())
        .background(background, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .onTapGesture(perform: select)
        // Like Finder's sidebar and the buttons here, a row answers the click that also brings the window forward.
        .allowsWindowActivationEvents(true)
        .onHover { hovering = $0 }
    }
    private var background: Color {
        dropTarget ? Theme.accent.opacity(0.35) : selected ? Theme.accent.opacity(0.16) : hovering ? Theme.ink.opacity(0.05) : .clear
    }
}

/// The bottom of the sidebar, level with the status bar: Settings, the light and dark palettes, and the progress of the
/// folder being indexed.
private struct SidebarFooter: View {
    @ObservedObject var model: CatalogModel
    var body: some View {
        VStack(spacing: 0) {
            Rule()
            HStack(spacing: 2) {
                SettingsAndAppearanceButtons()
                if model.sidebarTab == .folders {
                    // Applies to whichever folder is chosen, so it sits with the other standing choices.
                    Button { model.setFolderSubfolders(!model.folderSubfolders) } label: {
                        Image(systemName: "list.bullet.indent").foregroundStyle(model.folderSubfolders ? Color.primary : Color.secondary)
                            .frame(width: 28, height: 24)
                            .background(model.folderSubfolders ? Theme.ink.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                            .frame(height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help(L10n.tr("Include Subfolders")).accessibilityLabel(L10n.tr("Include Subfolders"))
                    .accessibilityAddTraits(model.folderSubfolders ? .isSelected : [])
                }
                Spacer(minLength: 4)
                if let sync = model.folderSync, sync.total > 0 || sync.listing {
                    if sync.total > 0 {
                        ProgressView(value: Double(sync.done), total: Double(sync.total)).progressViewStyle(.circular).controlSize(.small)
                        Text(verbatim: "\(sync.done.formatted())/\(sync.total.formatted())").font(.system(size: 11)).monospacedDigit().lineLimit(1)
                            .help(L10n.tr("Indexing \((sync.path as NSString).lastPathComponent)"))
                    } else {
                        // Listing: how many photos there are is not known until it ends.
                        ProgressView().controlSize(.small).help(L10n.tr("Indexing \((sync.path as NSString).lastPathComponent)"))
                    }
                    Button(action: model.stopFolderSync) { Image(systemName: "xmark.circle.fill").frame(width: 22, height: 28).contentShape(Rectangle()) }
                        .buttonStyle(.plain).help(L10n.tr("Stop")).accessibilityLabel(L10n.tr("Stop"))
                }
            }
            .font(.system(size: 13)).foregroundStyle(.secondary).padding(.horizontal, 8).frame(height: 36)
        }
    }
}

/// Import Photos with its sources: devices discovered by Image Capture, Photos, and folders.
private struct ImportSplitButton: View {
    @ObservedObject var catalog: CatalogModel
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 0) {
            Button(action: catalog.chooseImport) {
                Label(L10n.tr("Import Photos…"), systemImage: "square.and.arrow.down")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity).frame(height: 32).contentShape(Rectangle())
            }.buttonStyle(.plain).help(L10n.tr("Import Photos (⇧⌘I)"))
            Rectangle().fill(Theme.accent.opacity(0.35)).frame(width: 1, height: 18)
            Menu { CardImportItems(catalog: catalog, compact: true) } label: {
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.accent)
                    .frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help(L10n.tr("Import from Camera, Photos, or Folder")).accessibilityLabel(L10n.tr("Import sources"))
            .findsCamerasWhenOpened(catalog)
        }
        .foregroundStyle(Theme.accent)
        .background(Theme.accent.opacity(hovering && isEnabled ? 0.1 : 0), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.accent.opacity(0.6)))
        .opacity(isEnabled ? 1 : 0.4)
        .allowsWindowActivationEvents(true)
        .onHover { hovering = $0 }
    }
}

/// Settings, and the light and dark palettes, in the sidebar's footer.
struct SettingsAndAppearanceButtons: View {
    @AppStorage(AppearanceChoice.key) private var appearance = AppearanceChoice.dark.rawValue
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        SettingsLink { Image(systemName: "gearshape").frame(width: 28, height: 28).contentShape(Rectangle()) }
            .buttonStyle(.plain).help(L10n.tr("Settings (⌘,)")).accessibilityLabel(L10n.tr("Settings"))
        // One click swaps the surround a photo is judged against; the menu also offers following the system.
        Button { appearance = (colorScheme == .dark ? AppearanceChoice.light : .dark).rawValue } label: {
            Image(systemName: colorScheme == .dark ? "moon" : "sun.max").frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(L10n.tr("Appearance")).accessibilityLabel(L10n.tr("Appearance"))
        .contextMenu {
            ForEach(AppearanceChoice.allCases) { choice in
                Toggle(choice.name, isOn: Binding(get: { appearance == choice.rawValue }, set: { _ in appearance = choice.rawValue }))
            }
        }
    }
}
