import SwiftUI
import MapKit
import CevicheCore

/// The inspector for one catalog photo, in the Library and as Develop's Info tab: rating and flag, the editable
/// fields, albums and labels, tools, the original's location, around the card, capture details and metadata list
/// (see PhotoInfoPanel.swift). In Develop it leaves out the Develop button and adds how the photo is processed.
struct CatalogInspector: View {
    @ObservedObject var model: CatalogModel
    @ObservedObject var editor: EditorModel
    let asset: CatalogAsset
    var inDevelop = false
    @State private var summary = PhotoMetadataSummary()
    @State private var settingLocation = false
    /// The original on this Mac, for its capture metadata; an offline or not-yet-downloaded one is left alone.
    private var originalURL: URL? {
        if case .available(let url) = asset.availability(catalog: model.root) { return url }
        return nil
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PhotoFileCard(filename: asset.filename, isRAW: asset.info.isRAW, width: asset.info.width, height: asset.info.height, captured: summary.captured) {
                    InspectorHeaderActions(model: model, editor: editor, targets: [asset])
                }
                if !inDevelop {
                    Button { model.develop(asset, editor: editor) } label: { Text(L10n.tr("Develop")).frame(maxWidth: .infinity) }
                        .buttonStyle(.secondaryAction)
                        .controlSize(.large).disabled(editor.busy).help(L10n.tr("Develop (⌘↩)"))
                }
                // Ratings, flags and text are the catalog's: a folder's photo shows what the file says.
                if !model.isFolderIndex {
                    InspectorReviewControls(rating: model.metadata.rating, review: model.metadata.review,
                                            setRating: { model.metadata.rating = $0 }, setReview: { model.metadata.review = $0 })
                        .disabled(!model.canStartJob)
                    VStack(alignment: .leading, spacing: 10) {
                        field(L10n.tr("Title")) { TextField("", text: $model.metadata.title) }
                        field(L10n.tr("Caption")) { TextField("", text: $model.metadata.caption, axis: .vertical).lineLimit(2...6) }
                        field(L10n.tr("Keywords")) { TextField("", text: $model.metadata.keywords, prompt: Text(L10n.tr("Separated by commas")), axis: .vertical).lineLimit(1...4) }
                        // A changed date is the catalog's alone; a folder's photo keeps the date in its file.
                        if !model.isFolderIndex {
                            field(L10n.tr("Date")) {
                                HStack(spacing: 4) {
                                    TextField("", text: $model.metadata.captureDay, prompt: Text(L10n.tr("YYYY-MM-DD")))
                                    CaptureDayPicker(day: $model.metadata.captureDay)
                                }
                            }
                        }
                        if !model.captureDayValid { Text(L10n.tr("Use YYYY-MM-DD, or leave empty.")).font(.caption).foregroundStyle(Theme.warning) }
                    }.textFieldStyle(.formField)
                }
                if !model.isFolderIndex { AlbumAndLabelRow(model: model, targets: [asset]) }
                PhotoToolList(model: model, editor: editor, targets: [asset])
                if !asset.suggestedTags.isEmpty || model.selectedIndexError != nil {
                    InfoSection(L10n.tr("Suggested Tags")) {
                        if !asset.suggestedTags.isEmpty { Text(asset.suggestedTags).font(.caption).foregroundStyle(.secondary) }
                        if let failure = model.selectedIndexError {
                            HStack {
                                Text(failure).font(.caption).foregroundStyle(Theme.error)
                                Button(L10n.tr("Try Again"), action: model.analyze).buttonStyle(.textLink).font(.caption).disabled(model.catalogBusy)
                            }
                        }
                    }
                }
                let place = [asset.placeCity, asset.placeRegion, asset.placeCountry].compactMap({ $0 }).reduce(into: [String](), { if !$0.contains($1) { $0.append($1) } }).nonEmptyJoined
                // Where the photo itself was taken; a place borrowed from a neighbouring photo has no point to show.
                let coordinate: CLLocationCoordinate2D? = {
                    guard let latitude = asset.latitude ?? summary.latitude, let longitude = asset.longitude ?? summary.longitude else { return nil }
                    return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                }()
                // A folder's photo shows what its file says; only the catalog's own photos are placed by hand.
                if place != nil || coordinate != nil || !model.isFolderIndex {
                    InfoSection(L10n.tr("Place"), accessory: {
                        if !model.isFolderIndex {
                            IconButton("mappin.and.ellipse", L10n.tr("Set Location…"), pointSize: 11, size: CGSize(width: 18, height: 18)) { settingLocation = true }
                                .disabled(!model.canStartJob)
                        }
                    }) {
                        if let place = place ?? coordinate.map(LocationPicker.text) { PlaceLink(place: place, coordinate: coordinate) }
                        else { Text(L10n.tr("None")).font(.caption).foregroundStyle(.tertiary) }
                        if asset.locationSource != nil {
                            Text(L10n.tr("Set in Ceviche")).font(.caption2).foregroundStyle(.tertiary)
                        } else if asset.latitude == nil, asset.placeSource == CatalogPlace.Source.nearby.rawValue {
                            Text(L10n.tr("Approximate, from a photo taken around the same time")).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .sheet(isPresented: $settingLocation) { LocationPicker(model: model, targets: [asset]) }
                }
                if originalURL != nil { CaptureDetails(summary: summary, camera: asset.info.camera, lens: asset.info.lens) }
                if inDevelop { ProcessingDetails(model: editor) }
                InfoSection(L10n.tr("File")) {
                    let location = OriginalLocation(locator: asset.locator)
                    Text(location.storage).font(.caption)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(location.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3).truncationMode(.middle)
                        Spacer(minLength: 0)
                        // Only an original on this Mac can be shown; offline and not-yet-downloaded ones cannot.
                        let local: Bool = { switch model.availability[asset.id] { case .offline?, .fetchable?: false; default: true } }()
                        Button { model.showInFinder([asset]) } label: {
                            Image(systemName: "magnifyingglass.circle.fill").font(.system(size: 13))
                        }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(!local || asset.isLatent)
                            .help(L10n.tr("Show in Finder")).accessibilityLabel(L10n.tr("Show in Finder"))
                    }
                    if let availability = model.availability[asset.id] {
                        switch availability {
                        case .offline(let reason):
                            Label(L10n.tr("Offline"), systemImage: "exclamationmark.icloud").font(.caption).foregroundStyle(Theme.warning)
                            Text(reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if !model.isFolderIndex {
                                HStack {
                                    Button(L10n.tr("Locate Original…"), action: model.relink)
                                    Button(L10n.tr("Replace Original…"), action: model.replaceOriginal)
                                }.controlSize(.small).disabled(model.catalogBusy)
                            }
                        case .fetchable(let storage):
                            Label(L10n.tr("On \(storage); downloads when opened"), systemImage: "icloud.and.arrow.down").font(.caption).foregroundStyle(.secondary)
                        case .available: EmptyView()
                        }
                    }
                }
                if let report = XMPCodec.compatibilityReport(asset.xmpWarnings) {
                    XMPCompatibilitySection(model: model, editor: editor, asset: asset, report: report)
                }
                AllMetadataDisclosure(fields: summary.extended)
            }.padding(16)
        }
        .loadsPhotoSummary(originalURL, into: $summary)
    }
    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content().accessibilityLabel(label)
        }
    }
}

/// Changes for several selected photos at once: the Library selection, or the photos selected in Develop's filmstrip.
struct CatalogBatchInspector: View {
    @ObservedObject var model: CatalogModel
    @ObservedObject var editor: EditorModel
    @State private var keywords = ""
    @State private var settingLocation = false
    private var targets: [CatalogAsset] { model.cullingTargets(editor: editor) }
    /// The value every selected photo shares, if any.
    private var commonRating: Int? { Set(targets.map(\.rating)).count == 1 ? targets.first?.rating : nil }
    /// The flag every selected photo shares, if any.
    private var commonReview: ReviewState? { Set(targets.map(\.review)).count == 1 ? targets.first?.review : nil }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.tr("\(targets.count) Photos")).font(.headline)
                        if model.filter.area == .trash { Label(L10n.tr("In Trash"), systemImage: "trash").font(.caption).foregroundStyle(.secondary) }
                        if model.filter.area == .archive { Label(L10n.tr("Archived"), systemImage: "archivebox").font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 0)
                    if model.filter.area == .library { InspectorHeaderActions(model: model, editor: editor, targets: targets) }
                }
                if model.filter.area == .archive {
                    ArchiveActions(model: model, editor: editor, targets: targets)
                } else if model.filter.area == .trash {
                    VStack(spacing: 8) {
                        Button { Task { await model.recoverFromTrash(targets) } } label: { Text(L10n.tr("Recover")).frame(maxWidth: .infinity) }.buttonStyle(.primaryAction)
                        Button(role: .destructive) { Task { await model.requestPermanentDeletion(targets, editor: editor) } } label: { Text(L10n.tr("Remove from Library…")).frame(maxWidth: .infinity) }
                            .buttonStyle(.destructiveAction)
                    }.disabled(model.catalogBusy || editor.busy)
                    Text(L10n.tr("Recovering keeps the edits and history. Deleting permanently removes the photos with their edits; the confirmation asks whether the files go too."))
                        .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Button { model.requestExport(targets) } label: { Text(L10n.tr("Export…")).frame(maxWidth: .infinity) }
                        .buttonStyle(.secondaryAction).controlSize(.large).disabled(!model.canStartJob)
                    if !model.isFolderIndex {
                        InspectorReviewControls(rating: commonRating, review: commonReview,
                            setRating: { value in let photos = targets; Task { await model.setQuickMetadata(photos, rating: value) } },
                            setReview: { value in let photos = targets; Task { await model.setQuickMetadata(photos, review: value) } })
                            .disabled(!model.canStartJob)
                        InfoSection(L10n.tr("Add Keywords")) {
                            HStack(spacing: 6) {
                                TextField("", text: $keywords, prompt: Text(L10n.tr("Separated by commas"))).textFieldStyle(.formField)
                                    .onSubmit(addKeywords).accessibilityLabel(L10n.tr("Add Keywords"))
                                Button(L10n.tr("Add"), action: addKeywords).buttonStyle(.secondaryAction)
                                    .disabled(keywords.trimmingCharacters(in: .whitespaces).isEmpty)
                            }.controlSize(.small)
                        }
                        AlbumAndLabelRow(model: model, targets: targets)
                        InfoSection(L10n.tr("Place"), accessory: {
                            IconButton("mappin.and.ellipse", L10n.tr("Set Location…"), pointSize: 11, size: CGSize(width: 18, height: 18)) { settingLocation = true }
                                .disabled(!model.canStartJob)
                        }) {
                            let located = targets.filter { $0.latitude != nil }.count
                            Text(L10n.tr("\(located) of \(targets.count) located")).font(.caption).foregroundStyle(.secondary)
                        }
                        .sheet(isPresented: $settingLocation) { LocationPicker(model: model, targets: targets) }
                    }
                    PhotoToolList(model: model, editor: editor, targets: targets)
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
    private func addKeywords() {
        let text = keywords, targets = targets
        Task { await model.addKeywords(text, to: targets); keywords = "" }
    }
}

/// Every tool for the selection, one per row in named groups: the ones that make new photos from it and the ones
/// that work on each photo's look. With one photo selected only the tools that take a single photo show.
private struct PhotoToolList: View {
    @ObservedObject var model: CatalogModel
    @ObservedObject var editor: EditorModel
    let targets: [CatalogAsset]
    private var single: Bool { targets.count == 1 }
    /// Why Denoise and Negative are unavailable when the selection is the reason.
    private var rawOnly: String? { targets.allSatisfy(CatalogModel.isRAW) ? nil : L10n.tr("RAW only") }
    /// Photos merged into one; with one photo selected only Pixel Shift, whose set may be in one file.
    private var merges: some View {
        ToolGroup(L10n.tr("Merge", context: "tool group")) {
            if !single {
                ToolRow(L10n.tr("Panorama Merge"), help: L10n.tr("Merge to Panorama…"), icon: { Image(systemName: "pano") }) { model.requestPanoramaMerge(targets) }
                    .disabled(!model.canMergePanorama(targets) || model.panoramaMerge != nil)
                ToolRow(L10n.tr("HDR Merge"), help: L10n.tr("Merge to HDR…"), icon: { Image(systemName: "square.3.layers.3d") }) { model.requestHDRMerge(targets) }
                    .disabled(!model.canMergeHDR(targets) || model.hdrMerge != nil)
                ToolRow(L10n.tr("Focus Stack"), help: L10n.tr("Focus Stack…"), icon: { Image(systemName: "camera.macro") }) { model.requestFocusStack(targets) }
                    .disabled(!model.canFocusStack(targets) || model.focusStack != nil)
            }
            // A Pentax set is one photo holding four exposures; whether a selection is a set shows in its window.
            ToolRow(L10n.tr("Pixel Shift"), help: L10n.tr("Merge Pixel Shift…"), icon: { Image(systemName: "square.grid.2x2") }) { model.requestPixelShift(targets) }
                .disabled(!model.canPixelShift(targets) || model.pixelShift != nil)
            if !single {
                ToolRow(L10n.tr("Best Faces"), help: L10n.tr("Merge Best Faces…"), icon: { Image(systemName: "person.3") }) { model.requestBestFaces(targets) }
                    .disabled(!model.canMergeBestFaces(targets) || model.bestFaces != nil)
            }
        }
    }
    var body: some View {
        InfoSection(L10n.tr("Tools")) {
            VStack(spacing: 1) {
                // Grouped by what the photos are for: several photos into one, the night sky, a sequence over time,
                // then one photo at a time. Groups that need several photos only show for a selection of several.
                if !single { merges }
                if !single {
                    // Stack, one row per technique, each opening the Stack dialog in its mode.
                    ToolGroup(L10n.tr("Stack", context: "tool group")) {
                        ForEach(PhotoStackMode.menuItems) { mode in
                            ToolRow(mode.toolTitle ?? mode.title, help: mode.menuTitle ?? "", icon: { Image(systemName: mode.symbol) }) { model.requestStack(targets, mode: mode) }
                                .disabled(!model.canStack(targets) || model.photoStack != nil)
                        }
                    }
                    ToolGroup(L10n.tr("Night Sky", context: "tool group")) {
                        ForEach([NightSkyTool.starTrails, .denoise, .meteorShower]) { tool in
                            ToolRow(tool.tileTitle, help: tool.menuTitle, icon: { NightSkyToolIcon(tool: tool) }) { model.requestNightSky(tool, targets) }
                                .disabled(!model.canUseNightSky(tool, targets))
                        }
                    }
                    // Made from a sequence, then kept even across it.
                    ToolGroup(L10n.tr("Sequence", context: "tool group")) {
                        ToolRow(L10n.tr("Timelapse Video"), help: L10n.tr("Create Timelapse Video…"), icon: { Image(systemName: "timelapse") }) { model.requestTimelapse(targets) }
                            .disabled(!model.canCreateTimelapse(targets) || model.timelapse != nil || model.panoramaMerge != nil)
                        ToolRow(L10n.tr("Live Photo"), help: L10n.tr("Create Live Photo…"), icon: { Image(systemName: "livephoto") }) { model.requestLivePhoto(targets) }
                            .disabled(!model.canCreateLivePhoto(targets))
                        ToolRow(L10n.tr("Timelapse Deflicker"), help: L10n.tr("Timelapse Deflicker…"), icon: { Image(systemName: "sun.max") }) { model.requestExposureRamp(targets) }
                            .disabled(!model.canBalanceExposure(targets) || model.exposureRamp != nil || model.timelapse != nil)
                        ToolRow(L10n.tr("Match Series"), help: L10n.tr("Match Series…"), note: rawOnly, icon: { Image(systemName: "circle.lefthalf.filled.righthalf.striped.horizontal") }) { model.requestMatchSeries(targets) }
                            .disabled(!model.canMatchSeries(targets))
                    }
                }
                ToolGroup(L10n.tr("Enhance", context: "tool group")) {
                    ToolRow(L10n.tr("AI Noise Reduction"), help: L10n.tr("AI Noise Reduction…"), note: rawOnly, icon: { Image(systemName: "wand.and.sparkles") }) { model.requestDenoise(targets) }
                        .disabled(!model.canDenoise(targets) || model.denoise != nil)
                    ToolRow(L10n.tr("Wide-Angle Faces"), help: L10n.tr("Wide-Angle Faces…"), icon: { Image(systemName: "person.2.wave.2") }) { model.requestWideAngle(targets) }
                        .disabled(!model.canCorrectWideAngle(targets) || model.wideAngle != nil)
                    ToolRow(L10n.tr("Creative Filters"), help: L10n.tr("Creative Filters…"), icon: { Image(systemName: "camera.filters") }) { model.requestFilters(targets) }
                        .disabled(!model.canApplyFilters(targets))
                }
                // Film scans and measured color.
                ToolGroup(L10n.tr("Color", context: "tool group")) {
                    ToolRow(L10n.tr("Convert Negative"), help: L10n.tr("Convert Negative…"), note: rawOnly, icon: { Image(systemName: "film") }) { model.requestNegative(targets) }
                        .disabled(!model.canConvertNegative(targets) || model.negative != nil)
                    // With a shoot selected, the chart is looked for in it and the profile goes on the rest.
                    ToolRow(L10n.tr("Chart Profile"), help: L10n.tr("Chart Profile…"), note: rawOnly, icon: { Image(systemName: "square.grid.3x2") }) { model.requestChartProfile(targets) }
                        .disabled(!model.canMakeChartProfile(targets))
                }
                ToolGroup(L10n.tr("Print", context: "tool group")) {
                    // A proof is of one photo.
                    if single {
                        ToolRow(L10n.tr("Print Proof"), help: L10n.tr("Print Proof (⌘Y)"), icon: { Image(systemName: "printer") }) { model.togglePrintProof(targets, editor: editor) }
                            .disabled(!model.canPrintProof(targets, editor: editor))
                    }
                    ToolRow(L10n.tr("ID Photo"), help: L10n.tr("ID Photo…"), icon: { Image(systemName: "person.crop.square") }) { model.requestIDPhoto(targets, editor: editor) }
                        .disabled(!model.canMakeIDPhoto(targets) || model.idPhoto != nil)
                }
                // One photo only merges as a Pentax Pixel Shift set, the least likely use, so it comes last.
                if single { merges }
            }
            // Imports run in the background; the tools' own checks say when one can start.
            .disabled(!model.canStartJob || editor.busy)
        }
    }
}

/// A group of tools under its name, in a quieter style than the section's own title.
private struct ToolGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) { self.title = title; self.content = content }
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 2).accessibilityAddTraits(.isHeader)
            content()
        }
    }
}

private extension PhotoStackMode {
    /// The technique's icon in the tool list.
    var symbol: String {
        switch self {
        case .median: "person.2.slash"
        case .clippedMean: "square.stack.3d.down.right"
        case .mean: "water.waves"
        case .maximum: "scribble.variable"
        case .sequence: "figure.run"
        case .lighten: "lightbulb.max"
        case .minimum, .darken: "square.stack"
        }
    }
}

/// One tool in the list: its icon, its name, and while it is unavailable a short reason on the right when there is one.
private struct ToolRow<Icon: View>: View {
    let title: String
    let help: String
    var note: String?
    @ViewBuilder let icon: () -> Icon
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    init(_ title: String, help: String, note: String? = nil, @ViewBuilder icon: @escaping () -> Icon, action: @escaping () -> Void) {
        self.title = title; self.help = help; self.note = note; self.icon = icon; self.action = action
    }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                icon().font(.system(size: 13)).frame(width: 18)
                Text(title).font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 4)
                // Why it is off, readable beside the dimmed title.
                if !enabled, let note { Text(note).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
            }
            .foregroundStyle(enabled ? .primary : .tertiary)
            .padding(.horizontal, 8).frame(height: 26)
            .background(hovering && enabled ? Theme.ink.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovering = $0 }
        .help(help).accessibilityLabel(help).accessibilityHint(!enabled ? note ?? "" : "")
    }
}

/// Five stars set by clicking one or dragging across them; clicking the current rating clears it, and dragging left of
/// the first star sets none. The stars follow the pointer and the rating is set once, on release.
struct StarRatingDrag: View {
    let rating: Int?
    let set: (Int) -> Void
    @State private var dragging: Int?
    var star: CGFloat = 24
    var spacing: CGFloat = 2
    var filledColor: Color = Theme.accent
    var emptyColor: Color = .secondary
    var body: some View {
        let shown = dragging ?? rating ?? 0
        HStack(spacing: spacing) {
            ForEach(1...5, id: \.self) { value in
                Button { set(Self.committedRating(value, previous: rating, horizontalTravel: 0)) } label: {
                    Image(systemName: shown >= value ? "star.fill" : "star")
                        .foregroundStyle(shown >= value ? filledColor : emptyColor)
                        .frame(width: star, height: star)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .contentShape(Rectangle())
        .highPriorityGesture(DragGesture(minimumDistance: 3).onChanged { dragging = value(at: $0.location.x) }.onEnded { drag in
            let value = value(at: drag.location.x)
            dragging = nil
            set(value)
        })
        .help(L10n.tr("Rating"))
        .accessibilityElement().accessibilityLabel(L10n.tr("Rating"))
        .accessibilityValue(rating.map { $0 == 1 ? L10n.tr("1 star") : L10n.tr("\($0) stars") } ?? L10n.tr("Mixed"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: set(min((rating ?? 0) + 1, 5))
            case .decrement: set(max((rating ?? 0) - 1, 0))
            @unknown default: break
            }
        }
    }
    static func committedRating(_ value: Int, previous: Int?, horizontalTravel: CGFloat) -> Int {
        abs(horizontalTravel) < 3 && previous == value ? 0 : value
    }
    private func value(at x: CGFloat) -> Int { x < 0 ? 0 : min(5, Int(x / (star + spacing)) + 1) }
}

/// Where an original lives, for inspectors and confirmations: the storage, and the path inside it.
struct OriginalLocation {
    let storage: String
    let path: String
    private init(storage: String, path: String) { self.storage = storage; self.path = path }
    init(locator: AssetLocator) {
        switch locator {
        case .catalog(let relative): self.init(storage: L10n.tr("Catalog folder"), path: relative)
        case .file(let absolute): self.init(storage: L10n.tr("This Mac"), path: (absolute as NSString).abbreviatingWithTildeInPath)
        case .volume(_, let relative): self.init(storage: locator.storageDescription, path: relative)
        }
    }
    /// Styled interpolation needs a `Text` to interpolate into; inside a `String` the storage printed its own description.
    var text: Text { Text("\(Text(storage).foregroundStyle(.primary)) - \(Text(verbatim: path))") }
}

/// A photo in the Trash or the archive: what it is, where its original lives, and the ways out.
struct CatalogTrashInspector: View {
    @ObservedObject var model: CatalogModel
    @ObservedObject var editor: EditorModel
    let asset: CatalogAsset
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(asset.filename).font(.headline).lineLimit(2).textSelection(.enabled)
                    let info = asset.info
                    Text([("\(info.width) × \(info.height)"), info.camera, info.lens].filter { !$0.isEmpty }.joined(separator: " - "))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let date = asset.trashedAt {
                        Label { Text(L10n.tr("In Trash since \(date, format: .dateTime.day().month().year())")) } icon: { Image(systemName: "trash") }
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                    } else if let date = asset.archivedAt {
                        Label { Text(L10n.tr("Archived \(date, format: .dateTime.day().month().year())")) } icon: { Image(systemName: "archivebox") }
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                    }
                }
                if asset.area == .archive {
                    ArchiveActions(model: model, editor: editor, targets: [asset])
                } else {
                VStack(spacing: 8) {
                    Button { Task { await model.recoverFromTrash([asset]) } } label: { Text(L10n.tr("Recover")).frame(maxWidth: .infinity) }
                        .buttonStyle(.primaryAction).help(L10n.tr("Put the photo back in the library (⌘⌫)"))
                    Button(role: .destructive) { Task { await model.requestPermanentDeletion([asset], editor: editor) } } label: { Text(L10n.tr("Remove from Library…")).frame(maxWidth: .infinity) }
                        .help(L10n.tr("Remove the photo with its edits and history, and choose whether the original file goes too (⌥⌘⌫)"))
                }.controlSize(.large).disabled(model.catalogBusy || editor.busy)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.tr("Original")).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
                    let location = OriginalLocation(locator: asset.locator)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(location.storage).font(.caption)
                        Text(location.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3).truncationMode(.middle)
                    }
                    if let url = asset.availability(catalog: model.root).localURL {
                        Button(L10n.tr("Show in Finder")) { NSWorkspace.shared.showInFinder([url]) }.buttonStyle(.textLink).font(.caption)
                    } else {
                        Label(L10n.tr("Not on this Mac right now"), systemImage: "exclamationmark.icloud").font(.caption).foregroundStyle(Theme.warning)
                    }
                }
                if !asset.title.isEmpty || !asset.caption.isEmpty || !asset.keywords.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.tr("Metadata")).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
                        if !asset.title.isEmpty { Text(asset.title).font(.caption) }
                        if !asset.caption.isEmpty { Text(asset.caption).font(.caption).foregroundStyle(.secondary) }
                        if !asset.keywords.isEmpty { Text(asset.keywords).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if asset.area == .trash {
                Text(L10n.tr("Recovering keeps the edits and history. Deleting the original removes them with the photo."))
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(16)
        }
    }
}

private extension Array where Element == String {
    /// "City, Region, Country", or nil when there is nothing to show.
    var nonEmptyJoined: String? { isEmpty ? nil : joined(separator: ", ") }
}

/// The Info panel of a browsed folder with nothing selected: what it is, where, and how much it holds.
struct FolderInfoPanel: View {
    @ObservedObject var model: CatalogModel
    let folder: String
    @State private var summary: CatalogFolderSummary?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text((folder as NSString).lastPathComponent).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        Button { NSWorkspace.shared.showInFinder([URL(fileURLWithPath: folder)]) } label: {
                            Image(systemName: "magnifyingglass.circle.fill").font(.system(size: 13))
                        }.buttonStyle(.plain).foregroundStyle(.secondary).help(L10n.tr("Show in Finder")).accessibilityLabel(L10n.tr("Show in Finder"))
                    }
                    Text((folder as NSString).abbreviatingWithTildeInPath).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(3).truncationMode(.middle).textSelection(.enabled).help(folder)
                }
                if let summary {
                    InfoSection(L10n.tr("Photos")) {
                        row(L10n.tr("All Photos"), summary.photos.formatted())
                        if summary.raw > 0 { row(L10n.tr("RAW"), summary.raw.formatted()) }
                        if summary.edited > 0 { row(L10n.tr("Edited"), summary.edited.formatted()) }
                        row(L10n.tr("Size"), ByteCountFormatter.string(fromByteCount: summary.bytes, countStyle: .file))
                        if let span = CaptureSpan.days(summary.firstDay, summary.lastDay) { row(L10n.tr("Captured"), span) }
                    }
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .topLeading)
        }
        // Again as the folder is indexed, so the numbers follow the grid.
        .task(id: "\(model.assets.count)|\(model.folderSync == nil)|\(model.filter.subfolders)") {
            summary = try? await model.store?.folderSummary(folder, deep: model.filter.subfolders)
        }
    }
    private func row(_ title: String, _ value: String) -> some View {
        HStack { Text(title).foregroundStyle(.secondary); Spacer(); Text(value).monospacedDigit() }.font(.system(size: 11))
    }
}
