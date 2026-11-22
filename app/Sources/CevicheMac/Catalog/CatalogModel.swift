import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import CevicheCore

@MainActor
final class CatalogModel: ObservableObject {
    @Published var assets: [CatalogAsset] = [] { didSet { assetPositions = nil; layoutRevision &+= 1 } }
    /// Changes with the photos or their shapes: the grid's rows are laid out again only then (`LibraryGrid`).
    private(set) var layoutRevision = 0
    /// Where each photo sits in `assets` and `browsingAssets`, built when first asked for after a change, so the
    /// selection is found without scanning the library (the menu bar asks on every change).
    private var assetPositions: [String: Int]?
    private var browsingPositions: [String: Int]?
    private static func positions(_ list: [CatalogAsset]) -> [String: Int] {
        Dictionary(list.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
    /// The photos of `ids` in `assets`, in the grid's order.
    func assets(withIDs ids: Set<String>) -> [CatalogAsset] {
        if assetPositions == nil { assetPositions = Self.positions(assets) }
        return ids.compactMap { assetPositions?[$0] }.sorted().map { assets[$0] }
    }
    /// Where the photo `id` sits in `browsingAssets`.
    func browsingPosition(_ id: String) -> Int? {
        if browsingPositions == nil { browsingPositions = Self.positions(browsingAssets) }
        return browsingPositions?[id]
    }
    /// The photos of `ids` in `browsingAssets`, in the filmstrip's order.
    func browsingAssets(withIDs ids: Set<String>) -> [CatalogAsset] {
        if browsingPositions == nil { browsingPositions = Self.positions(browsingAssets) }
        return ids.compactMap { browsingPositions?[$0] }.sorted().map { browsingAssets[$0] }
    }
    /// The folder `assets` were last read for: until it is the shown one, an empty grid is still loading, not empty.
    @Published var refreshedFolder: String?
    @Published var pendingOutputs: [PendingOutput] = []
    @Published var dates: [CaptureDateNode] = []
    @Published var albums: [CatalogAlbumSummary] = []
    @Published var importDays: [ImportDayNode] = []
    @Published var recentEditsCount = 0
    @Published var albumDraft: AlbumDraft?
    @Published var kinds: [String] = []
    @Published var total = 0
    /// The first count of the open catalog has arrived; until then an empty `total` says nothing.
    @Published var totalLoaded = false
    /// Photos matching the current collection and filters, including ones not loaded yet.
    @Published var matchingCount = 0
    var hasMore: Bool { !filter.geotagged && assets.count < matchingCount }
    @Published var trashCount = 0
    @Published var archiveCount = 0
    @Published var mutatingCatalog = false
    @Published var pendingDeletion: CatalogDeletionBatch?
    var deletionStore: CatalogStore?
    /// The confirmation's checkbox, shown only when the list has referenced originals: also delete those files.
    /// Unticked for each confirmation.
    @Published var deleteReferencedFiles = false
    /// The editor whose open photo may be among the files deleted, saved and closed before they go.
    weak var deletionEditor: EditorModel?
    /// The confirmation is being prepared. Not published: flipping a published flag redraws the whole window, and
    /// the confirmation would wait behind that redraw.
    var preparingDeletion = false
    @Published var automationBusy = false
    /// Blocks browsing and culling. An import runs in the background and does not.
    var interactionBusy: Bool { automationBusy || handlingXMP || mutatingCatalog || navigating || preparingDeletion || pendingDeletion != nil }
    /// Holds back changes to photos: something the person started is under way, or catalog maintenance. An import only
    /// adds photos and does not: trashing, editing, grouping or filing other photos meanwhile is fine.
    var catalogBusy: Bool { interactionBusy || maintenance != nil }
    /// Holds back catalog-wide work, which would cut a running import short or miss its photos: opening, closing or
    /// creating a catalog, and backups.
    var catalogWideBusy: Bool { catalogBusy || importing }
    /// Imports and exports run as background jobs beside each other; only catalog-wide work holds them back.
    var canStartJob: Bool { !interactionBusy && maintenance == nil }
    /// Imports need somewhere to go: the catalog, or the folder shown. The index of browsed folders is neither.
    var canImport: Bool { canStartJob && (!isFolderIndex || filter.folder != nil) }
    /// A photo tool fills the window (a merge, stack, night sky, timelapse, deflicker, noise reduction or negative):
    /// the others wait until it closes.
    var toolOpen: Bool {
        panoramaMerge != nil || hdrMerge != nil || photoStack != nil || nightSky != nil || focusStack != nil || pixelShift != nil || bestFaces != nil || matchSeries != nil || chartProfile != nil || filters != nil
            || timelapse != nil || exposureRamp != nil || denoise != nil || negative != nil || wideAngle != nil
    }
    let activity = ActivityCenter.shared
    /// What the menu bar observes in place of the whole model.
    lazy var menuState = CatalogMenuState(catalog: self)
    var importing: Bool { activity.contains(.importing) }
    private var jobsObservation: AnyCancellable?
    private var languageObservation: AnyCancellable?
    private var cameraObservation: AnyCancellable?
    /// A long catalog task such as a backup or verifying a relinked original. It holds back other catalog work and
    /// shows in the activity center.
    @Published var maintenance: String? { didSet { mirrorMaintenance() } }
    /// 0…1 while `maintenance` is work that reports how far along it is, such as downloading an original.
    @Published var maintenanceProgress: Double? { didSet { mirrorMaintenance() } }
    /// Where the current maintenance reads from, shown as its step.
    @Published var maintenanceDetail: String? { didSet { mirrorMaintenance() } }
    /// Set with `maintenance` when the work is a download, so the activity center shows it as one.
    var maintenanceKind = Activity.Kind.catalog
    private var maintenanceActivity: UUID?
    private func mirrorMaintenance() {
        guard let maintenance else {
            if let id = maintenanceActivity {
                // Brief catalog chores come and go without cluttering Recent.
                let lasted = activity.running.first { $0.id == id }.map { Date().timeIntervalSince($0.started) } ?? 0
                activity.end(id, keep: lasted > 2)
                maintenanceActivity = nil
            }
            maintenanceKind = .catalog
            return
        }
        if maintenanceActivity == nil {
            maintenanceActivity = activity.begin(maintenanceKind, title: maintenance, stop: nil)
        }
        if let id = maintenanceActivity {
            activity.update(id, progress: maintenanceProgress, detail: maintenanceDetail ?? "", title: maintenance)
        }
    }
    @Published var exportSession: CatalogExportSession?
    @Published var selected: CatalogAsset?
    @Published var selectedIDs: Set<String> = []
    var selectionAnchorID: String?
    /// The selected photos the actions apply to: a folded group's cover brings every photo in the group.
    var selectedAssets: [CatalogAsset] { withGroups(selectedCells) }
    /// The selected cells as the grid shows them, a folded group as its cover alone: what opens, and what Compare pairs.
    var selectedCells: [CatalogAsset] { assets(withIDs: selectedIDs) }
    /// The one cell selected in the grid, a folded group's cover included: what Expand Group opens.
    var selectedCell: CatalogAsset? { selectedIDs.count == 1 ? selectedCells.first : nil }
    /// How many photos `selectedAssets` holds, counting every photo of a folded group.
    var selectionCount: Int { selectedIDs.reduce(0) { $0 + (foldedMembers(of: $1)?.count ?? 1) } }
    func contextAssets(for asset: CatalogAsset) -> [CatalogAsset] {
        selectedIDs.contains(asset.id) ? selectedAssets : withGroups([asset])
    }
    @Published var history: [CatalogRevision] = []
    @Published var snapshots: [CatalogSnapshot] = []
    @Published var undoSteps: [CatalogUndoStep] = []
    @Published var redoSteps: [CatalogUndoStep] = []
    @Published var filter = CatalogFilter() { didSet { cancelLibraryKeyboardNavigation(); scheduleRefresh(throttled: filter.changesContinuously(from: oldValue)); if filter.folder != oldValue.folder || filter.subfolders != oldValue.subfolders { folderChanged() } } }
    @Published var metadata = CatalogMetadata() { didSet { if !loadingSelection { scheduleMetadata() } } }
    @Published var metadataPending = false
    var captureDayValid: Bool {
        var probe = CatalogMetadata(); probe.captureDay = metadata.captureDay
        return (try? probe.validated()) != nil
    }
    /// Minimum grid cell width, or the wall's row height, chosen with the thumbnail size slider.
    @Published var tileSize: Double { didSet { preferences.set(tileSize, forKey: "libraryTileSize") } }
    static let tileSizes: ClosedRange<Double> = 120...320
    /// The grid's two presentations, as in other RAW editors: tiles with names, flags and ratings for culling,
    /// or a wall of photos edge to edge with nothing else, for looking.
    enum GridStyle: String, CaseIterable, Identifiable {
        case tiles, wall
        var id: String { rawValue }
        var title: String { self == .tiles ? L10n.tr("Grid") : L10n.tr("Wall") }
        var icon: String { self == .tiles ? "square.grid.2x2" : "rectangle.grid.3x2" }
    }
    /// Sorted by capture date, the grid, the wall and Faces start each day under its date.
    @Published var groupsByDate = true { didSet { preferences.set(groupsByDate, forKey: "libraryGroupsByDate") } }
    /// The month the status bar's date button asked the library to scroll to.
    @Published var dateJump: DateJumpRequest?
    @Published var gridStyle: GridStyle { didSet { preferences.set(gridStyle.rawValue, forKey: "libraryGridStyle") } }
    /// The wall's rows as ranges of `assets`, for arrow keys; `nil` in the tile grid, which moves by columns.
    var libraryRows: [Range<Int>]?
    /// Up and down keep the column in `libraryRows` (the grid's days) rather than the place along the row (the wall).
    var libraryRowsKeepColumns = false
    /// The top of a collection that has one, above its photos: Map's pins, People's cards, or without the People model
    /// a wall of every face, still called People. Its photos (a pin's, a person's, or all of them) show in the wall and the grid like any other
    /// collection's; ⌘↑ goes back up.
    enum Overview {
        case map, people, faces
        var title: String { switch self { case .map: L10n.tr("Map"); case .people, .faces: L10n.tr("People") } }
        var icon: String { switch self { case .map: "map"; case .people, .faces: "person.2" } }
    }
    /// The overview of the collection the sidebar shows, whether or not it is on screen.
    var collectionOverview: Overview? {
        guard filter.area == .library else { return nil }
        if filter.geotagged { return .map }
        if filter.withFaces { return peopleStatus.available ? .people : .faces }
        return nil
    }
    /// The overview on screen in the main window's library, if any.
    var shownOverview: Overview? { showingLibrary && showingOverview && !drilledIn ? collectionOverview : nil }
    /// Inside one pin of the Map or one person.
    var drilledIn: Bool { filter.mapArea != nil || filter.personID != nil }
    /// A person's faces rather than their photos.
    var showingPersonFaces: Bool { showingLibrary && filter.personID != nil && personShowsFaces }
    /// The library shows photos as the wall or the grid (`gridStyle`), not an overview or a person's faces.
    var showingPhotos: Bool { showingLibrary && shownOverview == nil && !showingPersonFaces }
    /// Photos or faces by day, for the date button: not the Map or the People cards.
    var showsDates: Bool {
        guard showingLibrary else { return false }
        switch shownOverview { case .map: return false; case .people: return peopleSubpage == .allFaces; default: return true }
    }
    /// ⌘1 and ⌘2: the photos of the collection, or of the pin or person open in it, as the wall or the grid.
    func showPhotos(_ style: GridStyle, editor: EditorModel) {
        gridStyle = style; showingOverview = false; personShowsFaces = false; peopleSubpage = nil
        show(.grid, editor: editor)
    }
    /// ⌘↑: the collection's overview, from its photos, a pin, a person, or a photo opened from one.
    func showOverview(editor: EditorModel) {
        guard collectionOverview != nil else { return }
        showingOverview = true; peopleSubpage = nil
        if !showingLibrary { show(.grid, editor: editor) }
        if drilledIn { Task { await goUp() } }
    }
    /// Back from a pin or a person to the overview, in the library.
    func goUp() async {
        showingOverview = true; peopleSubpage = nil
        guard drilledIn else { return }
        var value = filter; value.personID = nil; value.mapArea = nil
        await applyFilterNow(value)
    }
    /// One person's faces or photos (`personShowsFaces`).
    func openPerson(_ id: String) async {
        var value = filter; value.personID = id; value.mapArea = nil
        showingOverview = false; peopleSubpage = nil
        await applyFilterNow(value)
    }
    /// The photos of a pin on the Map, as the wall or the grid.
    func openPlace(_ photos: [CatalogAsset]) async {
        guard let area = CatalogMapArea(around: photos.compactMap { a in a.latitude.flatMap { lat in a.longitude.map { (lat, $0) } } }) else { return }
        var value = filter; value.mapArea = area; value.personID = nil
        showingOverview = false
        await applyFilterNow(value)
    }
    /// G: the grid, or from the grid its other presentation, in whichever window the key was pressed; from an overview,
    /// its photos.
    func pressGrid(secondary: Bool = false, editor: EditorModel) {
        if secondary {
            if secondaryViewMode == .grid { gridStyle = gridStyle == .tiles ? .wall : .tiles } else { showSecondary(.grid, editor: editor) }
        } else if showingPhotos {
            gridStyle = gridStyle == .tiles ? .wall : .tiles
        } else if showingLibrary {
            showPhotos(gridStyle, editor: editor)
        } else {
            show(.grid, editor: editor)
        }
    }
    private var aspectCache: [String: Double] = [:]
    /// Width over height of the finished photo, with its crop and rotation, for the wall's rows.
    func aspect(of asset: CatalogAsset) -> Double {
        let key = asset.id + "/" + asset.renderKey
        if let cached = aspectCache[key] { return cached }
        var aspect = 1.5
        // The original's shape until the thumbnail, which shows the crop and rotation, settles it (`noteThumbnail`).
        let info = asset.info; if info.width > 0, info.height > 0 { aspect = Double(info.width) / Double(info.height) }
        // Above a whole loaded library: a smaller limit emptied the cache partway through every wall layout, which then
        // decoded every photo's info again.
        if aspectCache.count > 100_000 { aspectCache = [:] }
        aspectCache[key] = aspect
        return aspect
    }
    /// The thumbnail is the finished photo, so its pixels settle the aspect: photos imported before the
    /// importer turned sideways frames upright, and crops made in another app, reflow the wall when they load.
    /// Thumbnails arriving together reflow it once: each reflow lays out the whole loaded library.
    func noteThumbnail(of asset: CatalogAsset, size: CGSize) {
        guard size.width > 0, size.height > 0, gridStyle == .wall else { return }
        let key = asset.id + "/" + asset.renderKey, aspect = size.width / size.height
        if let known = aspectCache[key], abs(known - aspect) < 0.01 { return }
        aspectCache[key] = aspect
        guard !aspectReflowPending else { return }
        aspectReflowPending = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self else { return }
            aspectReflowPending = false
            objectWillChange.send(); layoutRevision &+= 1
        }
    }
    private var aspectReflowPending = false
    var countLabel: String {
        let collection: Int
        if let id = filter.albumID { collection = albums.first { $0.id == id }?.count ?? 0 }
        else if filter.folder != nil { collection = max(folderCount, matchingCount) }
        else if isFolderIndex { collection = 0 }
        else if filter.recentEdits { collection = recentEditsCount }
        else if let day = filter.importDay, let node = importDays.first(where: { $0.id == day }) {
            collection = filter.importBatchID.flatMap { id in node.batches.first { $0.batchID == id }?.count } ?? node.count
        } else { collection = filter.area == .trash ? trashCount : filter.area == .archive ? archiveCount : total }
        if filter.isRefined || filter.geotagged || filter.withFaces {
            return (collection == 1 ? L10n.tr("\(matchingCount.formatted()) of \(collection.formatted()) photo") : L10n.tr("\(matchingCount.formatted()) of \(collection.formatted()) photos"))
        }
        return (matchingCount == 1 ? L10n.tr("\(matchingCount.formatted()) photo") : L10n.tr("\(matchingCount.formatted()) photos"))
    }
    @Published var showInspector: Bool { didSet { preferences.set(showInspector, forKey: "showLibraryInspector") } }
    @Published var snapshotNameRequested = false
    /// The Library inspector's tabs: the selected photo's details, or its catalog history.
    enum LibraryPanel: String, CaseIterable { case info, history }
    @Published var libraryPanel: LibraryPanel { didSet { preferences.set(libraryPanel.rawValue, forKey: "libraryInspectorPanel") } }
    /// Shows `panel`; choosing the one already showing hides the inspector, as the tool rail does in Develop.
    func showLibraryPanel(_ panel: LibraryPanel) {
        if showInspector && libraryPanel == panel { showInspector = false; return }
        libraryPanel = panel; showInspector = true
    }
    @Published var showSidebar: Bool { didSet { preferences.set(showSidebar, forKey: "showLibrarySidebar") } }
    /// The sidebar lists the open catalog, so the welcome screen has none; the preference comes back with a catalog.
    var sidebarVisible: Bool { showSidebar && store != nil && !developPanelsHidden }
    /// Tab in Detail hides every panel around the photo and brings them back; each panel keeps its own setting.
    @Published var panelsHidden = false
    var developPanelsHidden: Bool { panelsHidden && !showingLibrary && viewMode == .detail }
    /// The sidebar's width, dragged at its edge; shared by every view.
    @Published var sidebarWidth: Double { didSet { preferences.set(sidebarWidth, forKey: "librarySidebarWidth") } }
    static let sidebarWidths: ClosedRange<Double> = 170...360
    static let defaultSidebarWidth = 210.0
    /// ⌘+ / ⌘− step the thumbnail size slider.
    func stepTileSize(larger: Bool) {
        tileSize = min(Self.tileSizes.upperBound, max(Self.tileSizes.lowerBound, tileSize + (larger ? 40 : -40)))
    }
    /// Work in progress, in the status bar.
    @Published var status = ""
    /// A short confirmation of finished work, shown as a toast that goes away by itself.
    @Published var notice: String?
    /// Photos waiting for confirmation before they move to Trash (`requestMoveToTrash`).
    @Published var pendingTrash: [CatalogAsset]?
    /// Photos waiting for the reset confirmation, from the Photo menu or a photo's context menu.
    @Published var pendingReset: [CatalogAsset]?
    /// "Recovered" for one photo, "3 photos recovered" for several.
    enum PhotoOutcome { case exported, exportedWithXMP, movedToTrash, recovered, removed, deleted, archived, unarchived, moved }
    static func counted(_ count: Int, _ outcome: PhotoOutcome) -> String {
        switch outcome {
        case .exported: return count == 1 ? L10n.tr("Exported") : L10n.tr("\(count) photos exported")
        case .exportedWithXMP: return count == 1 ? L10n.tr("Exported with XMP") : L10n.tr("\(count) photos exported with XMP")
        case .movedToTrash: return count == 1 ? L10n.tr("Moved to Trash") : L10n.tr("\(count) photos moved to Trash")
        case .recovered: return count == 1 ? L10n.tr("Recovered") : L10n.tr("\(count) photos recovered")
        case .removed: return count == 1 ? L10n.tr("Removed from the library") : L10n.tr("\(count) photos removed from the library")
        case .deleted: return count == 1 ? L10n.tr("Deleted") : L10n.tr("\(count) originals deleted")
        case .archived: return count == 1 ? L10n.tr("Archived", context: "one photo was just archived, as a short notice") : L10n.tr("\(count) photos archived")
        case .unarchived: return count == 1 ? L10n.tr("Back in the library") : L10n.tr("\(count) photos back in the library")
        case .moved: return count == 1 ? L10n.tr("Original moved") : L10n.tr("\(count) originals moved")
        }
    }
    @Published var error: String? {
        // A write to a catalog shown read-only fails in SQLite; say why instead.
        didSet { if isReadOnly, let error, error.contains("readonly database") { self.error = L10n.tr("This catalog is open read-only.") } }
    }
    /// A failure the person must see, such as an export that wrote nothing: an alert (`failureAlerts`), where `error`
    /// is a toast.
    @Published var failure: Failure?
    /// A catalog that didn't open as usual, waiting for the person: shown read-only, or left closed.
    struct OpenFailure: Equatable { let root: URL; let folderIndex: Bool; let reason: CatalogOpenError }
    @Published var catalogOpenFailure: OpenFailure?
    /// Background analysis as it goes, published apart from the catalog: it changes with every photo analysed, and
    /// each change of the catalog itself rebuilds the menus, closing an open submenu.
    let analysis = AnalysisProgress()
    var indexing: CatalogAnalysisStatus {
        get { analysis.status }
        set { if analysis.status != newValue { analysis.status = newValue } }
    }
    var indexingMessage: String {
        get { analysis.message }
        set { if analysis.message != newValue { analysis.message = newValue } }
    }
    func updateIndexing(_ status: CatalogAnalysisStatus, message: String? = nil) {
        indexing = status
        if let message { indexingMessage = message }
    }
    /// New suggested tags only affect the grid when a search can match them; otherwise only the inspector updates.
    func indexingCompletedPhotos() async {
        peopleGrouper.workAvailable()
        if filter.followsAnalysis { await refresh(); return }
        guard let selected, let store else { return }
        do {
            let current = try await store.asset(selected.id)
            guard self.selected?.id == current.id, current.suggestedTags != selected.suggestedTags else { return }
            self.selected = current
        } catch { self.error = error.localizedDescription }
    }
    @Published var selectedIndexError: String?
    let indexer = CatalogIndexer()
    let placeNamer = CatalogPlaceNamer()
    let peopleGrouper = CatalogPeopleGrouper()
    func startIndexing() { indexer.start(catalog: self); placeNamer.start(catalog: self); peopleGrouper.start(catalog: self) }
    func stopIndexing() { indexer.stop(); placeNamer.stop(); peopleGrouper.stop() }
    /// Where People stands: the model, faces still to embed, and a count that moves whenever grouping changed.
    struct PeopleStatus: Equatable {
        var available = FaceEmbedding.isAvailable
        var waiting = 0
        var generation = 0
    }
    @Published var peopleStatus = PeopleStatus()
    /// People changed by hand: the wall reloads.
    func peopleEdited() { peopleStatus.generation += 1 }
    /// Place names only change what a search finds, and the inspector.
    func placesChanged(in store: CatalogStore) async {
        guard self.store === store else { return }
        if !filter.search.isEmpty { await refresh(); return }
        guard let selected else { return }
        do {
            let current = try await store.asset(selected.id)
            guard self.selected?.id == current.id, current.placeCity != selected.placeCity || current.placeCountry != selected.placeCountry else { return }
            self.selected = current
        } catch { self.error = error.localizedDescription }
    }
    func retryIndexing() {
        Task {
            guard let store else { return }
            do { try await store.retryFailedAnalysis(); indexer.workAvailable(); indexing = try await store.analysisStatus() }
            catch { self.error = error.localizedDescription }
        }
    }
    @Published var handlingXMP = false
    @Published var xmpReport: String?
    /// Grid, Compare and Detail share one window, as in other RAW editors; the sidebar and status bar stay put.
    enum ViewMode: String, CaseIterable, Identifiable {
        case grid, compare, detail
        var id: String { rawValue }
        var title: String { switch self { case .grid: return L10n.tr("Grid"); case .compare: return L10n.tr("Compare"); case .detail: return L10n.tr("Detail") } }
        var icon: String { switch self { case .grid: return "square.grid.2x2"; case .compare: return "rectangle.split.2x1"; case .detail: return "rectangle" } }
    }
    @Published var viewMode: ViewMode = .grid {
        // The grid is in one window at a time: when the main window takes it, the other shows the photo.
        // Both may show the photo, the main window with its tools and the other one alone on its display.
        didSet { if viewMode == .grid, secondaryViewMode == .grid { secondaryViewMode = .detail } }
    }
    /// The grid; the other modes show the open photo.
    var showingLibrary: Bool {
        get { viewMode == .grid }
        set { if newValue { viewMode = .grid } else if viewMode == .grid { viewMode = .detail } }
    }
    /// A second window, usually on another display, shows the grid or Detail; `nil` while it is closed.
    /// Detail there beside Detail or Compare in the main window is the photo alone, as a master preview.
    /// Compare stays in the main window.
    static let secondaryViewModes: [ViewMode] = [.grid, .detail]
    @Published var secondaryViewMode: ViewMode?
    @Published private(set) var displayCount = NSScreen.screens.count
    var hasSecondaryDisplay: Bool { displayCount > 1 }
    func updateDisplayCount(_ count: Int) {
        displayCount = count
        guard !hasSecondaryDisplay, let secondaryViewMode else { return }
        // Keep the open photo visible when its display goes away.
        if secondaryViewMode == .detail { viewMode = .detail }
        self.secondaryViewMode = nil
        SecondaryWindowView.current?.close()
    }
    /// The view the secondary window shows, or would show when opened: the one the main window is not showing.
    var secondaryViewChoice: ViewMode { secondaryViewMode ?? Self.secondaryAlternative(to: viewMode) }
    private static func secondaryAlternative(to mode: ViewMode) -> ViewMode { mode == .grid ? .detail : .grid }
    /// The grid is on screen in one of the windows.
    var gridVisible: Bool { showingLibrary || secondaryViewMode == .grid }
    /// The secondary window shows the open photo alone while the main window shows it with its tools.
    var secondaryMirrorsPhoto: Bool { secondaryViewMode == .detail && viewMode != .grid }
    /// Whether the secondary window can take `mode` now: Detail freely, the grid freely when the main window
    /// shows something else, otherwise only if the main window can switch to Detail.
    func canShowSecondary(_ mode: ViewMode, editor: EditorModel) -> Bool {
        guard Self.secondaryViewModes.contains(mode) else { return false }
        return mode == .detail || viewMode != .grid || canShow(.detail, editor: editor)
    }
    /// Puts `mode` in the secondary window. The grid leaves the main window when it shows it, for Detail,
    /// which may need to open the selected photo; `false` when it cannot, and nothing changes.
    @discardableResult
    func showSecondary(_ mode: ViewMode, editor: EditorModel) -> Bool {
        guard Self.secondaryViewModes.contains(mode) else { return false }
        guard mode == .grid, viewMode == .grid else { secondaryViewMode = mode; return true }
        guard canShow(.detail, editor: editor) else { return false }
        secondaryViewMode = mode
        show(.detail, editor: editor)
        return true
    }
    /// The secondary window closed. A photo it was showing while the main window stayed in the grid closes too.
    func closeSecondaryWindow(editor: EditorModel) {
        guard secondaryViewMode != nil else { return }
        secondaryViewMode = nil
        if showingLibrary, editor.hasImage { Task { await closePhoto(editor: editor) } }
    }
    /// While both windows are open the grid's selection is the photo the other window shows, as in other
    /// RAW editors: a click in the grid opens the photo there, keeping a multiple selection.
    func followSelection(editor: EditorModel) async {
        guard secondaryViewMode != nil, let selected, selected.inLibrary, selected.id != shownAssetID(editor: editor) else { return }
        await openPhoto(selected, editor: editor, keepSequence: browsingAssets.contains { $0.id == selected.id }, preservingSelection: true)
    }
    /// Compare shows the open photo beside its original, or beside another photo chosen with ⌘-click in the filmstrip.
    enum CompareSource: String, CaseIterable, Identifiable {
        case beforeAfter, twoPhotos
        var id: String { rawValue }
        var title: String { self == .beforeAfter ? L10n.tr("Before and After") : L10n.tr("Two Photos") }
    }
    enum CompareOrientation: String, CaseIterable, Identifiable {
        case columns, rows
        var id: String { rawValue }
        var title: String { self == .columns ? L10n.tr("Side by Side") : L10n.tr("Top and Bottom") }
        var icon: String { self == .columns ? "rectangle.split.2x1" : "rectangle.split.1x2" }
    }
    @Published var compareSource: CompareSource { didSet { preferences.set(compareSource.rawValue, forKey: "compareSource") } }
    @Published var compareOrientation: CompareOrientation { didSet { preferences.set(compareOrientation.rawValue, forKey: "compareOrientation") } }
    /// Swap exchanges the two panes.
    @Published var compareSwapped = false
    /// The second photo of a two-photo comparison; the open photo is always the first.
    @Published var compareAsset: CatalogAsset?
    /// The second photo rendered with its saved development.
    @Published var comparePreview: CGImage?
    @Published var compareRendering = false
    var compareRenderTask: Task<Void, Never>?
    var compareRenderKey: String?
    /// Map and Faces show their overview (`collectionOverview`) rather than their photos.
    @Published var showingOverview = true
    /// A person shows their faces, to put right; off, their photos in the wall or the grid.
    @Published var personShowsFaces = true
    /// A page of faces under People that are no one person's.
    enum PeopleSubpage { case ungrouped, allFaces }
    @Published var peopleSubpage: PeopleSubpage?
    /// Where Show Nearby Photos points the Map; nil lets the Map frame all its photos.
    @Published var mapFocus: MapFocus?
    @Published var navigating = false
    /// Develop's sequence: its filmstrip, the arrow keys and Compare's partner.
    @Published var browsingAssets: [CatalogAsset] = [] { didSet { browsingPositions = nil } }
    /// The latent image Develop shows instead of a photo: its preview and a button for its tool, no editing.
    @Published var latentShown: CatalogAsset?
    /// Photos outside the Trash in each group, by its cover.
    @Published var stackSizes: [String: Int] = [:]
    /// The photos of each group folded under a cover the grid or the filmstrip shows, cover first, by cover.
    @Published var groupMembers: [String: [CatalogAsset]] = [:]
    @Published private(set) var root: URL?
    private(set) var store: CatalogStore?
    var manifest: CatalogManifest? { store?.manifest }
    /// A catalog opened read-only on request (`catalogOpenFailure`).
    var isReadOnly: Bool { store?.isReadOnly == true }
    var previews: PreviewStore? { store?.previews }
    /// Thumbnails beyond this many bytes are evicted least recently shown first; nil keeps them all.
    var thumbnailBudget: Int? {
        let megabytes = preferences.integer(forKey: "thumbnailBudgetMB")
        return megabytes > 0 ? megabytes * 1_048_576 : nil
    }
    /// A fresh installation: no catalog yet, and the welcome choices are shown instead of an empty library.
    @Published private(set) var needsSetup = false
    /// Catalogs opened on this Mac, newest first; the File menu lists them.
    @Published var knownCatalogs: [CatalogReference] = []
    /// How the quick Import panel adds photos, as chosen there last; the advanced importers ask each time.
    @Published var importMode: CatalogImporter.ImportMode { didSet { preferences.set(importMode.rawValue, forKey: "libraryImportMode") } }
    @Published var photoDropTargeted = false
    @Published var cardImport: CardImportRequest?
    /// The panorama merge, which takes the whole window like the card importer.
    @Published var panoramaMerge: PanoramaMergeRequest?
    /// The HDR merge, which takes the whole window like the panorama merge.
    @Published var hdrMerge: HDRMergeRequest?
    /// The stack (median, mean, maximum, minimum), which takes the whole window like the HDR merge.
    @Published var photoStack: PhotoStackRequest?
    @Published var pixelShift: PixelShiftRequest?
    @Published var bestFaces: BestFacesRequest?
    /// The library's feature prints for Show Similar, with how far analysis had got when read.
    var printCache: (key: Int, store: CatalogStore, index: CatalogPrintIndex)?
    /// How many photos the last duplicate search listed; nil until it has looked in this catalog.
    @Published var duplicateCount: Int?
    /// The last duplicate search, shown at once when Duplicates is chosen while a fresh one runs.
    var duplicateCache: (store: CatalogStore, groups: [[String]])?
    @Published var matchSeries: MatchSeriesRequest?
    @Published var chartProfile: ChartProfileRequest?
    @Published var filters: FiltersRequest?
    /// Counts Export commands given while Creative Filters is open: the tool opens its own Export dialog for each.
    @Published var filtersExport = 0
    @Published var filtersPrint = 0
    @Published var filtersCanPrint = false
    /// A night-sky tool (star trails, denoise, meteor shower), which takes the whole window like the HDR merge.
    @Published var nightSky: NightSkyRequest?
    /// The open night-sky tool's retouching history, for Edit › Undo and Redo.
    @Published var nightSkyHistory: NightSkyHistory?
    /// The focus stack, which takes the whole window like the HDR merge.
    @Published var focusStack: FocusStackRequest?
    /// The open focus stack's layer-brush history, for Edit › Undo and Redo.
    @Published var focusStackHistory: FocusStackHistory?
    /// The open HDR merge's layer-brush history, for Edit › Undo and Redo.
    @Published var hdrMergeHistory: BrushHistory<HDRMergeStroke>?
    @Published var photoStackHistory: BrushHistory<PhotoStackStroke>?
    /// The timelapse video dialog, a sheet over the library.
    @Published var timelapse: TimelapseRequest?
    /// The Balance Exposure dialog, a sheet over the library.
    @Published var exposureRamp: ExposureRampRequest?
    /// The Denoise dialog, a sheet over the library.
    @Published var denoise: DenoiseRequest?
    /// The Wide-Angle Faces dialog, a sheet over the library.
    @Published var wideAngle: WideAngleRequest?
    /// The Convert Negative dialog, a sheet over the library.
    @Published var negative: NegativeRequest?
    /// The ID Photo dialog, a sheet over the library.
    @Published var idPhoto: IDPhotoRequest?
    /// The open Convert Negative dialog, for Edit › Undo and Redo.
    @Published var negativeHistory: NegativeModel?
    /// The culling assistant, which takes over the window like the merges.
    @Published var cullingAssistant: CullingAssistantRequest?
    /// Find Flawed Photos, in place of the library.
    @Published var problemPhotos: CullingAssistantRequest?
    /// Check Faces, in place of the library.
    @Published var faceCheck: CullingAssistantRequest?
    /// Measures photos for the culling tools in the background, freshly imported ones included.
    lazy var cullingScanner = CullingScanner(activity: activity)
    /// How readily a photo counts as blurry, out of focus, badly exposed or blinking; set in Find Flawed Photos.
    @Published var cullingSensitivity = CullingSensitivity.balanced { didSet { preferences.set(cullingSensitivity.rawValue, forKey: "cullingSensitivity") } }
    /// What an import does with RAW + JPEG pairs.
    @Published var rawJPEGImport = RawJPEGImport.both { didSet { preferences.set(rawJPEGImport.rawValue, forKey: "rawJPEGImport") } }
    /// Imported pairs become one group under the RAW, so the library shows one tile per shot. Off unless the person
    /// turns it on.
    @Published var groupRawJPEGPairsOnImport = false { didSet { preferences.set(groupRawJPEGPairsOnImport, forKey: "groupRawJPEGPairsOnImport") } }
    /// Tidy RAW + JPEG Pairs, in place of the library.
    @Published var tidyPairs: CullingAssistantRequest?
    let cameraImporter = CameraImportModel()
    /// The sidebar's folder outline.
    let folders: FolderBrowser
    /// Which of the sidebar's lists shows: the catalog's collections, or folders on disk.
    enum SidebarTab: String { case catalog, folders }
    @Published var sidebarTab: SidebarTab { didSet { preferences.set(sidebarTab.rawValue, forKey: "sidebarTab"); if sidebarTab != oldValue { tabChanged() } } }
    /// The open catalog is the index of browsed folders, kept in the system's cache folder.
    @Published var isFolderIndex = false
    /// The person's own catalog, to return to from the Folders tab.
    var libraryRoot: URL?
    /// False while folders are browsed from the welcome screen with no catalog of the person's to go back to: the
    /// Library tab is hidden until they open or make one.
    var hasLibrary: Bool { !isFolderIndex || libraryRoot != nil || preferences.string(forKey: "catalogRoot") != nil }
    var restoringTab = true
    /// Tests keep the index in a scratch folder.
    var folderIndexOverride: URL?
    var folderEditsTask: Task<Void, Never>?
    /// The root of the outline the shown folder was chosen under, so the same folder under another root stays unmarked.
    @Published var folderRoot: String?
    /// A folder the outline scrolls to once its row is there: the folder of a photo opened from the Finder.
    @Published var folderScrollTarget: String?
    /// The shown folder being indexed: photos handled so far, of how many it has to add.
    @Published var folderSync: FolderSync?
    /// Why the shown folder has nothing to show, when it could not be read.
    @Published var folderIssue: FolderIssue?
    /// Photos the shown folder held at the last sync.
    var folderCount = 0
    var folderSyncTask: Task<Void, Never>?
    /// The shown folder changed on disk while it was being read: read it once more when that ends.
    var folderResync = false
    /// An import is copying into the shown folder; syncing it meanwhile would list the same files a second time.
    var folderImporting = false
    /// The folder whose indexing the person stopped; it stays stopped until they choose it again.
    @Published var folderStopped: String?
    /// Folders show the photos of the folders below them as well.
    @Published var folderSubfolders: Bool { didSet { preferences.set(folderSubfolders, forKey: "folderSubfolders") } }
    var folderSyncGeneration = 0
    var folderRefreshedAt = Date.distantPast
    /// Files that could not be read as photos, by folder, with the file's modification date at the time.
    var folderFailures: [String: [String: Date]] = [:]
    @Published var showingCameraImport = false
    @Published var showingPhotosImport = false
    @Published var showingNewCloudCatalog = false
    @Published var showingCloudCatalogs = false
    /// Every iCloud catalog this Apple ID has, by name, once `lookForCloudCatalogs` has run.
    @Published var cloudCatalogs: [CloudCatalogListing] = []
    /// Nil until the first look; false when this build cannot reach iCloud.
    @Published var cloudCatalogsReachable: Bool?
    @Published var lookingForCloudCatalogs = false
    var cloudDirectory: CloudCatalogDirectory?
    var cloudDirectoryTask: Task<Void, Never>?
    /// The original `resolveOriginal` is fetching, so its late progress updates can tell it already finished.
    var activeFetch: UUID?
    /// The catalog at a glance: the Library's Info panel with nothing selected. From Develop the photo is put away
    /// first, and a selection is cleared, since the panel shows the catalog only when no photo is picked.
    func showCatalogOverview(editor: EditorModel) {
        Task {
            if !showingLibrary { await closePhoto(editor: editor) }
            guard showingLibrary, await flushMetadata() else { return }
            clearSelection()
            libraryPanel = .info; showInspector = true
        }
    }
    /// Photos on the current page whose originals are not on disk right now, by photo ID.
    @Published var availability: [String: AssetAvailability] = [:]
    @Published var syncState: CloudSyncState?
    var sync: CloudSyncEngine?
    var syncStartupTask: Task<Void, Never>?
    private var loadingSelection = false
    /// Shows stored metadata in the inspector without treating it as an edit to save.
    func showMetadata(_ update: (inout CatalogMetadata) -> Void) {
        loadingSelection = true; update(&metadata); loadingSelection = false
    }

    func acceptAutomationMetadata(_ value: CatalogMetadata, assetID: String) {
        guard selected?.id == assetID else { return }
        showMetadata { $0 = value }; metadataPending = false
    }
    var refreshTask: Task<Void, Never>?
    /// When the last refresh started, for `scheduleRefresh`'s throttle.
    var lastRefreshStart = ContinuousClock.now - .seconds(1)
    var metadataTask: Task<Void, Never>?
    /// The "Updating thumbnails" row and the tickets behind it.
    var thumbnailJob: ThumbnailJob?
    var thumbnailCatchUpTask: Task<Void, Never>?
    /// The grid's request for its photos' edited thumbnails (`developOnScreen`).
    var onScreenTicket: ThumbnailReactor.Ticket?
    var onScreenGeneration = 0
    /// Album covers tried once this session, so an offline or undecodable cover is not retried on every refresh.
    var coverThumbnailAttempts: Set<String> = []
    var previewSweepTask: Task<Void, Never>?
    var thumbnailWatchTask: Task<Void, Never>?
    /// `start` has run; until then a catalog opened from the Finder waits in `launchCatalog`.
    private var started = false
    /// `start` has finished opening the launch catalog; until then photos from the Finder wait in `launchPhotos`.
    private var launched = false
    private var starting: Task<Void, Never>?
    private var launchCatalog: URL?
    /// Photos or a folder opened from the Finder before `start`: they wait here and are then shown in the Folders view.
    private var launchPhotos: [URL] = []
    private weak var launchEditor: EditorModel?
    /// Photos opened from the Finder, selected (and one opened in Detail) once their folder lists them.
    var pendingFinderPhotos: FinderPhotos?
    /// The folder index being opened, so a tab switch and a folder shown at the same moment open it once.
    var folderIndexOpening: Task<Void, Never>?
    var thumbnailFlushTask: Task<Void, Never>?
    var pendingThumbnailIDs: Set<String> = []
    /// Photos edited in Detail, as last shown there, until their saved thumbnails arrive.
    @Published var liveThumbnails: [String: NSImage] = [:]
    func showLiveThumbnail(_ image: NSImage, of assetID: String) { liveThumbnails[assetID] = image }
    var limit = CatalogModel.pageSize
    var refreshGeneration = 0
    var selectionGeneration = 0
    var libraryColumnCount = 1
    var keyboardSelectionID: String?
    var keyboardSelectionGeneration = 0
    let preferences: UserDefaults
    init(preferences: UserDefaults = .standard, folders: FolderBrowser? = nil) {
        self.preferences = preferences
        self.folders = folders ?? FolderBrowser()
        tileSize = min(Self.tileSizes.upperBound, max(Self.tileSizes.lowerBound, preferences.object(forKey: "libraryTileSize") as? Double ?? 180))
        gridStyle = preferences.string(forKey: "libraryGridStyle").flatMap(GridStyle.init) ?? .tiles
        groupsByDate = preferences.object(forKey: "libraryGroupsByDate") as? Bool ?? true
        showInspector = preferences.object(forKey: "showLibraryInspector") as? Bool ?? true
        libraryPanel = LibraryPanel(rawValue: preferences.string(forKey: "libraryInspectorPanel") ?? "") ?? .info
        showSidebar = preferences.object(forKey: "showLibrarySidebar") as? Bool ?? true
        importMode = preferences.string(forKey: "libraryImportMode").flatMap(CatalogImporter.ImportMode.init(rawValue:)) ?? .copy
        sidebarTab = SidebarTab(rawValue: preferences.string(forKey: "sidebarTab") ?? "") ?? .catalog
        folderSubfolders = preferences.bool(forKey: "folderSubfolders")
        sidebarWidth = min(Self.sidebarWidths.upperBound, max(Self.sidebarWidths.lowerBound, preferences.object(forKey: "librarySidebarWidth") as? Double ?? Self.defaultSidebarWidth))
        compareSource = preferences.string(forKey: "compareSource").flatMap(CompareSource.init) ?? .beforeAfter
        compareOrientation = preferences.string(forKey: "compareOrientation").flatMap(CompareOrientation.init) ?? .columns
        filter.sort = preferences.string(forKey: "librarySort").flatMap(CatalogSort.init) ?? .captureDate
        filter.ascending = preferences.object(forKey: "librarySortAscending") as? Bool ?? filter.sort.defaultAscending
        knownCatalogs = (preferences.data(forKey: "knownCatalogs")).flatMap { try? JSONDecoder().decode([CatalogReference].self, from: $0) } ?? []
        // Views and commands that ask whether an import is running redraw when jobs come and go, not on every progress
        // tick: that redrew every cell and rebuilt open context menus, closing their submenus.
        jobsObservation = activity.$running.map { $0.map(\.id) }.removeDuplicates().dropFirst()
            .sink { [weak self] _ in self?.objectWillChange.send() }
        // The capture-date outline keeps month and day names from the last refresh.
        languageObservation = NotificationCenter.default.publisher(for: L10n.languageDidChangeNotification).sink { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        // Native menus must invalidate when discovery completes after their first rendering.
        cameraObservation = cameraImporter.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        cullingSensitivity = preferences.string(forKey: "cullingSensitivity").flatMap(CullingSensitivity.init) ?? .balanced
        rawJPEGImport = preferences.string(forKey: "rawJPEGImport").flatMap(RawJPEGImport.init) ?? .both
        groupRawJPEGPairsOnImport = preferences.bool(forKey: "groupRawJPEGPairsOnImport")
        // Show on a finished merge or import selects its photo when the grid has it.
        activity.showPhoto = { [weak self] id in
            guard let self, let asset = self.assets.first(where: { $0.id == id }) else { NSSound.beep(); return }
            self.select(asset)
        }
    }

    /// The last-used catalog when it was moved or renamed. Never replaced by a new empty catalog silently.
    @Published private(set) var missingCatalog: URL?
    /// The last catalog, there but not opened at launch: a sandboxed build has no access to one saved by path alone.
    @Published private(set) var unopenedCatalog: URL?
    static var defaultCatalogRoot: URL { CatalogManifest.defaultRoot }
    static func catalogExists(at root: URL) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent("catalog.sqlite").path) }
    /// Runs once: the workspace's `.task` can fire again while the first run is still opening the last catalog, and
    /// a second run would act on the Finder's photos before that open finishes and switches the tab back.
    func start() async {
        if let starting { await starting.value; return }
        let task = Task { await startOnce() }
        starting = task
        await task.value
    }
    private func startOnce() async {
        started = true
        await startCatalog()
        // Only the catalog opened at launch returns to the Folders tab; one opened later from the welcome screen shows itself.
        restoringTab = false
        launched = true
        // Photos the Finder handed over while the last catalog was opening: shown now, so that open can't undo the switch.
        if !launchPhotos.isEmpty, let editor = launchEditor {
            let urls = launchPhotos; launchPhotos = []
            await openInPlace(urls, editor: editor)
        }
    }
    private func startCatalog() async {
        _ = FileAccess.shared
        guard store == nil else { return }
        // `--new-catalog` or `--catalog` on the command line wins over the last catalog and a Finder open.
        if let launch = LaunchOptions.current {
            LaunchOptions.current = nil; launchCatalog = nil
            await openCatalog(launch.catalog, manifest: launch.create ? CatalogManifest(name: launch.catalog.deletingPathExtension().lastPathComponent, kind: .file) : nil)
            guard store != nil else {
                FileHandle.standardError.write(Data("Ceviche: couldn’t open \(launch.catalog.path): \(error ?? "")\n".utf8))
                if launch.quitWhenDone { LaunchOptions.quit(status: 1) }
                return
            }
            let finished: ((ImportSummary) -> Void)? = launch.quitWhenDone ? { LaunchOptions.report($0) } : nil
            if launch.imports.isEmpty || !importFiles(launch.imports, mode: launch.mode, finished: finished) {
                if launch.quitWhenDone { LaunchOptions.quit(status: launch.imports.isEmpty ? 0 : 1) }
            }
            return
        }
        // Photos double-clicked to launch the app show in the Folders view, with no catalog of the person's opened.
        if !launchPhotos.isEmpty, let editor = launchEditor {
            let urls = launchPhotos; launchPhotos = []; launchCatalog = nil
            await openInPlace(urls, editor: editor)
            if store != nil { return }
        }
        // A catalog double-clicked to launch the app opens instead of the last one.
        if let url = launchCatalog {
            launchCatalog = nil; await openCatalog(url)
            if store == nil { unopenedCatalog = url }
            return
        }
        if preferences.bool(forKey: "catalogClosed") { needsSetup = true; return }
        if let saved = preferences.string(forKey: "catalogRoot").map({ URL(fileURLWithPath: $0) }) {
            guard Self.catalogExists(at: saved) else { missingCatalog = saved; return }
            await openCatalog(saved)
            if store == nil { unopenedCatalog = saved }
            return
        }
        needsSetup = true
    }
    /// `manifest` names and kinds a catalog being created; an existing catalog keeps its own.
    /// `folderIndex` opens the index of browsed folders: a catalog like any other, but a cache, so it is not
    /// remembered as the person's catalog, is not searched for subjects, and keeps what is made in it in the folders.
    /// `readOnly` shows the catalog without writing to it; otherwise one that can't be opened as usual is left closed
    /// and `catalogOpenFailure` asks what to do.
    func openCatalog(_ root: URL, manifest: CatalogManifest? = nil, folderIndex: Bool = false, readOnly: Bool = false) async {
        guard !catalogWideBusy, await flushMetadata() else { return }
        FileAccess.shared.remember(root)
        do {
            // A schema upgrade (such as compacting History) can take a while on large catalogs.
            maintenance = L10n.tr("Updating catalog…")
            let opened: CatalogStore
            do { opened = try await Task.detached { try CatalogStore(root: root, manifest: manifest, readOnly: readOnly) }.value; maintenance = nil }
            catch { maintenance = nil; throw error }
            FileAccess.shared.remember(root)
            let writable = !opened.isReadOnly
            if writable {
                try await opened.setAnalysisEnabled(!folderIndex)
                if !folderIndex { try await opened.enqueueOutdatedAnalysis(version: CatalogImporter.analysisVersion) }
            }
            // Everything that can fail runs before any state changes, so a failed open leaves the current catalog intact.
            let analysis = try await opened.analysisStatus()
            if writable { await recoverPendingOutputs(in: opened) }
            indexer.catalogChanged(); placeNamer.workAvailable(); peopleGrouper.workAvailable()
            cullingScanner.reset()
            refreshTask?.cancel(); refreshGeneration += 1; selectionGeneration += 1
            cancelLibraryKeyboardNavigation(); metadataTask?.cancel()
            selectedIDs = []; selectionAnchorID = nil
            undoSteps = []; redoSteps = []
            stopSync()
            if let store { previewSweepTask?.cancel(); stopThumbnails(of: store); Task { try? await store.previews.flushSeen() } }
            let previousRoot = self.root
            store = opened; self.root = root; missingCatalog = nil; unopenedCatalog = nil; needsSetup = false; selected = nil; history = []; assets = []; selectedIndexError = nil; availability = [:]
            showMetadata { $0 = CatalogMetadata() }; metadataPending = false
            indexing = analysis; status = ""; indexingMessage = ""
            // The catalog the Library tab goes back to, while folders are browsed.
            if folderIndex, !isFolderIndex { libraryRoot = previousRoot }
            isFolderIndex = folderIndex
            folderEditsTask?.cancel(); folderEditsTask = nil
            if folderIndex {
                followFolderEdits(of: opened)
            } else {
                preferences.set(root.path, forKey: "catalogRoot")
                preferences.set(false, forKey: "catalogClosed")
                remember(CatalogReference(store: opened))
            }
            await applyFilterNow(baseFilter())
            folderFailures = [:]; folderStopped = nil
            if !folderIndex, sidebarTab == .folders {
                // At launch the Folders tab is where the person left off; opening a catalog later shows that catalog.
                if restoringTab { restoringTab = false; await openFolderIndex(); await showLastFolder(); return } else { sidebarTab = .catalog }
            }
            restoringTab = false
            startSync(for: opened)
            if !folderIndex { prepareDuplicates(of: opened) }
            schedulePreviewSweep(for: opened)
            watchThumbnails(of: opened)
            scheduleThumbnailCatchUp(for: opened)
            // Fold old History steps and drop unreferenced mask data without delaying browsing.
            if writable { Task.detached(priority: .background) { _ = try? await opened.compactHistory(); try? await opened.reclaimSpace() } }
        } catch let reason as CatalogOpenError {
            catalogOpenFailure = OpenFailure(root: root, folderIndex: folderIndex, reason: reason)
        } catch { self.failure = Failure(L10n.tr("Couldn’t Open the Catalog"), error) }
    }
    /// Saves pending work and returns to the welcome screen without removing the catalog.
    func closeCatalog(editor: EditorModel) async {
        guard store != nil, !catalogWideBusy, !editor.busy else { return }
        navigating = true
        defer { navigating = false }
        guard await flushMetadata(), await editor.flushEdits() else { return }
        editor.closeDocument()
        secondaryViewMode = nil; SecondaryWindowView.current?.close()
        indexer.catalogChanged(); stopSync()
        refreshTask?.cancel(); refreshGeneration += 1; selectionGeneration += 1
        cancelLibraryKeyboardNavigation(); metadataTask?.cancel(); previewSweepTask?.cancel()
        thumbnailWatchTask?.cancel(); thumbnailFlushTask?.cancel(); thumbnailFlushTask = nil; pendingThumbnailIDs = []; liveThumbnails = [:]
        if let store { stopThumbnails(of: store); try? await store.previews.flushSeen() }
        store = nil; root = nil; missingCatalog = nil; unopenedCatalog = nil; needsSetup = true
        selected = nil; selectedIDs = []; selectionAnchorID = nil; history = []; assets = []
        dates = []; kinds = []; total = 0; totalLoaded = false; matchingCount = 0; trashCount = 0; archiveCount = 0
        browsingAssets = []; latentShown = nil; setCompareAsset(nil, editor: editor); compareSwapped = false
        viewMode = .grid; showingOverview = true; peopleSubpage = nil; filter = baseFilter()
        showMetadata { $0 = CatalogMetadata() }; metadataPending = false
        undoSteps = []; redoSteps = []; availability = [:]; aspectCache = [:]
        albums = []; importDays = []; recentEditsCount = 0; denoise = nil; wideAngle = nil; idPhoto = nil
        selectedIndexError = nil; indexing = CatalogAnalysisStatus(); indexingMessage = ""; status = ""; duplicateCount = nil
        showingCameraImport = false
        cameraImporter.stopDiscovery()
        folderFailures = [:]; isFolderIndex = false; folderEditsTask?.cancel(); folderEditsTask = nil; libraryRoot = nil
        showingPhotosImport = false
        cardImport = nil; panoramaMerge = nil; hdrMerge = nil; photoStack = nil; pixelShift = nil; bestFaces = nil; matchSeries = nil; chartProfile = nil; filters = nil; nightSky = nil; focusStack = nil; cullingAssistant = nil; problemPhotos = nil; tidyPairs = nil; faceCheck = nil; cullingScanner.reset(); timelapse = nil; exposureRamp = nil
        preferences.removeObject(forKey: "catalogRoot")
        preferences.set(true, forKey: "catalogClosed")
    }
    /// `near` starts the open panel beside that catalog, so choosing it there grants the access a saved path lacks.
    func chooseCatalog(create: Bool, near: URL? = nil) {
        Task {
            if create {
                guard let url = await FileChooser.save(FileSaveRequest(name: "Library.cevichecatalog",
                    message: L10n.tr("Choose where to create the catalog. Originals stay where they are."))) else { return }
                guard !FileManager.default.fileExists(atPath: url.path) else { failure = Failure(L10n.tr("Couldn’t Create the Catalog"), L10n.tr("Choose a new folder name for this catalog.")); return }
                await openCatalog(url, manifest: CatalogManifest(name: url.deletingPathExtension().lastPathComponent, kind: .file))
            } else {
                // A catalog is a package, which the panel offers as a file.
                guard let url = await FileChooser.openOne(FileOpenRequest(types: [.cevicheCatalog], folders: true,
                    message: L10n.tr("Choose a Ceviche catalog."), directory: near?.deletingLastPathComponent())) else { return }
                guard Self.catalogExists(at: url) else { failure = Failure(L10n.tr("Couldn’t Open the Catalog"), L10n.tr("This folder does not contain a Ceviche catalog.")); return }
                await openCatalog(url)
            }
        }
    }
    /// What the Finder hands over (a double-click, Open With, a drop on the app's icon, `open -a`). A catalog opens in
    /// place of the current one; photos and folders are shown where they are, in the Folders view, not imported.
    func open(_ urls: [URL], editor: EditorModel) {
        let catalogs = urls.filter { $0.pathExtension.lowercased() == "cevichecatalog" || Self.catalogExists(at: $0) }
        catalogs.forEach(open)
        let others = urls.filter { !catalogs.contains($0) }
        guard !others.isEmpty else { return }
        guard launched else { launchPhotos += others; launchEditor = editor; return }
        Task { await openInPlace(others, editor: editor) }
    }
    private func open(_ url: URL) {
        guard url.standardizedFileURL.path != root?.standardizedFileURL.path else { return }
        guard Self.catalogExists(at: url) else { failure = Failure(L10n.tr("Couldn’t Open the Catalog"), L10n.tr("This folder does not contain a Ceviche catalog.")); return }
        guard started else { launchCatalog = url; return }
        guard !catalogWideBusy else { NSSound.beep(); notice = L10n.tr("Busy, try again in a moment"); return }
        Task { await openCatalog(url) }
    }
    var loadingMore = false
    /// Incremented by Edit > Find; the library focuses its search field.
    @Published var searchFocusRequest = 0
}


/// Background analysis's queue and message, for the views that show or follow it (`CatalogModel.analysis`).
@MainActor final class AnalysisProgress: ObservableObject {
    @Published var status = CatalogAnalysisStatus()
    @Published var message = ""
}
