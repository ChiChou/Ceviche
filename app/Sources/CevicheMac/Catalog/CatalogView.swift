import SwiftUI
import MapKit
import CevicheCore

/// The grid; the workspace supplies the header with search and filters, the sidebar, inspector and status bar.
struct CatalogView: View {
    @FocusState private var gridFocused: Bool
    @ObservedObject var model: CatalogModel
    @ObservedObject var editor: EditorModel
    var body: some View {
                VStack(spacing: 0) {
                    if model.showingLibrary, model.filter.withFaces, let person = model.filter.personID { PersonBar(model: model, personID: person) }
                    if model.showingLibrary, model.filter.geotagged, let area = model.filter.mapArea { PlaceBar(model: model, area: area) }
                    ZStack {
                        if model.needsSetup && model.store == nil {
                            WelcomeView(model: model)
                        } else if let missing = model.missingCatalog {
                            ContentUnavailableView {
                                Label(L10n.tr("Catalog Not Found"), systemImage: "questionmark.folder")
                            } description: {
                                Text(L10n.tr("“\(missing.deletingPathExtension().lastPathComponent)” is no longer at \(missing.deletingLastPathComponent().path). It may have been moved, renamed, or be on a disconnected drive."))
                            } actions: {
                                Button(L10n.tr("Locate Catalog…")) { model.chooseCatalog(create: false) }.buttonStyle(.primaryAction)
                                Button(L10n.tr("New Catalog…")) { model.chooseCatalog(create: true) }.buttonStyle(.secondaryAction)
                            }
                        } else if let unopened = model.unopenedCatalog, model.store == nil {
                            // Imports need an open catalog; an empty library here would take none.
                            ContentUnavailableView {
                                Label(L10n.tr("Can’t Open Catalog"), systemImage: "lock")
                            } description: {
                                Text(verbatim: unopened.path)
                            } actions: {
                                Button(L10n.tr("Open Catalog…")) { model.chooseCatalog(create: false, near: unopened) }.buttonStyle(.primaryAction)
                                Button(L10n.tr("New Catalog…")) { model.chooseCatalog(create: true) }.buttonStyle(.secondaryAction)
                            }
                        } else if model.filter.area == .archive && model.archiveCount == 0 {
                            ContentUnavailableView(L10n.tr("Archive Is Empty"), systemImage: "archivebox", description: Text(L10n.tr("Camera JPEGs archived by Tidy RAW + JPEG Pairs appear here.")))
                        } else if model.filter.area == .trash && model.trashCount == 0 {
                            ContentUnavailableView(L10n.tr("Trash Is Empty"), systemImage: "trash", description: Text(L10n.tr("Photos you move to Trash appear here until you delete them.")))
                        } else if model.filter.folder != nil, let issue = model.folderIssue {
                            if case .denied = issue {
                                ContentUnavailableView {
                                    Label(L10n.tr("No Access"), systemImage: "lock")
                                } actions: {
                                    Button(L10n.tr("Privacy Settings…")) { CatalogModel.openPrivacySettings() }.buttonStyle(.primaryAction)
                                    Button(L10n.tr("Try Again"), action: model.retryFolder).buttonStyle(.secondaryAction)
                                }
                            } else {
                                ContentUnavailableView(L10n.tr("Folder Not Found"), systemImage: "questionmark.folder")
                            }
                        } else if model.filter.folder != nil && model.assets.isEmpty && !model.filter.isRefined {
                            // Photos new to the catalog arrive as they are indexed.
                            if model.folderSync != nil || model.refreshedFolder != model.filter.folder { ProgressView().controlSize(.small) }
                            else { ContentUnavailableView(L10n.tr("No Photos"), systemImage: "folder") }
                        } else if model.isFolderIndex && model.filter.folder == nil {
                            // Browsing folders: photos come from the folder chosen beside this. With none chosen there
                            // is nothing to show; the index's photos are not a collection of their own.
                            ContentUnavailableView(L10n.tr("No Photos"), systemImage: "folder")
                        } else if model.filter.area == .library && !model.totalLoaded {
                            // An opening catalog is not an empty one: no "No Photos Yet" and Import buttons until it is counted.
                            Color.clear
                        } else if model.filter.area == .library && model.total == 0 {
                            // The sidebar's Import may be hidden, so the empty catalog offers it itself.
                            ContentUnavailableView {
                                Label(L10n.tr("No Photos Yet"), systemImage: "photo.stack")
                            } actions: {
                                HStack(spacing: 12) {
                                    Button(L10n.tr("Import Photos…"), action: model.chooseImport).buttonStyle(.primaryAction)
                                    Menu { CardImportItems(catalog: model) } label: { Text(L10n.tr("Import From")) }
                                        .menuStyle(.button).buttonStyle(.secondaryAction).fixedSize().findsCamerasWhenOpened(model)
                                }.padding(.top, 12)
                            }
                        } else if model.filter.withFaces && model.assets.isEmpty && !model.filter.isRefined {
                            ContentUnavailableView(L10n.tr("No Faces Found Yet"), systemImage: "person.crop.square",
                                                   description: Text(L10n.tr("Faces appear here as photos are analyzed.")))
                        } else if model.filter.geotagged && model.assets.isEmpty && !model.filter.isRefined {
                            ContentUnavailableView(L10n.tr("No Photos with Locations"), systemImage: "map", description: Text(L10n.tr("Photos with location data appear here.")))
                        } else if model.assets.isEmpty && !model.filter.isRefined && model.filter.albumID != nil {
                            ContentUnavailableView(L10n.tr("Album Is Empty"), systemImage: "rectangle.stack", description: Text(L10n.tr("Select photos in All Photos, then choose Add to Album from their context menu.")))
                        } else if model.assets.isEmpty && !model.filter.isRefined && model.filter.recentEdits {
                            ContentUnavailableView(L10n.tr("No Recent Edits"), systemImage: "slider.horizontal.3", description: Text(L10n.tr("Photos appear here when you change their development. Ratings and flags do not count as edits.")))
                        } else if model.assets.isEmpty && !model.filter.isRefined && model.filter.recentlyAdded {
                            ContentUnavailableView(L10n.tr("No Imported Photos"), systemImage: "clock", description: Text(L10n.tr("Photos from this import appear here.")))
                        } else if model.assets.isEmpty {
                            ContentUnavailableView {
                                Label(model.filter.search.isEmpty ? L10n.tr("No Matching Photos") : L10n.tr("No Results for “\(model.filter.search)”"), systemImage: "magnifyingglass")
                            } description: {
                                Text(model.filter.search.isEmpty ? L10n.tr("Try changing your filters.") : L10n.tr("Check the spelling or try a new search."))
                                // Folders are found by what their files say; nothing looks at the pictures.
                                if model.isFolderIndex, !model.filter.search.isEmpty { Text(L10n.tr("Subjects are recognized in a catalog only.")).font(.caption).foregroundStyle(.tertiary) }
                            } actions: {
                                Button(L10n.tr("Clear Filters"), action: model.clearFilters)
                            }
                        } else if model.shownOverview == .map {
                            CatalogMapView(model: model, editor: editor)
                        } else if model.shownOverview == .people || model.showingPersonFaces {
                            PeopleView(model: model, editor: editor, analysis: model.analysis)
                        } else if model.shownOverview == .faces {
                            FaceWallView(model: model, editor: editor, analysis: model.analysis).overlay(alignment: .bottomTrailing) { PeopleModelPrompt() }
                        } else {
                            LibraryGrid(model: model, editor: editor) { gridFocused = true }
                                // Delete moves to the catalog Trash, which is recoverable; originals are untouched.
                                .selectionKeys(focus: $gridFocused, hasSelection: !model.selectedIDs.isEmpty,
                                               selectAll: model.selectAll, deselectAll: model.deselectAll, escapeDeselects: true,
                                               delete: model.filter.area == .trash ? nil : { model.requestMoveToTrash(model.selectedAssets, editor: editor) })
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { gridFocused = true }
        .background(Theme.canvas)
    }
}

/// "At least N stars": click a star to filter, click the active star again to clear.
struct CatalogRatingFilter: View {
    @Binding var minimum: Int
    var body: some View {
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { value in
                Button { minimum = minimum == value ? 0 : value } label: {
                    Image(systemName: minimum >= value ? "star.fill" : "star").font(.system(size: 11))
                        .foregroundStyle(minimum >= value ? Theme.accent : Color.secondary)
                        .frame(width: 16, height: 22).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .help(minimum == value ? L10n.tr("Show all ratings") : (value == 1 ? L10n.tr("Show \(value) star or more") : L10n.tr("Show \(value) stars or more")))
                    .accessibilityLabel((value == 1 ? L10n.tr("\(value) star or more") : L10n.tr("\(value) stars or more")))
                    .accessibilityAddTraits(minimum == value ? .isSelected : [])
            }
        }.accessibilityElement(children: .contain).accessibilityLabel(L10n.tr("Minimum rating"))
    }
}

/// Toggle buttons for review state: picked, unreviewed, rejected.
struct CatalogReviewFilter: View {
    @Binding var review: ReviewState?
    var body: some View {
        HStack(spacing: 2) {
            button(.accepted, title: L10n.tr("Picked"))
            button(.unreviewed, title: L10n.tr("Unflagged"))
            button(.rejected, title: L10n.tr("Rejected"))
        }.accessibilityElement(children: .contain).accessibilityLabel(L10n.tr("Flag"))
    }
    private func button(_ state: ReviewState, title: String) -> some View {
        Button { review = review == state ? nil : state } label: {
            Group {
                if state == .unreviewed {
                    Image(systemName: "flag.slash").font(.system(size: 13))
                        .foregroundStyle(review == state ? Color.primary : Color.secondary.opacity(0.7))
                } else {
                    ReviewFlag(state: state, active: review == state, size: 13)
                }
            }.frame(width: 22, height: 22).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .help(review == state ? L10n.tr("Show All Photos") : L10n.tr("Show Only \(title) Photos"))
            .accessibilityLabel(title).accessibilityAddTraits(review == state ? .isSelected : [])
    }
}

/// What every cell of the grid and the wall does: a click selects, a double-click opens Develop, the last
/// cells load the next page, the context menu, and dragging onto albums. It reads the models only when acted on:
/// observing them redrew every visible cell on any catalog change.
struct LibraryCell: ViewModifier {
    let model: CatalogModel
    let editor: EditorModel
    let asset: CatalogAsset
    /// The grid shows the library, not the Trash or the archive.
    let draggable: Bool
    let focus: () -> Void
    func body(content: Content) -> some View {
        content
            // Pages load as the last rows scroll into view.
            .onAppear { if model.hasMore, model.assets.suffix(CatalogModel.pageSize / 10).contains(where: { $0.id == asset.id }) { model.loadMore() } }
            // One handler: a separate double-tap recognizer delays every single click.
            .onTapGesture {
                focus()
                let event = NSApp.currentEvent
                if (event?.clickCount ?? 1) >= 2 { model.develop(asset, editor: editor); return }
                let modifiers = event?.modifierFlags ?? NSEvent.modifierFlags
                model.select(asset, extending: modifiers.contains(.shift), toggling: modifiers.contains(.command))
            }
            // VoiceOver cannot perform the tap gesture.
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.select(asset) }
            .accessibilityAction(named: L10n.tr("Develop")) { model.develop(asset, editor: editor) }
            .contextMenu { PhotoContextMenu(catalog: model, editor: editor, asset: asset) }
            // Dragging a photo takes it, or the selection it belongs to, to an album.
            .modifier(PhotoDragSource(model: model, asset: asset, libraryArea: draggable))
    }
}

/// A frameless cell: the photo, its name, then flags on the left and ratings on the right.
/// Unset flags and badges appear on hover; rejected photos are dimmed.
struct CatalogTile: View {
    let asset: CatalogAsset
    let previews: PreviewStore?
    let selected: Bool
    /// Present only when the original is not on disk right now.
    var availability: AssetAvailability? = nil
    let rating: Int
    let review: ReviewState
    var label: CatalogLabel? = nil
    let setRating: (Int) -> Void
    let setReview: (ReviewState) -> Void
    var group: GroupBadge? = nil
    /// False in a browsed folder, where photos have no flags or ratings.
    var showsReview = true
    @State private var hovering = false
    /// In the Trash the stars and flag only show what the photo had; nothing invites editing it there.
    private var culling: Bool { asset.inLibrary }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CatalogThumbnail(asset: asset, previews: previews)
                .opacity(review == .rejected && !selected && !hovering ? 0.45 : 1)
                .clipped()
                .selectionRing(selected ? Theme.accent : nil, outside: true)
                .groupBadge(group)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .aspectRatio(4 / 3, contentMode: .fit)
                .overlay(alignment: .topLeading) {
                    // Offline and not-yet-downloaded originals are marked without hovering.
                    if let availability {
                        Image(systemName: availability.isOffline ? "exclamationmark.icloud" : "icloud.and.arrow.down")
                            .font(.caption).foregroundStyle(availability.isOffline ? Theme.warning : Color.secondary).padding(8)
                            .help(availability.isOffline ? L10n.tr("Offline: the original is not reachable from this Mac") : L10n.tr("Downloads from \(asset.locator.storageDescription) when opened"))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if hovering {
                        HStack(spacing: 4) {
                            if asset.thumbnailRenderKey != asset.renderKey {
                                Image(systemName: "arrow.triangle.2.circlepath").help(L10n.tr("The thumbnail updates when you open the photo"))
                            }
                            if asset.latitude != nil && asset.longitude != nil {
                                Image(systemName: "mappin.and.ellipse").help(L10n.tr("Has location"))
                            }
                        }.font(.caption2).foregroundStyle(.secondary).padding(8)
                    }
                }
            HStack(spacing: 5) {
                if asset.isLatent { Image(systemName: "circle.bottomhalf.filled").help(L10n.tr("Latent Image")) }
                if let label { LabelDot(label: label) }
                Text(asset.title.isEmpty ? asset.filename : asset.title).font(.caption).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(selected ? .primary : .secondary)
            }.padding(.top, 4)
            // Narrow tiles shrink the stars, then drop the unset flags, rather than letting the stars run under the flags.
            if showsReview {
                ViewThatFits(in: .horizontal) {
                    footer(flag: 24, star: 18)
                    footer(flag: 20, star: 13)
                    // Narrowest: the flag only when one is set.
                    HStack(spacing: 0) {
                        if review != .unreviewed { reviewButton(review, width: 18) }
                        Spacer(minLength: 0); stars(13)
                    }
                }.buttonStyle(.plain)
            }
        }
            .contentShape(Rectangle()).onHover { hovering = $0 }
            .accessibilityElement(children: .contain).accessibilityLabel(asset.filename)
            .accessibilityValue([rating > 0 ? (rating == 1 ? L10n.tr("\(rating) star") : L10n.tr("\(rating) stars")) : nil, review == .accepted ? L10n.tr("Picked") : review == .rejected ? L10n.tr("Rejected") : nil, label?.title].compactMap { $0 }.joined(separator: ", "))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
    /// A tile's height at `width`: the photo at 4:3, its name, and the flags and stars below. Fixed, so the grid knows
    /// every row's place before showing it.
    static func height(width: CGFloat, showsReview: Bool) -> CGFloat { width * 3 / 4 + (showsReview ? 56 : 28) }
    private func footer(flag: CGFloat, star: CGFloat) -> some View {
        HStack(spacing: 0) {
            reviewButton(.accepted, width: flag)
            reviewButton(.rejected, width: flag)
            Spacer(minLength: 2)
            stars(star)
        }
    }
    private func stars(_ size: CGFloat) -> some View {
        StarRatingDrag(rating: rating, set: setRating, star: size, spacing: size > 14 ? 2 : 1,
                       filledColor: Theme.ink, emptyColor: Theme.ink.opacity(0.3))
            .font(.caption2)
            .fixedSize(horizontal: true, vertical: false)
            .frame(height: 24)
            .disabled(!culling)
    }
    private func reviewButton(_ state: ReviewState, width: CGFloat = 24) -> some View {
        Button { setReview(state) } label: {
            ReviewFlag(state: state, active: review == state, size: 10).frame(width: width, height: 24)
                .opacity((hovering && culling) || review == state ? 1 : 0)
        }.help(review == state ? L10n.tr("Unflag (U)") : state == .accepted ? L10n.tr("Pick (P)") : L10n.tr("Reject (X)"))
            .allowsHitTesting(culling && (hovering || review == state))
            .accessibilityLabel(state == .accepted ? L10n.tr("Pick") : L10n.tr("Reject"))
            .accessibilityAddTraits(review == state ? .isSelected : [])
    }
}

struct CatalogThumbnail: View {
    let assetID: String
    let thumbnailKey: String?
    let previews: PreviewStore?
    /// Told the thumbnail's pixel size once it shows.
    var onImage: ((CGSize) -> Void)? = nil
    var fillsFrame = false
    @State private var image: NSImage?
    /// Sized for several screens of the smallest tiles; cost is the decoded bitmap size.
    @MainActor private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>(); cache.totalCostLimit = 384 * 1024 * 1024; return cache
    }()
    /// Changes with every installed thumbnail, so a re-rendered photo reloads and the cache needs no invalidation.
    private var key: String? { thumbnailKey.map { assetID + "/" + $0 } }
    init(asset: CatalogAsset, previews: PreviewStore?, fillsFrame: Bool = false, onImage: ((CGSize) -> Void)? = nil) {
        assetID = asset.id; thumbnailKey = asset.thumbnailKey; self.previews = previews; self.fillsFrame = fillsFrame; self.onImage = onImage
    }
    init(assetID: String, thumbnailKey: String?, previews: PreviewStore?, fillsFrame: Bool) {
        self.assetID = assetID; self.thumbnailKey = thumbnailKey; self.previews = previews; self.fillsFrame = fillsFrame
    }
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: fillsFrame ? .fill : .fit) }
            else { Image(systemName: "photo").font(.largeTitle).foregroundStyle(.tertiary) }
        }.task(id: key) {
            // The previous image stays visible until its replacement is ready.
            guard let key, let previews else { image = nil; return }
            if let cached = Self.cache.object(forKey: key as NSString) { image = cached; onImage?(cached.size); return }
            guard let data = try? await previews.data(assetID: assetID) else { return }
            let decoded = await Task.detached(priority: .utility) { Self.decode(data) }.value
            guard !Task.isCancelled, let decoded else { return }
            let nsImage = NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height))
            Self.cache.setObject(nsImage, forKey: key as NSString, cost: decoded.bytesPerRow * decoded.height)
            image = nsImage; onImage?(nsImage.size)
        }
    }
    /// Decodes eagerly off the main thread so drawing never waits on JPEG decompression.
    private nonisolated static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}

/// Sort keys and direction; shared by the filter bar and the View menu.
struct CatalogSortItems: View {
    @ObservedObject var model: CatalogModel
    var body: some View {
        Picker(L10n.tr("Sort By"), selection: Binding(get: { model.filter.sort }, set: { model.setSort($0) })) {
            // A browsed folder has no ratings to sort by.
            ForEach(CatalogSort.allCases.filter { !(model.isFolderIndex && $0 == .rating) }, id: \.self) { Text($0.title).tag($0) }
        }.pickerStyle(.inline)
        Divider()
        Picker(L10n.tr("Order"), selection: Binding(get: { model.filter.ascending }, set: { model.setSort(model.filter.sort, ascending: $0) })) {
            Text(model.filter.sort.descendingTitle).tag(false)
            Text(model.filter.sort.ascendingTitle).tag(true)
        }.pickerStyle(.inline)
        Divider()
        Toggle(L10n.tr("Group by Date"), isOn: $model.groupsByDate).disabled(model.filter.sort != .captureDate)
    }
}

/// A calendar for a photo's capture day. The day is the camera's own date with no time zone, so it is read and written
/// as a calendar date in UTC and never shifts with the Mac's time zone.
struct CaptureDayPicker: View {
    @Binding var day: String
    @State private var choosing = false
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        return formatter
    }()
    private var date: Binding<Date> {
        Binding(get: { Self.formatter.date(from: day) ?? Self.formatter.date(from: Self.formatter.string(from: Date()))! },
                set: { day = Self.formatter.string(from: $0) })
    }
    var body: some View {
        Button { choosing = true } label: { Image(systemName: "calendar") }
            .buttonStyle(.borderless).help(L10n.tr("Choose Date"))
            .popover(isPresented: $choosing, arrowEdge: .bottom) {
                // Sized by the calendar itself, so it sits flush in the popover.
                VStack(spacing: 10) {
                    DatePicker(L10n.tr("Date"), selection: date, displayedComponents: .date)
                        .datePickerStyle(.graphical).labelsHidden().focusEffectDisabled()
                        .environment(\.calendar, Self.formatter.calendar).environment(\.timeZone, Self.formatter.timeZone)
                    HStack {
                        Button(L10n.tr("Unknown Date")) { day = ""; choosing = false }.buttonStyle(.textLink).font(.callout).help(L10n.tr("Clear the date"))
                        Spacer()
                        Button(L10n.tr("Done")) { choosing = false }.keyboardShortcut(.defaultAction).controlSize(.small).buttonStyle(.primaryAction)
                    }
                }.padding(12).fixedSize()
            }
    }
}
