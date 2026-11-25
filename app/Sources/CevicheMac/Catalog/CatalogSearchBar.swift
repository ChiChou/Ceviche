import SwiftUI
import AppKit
import CevicheCore

/// Title-bar search: a field in the middle of the header with a filter button beside it
/// that drops down the rating, flag, label, settings, flash, orientation and faces filters. The filters apply in every view. Exact tags, settings
/// and those filters show in the field as chips before the typed text; the search text still holds the tags and settings.
struct CatalogSearchBar: View {
    @ObservedObject var model: CatalogModel
    @FocusState private var searchFocused: Bool
    @State private var showingFilters = false
    @State private var suggestions: [CatalogSearchSuggestion] = []
    @State private var selectedIndex: Int?
    @State private var dismissedQuery: String?
    /// What the shown suggestions were looked up for.
    @State private var suggestionsRequest: Request?
    @State private var scales = Scales()
    @State private var tokens: [CatalogSearchToken] = []
    @State private var text = ""
    /// The tags offered while the field is empty: the most used, or all of them.
    @State private var tags: [CatalogSearchSuggestion] = []
    @State private var allTags = false
    /// Watches for Backspace while the field is focused; the field's editor takes the key before SwiftUI sees it.
    @State private var backspaceMonitor: Any?
    private enum Chip: Hashable { case rating, review, label, focal, exposure(CatalogExposureScale), flash, orientation, faces, token(CatalogSearchToken) }
    /// The ticks of the focal-length and exposure scales, from the catalog's own range of each.
    private struct Scales {
        var focal: [CatalogScaleTick] = []
        var exposure: [CatalogExposureScale: [CatalogScaleTick]] = [:]
    }
    private struct Request: Hashable {
        let query: String
        let root: URL?
        let area: CatalogArea
        let generation: Int64
        let focused: Bool
        func sameQuery(as other: Request) -> Bool {
            query == other.query && root == other.root && area == other.area && focused == other.focused
        }
    }
    private struct TagsRequest: Hashable {
        let root: URL?
        let area: CatalogArea
        let generation: Int64
        let all: Bool
        let focused: Bool
    }
    private struct ScalesRequest: Hashable {
        let root: URL?
        let area: CatalogArea
        let generation: Int64
        let photos: Int
    }
    private var request: Request {
        Request(query: text, root: model.store?.root, area: model.filter.area,
                generation: model.indexing.generation, focused: searchFocused)
    }
    private var showingSuggestions: Bool {
        searchFocused && dismissedQuery != text && !suggestions.isEmpty
    }
    private var showingTags: Bool {
        searchFocused && text.isEmpty && dismissedQuery != text && !offeredTags.isEmpty
    }
    /// The tags not already in the search.
    private var offeredTags: [CatalogSearchSuggestion] {
        tags.filter { tag in !tokens.contains { $0.source == tag.source && $0.label.caseInsensitiveCompare(tag.tag) == .orderedSame } }
    }
    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                GeometryReader { geometry in
                    ScrollViewReader { scroller in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                ForEach(chips, id: \.self) { chip($0) }
                                field.frame(minWidth: 80).id("field")
                            }.frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .leading)
                        }
                        .onChange(of: chips.count) { scroller.scrollTo("field", anchor: .trailing) }
                    }
                }
                if !chips.isEmpty || !text.isEmpty {
                    Button(action: clearSearch) { Label(L10n.tr("Clear Search"), systemImage: "xmark.circle.fill").labelStyle(.iconOnly) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8).frame(height: 26)
            .background(Theme.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .frame(maxWidth: 420)
            .overlay(alignment: .topLeading) {
                if showingSuggestions {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.tr("Suggestions")).font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 4)
                        ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                            Button { accept(suggestion) } label: {
                                HStack {
                                    Image(systemName: suggestion.source.symbol).foregroundStyle(.secondary).frame(width: 16)
                                        .help(suggestion.source.title)
                                    Text(suggestion.tag).lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(suggestion.photoCount.formatted()).foregroundStyle(.secondary).monospacedDigit()
                                }.font(.system(size: 12)).padding(.horizontal, 8).padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                    .background(selectedIndex == index ? Theme.accent.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                            }.buttonStyle(.plain)
                                .accessibilityLabel((suggestion.photoCount == 1 ? L10n.tr("\(suggestion.tag), \(suggestion.photoCount) photo") : L10n.tr("\(suggestion.tag), \(suggestion.photoCount) photos")))
                                .accessibilityAddTraits(selectedIndex == index ? .isSelected : [])
                        }
                    }.padding(5).fixedSize(horizontal: false, vertical: true)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.hairline))
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                        .offset(y: 32)
                        .accessibilityElement(children: .contain).accessibilityLabel(L10n.tr("Search suggestions"))
                } else if showingTags {
                    tagPanel.offset(y: 32)
                }
            }
            Button { showingFilters.toggle() } label: {
                Image(systemName: model.filter.isRefined ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .font(.system(size: 15)).frame(width: 26, height: 26).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(model.filter.isRefined ? Theme.accent : .secondary)
                .help(model.filter.isRefined ? L10n.tr("Filters are on") : L10n.tr("Filters"))
                .accessibilityLabel(L10n.tr("Filters")).accessibilityAddTraits(model.filter.isRefined ? .isSelected : [])
                .popover(isPresented: $showingFilters, arrowEdge: .bottom) { filters }
        }
        // Ready before the filters open, so the popover doesn't change size once shown.
        .task(id: ScalesRequest(root: model.store?.root, area: model.filter.area, generation: model.indexing.generation, photos: model.total + model.trashCount + model.archiveCount)) {
            guard let store = model.store else { scales = Scales(); return }
            let area = model.filter.area
            var loaded = Scales()
            loaded.focal = (try? await store.focalRange(area: area)).map { CatalogFocalFilter.ticks(from: $0).map(\.scaleTick) } ?? []
            for scale in CatalogExposureScale.allCases {
                loaded.exposure[scale] = (try? await store.exposureRange(scale, area: area)).map { scale.ticks(from: $0) } ?? []
            }
            scales = loaded
        }
        .onChange(of: model.searchFocusRequest) { searchFocused = true }
        .onAppear { (tokens, text) = CatalogSearchToken.split(model.filter.search) }
        // Changed somewhere else (Clear Filters, a saved view): the field reads it again.
        .onChange(of: model.filter.search) {
            if model.filter.search != composed { (tokens, text) = CatalogSearchToken.split(model.filter.search) }
        }
        .onChange(of: text) {
            suggestions = []; selectedIndex = nil
            if dismissedQuery != text { dismissedQuery = nil }
            // A finished term (a space after it) that is a tag or a setting becomes a chip.
            if text.last?.isWhitespace == true {
                let (found, rest) = CatalogSearchToken.split(text)
                if !found.isEmpty { tokens += found; text = rest.isEmpty ? "" : rest + " " }
            }
            write()
        }
        .onChange(of: tokens) { write() }
        .onChange(of: searchFocused) {
            if !searchFocused { suggestions = []; selectedIndex = nil }; dismissedQuery = nil
            if let backspaceMonitor { NSEvent.removeMonitor(backspaceMonitor); self.backspaceMonitor = nil }
            // Backspace in an empty field takes the last chip.
            if searchFocused {
                backspaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard event.keyCode == 51, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                          text.isEmpty, let last = chips.last else { return event }
                    remove(last); return nil
                }
            }
        }
        .onDisappear { if let backspaceMonitor { NSEvent.removeMonitor(backspaceMonitor) } }
        // Loaded only while the field is focused; the shown list stays until a fresh one replaces it.
        .task(id: TagsRequest(root: model.store?.root, area: model.filter.area, generation: model.indexing.generation, all: allTags, focused: searchFocused)) {
            guard searchFocused, let store = model.store else { return }
            let found = (try? await store.popularTags(area: model.filter.area, limit: allTags ? nil : 40)) ?? []
            if !Task.isCancelled, found != tags { tags = found }
        }
        .task(id: request) {
            let snapshot = request
            // Only the catalog changed (an import, new tags): the open list stays up until the fresh one replaces it,
            // instead of closing and reopening on every imported page.
            if suggestionsRequest?.sameQuery(as: snapshot) != true { suggestions = []; selectedIndex = nil }
            suggestionsRequest = snapshot
            guard snapshot.focused, !snapshot.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  dismissedQuery != snapshot.query, let store = model.store else { return }
            do {
                try await Task.sleep(for: .milliseconds(120))
                let found = try await store.searchSuggestions(for: snapshot.query, area: snapshot.area)
                guard !Task.isCancelled, request == snapshot, dismissedQuery != snapshot.query else { return }
                guard found != suggestions else { return }
                // The highlighted suggestion stays highlighted when a fresh list still has it.
                let selectedID = selectedIndex.map { suggestions[$0].id }
                suggestions = found
                selectedIndex = selectedID.flatMap { id in found.firstIndex { $0.id == id } }
            } catch { /* Suggestions are optional; typing and the regular search stay available. */ }
        }
    }
    private func dismiss() { dismissedQuery = text; suggestions = []; selectedIndex = nil }
    private func accept(_ suggestion: CatalogSearchSuggestion) {
        // The space after it makes the picked tag a chip.
        text = suggestion.completion + " "
        dismiss()
    }
    private var composed: String { CatalogSearchToken.search(tokens, text: text.trimmingCharacters(in: .whitespaces)) }
    private func write() { if model.filter.search != composed { model.filter.search = composed } }
    private func clearSearch() {
        tokens = []; text = ""
        model.filter.minimumRating = 0; model.filter.review = nil; model.filter.label = nil; model.filter.focalLength = nil
        model.filter.aperture = nil; model.filter.shutter = nil; model.filter.iso = nil
        model.filter.flash = nil; model.filter.orientation = nil; model.filter.faces = nil
    }
    private var chips: [Chip] {
        var chips: [Chip] = []
        if model.filter.minimumRating > 0 { chips.append(.rating) }
        if model.filter.review != nil { chips.append(.review) }
        if model.filter.label != nil { chips.append(.label) }
        if model.filter.focalLength != nil { chips.append(.focal) }
        chips += CatalogExposureScale.allCases.filter { model.filter[$0] != nil }.map(Chip.exposure)
        if model.filter.flash != nil { chips.append(.flash) }
        if model.filter.orientation != nil { chips.append(.orientation) }
        if model.filter.faces != nil { chips.append(.faces) }
        return chips + tokens.map(Chip.token)
    }
    private func remove(_ chip: Chip) {
        switch chip {
        case .rating: model.filter.minimumRating = 0
        case .review: model.filter.review = nil
        case .label: model.filter.label = nil
        case .focal: model.filter.focalLength = nil
        case .exposure(let scale): model.filter[scale] = nil
        case .flash: model.filter.flash = nil
        case .orientation: model.filter.orientation = nil
        case .faces: model.filter.faces = nil
        case .token(let token): tokens.removeAll { $0 == token }
        }
    }
    private var field: some View {
        TextField(chips.isEmpty ? L10n.tr("Search") : "", text: $text)
            .accessibilityLabel(L10n.tr("Search"))
            .help(L10n.tr("Search text, places, cameras and lenses, or settings such as f/1.4, 35mm, 1/250s, iso>3200"))
            .textFieldStyle(.plain).focused($searchFocused)
            .onKeyPress(.downArrow) { moveSelection(1) }
            .onKeyPress(.upArrow) { moveSelection(-1) }
            .onKeyPress(.return) {
                guard showingSuggestions else { return .ignored }
                if let selectedIndex { accept(suggestions[selectedIndex]) } else { dismiss() }
                return .handled
            }
            .onKeyPress(.tab) {
                guard showingSuggestions else { return .ignored }
                accept(suggestions[selectedIndex ?? 0]); return .handled
            }
            .onKeyPress(.escape) {
                guard showingSuggestions || showingTags else { return .ignored }
                dismiss(); return .handled
            }
    }
    @ViewBuilder private func chip(_ chip: Chip) -> some View {
        switch chip {
        case .rating:
            let value = model.filter.minimumRating
            CatalogSearchChip(symbol: "star.fill", label: "\(value)+", help: value == 1 ? L10n.tr("\(value) star or more") : L10n.tr("\(value) stars or more")) { remove(chip) }
        case .review:
            let review = model.filter.review ?? .unreviewed
            CatalogSearchChip(symbol: review == .accepted ? "flag.fill" : review == .rejected ? "xmark.square" : "flag.slash",
                              label: review == .accepted ? L10n.tr("Picked") : review == .rejected ? L10n.tr("Rejected") : L10n.tr("Unflagged"),
                              help: L10n.tr("Flag")) { remove(chip) }
        case .focal:
            let range = model.filter.focalLength ?? 0...0
            CatalogSearchChip(symbol: "scope", label: CatalogFocalFilter.label(range), help: L10n.tr("Focal length")) { remove(chip) }
        case .exposure(let scale):
            CatalogSearchChip(symbol: scale.symbol, label: scale.label(model.filter[scale] ?? 0...0), help: scale.title) { remove(chip) }
        case .label:
            let label = model.filter.label ?? .red
            CatalogSearchChip(symbol: "circle.fill", tint: label.color, label: label.title, help: L10n.tr("Label")) { remove(chip) }
        case .flash:
            CatalogSearchChip(symbol: model.filter.flash == false ? "bolt.slash" : "bolt.fill", label: L10n.tr("Flash"), help: L10n.tr("Flash")) { remove(chip) }
        case .orientation:
            let orientation = model.filter.orientation ?? .landscape
            CatalogSearchChip(symbol: orientation.symbol, label: orientation.title, help: L10n.tr("Orientation")) { remove(chip) }
        case .faces:
            let faces = model.filter.faces ?? .some
            CatalogSearchChip(symbol: faces.symbol, label: faces.title, help: L10n.tr("Faces")) { remove(chip) }
        case .token(let token):
            CatalogSearchChip(symbol: token.source.symbol, label: token.label, help: token.source.title) { remove(chip) }
        }
    }
    private var tagPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(allTags ? L10n.tr("All Tags") : L10n.tr("Popular Tags")).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button(allTags ? L10n.tr("Popular") : L10n.tr("All")) { allTags.toggle() }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Theme.accent)
            }.padding(.horizontal, 3)
            ScrollView {
                TagFlow(spacing: 4) {
                    ForEach(offeredTags) { tag in
                        Button { if let token = CatalogSearchToken(tag.completion) { tokens.append(token) } } label: {
                            Text(verbatim: tag.tag).lineLimit(1).font(.system(size: 11))
                                .padding(.horizontal, 7).frame(height: 20)
                                .background(Theme.ink.opacity(tag.source == .keyword ? 0.14 : 0.07), in: Capsule())
                                .contentShape(Capsule())
                        }.buttonStyle(.plain)
                            .help(tag.source.title + " · " + tag.photoCount.formatted())
                            .accessibilityLabel(tag.photoCount == 1 ? L10n.tr("\(tag.tag), \(tag.photoCount) photo") : L10n.tr("\(tag.tag), \(tag.photoCount) photos"))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 260)
        }.padding(8).fixedSize(horizontal: false, vertical: true)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.hairline))
            .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
            .accessibilityElement(children: .contain).accessibilityLabel(L10n.tr("Tags"))
    }
    private func moveSelection(_ delta: Int) -> KeyPress.Result {
        guard showingSuggestions else { return .ignored }
        selectedIndex = ((selectedIndex ?? (delta > 0 ? -1 : 0)) + delta + suggestions.count) % suggestions.count
        return .handled
    }
    private var filters: some View {
        VStack(spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
                // A browsed folder is filtered by what its files say, not by ratings, flags or labels.
                if !model.isFolderIndex {
                    GridRow {
                        rowTitle(L10n.tr("Rating"))
                        CatalogRatingFilter(minimum: $model.filter.minimumRating)
                    }
                    GridRow {
                        rowTitle(L10n.tr("Flag"))
                        CatalogReviewFilter(review: $model.filter.review)
                    }
                    GridRow {
                        rowTitle(L10n.tr("Label"))
                        CatalogLabelFilter(label: $model.filter.label)
                    }
                }
                if scales.focal.count > 1 {
                    GridRow(alignment: .top) {
                        rowTitle(L10n.tr("Focal")).padding(.top, 13)
                        CatalogScaleFilter(ticks: scales.focal, range: $model.filter.focalLength, title: L10n.tr("Focal length (35 mm equivalent)"), describe: CatalogFocalFilter.label)
                            .help(L10n.tr("Focal length (35 mm equivalent)"))
                    }
                }
                ForEach(CatalogExposureScale.allCases, id: \.self) { scale in
                    if let ticks = scales.exposure[scale], ticks.count > 1 {
                        GridRow(alignment: .top) {
                            rowTitle(scale.title).padding(.top, 13)
                            CatalogScaleFilter(ticks: ticks, range: $model.filter[scale], title: scale.title, describe: scale.label)
                        }
                    }
                }
                GridRow {
                    rowTitle(L10n.tr("Flash"))
                    CatalogFilterToggles(options: [true], selection: $model.filter.flash, title: L10n.tr("Flash")) { _ in
                        (L10n.tr("Flash"), "bolt.fill")
                    }
                }
                GridRow {
                    rowTitle(L10n.tr("Orientation"))
                    CatalogFilterToggles(options: CatalogOrientation.allCases, selection: $model.filter.orientation, title: L10n.tr("Orientation")) {
                        ($0.title, $0.symbol)
                    }
                }
                // Faces come from background tagging, which browsed folders don't have.
                if !model.isFolderIndex {
                    GridRow {
                        rowTitle(L10n.tr("Faces"))
                        CatalogFilterToggles(options: CatalogFaces.allCases, selection: $model.filter.faces, title: L10n.tr("Faces")) {
                            ($0.title, $0.symbol)
                        }
                    }
                }
            }
            // Always laid out: an open popover grows over the title bar instead of downwards.
            Button(L10n.tr("Clear Filters"), action: model.clearFilters).buttonStyle(.secondaryAction).controlSize(.small).help(L10n.tr("Clear Filters (⌥⌘F)"))
                .disabled(!model.filter.isRefined)
                .frame(maxWidth: .infinity)
        }.font(.system(size: 11)).padding(14).frame(width: 300)
    }
    private func rowTitle(_ title: String) -> some View {
        Text(title).foregroundStyle(.secondary).fixedSize().gridColumnAlignment(.leading)
    }
}

/// Icon buttons of which at most one is on, like the flag filter's: a click turns one on, or off again.
private struct CatalogFilterToggles<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value?
    let title: String
    let look: (Value) -> (title: String, symbol: String)
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let (name, symbol) = look(option), on = selection == option
                Button { selection = on ? nil : option } label: {
                    Image(systemName: symbol).font(.system(size: 13))
                        .foregroundStyle(on ? Theme.accent : Color.secondary.opacity(0.7))
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .help(name)
                    .accessibilityLabel(name).accessibilityAddTraits(on ? .isSelected : [])
            }
        }.accessibilityElement(children: .contain).accessibilityLabel(title)
    }
}

/// The five labels as dots, at most one on: a click shows only that label's photos, or all again.
private struct CatalogLabelFilter: View {
    @Binding var label: CatalogLabel?
    var body: some View {
        HStack(spacing: 2) {
            ForEach(CatalogLabel.allCases, id: \.self) { option in
                let on = label == option
                Button { label = on ? nil : option } label: {
                    ZStack {
                        if on { Circle().strokeBorder(Theme.ink.opacity(0.8), lineWidth: 1.5).frame(width: 18, height: 18) }
                        LabelDot(label: option, size: 12).opacity(label == nil || on ? 1 : 0.55)
                    }.frame(width: 22, height: 22).contentShape(Rectangle())
                }.buttonStyle(.plain).help(option.title)
                    .accessibilityAddTraits(on ? .isSelected : [])
            }
        }.accessibilityElement(children: .contain).accessibilityLabel(L10n.tr("Label"))
    }
}

/// One filter in the search field, with a button that removes it.
private struct CatalogSearchChip: View {
    let symbol: String
    var tint = Theme.accent
    let label: String
    let help: String
    let remove: () -> Void
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 9)).foregroundStyle(tint)
            Text(verbatim: label).lineLimit(1).truncationMode(.middle).frame(maxWidth: 150, alignment: .leading).fixedSize(horizontal: true, vertical: false)
            Button(action: remove) { Image(systemName: "xmark").font(.system(size: 7, weight: .bold)).frame(width: 12, height: 12).contentShape(Rectangle()) }
                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel(L10n.tr("Remove \(label)"))
        }
        .font(.system(size: 11)).padding(.leading, 6).padding(.trailing, 3).frame(height: 18)
        .background(Theme.accent.opacity(0.16), in: Capsule())
        .help(help)
        .accessibilityElement(children: .contain).accessibilityLabel("\(help): \(label)")
    }
}

private extension CatalogExposureScale {
    var title: String {
        switch self {
        case .aperture: L10n.tr("Aperture")
        case .shutter: L10n.tr("Shutter")
        case .iso: "ISO"
        }
    }
    var symbol: String {
        switch self {
        case .aperture: "f.cursive"
        case .shutter: "timer"
        case .iso: "sun.max"
        }
    }
}

private extension CatalogOrientation {
    var title: String {
        switch self {
        case .landscape: L10n.tr("Landscape", context: "orientation")
        case .portrait: L10n.tr("Portrait", context: "orientation")
        case .square: L10n.tr("Square", context: "orientation")
        }
    }
    var symbol: String {
        switch self {
        case .landscape: "rectangle"
        case .portrait: "rectangle.portrait"
        case .square: "square"
        }
    }
}

private extension CatalogFaces {
    var title: String {
        switch self {
        case .none: L10n.tr("No Faces")
        case .some: L10n.tr("Faces")
        case .group: L10n.tr("Group Photo")
        }
    }
    var symbol: String {
        switch self {
        case .none: "person.slash"
        case .some: "person"
        case .group: "person.3"
        }
    }
}

/// Tags left to right, wrapping to a new line when the next one doesn't fit.
private struct TagFlow: Layout {
    let spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = frames(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(subviews, width: bounds.width)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }
    private func frames(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        return subviews.map { subview in
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            defer { x += size.width + spacing; line = max(line, size.height) }
            return CGRect(origin: CGPoint(x: x, y: y), size: size)
        }
    }
}
