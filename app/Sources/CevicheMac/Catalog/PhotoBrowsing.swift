import SwiftUI
import CevicheCore

/// The browsing sequence under the photo in Detail and Compare. Click opens a photo; in Compare,
/// ⌘-click makes it the second photo of a two-photo comparison. Photo shows one row of the wall: photos edge to edge
/// at their finished shape, with only the name and file type over a corner. Square shows framed cells with the name, file type and rating.
struct PhotoFilmstrip: View {
    @ObservedObject var catalog: CatalogModel
    /// Not observed: a slider changes the editor many times a second. The strip follows `chrome`.
    let editor: EditorModel
    @ObservedObject var chrome: EditorMenuState
    /// Clicking a frame focuses the strip, as clicking a cell focuses the grid; ⌘A selects the whole strip only then.
    @FocusState private var focused: Bool
    private var square: Bool { editor.filmstripStyle == .square }
    private var stripHeight: CGFloat { CGFloat(editor.filmstripHeight) }
    /// The row's height inside the strip's padding: a Photo cell's height, or a Square cell's.
    private var rowHeight: CGFloat { stripHeight - 16 }
    /// A Square cell's photo: the row less the name above it and the rating below.
    private var squareSide: CGFloat { max(24, rowHeight - FilmstripSquareCell.chrome) }
    var body: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 4) {
                    ForEach(catalog.browsingAssets) { cell($0).id($0.id) }
                }.padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: stripHeight)
                    .contentShape(Rectangle())
                    .contextMenu {
                        Picker(L10n.tr("Filmstrip Style"), selection: Binding(get: { editor.filmstripStyle }, set: { editor.filmstripStyle = $0 })) {
                            Text(L10n.tr("Photo")).tag(EditorModel.FilmstripStyle.photo)
                            Text(L10n.tr("Square")).tag(EditorModel.FilmstripStyle.square)
                        }
                        if !editor.inFolder { Toggle(L10n.tr("Culling Bar"), isOn: Binding(get: { editor.showCullingBar }, set: { editor.showCullingBar = $0 })) }
                    }
            }.scrollIndicators(.hidden)
                .selectionKeys(focus: $focused, hasSelection: catalog.selectedIDs.count > 1,
                               selectAll: { catalog.selectAllInFilmstrip(editor: editor) }, deselectAll: { catalog.deselectFilmstrip(editor: editor) })
                .onChange(of: catalog.shownAssetID(editor: editor)) { _, id in if let id { withAnimation(.easeOut(duration: 0.2)) { reader.scrollTo(id, anchor: .center) } } }
                .onAppear { if let id = catalog.shownAssetID(editor: editor) { reader.scrollTo(id, anchor: .center) } }
        }.frame(height: stripHeight).background(Theme.panel)
            .disabled(catalog.interactionBusy || editor.busy)
    }
    private func cell(_ asset: CatalogAsset) -> some View {
        let open = catalog.shownAssetID(editor: editor) == asset.id
        let partner = catalog.viewMode == .compare && catalog.compareSource == .twoPhotos && catalog.compareAsset?.id == asset.id
        let selected = catalog.selectedIDs.contains(asset.id) && catalog.selectedIDs.count > 1
        let aspect = CGFloat(catalog.aspect(of: asset))
        let live = catalog.liveThumbnails[asset.id]
        return Group {
            if square {
                FilmstripSquareCell(asset: asset, previews: catalog.previews, live: live, aspect: aspect, side: squareSide, open: open, marked: partner || selected, group: catalog.groupBadge(for: asset))
                    .frame(width: max(squareSide + 2 * FilmstripSquareCell.inset, 104), height: rowHeight)
            } else {
                FilmstripThumbnail(asset: asset, previews: catalog.previews, live: live)
                    .frame(width: rowHeight * aspect, height: rowHeight)
                    .background(Theme.ink.opacity(0.04))
                    .clipped()
                    .overlay(alignment: .topLeading) { FilmstripCaption(filename: asset.filename).padding(3) }
                    .opacity(asset.review == .rejected && !open ? 0.45 : 1)
                    .selectionRing(open ? Theme.accent : partner ? Theme.ink.opacity(0.7) : selected ? Theme.accent.opacity(0.6) : nil)
                    .groupBadge(catalog.groupBadge(for: asset))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            focused = true
            let extending = SelectionClick.extending, toggling = SelectionClick.toggling
            if catalog.viewMode == .compare, toggling, !extending, !open {
                catalog.compareSource = .twoPhotos; catalog.setCompareAsset(asset, editor: editor)
            } else if extending || toggling {
                catalog.filmstripSelect(asset, extending: extending, toggling: toggling)
            } else if !open {
                Task { await catalog.openPhoto(asset, editor: editor, keepSequence: true) }
            }
        }
        .help(partner ? L10n.tr("\(asset.filename) - comparing") : catalog.viewMode == .compare ? L10n.tr("\(asset.filename) - ⌘-click to compare") : asset.filename)
        .accessibilityAddTraits(.isButton).accessibilityLabel(asset.filename)
        .accessibilityAddTraits(open ? .isSelected : [])
        .accessibilityAction { Task { await catalog.openPhoto(asset, editor: editor, keepSequence: true) } }
        .accessibilityAction(named: L10n.tr("Compare")) { catalog.compareSource = .twoPhotos; catalog.setCompareAsset(asset, editor: editor); catalog.show(.compare, editor: editor) }
        .contextMenu { PhotoContextMenu(catalog: catalog, editor: editor, asset: asset) }
        .modifier(PhotoDragSource(model: catalog, asset: asset, libraryArea: catalog.filter.area == .library))
    }
}

/// A filmstrip photo: the open one's edit as it is made, the others' stored thumbnails.
private struct FilmstripThumbnail: View {
    let asset: CatalogAsset
    let previews: PreviewStore?
    let live: NSImage?
    var body: some View {
        if let live { Image(nsImage: live).resizable().aspectRatio(contentMode: .fill) }
        else { CatalogThumbnail(asset: asset, previews: previews, fillsFrame: true) }
    }
}

/// The file type a filmstrip cell shows; a latent image's package extension is too long for a badge.
private func filmstripType(_ name: NSString) -> String {
    name.pathExtension == LatentImage.fileExtension ? L10n.tr("Latent").uppercased() : name.pathExtension.uppercased()
}

/// Which photo of a series a Photo cell is: its name and file type in the corner, or the type alone on a cell too narrow
/// for both.
private struct FilmstripCaption: View {
    let filename: String
    var body: some View {
        let name = filename as NSString, type = filmstripType(name)
        ViewThatFits(in: .horizontal) {
            label { Text(name.deletingPathExtension).font(.system(size: 9, weight: .semibold)); Text(type).font(.system(size: 8, weight: .bold)).opacity(0.7) }
            label { Text(type).font(.system(size: 8, weight: .bold)) }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
    private func label(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 4, content: content).lineLimit(1).fixedSize().foregroundStyle(.white)
            .padding(.horizontal, 4).padding(.vertical, 2).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: Theme.Radius.tag)).environment(\.colorScheme, .dark)
    }
}

/// A Square filmstrip cell: the name and file type on top, the photo fitted in a square, then its flag and rating.
/// The open photo's cell is lit and its photo outlined.
private struct FilmstripSquareCell: View {
    let asset: CatalogAsset
    let previews: PreviewStore?
    let live: NSImage?
    let aspect: CGFloat
    /// The square the photo is fitted in.
    let side: CGFloat
    let open: Bool
    let marked: Bool
    var group: GroupBadge? = nil
    @State private var hovering = false
    static let inset: CGFloat = 6
    /// The height of everything around the photo: the name row, the rating row, their spacing and the padding.
    static let chrome: CGFloat = 13 + 12 + 2 * 4 + 2 * 4
    var body: some View {
        let name = asset.filename as NSString
        let rejected = asset.review == .rejected
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Text(name.deletingPathExtension).font(.system(size: 10, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 2)
                if !name.pathExtension.isEmpty {
                    Text(filmstripType(name)).font(.system(size: 8, weight: .bold)).fixedSize()
                        .padding(.horizontal, 4).padding(.vertical, 2).background(Theme.ink.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.Radius.tag))
                }
            }.foregroundStyle(.secondary).frame(height: 13)
            FilmstripThumbnail(asset: asset, previews: previews, live: live)
                .frame(width: aspect >= 1 ? side : side * aspect, height: aspect >= 1 ? side / aspect : side)
                .clipped()
                .selectionRing(open ? Theme.accent : nil)
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                .groupBadge(group)
                .frame(height: side)
                .opacity(rejected && !open && !hovering ? 0.45 : 1)
            HStack(spacing: 3) {
                if asset.review == .accepted { ReviewFlag(state: .accepted, active: true, size: 9) }
                if rejected { ReviewFlag(state: .rejected, active: true, size: 9) }
                if asset.rating > 0 { Text(String(repeating: "★", count: asset.rating)).foregroundStyle(Theme.accent) }
                if let label = asset.metadata.label { LabelDot(label: label, size: 7) }
            }.font(.system(size: 10, weight: .semibold)).frame(height: 12)
        }
        .padding(.horizontal, Self.inset).padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(open ? Theme.ink.opacity(0.09) : marked ? Theme.ink.opacity(0.06) : hovering ? Theme.ink.opacity(0.04) : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .onHover { hovering = $0 }
    }
}

/// Flags, stars and labels for the open photo, or the photos selected in the filmstrip, between the filmstrip's resize
/// handle and its thumbnails.
struct FilmstripCullingBar: View {
    @ObservedObject var catalog: CatalogModel
    @ObservedObject var editor: EditorModel
    var body: some View {
        HStack(spacing: 12) {
            if !catalog.isFolderIndex { PhotoRatingControls(catalog: catalog, editor: editor) }
            Rule(.vertical).frame(height: 16)
            PhotoLabelControls(catalog: catalog, targets: catalog.cullingTargets(editor: editor))
        }
        .font(.system(size: 13)).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity).frame(height: 30).background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.ink.opacity(0.06)).frame(height: 1) }
    }
}

/// The filmstrip's top edge. Dragging moves only a line over the photo; the strip takes the new height, and reflows its
/// cells once, when the drag ends. Double-click restores the default height.
struct FilmstripResizeHandle: View {
    @Binding var height: Double
    var range = EditorModel.filmstripHeights
    /// What a double-click restores.
    var defaultHeight = EditorModel.defaultFilmstripHeight
    /// How far the pointer has moved up since the drag began.
    @State private var lift: CGFloat?
    @State private var hovering = false
    private func target(_ lift: CGFloat) -> Double {
        min(range.upperBound, max(range.lowerBound, height + Double(lift)))
    }
    var body: some View {
        Rectangle().fill(Theme.ink.opacity(hovering || lift != nil ? 0.2 : 0.08)).frame(height: 1)
            .frame(maxWidth: .infinity).frame(height: 5).background(Theme.panel).contentShape(Rectangle())
            .overlay(alignment: .top) {
                if let lift {
                    Rectangle().fill(Theme.accent).frame(height: 2)
                        .offset(y: CGFloat(height - target(lift))).allowsHitTesting(false)
                }
            }
            .onHover(perform: setHovering)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { lift = -$0.translation.height }
                .onEnded { height = target(-$0.translation.height); lift = nil })
            .onTapGesture(count: 2) { height = defaultHeight }
            .help(L10n.tr("Drag to resize the filmstrip - double-click to reset"))
            .onDisappear { setHovering(false) }
            .accessibilityHidden(true)
    }
    /// Balances the cursor stack, including when the strip hides under the pointer.
    private func setHovering(_ inside: Bool) {
        guard inside != hovering else { return }
        hovering = inside
        if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
    }
}

/// Scoped to our window. Text fields and native controls keep their keyboard behavior.
/// The secondary window has its own monitor: G and D switch its view, and the grid and culling keys
/// follow what it shows; the editing keys belong to the main window.
struct PhotoBrowsingKeys: NSViewRepresentable {
    @ObservedObject var catalog: CatalogModel
    @ObservedObject var editor: EditorModel
    var secondary = false
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let secondary = secondary
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak view, weak catalog, weak editor] event in
            // Release must win even if focus or modifiers changed while a viewing key was held.
            if event.type == .keyUp {
                if !secondary, event.keyCode == Key.backslash, editor?.peekingOriginal == true {
                    editor?.peekingOriginal = false; return nil
                }
                if !secondary, event.keyCode == Key.space, let editor, editor.spaceHeld {
                    let canZoom = !editor.spaceDragged && event.window === view?.window && event.window?.attachedSheet == nil
                        && !(event.window?.firstResponder is NSTextView) && !(event.window?.firstResponder is NSControl)
                        && catalog?.viewMode == .detail && !editor.busy
                    editor.spaceHeld = false; editor.spaceDragged = false
                    if canZoom { editor.toggleImageFit() }
                    return nil
                }
                return event
            }
            guard let view, let window = view.window, let catalog, let editor, event.window === window,
                  event.window?.attachedSheet == nil, editor.editCopyDraft == nil,
                  !(event.window?.firstResponder is NSTextView), !(event.window?.firstResponder is NSTextField) else { return event }
            // The grid in this window, or the photo; the main window's Compare counts as the photo.
            let inGrid = secondary ? catalog.secondaryViewMode == .grid : catalog.showingLibrary
            // Tab in Detail hides every panel to leave only the photo, and brings them back, as in other RAW editors; it comes
            // before the focused-control check so a focused slider does not take it.
            if !secondary, event.keyCode == Key.tab, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
               !catalog.showingLibrary, catalog.viewMode == .detail {
                if !event.isARepeat { withAnimation(.easeInOut(duration: 0.15)) { catalog.panelsHidden.toggle() } }
                return nil
            }
            if !secondary, !catalog.showingLibrary, catalog.viewMode == .detail, editor.preview != nil,
               !editor.busy, !catalog.interactionBusy, NSEvent.pressedMouseButtons == 0,
               !(event.window?.firstResponder is NSControl) {
                let heldModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
                if event.keyCode == Key.backslash, heldModifiers.isEmpty, editor.originalPreview != nil {
                    if !event.isARepeat { editor.peekingOriginal = true }
                    return nil
                }
                if event.keyCode == Key.backslash, heldModifiers == .shift {
                    if !event.isARepeat { editor.comparing.toggle() }
                    return nil
                }
                if event.keyCode == Key.space, heldModifiers.isEmpty {
                    // Resolve a tap on release, so Space-drag can pan without changing zoom.
                    if !event.isARepeat { editor.spaceHeld = true; editor.spaceDragged = false }
                    return nil
                }
            }
            // Focused sliders and buttons keep their arrow and space keys; Escape still dismisses a tool or clears the selection,
            // and Return still finishes the crop.
            let finishesCrop = !secondary && [Key.returnKey, Key.enter].contains(event.keyCode) && !catalog.showingLibrary && editor.toolTab == .crop
            if event.window?.firstResponder is NSControl, event.keyCode != Key.escape, !finishesCrop { return event }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control])
            // ⌥C is Compare everywhere, as in other RAW editors; plain C is the Color panel in Detail.
            if !secondary, modifiers == .option, event.charactersIgnoringModifiers?.lowercased() == "c" || event.keyCode == Key.c {
                if !event.isARepeat { catalog.show(.compare, editor: editor) }; return nil
            }
            if !secondary, !inGrid, editor.toolTab == .crop, !editor.busy, !catalog.interactionBusy, modifiers.isEmpty || modifiers == .shift {
                // `modifiers` leaves Shift out, so ⇧O reads it from the event, as the canvas does.
                if event.charactersIgnoringModifiers?.lowercased() == "x", modifiers.isEmpty { if !event.isARepeat { editor.swapCropAspect() }; return nil }
                if event.charactersIgnoringModifiers?.lowercased() == "o" {
                    if !event.isARepeat { editor.cycleCropOverlay(reverseOrientation: event.modifierFlags.contains(.shift)) }
                    return nil
                }
            }
            // A toggles Visualize Spots while reviewing dust, as in other RAW editors.
            if !secondary, !inGrid, editor.reviewingDust, modifiers.isEmpty, event.charactersIgnoringModifiers?.lowercased() == "a" {
                if !event.isARepeat { editor.dustVisualize.toggle() }; return nil
            }
            if !secondary, !inGrid, editor.toolTab == .crop, editor.cropDrawingGuide, !editor.busy, !catalog.interactionBusy,
               modifiers.isEmpty, event.keyCode == Key.delete || event.keyCode == Key.forwardDelete { editor.deleteSelectedGuide(); return nil }
            // ⇧R makes another fill for the selected Remove strokes; / stays with the filmstrip.
            if !secondary, !inGrid, editor.removing, !editor.selectedStrokes.isEmpty, !editor.busy,
               modifiers.isEmpty, event.modifierFlags.contains(.shift), event.charactersIgnoringModifiers?.lowercased() == "r" {
                if !event.isARepeat { editor.refreshRetouch(editor.selectedRetouchIDs) }
                return nil
            }
            guard modifiers.isEmpty else { return event }
            guard !editor.busy, !catalog.interactionBusy else { return event }
            // Develop's single letters that are not panels, ahead of the case-insensitive panel letters: ⇧I Capture Info,
            // Z fit or 2×, W the white balance eyedropper on a RAW, O the mask overlay in Masks (Crop's O comes earlier).
            if !secondary, !catalog.showingLibrary, catalog.viewMode == .detail, editor.hasImage,
               let key = event.charactersIgnoringModifiers?.lowercased() {
                let shifted = event.modifierFlags.contains(.shift)
                switch (key, shifted) {
                case ("i", true): if !event.isARepeat { editor.showCaptureOverlay.toggle() }; return nil
                case ("z", false): if !event.isARepeat { editor.toggleImageFit() }; return nil
                case ("w", false) where editor.info?.isRAW == true:
                    if !event.isARepeat, editor.eyedropper != .whiteBalance { editor.toggleEyedropper(.whiteBalance) }
                    return nil
                case ("o", false) where editor.toolTab == .masks && editor.showInspector:
                    if !event.isARepeat { editor.showMaskOverlay.toggle() }; return nil
                default: break
                }
            }
            // Culling keys, as in most photo managers: 0–5 rate, P accept, X reject, U clears review, 6–9 label.
            if let key = event.charactersIgnoringModifiers?.lowercased(), !(inGrid && catalog.filter.area != .library) {
                let targets = catalog.cullingTargets(editor: editor)
                if !targets.isEmpty {
                    var rating: Int?, review: ReviewState?
                    switch key {
                    case "0", "1", "2", "3", "4", "5": rating = Int(key)
                    case "p": review = .accepted
                    case "x": review = .rejected
                    case "u": review = .unreviewed
                    default: break
                    }
                    if let label = CatalogLabel(key: key) {
                        if !event.isARepeat { Task { await catalog.toggleLabel(label, on: targets) } }
                        return nil
                    }
                    if rating != nil || review != nil {
                        Task { await catalog.setQuickMetadata(targets, rating: rating, review: review) }
                        return nil
                    }
                }
            }
            // G grid, D detail, as in other RAW editors; C opens Compare from the grid, where no Color panel takes the key.
            // G in the grid switches between the tiles and the wall.
            if event.charactersIgnoringModifiers?.lowercased() == "g" { if !event.isARepeat { catalog.pressGrid(secondary: secondary, editor: editor) }; return nil }
            if let key = event.charactersIgnoringModifiers?.lowercased(), let mode: CatalogModel.ViewMode =
                key == "d" ? .detail : key == "c" && inGrid && !secondary ? .compare : nil {
                if event.isARepeat { return nil }
                if secondary { catalog.showSecondary(mode, editor: editor) } else { catalog.show(mode, editor: editor) }
                return nil
            }
            // Develop's tool panels: one letter each, the conventional ones (C, H, M, I); the active one's key hides the inspector.
            if !secondary, !catalog.showingLibrary, editor.hasImage, let key = event.charactersIgnoringModifiers?.lowercased(), key.count == 1,
               let tab = ToolTab.allCases.first(where: { String($0.key) == key }) {
                if !event.isARepeat { editor.toggleTool(tab) }; return nil
            }
            // The filmstrip toggles with / in Detail and Compare, as in other RAW editors.
            if !secondary, event.keyCode == Key.slash, !catalog.showingLibrary, catalog.shownAssetID(editor: editor) != nil {
                if !event.isARepeat { editor.showFilmstrip.toggle() }; return nil
            }
            // MapKit retains its native arrow-key camera controls.
            if inGrid && !secondary && catalog.shownOverview == .map,
               [Key.left, Key.right, Key.down, Key.up, Key.home, Key.end].contains(event.keyCode) { return event }
            // Held keys repeat only for moving through photos; Escape, Delete and Return act once per press.
            switch event.keyCode {
            case Key.escape where !secondary && !catalog.showingLibrary:
                // Escape only dismisses tools in Develop (an armed eyedropper, targeted adjustment, gradient or guide tool, then the
                // Crop, Remove or Masks panel); it never returns to the Library.
                guard event.isARepeat || editor.dismissTool() else { return event }
            // The selected mask, retouch strokes and dust spots: not while a selection list such as the filmstrip has focus, where Delete
            // belongs to the list.
            case Key.delete where !secondary && !catalog.showingLibrary && editor.toolTab == .masks && editor.selectedMaskID != nil && !SelectionListFocus.active,
                 Key.forwardDelete where !secondary && !catalog.showingLibrary && editor.toolTab == .masks && editor.selectedMaskID != nil && !SelectionListFocus.active:
                // Delete removes the selected mask component, or the mask itself.
                if !event.isARepeat { editor.deleteSelectedMaskOrComponent() }
            case Key.delete where !secondary && !catalog.showingLibrary && editor.removing && !editor.selectedRetouchIDs.isEmpty && !SelectionListFocus.active,
                 Key.forwardDelete where !secondary && !catalog.showingLibrary && editor.removing && !editor.selectedRetouchIDs.isEmpty && !SelectionListFocus.active:
                // Delete removes the selected strokes, and dust spots from the review.
                if !event.isARepeat { editor.deleteSelectedRetouch() }
            case Key.left where inGrid, Key.right where inGrid, Key.down where inGrid, Key.up where inGrid, Key.home where inGrid, Key.end where inGrid:
                let move: CatalogGridMove
                switch event.keyCode {
                case Key.left: move = .left
                case Key.right: move = .right
                case Key.down: move = .down
                case Key.up: move = .up
                case Key.home: move = .first
                default: move = .last
                }
                catalog.moveLibrarySelection(move, extending: event.modifierFlags.contains(.shift))
            case Key.returnKey where finishesCrop, Key.enter where finishesCrop:
                // Return closes the Crop tool with the crop as shown: Done.
                if !event.isARepeat { editor.finishCrop() }
            case Key.space, Key.returnKey, Key.enter:
                // Space or Return opens Develop, like a double-click.
                if inGrid {
                    guard let asset = catalog.selected, asset.inLibrary else { return event }
                    if !event.isARepeat { catalog.develop(asset, editor: editor) }
                } else { return event }
            case Key.left where !inGrid && catalog.shownAssetID(editor: editor) != nil, Key.right where !inGrid && catalog.shownAssetID(editor: editor) != nil:
                // The filmstrip sequence; sliders and text fields keep their arrow keys (filtered above).
                Task { await catalog.navigate(event.keyCode == Key.left ? -1 : 1, editor: editor) }
            default: return event
            }
            return nil
        }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }; coordinator.monitor = nil }
    final class Coordinator { var monitor: Any? }
    /// Virtual key codes used by the monitor.
    private enum Key {
        static let c: UInt16 = 8, tab: UInt16 = 48, returnKey: UInt16 = 36, backslash: UInt16 = 42, slash: UInt16 = 44, space: UInt16 = 49, delete: UInt16 = 51, escape: UInt16 = 53
        static let enter: UInt16 = 76, home: UInt16 = 115, forwardDelete: UInt16 = 117, end: UInt16 = 119
        static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
    }
}
