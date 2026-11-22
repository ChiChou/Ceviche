import SwiftUI
import AppKit
import ImageIO
import ImageCaptureCore
import Combine
import CevicheCore

/// Scans a card recursively and shows it as an album; photos the catalog already has are marked.
@MainActor
final class CardImportModel: ObservableObject {
    @Published private(set) var candidates: [ImportCandidate] = []
    @Published private(set) var scanning = true
    /// Photos found so far while the card is being counted; the grid appears once the count is complete.
    @Published private(set) var foundCount = 0
    @Published var selected: Set<String> = []
    @Published var mode: CatalogImporter.ImportMode
    @Published var showingImported = true
    /// File types hidden by the chips in the title bar, as upper-case extensions.
    @Published var hiddenKinds: Set<String> = []
    @Published var error: String?
    private var task: Task<Void, Never>?
    private var cameraObservation: AnyCancellable?
    private var cameraChanges: AnyCancellable?
    private let camera: CameraImportModel?
    private let sessionID = UUID().uuidString
    private var cameraEntries: [String: CameraImportEntry] = [:]
    var isCamera: Bool { camera != nil }
    var importing: Bool { camera?.importing == true }
    var sourceTitle: String { camera?.camera?.name ?? camera?.requestedCamera?.name ?? request.title }
    func cameraFile(for candidate: ImportCandidate) -> ICCameraFile? { cameraEntries[candidate.id]?.file }
    func importSelection(into catalog: CatalogModel) {
        guard let camera else { return }
        camera.selected = Set(chosen.compactMap { cameraEntries[$0.id]?.id })
        camera.hiddenKinds = []; camera.showingImported = true
        camera.importSelection(into: catalog)
    }
    let request: CardImportRequest
    init(request: CardImportRequest) { self.request = request; mode = request.defaultMode; camera = nil }
    init(camera: CameraImportModel) {
        self.camera = camera
        request = CardImportRequest(roots: [], title: camera.requestedCamera?.name ?? L10n.tr("Camera"), defaultMode: .copy)
        mode = .copy
    }
    var newCount: Int { candidates.filter(\.isNew).count }
    /// Every file type on the card, with how many photos each has.
    var availableKinds: [(kind: String, count: Int)] {
        Dictionary(grouping: candidates, by: { Self.kind(of: $0) }).map { (kind: $0.key, count: $0.value.count) }.sorted { $0.kind < $1.kind }
    }
    static func kind(of candidate: ImportCandidate) -> String { (candidate.filename as NSString).pathExtension.uppercased() }
    var shown: [ImportCandidate] {
        candidates.filter { (showingImported || !$0.present) && !hiddenKinds.contains(Self.kind(of: $0)) }
    }
    var groups: [(title: String, items: [ImportCandidate])] { ImportScanner.groups(shown) }
    /// Whether any shot on the card was saved as both a RAW and a JPEG or HEIF file.
    var hasPairs: Bool { !RawJPEGPairs.pairs(candidates) { $0.locator.string }.isEmpty }
    /// The header checkbox: on when every shown photo is selected.
    var allShownSelected: Bool {
        get { !shown.isEmpty && shown.allSatisfy { selected.contains($0.id) } }
        set { if newValue { selected.formUnion(shown.map(\.id)) } else { selected.subtract(shown.map(\.id)) } }
    }
    /// What Import takes: the selected photos that are on screen. A type hidden by its chip never imports.
    var chosen: [ImportCandidate] { shown.filter { selected.contains($0.id) } }
    func start(store: CatalogStore) {
        guard task == nil else { return }
        if let camera {
            cameraChanges = camera.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
            cameraObservation = camera.$entries.combineLatest(camera.$scanning, camera.$error).sink { [weak self] entries, scanning, error in
                guard let self else { return }
                let previous = Set(self.candidates.map(\.id))
                self.cameraEntries = [:]
                self.candidates = entries.map { entry in
                    // A session-only identity for the existing browser UI, never a persisted original.
                    let candidate = ImportCandidate(locator: .volume(uuid: self.sessionID, relativePath: entry.path), url: nil,
                        filename: entry.filename, folder: (entry.path as NSString).deletingLastPathComponent,
                        fingerprint: ImportFingerprint(name: entry.filename, size: entry.file.fileSize > 0 ? Int64(entry.file.fileSize) : nil, captureTime: nil),
                        modified: entry.file.creationDate ?? entry.file.modificationDate,
                        present: entry.present, recentlyDeleted: entry.recentlyDeleted)
                    self.cameraEntries[candidate.id] = entry
                    return candidate
                }
                self.selected.formIntersection(self.candidates.map(\.id))
                self.selected.formUnion(self.candidates.filter { !previous.contains($0.id) && $0.isNew }.map(\.id))
                self.foundCount = entries.count; self.scanning = scanning; self.error = error
            }
            task = Task { await camera.start(store: store) }
            return
        }
        task = Task {
            defer { scanning = false }
            do {
                // Count first, without reading any EXIF, then lay out every tile at once: the grid, its groups and
                // the selection count settle in one step instead of shifting as photos trickle in.
                let presence = try await store.presence()
                var found: [ImportCandidate] = []
                for try await candidate in ImportScanner.scan(request.roots, presence: presence, quick: true) {
                    found.append(candidate)
                    if found.count % 50 == 0 { foundCount = found.count }
                }
                foundCount = found.count
                selected = Set(found.filter(\.isNew).map(\.id))
                candidates = found
            } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
        }
    }
    func stop() { task?.cancel(); cameraObservation = nil; cameraChanges = nil; camera?.stop() }
    func selectNew() { selected = Set(shown.filter(\.isNew).map(\.id)) }
    func toggleKind(_ kind: String) {
        if hiddenKinds.contains(kind) { hiddenKinds.remove(kind) } else { hiddenKinds.insert(kind) }
    }
}

/// The card importer fills the window, as in other RAW editors: the card and its filters in the title bar,
/// the album below, and how to add the photos at the bottom.
struct CardImportView: View {
    @ObservedObject var catalog: CatalogModel
    @StateObject private var model: CardImportModel
    @AppStorage("cardImportTileSize") private var tileSize = 200.0
    init(catalog: CatalogModel, request: CardImportRequest) {
        self.catalog = catalog; _model = StateObject(wrappedValue: CardImportModel(request: request))
    }
    init(catalog: CatalogModel, camera: CameraImportModel) {
        self.catalog = catalog; _model = StateObject(wrappedValue: CardImportModel(camera: camera))
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            Rule()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18, pinnedViews: .sectionHeaders) {
                    if model.candidates.isEmpty && model.scanning {
                        VStack(spacing: 10) {
                            ProgressView().controlSize(.regular)
                            Text(model.foundCount == 0 ? L10n.tr("Looking for photos…") : L10n.tr("Found \(model.foundCount) photos…")).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                        }.frame(maxWidth: .infinity).padding(60)
                    } else if model.candidates.isEmpty && !model.scanning {
                        ContentUnavailableView(L10n.tr("No Photos Found"), systemImage: "sdcard", description: Text(L10n.tr("No supported photos were found in \(model.request.title)."))).padding(40)
                    } else if model.shown.isEmpty && !model.scanning {
                        ContentUnavailableView(L10n.tr("Nothing to Show"), systemImage: "line.3.horizontal.decrease.circle", description: Text(L10n.tr("Every photo is hidden by the filters above."))).padding(40)
                    }
                    ForEach(model.groups, id: \.title) { group in
                        Section {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: tileSize, maximum: tileSize * 1.4), spacing: 12)], spacing: 12) {
                                ForEach(group.items) { candidate in
                                    CandidateTile(candidate: candidate, selected: model.selected.contains(candidate.id), cameraFile: model.cameraFile(for: candidate))
                                        .onTapGesture { if !model.importing { toggle(candidate) } }
                                        .accessibilityAddTraits(.isButton).accessibilityAction { if !model.importing { toggle(candidate) } }
                                }
                            }.padding(.horizontal, 16)
                        } header: {
                            HStack {
                                Text(title(for: group.title)).font(.headline)
                                Text(L10n.tr("\(group.items.count)")).foregroundStyle(.secondary).monospacedDigit()
                                Spacer()
                                Button(L10n.tr("Select")) { model.selected.formUnion(group.items.map(\.id)) }.disabled(model.importing).buttonStyle(.textLink).font(.caption)
                            }.padding(.horizontal, 16).padding(.vertical, 6).background(Theme.canvas)
                        }
                    }
                }.padding(.vertical, 12)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Rule()
            footer
        }
        .background(Theme.canvas)
        .onAppear { if let store = catalog.store { model.start(store: store) } }
        .onDisappear { model.stop() }
        .onExitCommand { if !model.importing { cancel() } }
        .onChange(of: model.importing) { wasImporting, importing in
            if wasImporting && !importing { cancel() }
        }
    }
    /// The title bar: the card and its filters, then Cancel and Import, as in the culling tools. What to select is in
    /// the footer with the other options.
    private var header: some View {
        let onCard = model.isCamera || model.request.roots.first.map { AssetLocator.describing($0).scheme == .volume } == true
        let count = model.chosen.count
        return ToolHeader(title: model.sourceTitle, caption: summary, icon: onCard ? "sdcard" : "folder") {
            HStack(spacing: 10) {
                if model.availableKinds.count > 1 {
                    HStack(spacing: 4) {
                        ForEach(model.availableKinds, id: \.kind) { entry in
                            let on = !model.hiddenKinds.contains(entry.kind)
                            FilterChip(title: entry.kind, count: entry.count, isOn: on) { model.toggleKind(entry.kind) }.help(on ? L10n.tr("Hide \(entry.kind) files") : L10n.tr("Show \(entry.kind) files"))
                        }
                    }
                }
                Toggle(L10n.tr("Show already imported"), isOn: $model.showingImported).toggleStyle(.formCheckbox).font(.callout)
            }.disabled(model.importing)
        } actions: {
            ActivityIndicator(center: catalog.activity)
            if model.scanning { ProgressView().controlSize(.small) }
            ToolCancelButton(title: model.importing ? L10n.tr("Stop Import") : nil) {
                if model.importing { catalog.cancelImport() } else { cancel() }
            }
            ToolPrimaryButton(title: count == 1 ? L10n.tr("Import 1 Photo") : L10n.tr("Import \(count.formatted()) Photos"), minWidth: 118) {
                if model.isCamera { model.importSelection(into: catalog) }
                else {
                    let chosen = model.chosen
                    model.stop(); catalog.cardImport = nil
                    catalog.importCandidates(chosen, mode: model.mode)
                }
            }
            .disabled(count == 0 || model.importing || model.scanning || !catalog.canStartJob)
        }
    }
    private var footer: some View {
        ToolOptionsBar(spacing: 10) {
            Group {
                Button(L10n.tr("Select All")) { model.allShownSelected = true }.disabled(model.shown.isEmpty || model.allShownSelected)
                Button(L10n.tr("Deselect All")) { model.allShownSelected = false }.disabled(model.chosen.isEmpty)
                Button(L10n.tr("Select New"), action: model.selectNew).disabled(model.newCount == 0)
            }.buttonStyle(.secondaryAction).controlSize(.small).disabled(model.importing)
            Rule(.vertical).frame(height: 14)
            Text(L10n.tr("Add photos by")).foregroundStyle(.secondary)
            FormSelect(L10n.tr("Add photos by"), selection: $model.mode, valueLabel: model.mode.title, expands: false) {
                ForEach(CatalogImporter.ImportMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }.fixedSize().disabled(model.isCamera || model.importing)
            if model.mode == .copy, let root = catalog.root {
                Text(L10n.tr("into \((root.appendingPathComponent("Originals").path as NSString).abbreviatingWithTildeInPath)")).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            // Only where the card has RAW + JPEG shots.
            if model.hasPairs {
                Text(L10n.tr("RAW + JPEG")).foregroundStyle(.secondary)
                FormSelect(L10n.tr("RAW + JPEG"), selection: $catalog.rawJPEGImport, valueLabel: catalog.rawJPEGImport.title, expands: false) {
                    ForEach(RawJPEGImport.allCases) { Text($0.title).tag($0) }
                }.fixedSize().disabled(model.importing).help(L10n.tr("What to import when a shot was saved as both a RAW and a JPEG or HEIF file"))
                if catalog.rawJPEGImport == .both {
                    Toggle(L10n.tr("Group RAW + JPEG Pairs"), isOn: $catalog.groupRawJPEGPairsOnImport).toggleStyle(.formCheckbox).disabled(model.importing)
                        .help(L10n.tr("The library shows each such shot as one tile, its RAW, with the JPEG inside the group"))
                }
            }
            Spacer()
            if let error = model.error { Text(error).foregroundStyle(Theme.error).lineLimit(1).truncationMode(.middle) }
            ThumbnailSizeSlider(size: $tileSize, range: 140...360)
        }
    }
    private var summary: String {
        let total = model.candidates.count, present = model.candidates.filter(\.present).count
        let deleted = model.candidates.filter(\.recentlyDeleted).count
        if model.scanning && model.candidates.isEmpty { return model.foundCount == 0 ? L10n.tr("Counting photos…") : L10n.tr("Counting… \(model.foundCount) so far") }
        var text = (total == 1 ? L10n.tr("\(total) photo") : L10n.tr("\(total) photos"))
        if present > 0 { text += L10n.tr(" - \(present) already in the catalog") }
        if deleted > 0 { text += L10n.tr(" - \(deleted) deleted from it recently") }
        let chosen = model.chosen.count
        if chosen > 0 { text += L10n.tr(" - \(chosen) selected") }
        return text
    }
    private func title(for key: String) -> String {
        if key.count == 10, key[key.index(key.startIndex, offsetBy: 4)] == "-" { return CaptureDateNode.title(for: key, full: true) }
        return key
    }
    private func toggle(_ candidate: ImportCandidate) {
        if model.selected.contains(candidate.id) { model.selected.remove(candidate.id) } else { model.selected.insert(candidate.id) }
    }
    private func cancel() { model.stop(); catalog.cardImport = nil; catalog.showingCameraImport = false }
}

/// A photo on the card: embedded preview, file type, name, and whether the catalog has it. The tile is a
/// fixed 4:3 box from the start, so previews arriving later never change the layout; the preview and the
/// capture time are read only once the tile has been on screen for a moment, and kept for scrolling back.
struct CandidateTile: View {
    let candidate: ImportCandidate
    let selected: Bool
    var cameraFile: ICCameraFile? = nil
    @State private var preview: CandidatePreview?
    var body: some View {
        VStack(spacing: 4) {
            Theme.ink.opacity(0.04)
                .frame(maxWidth: .infinity).aspectRatio(4 / 3, contentMode: .fit)
                .overlay {
                    if let image = preview?.image { Image(nsImage: image).resizable().scaledToFit().padding(2) }
                    else { Image(systemName: "photo").font(.largeTitle).foregroundStyle(.quaternary) }
                }
                .clipped()
                .opacity(!candidate.isNew && !selected ? 0.45 : 1)
                // The tick where the culling grids have theirs, readable over any photo and on either palette.
                .overlay(alignment: .topTrailing) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.system(size: 15))
                        .foregroundStyle(selected ? Theme.accent : Color.white.opacity(0.8))
                        .background(Circle().fill(.black.opacity(0.4))).padding(4)
                }
                .overlay(alignment: .bottomLeading) { PhotoCornerLabel(text: CardImportModel.kind(of: candidate)).padding(4) }
                .overlay(alignment: .bottomTrailing) {
                    if candidate.present || candidate.recentlyDeleted {
                        PhotoCornerLabel(text: candidate.present ? L10n.tr("In Catalog") : L10n.tr("Deleted")).padding(4)
                    }
                }
            Text(candidate.filename).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
            Text(timeLabel).font(.caption2).foregroundStyle(.secondary).monospacedDigit().frame(height: 12)
        }
        .padding(4)
        .background(selected ? Theme.ink.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(selected ? Theme.accent : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .task(id: candidate.id) {
            if let cameraFile {
                let data: Data? = await withCheckedContinuation { continuation in
                    cameraFile.requestThumbnailData(options: [.imageSourceThumbnailMaxPixelSize: 320, .imageSourceShouldCache: false]) { data, _ in
                        continuation.resume(returning: data)
                    }
                }
                guard !Task.isCancelled else { return }
                preview = CandidatePreview(image: data.flatMap(NSImage.init(data:)), captureTime: nil)
                return
            }
            guard let url = candidate.url else { return }
            if let cached = CandidatePreview.cache.object(forKey: url as NSURL) { preview = cached; return }
            // Tiles that fly past while scrolling are gone before this fires, and never decode anything.
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            let loaded = await Task.detached(priority: .utility) { CandidatePreview.load(url) }.value
            guard let loaded, !Task.isCancelled else { return }
            CandidatePreview.cache.setObject(loaded, forKey: url as NSURL, cost: loaded.image.map { Int($0.size.width * $0.size.height) * 4 } ?? 0)
            preview = loaded
        }
        .accessibilityElement(children: .combine).accessibilityLabel(candidate.filename + (candidate.present ? L10n.tr(", already in catalog") : candidate.recentlyDeleted ? L10n.tr(", deleted from catalog recently") : ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var timeLabel: String {
        if let time = preview?.captureTime ?? candidate.fingerprint.captureTime { return String(time.dropFirst(11)) }
        return candidate.modified?.localized(date: .omitted, time: .shortened) ?? " "
    }
}

/// The embedded preview and EXIF time of a photo on the card, read in one pass over the file's header.
final class CandidatePreview: @unchecked Sendable {
    let image: NSImage?
    let captureTime: String?
    init(image: NSImage?, captureTime: String?) { self.image = image; self.captureTime = captureTime }
    static let cache: NSCache<NSURL, CandidatePreview> = { let cache = NSCache<NSURL, CandidatePreview>(); cache.countLimit = 2000; cache.totalCostLimit = 192 << 20; return cache }()
    nonisolated static func load(_ url: URL) -> CandidatePreview? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let time = CatalogImporter.captureTime(source: source)
        guard let image = ImageDecode.thumbnail(source, 0, [kCGImageSourceCreateThumbnailFromImageIfAbsent: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 320] as CFDictionary) else {
            return CandidatePreview(image: nil, captureTime: time)
        }
        return CandidatePreview(image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)), captureTime: time)
    }
}

extension ImportCandidate {
    /// Neither in the catalog nor removed from it recently: what the importer preselects.
    var isNew: Bool { !present && !recentlyDeleted }
}
