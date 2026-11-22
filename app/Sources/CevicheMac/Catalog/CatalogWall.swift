import SwiftUI
import CevicheCore

/// Rows of photos at one height, each row scaled so its photos fill the width edge to edge, as a contact
/// sheet without frames. The last row keeps the chosen height when it cannot fill the width.
struct WallLayout: Equatable {
    struct Row: Equatable {
        let range: Range<Int>
        let height: CGFloat
        let widths: [CGFloat]
    }
    let rows: [Row]
    static let spacing: CGFloat = 2
    init(aspects: [Double], width: CGFloat, rowHeight: CGFloat, spacing: CGFloat = WallLayout.spacing) {
        var rows: [Row] = []
        guard width > 0, rowHeight > 0 else { self.rows = rows; return }
        var start = 0, sum = 0.0
        for (index, aspect) in aspects.enumerated() {
            sum += max(0.05, aspect)
            let gaps = CGFloat(index - start) * spacing
            let fills = sum * rowHeight + gaps >= width
            guard fills || index == aspects.count - 1 else { continue }
            let height = fills ? (width - gaps) / sum : rowHeight
            rows.append(Row(range: start..<index + 1, height: height, widths: aspects[start...index].map { CGFloat(max(0.05, $0)) * height }))
            start = index + 1; sum = 0
        }
        self.rows = rows
    }
}

/// Rows whose heights are known before any is shown: where each starts and how tall the whole list is. A lazy stack
/// measures every row it skips, so jumping far down a large library stalled for seconds; these rows are placed
/// directly, and only those near the visible part are built.
struct RowStack: Equatable {
    let tops: [CGFloat]
    let heights: [CGFloat]
    let total: CGFloat
    init(heights: [CGFloat], spacing: CGFloat, inset: CGFloat) {
        var tops: [CGFloat] = [], y = inset
        tops.reserveCapacity(heights.count)
        for height in heights { tops.append(y); y += height + spacing }
        self.tops = tops; self.heights = heights
        total = heights.isEmpty ? 2 * inset : y - spacing + inset
    }
    /// The rows that meet `rect`, widened by `margin` above and below.
    func rows(in rect: CGRect, margin: CGFloat) -> Range<Int> {
        let low = rect.minY - margin, high = rect.maxY + margin
        var first = 0, end = tops.count
        while first < end { let mid = (first + end) / 2; if tops[mid] + heights[mid] < low { first = mid + 1 } else { end = mid } }
        var last = first; end = tops.count
        while last < end { let mid = (last + end) / 2; if tops[mid] <= high { last = mid + 1 } else { end = mid } }
        return first..<max(first, last)
    }
}

/// Places the shown rows of a `RowStack` where the stack says, at the full width, and an optional footer below the
/// last row: a spinner at its top, the rest room kept for photos not loaded yet. It never asks the rows for their sizes
/// or spacing: a stack container does, which walked every tile of every shown row on each scroll step.
struct RowPlacement: Layout {
    let stack: RowStack
    let shown: Range<Int>
    let inset: CGFloat
    let footer: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: stack.total + footer)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = max(0, bounds.width - 2 * inset)
        for (offset, row) in shown.enumerated() where offset < subviews.count {
            subviews[offset].place(at: CGPoint(x: bounds.minX + inset, y: bounds.minY + stack.tops[row]), anchor: .topLeading,
                                   proposal: ProposedViewSize(width: width, height: stack.heights[row]))
        }
        if subviews.count > shown.count {
            subviews[shown.count].place(at: CGPoint(x: bounds.midX, y: bounds.minY + stack.total + 20), anchor: .center, proposal: .unspecified)
        }
    }
    func spacing(subviews: Subviews, cache: inout ()) -> ViewSpacing { ViewSpacing() }
}

/// Where the grid is scrolled to. Only the pinned date reads it as it changes; the grid itself moves its built rows
/// only when the scroll nears their edge (`LibraryGrid.window`).
@MainActor @Observable final class GridScroll {
    var visible = CGRect.zero
}

/// The Library's grid and wall. Rows are laid out from the photos alone (tiles at a fixed shape, wall rows from each
/// photo's finished aspect), so any scroll position, a jump to the end included, shows at once. Sorted by capture
/// date with Group by Date on, each day starts on a row of its own under its date. Photos not loaded yet have room
/// kept below the loaded ones, estimated from them, so the scroll bar holds still as pages load and can be dragged
/// anywhere; scrolling into that room loads the photos estimated to be there.
struct LibraryGrid: View {
    @ObservedObject var model: CatalogModel
    @ObservedObject var editor: EditorModel
    let focus: () -> Void
    @State private var width: CGFloat = 0
    @State private var scroll = GridScroll()
    /// The part of the grid whose rows are built: what is visible and about a screen past each edge, moved only when
    /// the visible part comes near its edge. Rebuilding the rows on every scroll frame made scrolling lag, the more so
    /// the more photos a screen holds.
    @State private var window = CGRect.zero
    @State private var position = ScrollPosition(edge: .top)
    @State private var memo = Memo()
    /// A photo to scroll to once the layout holds it: a jump past the loaded photos loads them first.
    @State private var pendingJump: Int?
    /// How far a scroll into the room for unloaded photos has asked to load, so each step does not ask again.
    @State private var requestedLoad = 0
    /// The last layout, kept while neither the photos, their shapes, the width nor the style change: scrolling
    /// asks for the rows on every frame.
    final class Memo {
        var key: Key?
        var layout = Layout(stack: RowStack(heights: [], spacing: 0, inset: 0), items: [], rows: [], rowItems: [], wall: nil, columns: 1, tileWidth: 0,
                            reserve: 0, photoHeight: 0)
        struct Key: Equatable { let revision: Int, width: CGFloat, tile: CGFloat, wall: Bool, review: Bool, byDay: Bool, missing: Int }
    }
    /// A line of the layout: a day's date, or a row of photos (an index into `rows`).
    enum Item: Equatable { case day(String), photos(Int) }
    struct Layout {
        let stack: RowStack
        let items: [Item]
        /// The photo rows as ranges of `assets`, and the item each is.
        let rows: [Range<Int>]
        let rowItems: [Int]
        let wall: [WallLayout.Row]?
        let columns: Int
        let tileWidth: CGFloat
        /// Room below the loaded rows for the photos not loaded yet: exact for an even grid, else the loaded photos'
        /// average height per photo (`photoHeight`) times their number.
        let reserve: CGFloat
        let photoHeight: CGFloat
    }
    static let dayHeight: CGFloat = 30
    private var wall: Bool { model.gridStyle == .wall }
    private var inset: CGFloat { wall ? 0 : CatalogGridMove.padding }
    private var byDay: Bool { model.filter.sort == .captureDate && model.groupsByDate }
    private func layout() -> Layout {
        let missing = model.hasMore ? max(0, model.matchingCount - model.assets.count) : 0
        let key = Memo.Key(revision: model.layoutRevision, width: width, tile: model.tileSize, wall: wall, review: !model.isFolderIndex, byDay: byDay,
                           missing: missing)
        if memo.key == key { return memo.layout }
        let assets = model.assets
        // Runs of one capture day, or the whole list.
        var runs: [Range<Int>] = []
        if byDay {
            var start = 0
            for index in assets.indices where index == assets.count - 1 || assets[index + 1].captureDay != assets[index].captureDay {
                runs.append(start..<index + 1); start = index + 1
            }
        } else if !assets.isEmpty { runs = [0..<assets.count] }
        var items: [Item] = [], heights: [CGFloat] = [], rows: [Range<Int>] = [], rowItems: [Int] = [], lines: [WallLayout.Row] = []
        let columns = wall ? 1 : CatalogGridMove.columnCount(width: width, tile: model.tileSize)
        let spacing = wall ? WallLayout.spacing : CatalogGridMove.spacing
        let tileWidth = wall ? 0 : max(1, (width - 2 * inset - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        let tileHeight = CatalogTile.height(width: tileWidth, showsReview: !model.isFolderIndex)
        for run in runs {
            if byDay { items.append(.day(assets[run.lowerBound].captureDay)); heights.append(Self.dayHeight) }
            if wall {
                let laid = WallLayout(aspects: assets[run].map(model.aspect(of:)), width: width, rowHeight: model.tileSize)
                for line in laid.rows {
                    let range = (line.range.lowerBound + run.lowerBound)..<(line.range.upperBound + run.lowerBound)
                    lines.append(WallLayout.Row(range: range, height: line.height, widths: line.widths))
                    rowItems.append(items.count); items.append(.photos(rows.count)); rows.append(range); heights.append(line.height)
                }
            } else {
                for start in stride(from: run.lowerBound, to: run.upperBound, by: columns) {
                    rowItems.append(items.count); items.append(.photos(rows.count)); rows.append(start..<min(run.upperBound, start + columns)); heights.append(tileHeight)
                }
            }
        }
        let stack = RowStack(heights: heights, spacing: spacing, inset: inset)
        var reserve: CGFloat = 0, photoHeight: CGFloat = 0
        if missing > 0 {
            if !wall && !byDay {
                photoHeight = (tileHeight + spacing) / CGFloat(columns)
                reserve = CGFloat((missing + columns - 1) / columns) * (tileHeight + spacing)
            } else if !assets.isEmpty {
                photoHeight = stack.total / CGFloat(assets.count); reserve = CGFloat(missing) * photoHeight
            }
        }
        let made = Layout(stack: stack, items: items, rows: rows, rowItems: rowItems, wall: wall ? lines : nil, columns: columns, tileWidth: tileWidth,
                          reserve: reserve, photoHeight: photoHeight)
        memo.key = key; memo.layout = made
        return made
    }
    var body: some View {
        let layout = layout()
        let shown = layout.stack.rows(in: window, margin: 0)
        ScrollView {
            RowPlacement(stack: layout.stack, shown: shown, inset: inset, footer: model.hasMore ? max(40, layout.reserve) : 0) {
                ForEach(shown, id: \.self) { item in itemView(item, layout) }
                if model.hasMore { ProgressView().controlSize(.small) }
            }
            .background {
                // Clicking empty space clears the selection.
                Color.clear.contentShape(Rectangle()).onTapGesture { focus(); model.deselectAll() }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGRect.self) { $0.visibleRect } action: { _, rect in scrolled(to: rect) }
        .overlay(alignment: .top) { if byDay { StickyDay(scroll: scroll, layout: layout, inset: wall ? 8 : inset) } }
        .onChange(of: model.dateJump) { _, request in if let request { jump(to: request.month) } }
        // Another collection or search starts at its first photos, not where the last one was scrolled to. Opening or
        // closing a group stays where it is.
        .onChange(of: model.filter) { old, new in
            requestedLoad = 0
            var a = old, b = new; a.expandedStacks = []; b.expandedStacks = []
            if a != b { position.scrollTo(edge: .top) }
        }
        .onChange(of: model.matchingCount) { _, _ in requestedLoad = 0 }
        .onChange(of: model.selected?.id) { _, id in reveal(id) }
        .onAppear { reveal(model.selected?.id) }
        .onChange(of: layout.rows, initial: true) { _, rows in
            // Rows of uneven length (the wall, or days in the grid) are moved through by row; an even grid by columns.
            model.libraryRows = wall || byDay ? rows : nil; model.libraryColumnCount = layout.columns
            model.libraryRowsKeepColumns = !wall
        }
        .onChange(of: layout.stack.total) { _, _ in
            guard let index = pendingJump, index < model.assets.count else { return }
            pendingJump = nil
            // On the next turn, once the scroll view has taken the new height.
            DispatchQueue.main.async { scroll(toPhoto: index, self.layout()) }
        }
        .onChange(of: staleOnScreen(layout), initial: true) { _, ids in model.developOnScreen(ids) }
        .onDisappear { model.libraryRows = nil; model.developOnScreen([]) }
    }
    /// Photos in the built rows, top first, showing a thumbnail without their edits: the camera's preview of an edited
    /// photo. Photos with no thumbnail yet get the camera preview first (`regenerateThumbnails`) and come here once
    /// it shows.
    private func staleOnScreen(_ layout: Layout) -> [String] {
        let assets = model.assets
        return layout.stack.rows(in: window, margin: 0).flatMap { item -> [String] in
            guard case .photos(let row) = layout.items[item] else { return [] }
            return layout.rows[row].compactMap { index in
                guard assets.indices.contains(index) else { return nil }
                let asset = assets[index]
                return asset.thumbnailKey != nil && asset.thumbnailRenderKey != asset.renderKey ? asset.id : nil
            }
        }
    }
    /// Moves the built rows when the visible part nears their edge, and loads the photos scrolled to in the room kept
    /// for unloaded ones.
    private func scrolled(to rect: CGRect) {
        scroll.visible = rect
        let near: CGFloat = 100, margin = max(400, rect.height)
        if rect.minY - near < window.minY || rect.maxY + near > window.maxY || window.height != rect.height + 2 * margin {
            window = CGRect(x: 0, y: rect.minY - margin, width: 1, height: rect.height + 2 * margin)
        }
        guard model.hasMore else { return }
        let layout = layout()
        // Past the spinner. The loaded photos' last rows load the next page as they appear, but a drag far into the
        // room shows none of them.
        guard layout.photoHeight > 0, rect.maxY > layout.stack.total + 40 else { return }
        let index = min(model.matchingCount - 1, model.assets.count + Int((rect.maxY - layout.stack.total) / layout.photoHeight))
        guard index >= model.assets.count, index > requestedLoad else { return }
        requestedLoad = index + CatalogModel.pageSize / 2
        Task { await model.load(through: index) }
    }

    @ViewBuilder private func itemView(_ item: Int, _ layout: Layout) -> some View {
        switch layout.items[item] {
        case .day(let day): DayHeader(day: day, inset: wall ? 8 : 0)
        case .photos(let row):
            LibraryRow(cells: cells(row, layout), height: layout.stack.heights[layout.rowItems[row]], wall: layout.wall != nil,
                       showsReview: !model.isFolderIndex, draggable: model.filter.area == .library,
                       previewsID: model.previews.map(ObjectIdentifier.init), model: model, editor: editor, focus: focus)
                .equatable()
        }
    }
    /// What each photo of a row shows. The photo open in the inspector shows its unsaved rating, flag and label.
    private func cells(_ row: Int, _ layout: Layout) -> [LibraryRow.Cell] {
        let current = model.selected?.id
        return layout.rows[row].enumerated().map { offset, index in
            let asset = model.assets[index], open = asset.id == current
            return LibraryRow.Cell(asset: asset, width: layout.wall?[row].widths[offset] ?? layout.tileWidth,
                                   selected: model.selectedIDs.contains(asset.id), availability: model.availability[asset.id],
                                   rating: open ? model.metadata.rating : asset.rating,
                                   review: open ? model.metadata.review : asset.metadata.review,
                                   label: open ? model.metadata.label : asset.metadata.label,
                                   badge: model.groupBadge(for: asset).map { LibraryRow.Badge(count: $0.count, expanded: $0.expanded, toggles: $0.toggle != nil) })
        }
    }
    /// The nearest day item from `start`, walking by `step`.
    fileprivate static func dayItem(at start: Int, in items: [Item], step: Int) -> Int? {
        var index = start
        while items.indices.contains(index) {
            if case .day = items[index] { return index }
            index += step
        }
        return nil
    }
    /// Where to scroll for photo `index`: its day's date at the top edge when it is in the day's first row, else its
    /// row with the grid's margin above.
    private func top(of index: Int, _ layout: Layout) -> CGFloat? {
        guard let row = layout.rows.firstIndex(where: { $0.contains(index) }) else { return nil }
        let item = layout.rowItems[row]
        if item > 0, case .day = layout.items[item - 1] { return layout.stack.tops[item - 1] }
        return max(0, layout.stack.tops[item] - inset)
    }
    /// Scrolls the selected photo's row into view when it is outside it, as little as needed.
    private func reveal(_ id: String?) {
        guard let id, let index = model.assets.firstIndex(where: { $0.id == id }) else { return }
        let layout = layout(), visible = scroll.visible
        guard let row = layout.rows.firstIndex(where: { $0.contains(index) }) else { return }
        let item = layout.rowItems[row]
        let top = layout.stack.tops[item], bottom = top + layout.stack.heights[item]
        // Below the date pinned to the top edge.
        let covered = byDay ? Self.dayHeight : 0
        if visible.height == 0 { position.scrollTo(y: max(0, top - inset - covered)); return }
        if top < visible.minY + covered { position.scrollTo(y: max(0, top - inset - covered)) }
        else if bottom > visible.maxY { position.scrollTo(y: bottom + inset - visible.height) }
    }
    /// Scrolls to the first photo of `month`, or the nearest one when it has none, loading the photos up to it first.
    private func jump(to month: String) {
        guard let store = model.store else { return }
        let filter = model.filter
        Task {
            guard let offset = try? await store.offset(nearestMonth: month, filter: filter), model.filter == filter else { return }
            if offset >= model.assets.count, model.hasMore {
                // Placed once the new rows are laid out; scrolling now would stop at the old end.
                pendingJump = offset
                await model.load(through: offset)
            } else {
                guard model.filter == filter, !model.assets.isEmpty else { return }
                scroll(toPhoto: min(offset, model.assets.count - 1), layout())
            }
        }
    }
    private func scroll(toPhoto index: Int, _ layout: Layout) {
        if let y = top(of: index, layout) { position.scrollTo(y: y) }
    }
}

/// The date of the day scrolled under the top edge, pushed up by the next day's date as it arrives. The only part of
/// the grid redrawn on every scroll frame.
private struct StickyDay: View {
    let scroll: GridScroll
    let layout: LibraryGrid.Layout
    let inset: CGFloat
    var body: some View {
        let top = scroll.visible.minY, items = layout.items, stack = layout.stack
        let first = stack.rows(in: CGRect(x: 0, y: top, width: 1, height: 1), margin: 0).lowerBound
        // A date already at the top edge needs no pinned copy.
        let inPlace = items.indices.contains(first) && { if case .day = items[first] { return stack.tops[first] >= top - 1 } else { return false } }()
        if top > 0, !inPlace, let current = LibraryGrid.dayItem(at: min(first, items.count - 1), in: items, step: -1),
           stack.tops[current] < top, case .day(let day) = items[current] {
            let next = first + 1 < items.count ? LibraryGrid.dayItem(at: first + 1, in: items, step: 1) : nil
            let push = next.map { min(0, stack.tops[$0] - top - LibraryGrid.dayHeight) } ?? 0
            DayHeader(day: day, inset: inset).frame(height: LibraryGrid.dayHeight)
                .background(Theme.canvas.opacity(0.92))
                // Clear of the scroll bar, which runs down the right edge from the very top.
                .padding(.trailing, NSScroller.scrollerWidth(for: .regular, scrollerStyle: NSScroller.preferredScrollerStyle))
                .offset(y: push).allowsHitTesting(false)
        }
    }
}

/// One row of the grid or wall, redrawn only when what it shows changes: scrolling, and catalog changes that leave
/// its photos alone, skip it.
struct LibraryRow: View, Equatable {
    struct Badge: Equatable { let count: Int?; let expanded: Bool; let toggles: Bool }
    struct Cell: Equatable {
        let asset: CatalogAsset
        let width: CGFloat
        let selected: Bool
        let availability: AssetAvailability?
        let rating: Int
        let review: ReviewState
        let label: CatalogLabel?
        let badge: Badge?
    }
    let cells: [Cell]
    let height: CGFloat
    let wall: Bool
    let showsReview: Bool
    /// Photos drag onto albums from the library, not the Trash or the archive.
    let draggable: Bool
    let previewsID: ObjectIdentifier?
    let model: CatalogModel
    let editor: EditorModel
    let focus: () -> Void
    nonisolated static func == (a: LibraryRow, b: LibraryRow) -> Bool {
        a.cells == b.cells && a.height == b.height && a.wall == b.wall && a.showsReview == b.showsReview && a.draggable == b.draggable
            && a.previewsID == b.previewsID
    }
    var body: some View {
        HStack(alignment: .top, spacing: wall ? WallLayout.spacing : CatalogGridMove.spacing) {
            ForEach(cells, id: \.asset.id) { cell in
                let asset = cell.asset
                Group {
                    if wall {
                        CatalogWallCell(asset: asset, previews: model.previews, selected: cell.selected, rejected: cell.review == .rejected,
                                        onImage: { [model] in model.noteThumbnail(of: asset, size: $0) })
                            .frame(width: cell.width, height: height)
                            .groupBadge(badge(cell))
                    } else {
                        CatalogTile(asset: asset, previews: model.previews, selected: cell.selected, availability: cell.availability,
                                    rating: cell.rating, review: cell.review, label: cell.label,
                                    setRating: { [model] rating in Task { await model.setQuickMetadata([asset], rating: rating) } },
                                    setReview: { [model] review in Task { await model.updateQuickMetadata(asset, review: review) } },
                                    group: badge(cell), showsReview: showsReview)
                            .frame(width: cell.width, height: height)
                    }
                }
                .modifier(LibraryCell(model: model, editor: editor, asset: asset, draggable: draggable, focus: focus))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func badge(_ cell: Cell) -> GroupBadge? {
        cell.badge.map { badge in
            GroupBadge(count: badge.count, expanded: badge.expanded, toggle: badge.toggles ? { [model] in model.toggleGroup(cell.asset) } : nil)
        }
    }
}

/// A day's date above its photos.
struct DayHeader: View {
    let day: String
    var inset: CGFloat = 0
    var body: some View {
        Text(day.isEmpty ? L10n.tr("Unknown Date") : CaptureDateNode.title(for: day, full: true))
            .font(.callout.weight(.medium)).lineLimit(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, inset)
    }
}

struct CatalogWallCell: View {
    let asset: CatalogAsset
    let previews: PreviewStore?
    let selected: Bool
    let rejected: Bool
    let onImage: (CGSize) -> Void
    @State private var hovering = false
    var body: some View {
        CatalogThumbnail(asset: asset, previews: previews, onImage: onImage)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.ink.opacity(0.04))
            .clipped()
            .opacity(rejected && !selected && !hovering ? 0.45 : 1)
            .selectionRing(selected ? Theme.accent : hovering ? Theme.ink.opacity(0.5) : nil)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .help(asset.title.isEmpty ? asset.filename : asset.title)
            .accessibilityLabel(asset.title.isEmpty ? asset.filename : asset.title)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
