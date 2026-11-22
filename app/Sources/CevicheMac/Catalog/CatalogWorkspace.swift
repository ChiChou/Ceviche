import SwiftUI
import MapKit
import CevicheCore

/// One window for every view, as in other RAW editors: the header, the catalog sidebar on the left and the status
/// bar stay put while the middle shows the grid, Compare or Detail, with the filmstrip under the last two.
/// The right side is the library inspector in the grid and the editing inspector otherwise.
struct CatalogWorkspace: View {
    @ObservedObject var catalog: CatalogModel
    @ObservedObject var editor: EditorModel
    @AppStorage("editorInspectorWidth") private var inspectorWidth = EditorInspector.defaultWidth
    private var trashTitle: String {
        guard let targets = catalog.pendingTrash else { return "" }
        return targets.count == 1 ? L10n.tr("Move “\(targets[0].filename)” to Trash?") : L10n.tr("Move \(targets.count.formatted()) Photos to Trash?")
    }
    private var resetTitle: String {
        guard let targets = catalog.pendingReset else { return "" }
        return targets.count == 1 ? L10n.tr("Reset Edits on “\(targets[0].filename)”?") : L10n.tr("Reset Edits on \(targets.count.formatted()) Photos?")
    }
    var body: some View {
        Group {
            // The card importer takes the whole window, as in other RAW editors, instead of a sheet over it.
            if catalog.showingCameraImport { CardImportView(catalog: catalog, camera: catalog.cameraImporter) }
            else if let request = catalog.cardImport { CardImportView(catalog: catalog, request: request).id(request.id) }
            else if let request = catalog.panoramaMerge { PanoramaMergeView(catalog: catalog, request: request).id(request.id) }
            else if let request = catalog.hdrMerge { HDRMergeView(catalog: catalog, request: request).id(request.id) }
            else if let request = catalog.photoStack { PhotoStackView(catalog: catalog, request: request).id(request.id) }
            else if let request = catalog.pixelShift { PixelShiftView(catalog: catalog, request: request).id(request.id) }
            else if let request = catalog.bestFaces { BestFacesView(catalog: catalog, request: request).id(request.id) }
            else if let request = catalog.nightSky { NightSkyView(catalog: catalog, request: request).id(request.id) }
            else if let request = catalog.focusStack { FocusStackView(catalog: catalog, request: request).id(request.id) }
            else if let request = catalog.timelapse { TimelapseDialog(catalog: catalog, request: request).id(request.id) }
            else if let request = catalog.exposureRamp { ExposureRampDialog(catalog: catalog, editor: editor, request: request).id(request.id) }
            else if let request = catalog.matchSeries { MatchSeriesDialog(catalog: catalog, editor: editor, request: request).id(request.id) }
            else if let request = catalog.chartProfile { ChartProfileDialog(catalog: catalog, editor: editor, request: request).id(request.id) }
            else if let request = catalog.filters { FiltersDialog(catalog: catalog, request: request).id(request.id) }
            else if let request = catalog.negative { NegativeDialog(catalog: catalog, request: request).id(request.id) }
            else if let request = catalog.denoise { DenoiseDialog(catalog: catalog, request: request).id(request.id) }
            else if let request = catalog.wideAngle { WideAngleDialog(catalog: catalog, request: request).id(request.id) }
            else if let request = catalog.cullingAssistant { CullingAssistantView(catalog: catalog, editor: editor, request: request).id(request.id) }
            else if let request = catalog.problemPhotos { ProblemPhotosView(catalog: catalog, editor: editor, request: request).id(request.id) }
            else if let request = catalog.faceCheck { FaceCheckView(catalog: catalog, request: request).id(request.id) }
            else if let request = catalog.tidyPairs { TidyPairsView(catalog: catalog, editor: editor, request: request).id(request.id) }
            else if let request = catalog.idPhoto { IDPhotoDialog(catalog: catalog, editor: editor, request: request).id(request.id) }
            else { workspace.background(PhotoBrowsingKeys(catalog: catalog, editor: editor)) }
        }
        .overlay {
            if catalog.photoDropTargeted {
                VStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down").font(.system(size: 28))
                    Text(L10n.tr("Drop to import photos")).font(.headline)
                    Text(L10n.tr("⌥⌘ to only import as references")).font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.panel))
                .overlay { RoundedRectangle(cornerRadius: Theme.Radius.panel).strokeBorder(.secondary.opacity(0.4)) }
                .allowsHitTesting(false)
            }
        }
        .themed()
        .ignoresSafeArea(.container, edges: .top)
        .background(Theme.canvas)
        .disabled(catalog.handlingXMP || catalog.mutatingCatalog)
        .sheet(item: Binding(get: { catalog.pendingDeletion }, set: { if $0 == nil { catalog.cancelPermanentDeletion() } })) { plan in
            CatalogDeletionConfirmation(model: catalog, presented: plan)
        }
        .xmpReport($catalog.xmpReport)
        .xmpReport($editor.xmpReport, warnings: catalog.viewMode != .detail || catalog.latentShown != nil)
        .alert(L10n.tr("Save Preset"), isPresented: $editor.namingPreset) {
            TextField(L10n.tr("Name"), text: $editor.presetName)
            Button(L10n.tr("Save")) {
                if editor.savePreset(named: editor.presetName, in: LookLibrary.current(editor: editor, catalog: catalog)) { catalog.notice = L10n.tr("Preset saved") }
            }
            Button(L10n.tr("Cancel"), role: .cancel) {}
        }
        .modifier(PhotosImportPicker(catalog: catalog))
        .sheet(item: $catalog.albumDraft) { draft in AlbumNameSheet(model: catalog, draft: draft) }
        .sheet(item: $catalog.exportSession) { ExportDialog(model: $0) }
        .sheet(isPresented: $catalog.showingNewCloudCatalog) { NewCloudCatalogSheet(model: catalog) }
        .sheet(isPresented: $catalog.showingCloudCatalogs) { CloudCatalogsSheet(model: catalog, editor: editor) }
        .onChange(of: catalog.syncState) { _, state in if state == .removed { Task { await catalog.closeRemovedCatalog(editor: editor) } } }
        .alert(trashTitle, isPresented: Binding(get: { catalog.pendingTrash != nil }, set: { if !$0 { catalog.pendingTrash = nil } })) {
            Button(L10n.tr("Move to Trash")) {
                if let targets = catalog.pendingTrash { Task { await catalog.moveToTrash(targets, editor: editor) } }
                catalog.pendingTrash = nil
            }.keyboardShortcut(.defaultAction)
            Button(L10n.tr("Cancel"), role: .cancel) { catalog.pendingTrash = nil }
        } message: {
            Text(catalog.isFolderIndex ? L10n.tr("The files move to the Finder’s Trash.") : L10n.tr("You can recover photos from the Trash until it is emptied. Originals are not changed."))
        }
        .alert(resetTitle, isPresented: Binding(get: { catalog.pendingReset != nil }, set: { if !$0 { catalog.pendingReset = nil } })) {
            Button(L10n.tr("Reset Edits"), role: .destructive) {
                if let targets = catalog.pendingReset { Task { await catalog.resetEdits(targets: targets, editor: editor) } }
                catalog.pendingReset = nil
            }
            Button(L10n.tr("Cancel"), role: .cancel) { catalog.pendingReset = nil }
        } message: {
            Text(L10n.tr("Every adjustment, crop and mask returns to the camera defaults. Originals are not changed."))
        }
        .sheet(item: $editor.editCopyDraft) { CopyEditsSheet(editor: editor, draft: $0, sync: { catalog.syncEdits($0, to: $1, editor: editor) }, copied: { catalog.noteCopiedEdits(.everything) }) }
        .sheet(isPresented: $editor.showExport) { ExportDialog(model: editor) }
        .task { await catalog.start(); catalog.startIndexing() }
        .onReceive(editor.$liveThumbnail) { live in
            if let live, let store = catalog.store, editor.usesCatalog(store) { catalog.showLiveThumbnail(live.image, of: live.assetID) }
        }
        .onChange(of: editor.sourceURL) { _, url in if url != nil { catalog.latentShown = nil }; if url != nil, catalog.showingLibrary, catalog.secondaryViewMode != .detail { catalog.viewMode = .detail } }
    }
    private var workspace: some View {
        VStack(spacing: 0) {
            WorkspaceHeader(catalog: catalog, editor: editor).zIndex(1)
            Rule()
            HStack(spacing: 0) {
                if catalog.sidebarVisible {
                    CatalogSidebar(model: catalog, editor: editor).frame(width: catalog.sidebarWidth)
                }
                if catalog.store != nil, !catalog.developPanelsHidden {
                    SidebarResizeHandle(width: $catalog.sidebarWidth, range: CatalogModel.sidebarWidths, enabled: catalog.sidebarVisible)
                }
                // The bar belongs to the browsing area so the sidebar and inspector keep their full height.
                VStack(spacing: 0) {
                    switch catalog.viewMode {
                    case .grid: CatalogView(model: catalog, editor: editor)
                    case .compare: CompareView(catalog: catalog, editor: editor)
                    case .detail:
                        if let latent = catalog.latentShown { LatentDetailView(catalog: catalog, editor: editor, asset: latent).id(latent.id) }
                        else {
                            EditorCanvas(model: editor).openPhotoContextMenu(catalog: catalog, editor: editor)
                                .xmpWarningBanner(editor, strip: editor.canStripXMP ? { Task { await editor.stripUnsupportedXMP(); await catalog.refresh() } } : nil)
                        }
                    }
                    if catalog.filmstripShown(editor: editor) {
                        // Above the photo, so the line it draws while dragging shows over it.
                        FilmstripResizeHandle(height: $editor.filmstripHeight).zIndex(1)
                        if editor.showCullingBar, !catalog.isFolderIndex { FilmstripCullingBar(catalog: catalog, editor: editor) }
                        PhotoFilmstrip(catalog: catalog, editor: editor, chrome: editor.menuState)
                    }
                    // Without a catalog every control in the bar is idle, unless a photo was opened from a file.
                    if catalog.store != nil || editor.hasImage, !catalog.developPanelsHidden { CatalogStatusBar(model: catalog, editor: editor) }
                }.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                if catalog.showingLibrary {
                    // The inspector keeps its place while the selection changes, so clearing it or dragging a
                    // rubber band never reflows the grid; without a selection it shows the catalog.
                    if catalog.total + catalog.trashCount + catalog.archiveCount > 0 && catalog.shownOverview != .map {
                        Rule(.vertical)
                        LibraryInspector(catalog: catalog) {
                            // A folded group counts as all its photos, so selecting it alone shows the batch tools.
                            if catalog.selectionCount > 1 {
                                CatalogBatchInspector(model: catalog, editor: editor)
                            } else if let selected = catalog.selected {
                                if selected.inLibrary { CatalogInspector(model: catalog, editor: editor, asset: selected) }
                                else { CatalogTrashInspector(model: catalog, editor: editor, asset: selected) }
                            } else if catalog.filter.area == .archive {
                                ArchiveOverviewPanel(model: catalog, editor: editor)
                            } else if catalog.isFolderIndex {
                                // The index of browsed folders is not a catalog to describe; the folder shown is.
                                if let folder = catalog.filter.folder { FolderInfoPanel(model: catalog, folder: folder).id(folder) }
                                else { ContentUnavailableView(L10n.tr("No Selection"), systemImage: ToolTab.info.icon) }
                            } else {
                                CatalogOverviewPanel(model: catalog)
                            }
                        }
                    }
                } else if !catalog.developPanelsHidden, catalog.latentShown == nil {
                    SidebarResizeHandle(width: $inspectorWidth, range: EditorInspector.widths, enabled: editor.showInspector,
                                        defaultWidth: EditorInspector.defaultWidth, panelOnRight: true)
                    EditorInspector(model: editor, catalog: catalog)
                }
            }
        }
    }
}

/// The Library inspector with its tab rail, as in Develop: Info (`content`, the selection's details) and History (the
/// selected photo's catalog history, offered only while a photo is selected). The rail stays when the inspector is
/// hidden; choosing a tab brings it back, choosing the showing one hides it. Both grid styles, tiles and wall, share it.
struct LibraryInspector<Content: View>: View {
    @ObservedObject var catalog: CatalogModel
    @ViewBuilder let content: Content
    var body: some View {
        // History is a photo's: a folder's photo keeps its edits beside it, not the steps that led to them, and with
        // nothing selected there is no photo to show it for. The tab goes then, and Info shows; the choice of History
        // is kept, so it is back with the next photo selected.
        let history = !catalog.isFolderIndex && catalog.selected != nil
        let panel = history ? catalog.libraryPanel : .info
        HStack(spacing: 0) {
            if catalog.showInspector {
                Group {
                    switch panel {
                    case .info: content
                    case .history: ScrollView { HistoryPanel(model: catalog) }
                    }
                }.frame(width: 300)
                Rectangle().fill(Theme.ink.opacity(0.08)).frame(width: 1)
            }
            VStack(spacing: 8) {
                ToolRailButton(icon: ToolTab.info.icon, title: ToolTab.info.localizedTitle, shortcut: "⌥⌘I", active: catalog.showInspector && panel == .info) {
                    // Info is what shows without a photo, whatever tab was last chosen: the button hides and shows that.
                    if history { catalog.showLibraryPanel(.info) } else { catalog.showInspector.toggle() }
                }
                if history {
                    ToolRailButton(icon: ToolTab.history.icon, title: ToolTab.history.localizedTitle, active: catalog.showInspector && panel == .history) { catalog.showLibraryPanel(.history) }
                }
                Spacer()
            }.padding(.horizontal, 6).padding(.vertical, 8)
        }.background(Theme.panel)
    }
}

/// Import sources are explicit actions; opening the menu never scans external storage. Cameras and cards are looked
/// for from the first time Camera… is chosen, not when a catalog opens: discovery is what makes macOS ask for access
/// to a connected card, and it asked at every launch of a new build. Once found, they are listed here by name.
/// Looking for cameras and cards is what makes macOS ask for access to removable volumes, so it waits for the person
/// to open a menu that lists them: the moment the menu under the pointer starts tracking, before its items show.
/// Whatever is found joins the menu; until then it offers the camera importer by its plain name.
private struct FindsCamerasWhenOpened: ViewModifier {
    let catalog: CatalogModel
    @State private var under = false
    func body(content: Content) -> some View {
        content
            .onHover { under = $0 }
            .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
                if under { catalog.cameraImporter.startDiscovery() }
            }
    }
}

extension View {
    func findsCamerasWhenOpened(_ catalog: CatalogModel) -> some View { modifier(FindsCamerasWhenOpened(catalog: catalog)) }
}

struct CardImportItems: View {
    @ObservedObject var catalog: CatalogModel
    var compact: Bool
    @ObservedObject private var devices: CameraImportModel
    init(catalog: CatalogModel, compact: Bool = false) {
        self.catalog = catalog
        self.compact = compact
        self.devices = catalog.cameraImporter
    }
    var body: some View {
        ForEach(devices.cameras, id: \.self) { device in
            Button {
                devices.requestedCamera = device
                catalog.showingCameraImport = true
            } label: {
                Label { Text(verbatim: (device.name ?? L10n.tr("Camera")) + "…") }
                      icon: { Image(systemName: "camera") }
            }
        }
        if !devices.cameras.isEmpty { Divider() }
        if devices.cameras.isEmpty {
            Button(action: catalog.requestCameraImport) {
                Label(compact ? L10n.tr("Camera…") : L10n.tr("Import from Camera…"), systemImage: "camera")
            }
        }
        Button { catalog.showingPhotosImport = true } label: {
            Label(compact ? L10n.tr("Photos…") : L10n.tr("Import from Photos…"), systemImage: "photo.on.rectangle")
        }
        Button { catalog.requestFolderImport() } label: {
            Label(compact ? L10n.tr("Folder…") : L10n.tr("Import from Folder…"), systemImage: "folder")
        }
    }
}

/// The header shared by every view: the collection, and the grid's Culling and Export or the
/// editor's undo, redo and Export. Import lives at the top of the sidebar.
struct WorkspaceHeader: View {
    @ObservedObject var catalog: CatalogModel
    @ObservedObject var editor: EditorModel
    var body: some View {
        // Two sides of equal width around the search field keep it in the middle of the title bar, as in other RAW
        // editors, however wide either side's controls grow, such as the activity indicator coming and going.
        HStack(spacing: 14) {
            // A long collection name truncates before the empty title bar beside it gets too short to drag the window.
            HStack(spacing: 14) { leading.layoutPriority(1); titlebarSpace(minWidth: 44) }.frame(maxWidth: .infinity)
            CatalogSearchBar(model: catalog).disabled(catalog.store == nil)
            // A narrow window drops the button titles first, then the activity's title, before the empty title bar
            // beside them gets too short to drag the window.
            ViewThatFits(in: .horizontal) {
                trailingSide(.full)
                trailingSide(.iconsOnly)
                trailingSide(.minimal)
            }.frame(maxWidth: .infinity)
        }.padding(.horizontal, 16).frame(height: WindowTrafficLights.headerHeight).background(Theme.toolbar).background(WindowTrafficLights())
    }
    /// Empty title bar, which still drags the window. `room` is the width it asks for when the controls beside it pick how much to show.
    private func titlebarSpace(minWidth: CGFloat = 0, room: CGFloat? = nil) -> some View {
        Color.clear.frame(minWidth: minWidth, idealWidth: room, maxWidth: .infinity, maxHeight: .infinity).background(WindowTitlebarArea())
    }
    private func trailingSide(_ density: Density) -> some View {
        HStack(spacing: 14) { titlebarSpace(room: 64); HStack(spacing: 14) { trailing(density) }.layoutPriority(1) }
    }
    private var leading: some View {
        HStack(spacing: 8) {
            // Next to the panel it shows and hides, rather than at the far end of the status bar.
            PanelToggle(icon: "sidebar.left", title: L10n.tr("Sidebar"), shortcut: "⌃⌘S", isOn: $catalog.showSidebar).font(.system(size: 14))
                .disabled(catalog.store == nil)
            Text(catalog.collectionTitle).font(.headline).lineLimit(1).truncationMode(.tail).help(catalog.collectionTitle).layoutPriority(-1)
            SyncStatusIndicator(model: catalog)
            UnpaidBadge()
        }.padding(.leading, WindowTrafficLights.leadingReservation)
    }
    private enum Density { case full, iconsOnly, minimal }
    @ViewBuilder private func trailing(_ density: Density) -> some View {
        let iconsOnly = density != .full
        // The open photo's progress first, then every background activity, visible even with the status bar hidden.
        if !catalog.showingLibrary { EditorProgress(model: editor) }
        ActivityIndicator(center: catalog.activity, compact: density == .minimal)
        // Housekeeping works on flags, pairs and the catalog's own Trash: nothing of it applies to a browsed folder.
        if catalog.showingLibrary, !catalog.isFolderIndex {
            Menu {
                Button(L10n.tr("Pick from Bursts…")) { Task { await catalog.requestCullingAssistant(catalog.selectedAssets) } }
                Button(L10n.tr("Find Flawed Photos…")) { Task { await catalog.requestProblemPhotos(catalog.selectedAssets) } }
                Button(L10n.tr("Check Faces…")) { Task { await catalog.requestFaceCheck(catalog.selectedAssets) } }
                Divider()
                // Pairs are tidied into the catalog's archive and grouped in the catalog: neither exists for a folder.
                if !catalog.isFolderIndex {
                    Button(L10n.tr("Tidy RAW + JPEG Pairs…")) { Task { await catalog.requestTidyPairs(catalog.selectedAssets) } }
                    Button(L10n.tr("Group RAW + JPEG Pairs")) { Task { await catalog.groupRawJPEGPairs(catalog.selectedAssets) } }
                    Button(L10n.tr("Ungroup RAW + JPEG Pairs")) { Task { await catalog.ungroupRawJPEGPairs(catalog.selectedAssets) } }
                    Divider()
                }
                Button(L10n.tr("Move Rejected Photos to Trash…")) { Task { await catalog.requestTrashRejected(catalog.selectedAssets) } }
                // A folder has no missing photos: a file that is gone is simply not listed.
                if !catalog.isFolderIndex { Button(L10n.tr("Move Missing Photos to Trash…")) { Task { await catalog.requestTrashMissing(catalog.selectedAssets) } } }
            } label: {
                // Laid out like Export beside it: icon, title, then the small chevron of its preset menu.
                Label {
                    (iconsOnly ? Text("") : Text(L10n.tr("Culling")) + Text("  ")) + Text(Image(systemName: "chevron.down")).font(.system(size: 9, weight: .bold))
                } icon: { Image(systemName: "checkmark.rectangle.stack") }
                .accessibilityLabel(L10n.tr("Culling"))
            }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().focusable(false)
                .help(L10n.tr("Pick from bursts, find flawed photos, tidy or group RAW + JPEG pairs, or clear out rejected and missing photos")).accessibilityLabel(L10n.tr("Culling"))
                .disabled(!catalog.canCull(catalog.selectedAssets))
            HStack(spacing: 14) {
                Button(action: catalog.undo) { Image(systemName: "arrow.uturn.backward") }.disabled(!catalog.canUndo).help(L10n.tr("Undo (⌘Z)")).accessibilityLabel(L10n.tr("Undo"))
                Button(action: catalog.redo) { Image(systemName: "arrow.uturn.forward") }.disabled(!catalog.canRedo).help(L10n.tr("Redo (⇧⌘Z)")).accessibilityLabel(L10n.tr("Redo"))
            }.buttonStyle(.plain)
            ExportSplitButton(compact: iconsOnly, disabled: catalog.selectedIDs.isEmpty || catalog.filter.area != .library || !catalog.canStartJob,
                              export: { catalog.requestExport(catalog.selectedAssets) }) {
                ExportMenuItems(export: { catalog.export(catalog.selectedAssets, preset: $0) }, share: { catalog.share(catalog.selectedAssets) },
                                editIn: { catalog.editIn(catalog.selectedAssets, app: $0, editor: editor) }) {
                    Button(L10n.tr("Export Originals with XMP…")) { catalog.exportOriginals(catalog.selectedAssets) }
                }
            }
        } else {
            EditorHeaderControls(model: editor, compact: iconsOnly) { catalog.editInOpenPhoto(app: $0, editor: editor) }
        }
    }
}

/// A thin divider that widens the sidebar on its left when dragged.
struct SidebarResizeHandle: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    var enabled = true
    /// What a double-click restores.
    var defaultWidth = CatalogModel.defaultSidebarWidth
    /// For a panel on the handle's right, which widens as the handle moves left.
    var panelOnRight = false
    @State private var start: Double?
    @State private var hovering = false
    var body: some View {
        // A real 5-point strip, so the grab area is not hidden under the AppKit-backed views beside it.
        Rectangle().fill(Theme.ink.opacity(enabled && (hovering || start != nil) ? 0.2 : 0.08)).frame(width: 1)
            .frame(width: enabled ? 5 : 1).background(Theme.panel).contentShape(Rectangle())
            .onHover { if enabled { setHovering($0) } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global).onChanged { value in
                guard enabled else { return }
                let origin = start ?? width
                start = origin
                width = min(range.upperBound, max(range.lowerBound, origin + (panelOnRight ? -1 : 1) * value.translation.width))
            }.onEnded { _ in start = nil })
            .onTapGesture(count: 2) { if enabled { width = defaultWidth } }
            .help(enabled ? L10n.tr("Drag to resize - double-click to reset") : "")
            .onDisappear { setHovering(false) }
            .accessibilityHidden(true)
    }
    /// Balances the cursor stack, including when the panel collapses under the pointer.
    private func setHovering(_ inside: Bool) {
        guard inside != hovering else { return }
        hovering = inside
        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
    }
}
