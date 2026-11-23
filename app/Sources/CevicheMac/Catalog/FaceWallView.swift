import SwiftUI
import ImageIO
import CevicheCore

/// The Faces collection: every face background analysis found in the photos the sidebar and search show, newest first
/// and by day, one tile each. Click selects the photo, double-click or Return opens it, Space shows the face at actual
/// pixels. Tiles come from the previews database; nothing here reads an original except that loupe.
struct FaceWallView: View {
    @ObservedObject var model: CatalogModel
    @ObservedObject var editor: EditorModel
    /// Followed for new faces as analysis reaches more photos.
    @ObservedObject var analysis: AnalysisProgress
    @State private var entries: [CatalogFaceEntry] = []
    @State private var assets: [String: CatalogAsset] = [:]
    @State private var unanalysed = 0
    @State private var focus: String?
    @State private var loupe: CatalogFaceEntry?
    @State private var width: CGFloat = 0
    @FocusState private var focused: Bool

    private struct Section: Identifiable {
        let id: String
        let title: String?
        let entries: [CatalogFaceEntry]
    }
    /// What the wall is reloaded for: the filter, and every few photos analysis finishes.
    private struct LoadKey: Equatable {
        let filter: CatalogFilter
        let analysed: Int
    }
    private var side: CGFloat { (model.tileSize * 0.6).rounded() }
    private var sections: [Section] {
        guard model.filter.sort == .captureDate, model.groupsByDate else { return [Section(id: "all", title: nil, entries: entries)] }
        var result: [Section] = []
        var start = 0
        for index in entries.indices where index == entries.count - 1 || entries[index + 1].captureDay != entries[index].captureDay {
            let day = entries[index].captureDay
            result.append(Section(id: "\(day)/\(start)", title: day.isEmpty ? L10n.tr("No Date") : CaptureDateNode.title(for: day, full: true),
                                  entries: Array(entries[start...index])))
            start = index + 1
        }
        return result
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: side, maximum: side * 1.3), spacing: 2)], alignment: .leading, spacing: 2,
                          pinnedViews: [.sectionHeaders]) {
                    ForEach(sections) { section in
                        SwiftUI.Section {
                            ForEach(section.entries) { entry in tile(entry).id(entry.id) }
                        } header: {
                            if let title = section.title {
                                Text(title).font(.callout.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 4).padding(.vertical, 6).background(Theme.canvas)
                            }
                        }
                    }
                }.padding(.horizontal, 12).padding(.bottom, 12)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .onChange(of: focus) { _, id in if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } } }
            .onChange(of: model.dateJump) { _, request in
                // The month's first face, or the nearest day's when it has none.
                if let request, let target = FaceWallView.nearest(request.month, in: entries, ascending: model.filter.ascending) {
                    proxy.scrollTo(target, anchor: .top)
                }
            }
        }

        .background(Theme.canvas)
        .overlay(alignment: .bottom) {
            if unanalysed > 0 {
                Text(unanalysed == 1 ? L10n.tr("1 photo not analyzed yet") : L10n.tr("\(unanalysed.formatted()) photos not analyzed yet"))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .padding(.horizontal, 10).padding(.vertical, 5).background(.regularMaterial, in: Capsule()).padding(10)
            }
        }
        .overlay { if let loupe { FaceLoupe(entry: loupe, asset: assets[loupe.assetID], root: model.root) { self.loupe = nil } } }
        .focusable().focused($focused).focusEffectDisabled()
        .onKeyPress(.space) { if let current = focusedEntry { loupe = loupe == nil ? current : nil }; return .handled }
        .onKeyPress(.escape) { guard loupe != nil else { return .ignored }; loupe = nil; return .handled }
        .onKeyPress(.return) { if let current = focusedEntry, let asset = assets[current.assetID] { model.develop(asset, editor: editor) }; return .handled }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow], phases: [.down, .repeat]) { press in
            guard !press.modifiers.contains(.command) else { return .ignored }
            switch press.key {
            case .leftArrow, .rightArrow: move(by: press.key == .leftArrow ? -1 : 1)
            default: moveRow(by: press.key == .upArrow ? -1 : 1)
            }
            return .handled
        }
        .onAppear { focused = true }
        .task(id: LoadKey(filter: model.filter, analysed: analysis.status.complete / 25)) { await load() }
    }

    /// The first face of `month`, or of the day closest to it, in the wall's order.
    static func nearest(_ month: String, in entries: [CatalogFaceEntry], ascending: Bool) -> String? {
        let dated = entries.filter { !$0.captureDay.isEmpty }
        if let inMonth = dated.first(where: { $0.captureDay.hasPrefix(month) }) { return inMonth.id }
        let start = "\(month)-00", end = "\(month)-32"
        let earlier = dated.filter { $0.captureDay < start }.map(\.captureDay).max()
        let later = dated.filter { $0.captureDay > end }.map(\.captureDay).min()
        let day: String?
        switch (earlier, later) {
        case let (earlier?, later?): day = CatalogStore.daysBetween(earlier, start) <= CatalogStore.daysBetween(end, later) ? earlier : later
        default: day = earlier ?? later
        }
        return day.flatMap { day in dated.first { $0.captureDay == day }?.id }
    }
    private var focusedEntry: CatalogFaceEntry? { focus.flatMap { id in entries.first { $0.id == id } } }

    private func tile(_ entry: CatalogFaceEntry) -> some View {
        let asset = assets[entry.assetID]
        let selected = model.selectedIDs.contains(entry.assetID)
        return FaceWallTile(entry: entry, previews: model.previews, cropsThumbnail: asset?.lastEditedAt == nil)
            .frame(minWidth: side, maxWidth: .infinity).aspectRatio(1, contentMode: .fit)
            .clipped()
            .selectionRing(focus == entry.id ? Theme.accent : selected ? Theme.accent.opacity(0.5) : nil)
            .contentShape(Rectangle())
            .help(asset?.filename ?? "")
            .accessibilityLabel(asset?.filename ?? L10n.tr("Face"))
            .onTapGesture(count: 2) { if let asset { model.develop(asset, editor: editor) } }
            .onTapGesture { choose(entry) }
            .contextMenu { if let asset { PhotoContextMenu(catalog: model, editor: editor, asset: asset) } }
    }

    private func choose(_ entry: CatalogFaceEntry) {
        focus = entry.id; focused = true
        if let asset = assets[entry.assetID] { model.select(asset) }
        if loupe != nil { loupe = entry }
    }
    private func move(by step: Int) {
        guard !entries.isEmpty else { return }
        let index = focus.flatMap { id in entries.firstIndex { $0.id == id } }.map { $0 + step } ?? 0
        choose(entries[min(max(0, index), entries.count - 1)])
    }
    private func moveRow(by rows: Int) {
        guard let index = focus.flatMap({ id in entries.firstIndex { $0.id == id } }) else { move(by: 0); return }
        let columns = FaceGridLayout.columns(width: width - 24, side: side, spacing: 2)
        choose(entries[FaceGridLayout.index(from: index, rows: rows, sections: sections.map(\.entries.count), columns: columns)])
    }

    private func load() async {
        guard let store = model.store else { return }
        let filter = model.filter
        guard let found = try? await store.faceEntries(filter: filter) else { return }
        let missing = Array(Set(found.map(\.assetID)).subtracting(assets.keys))
        let loaded = (try? await store.assets(ids: missing)) ?? []
        let waiting = (try? await store.unanalysedFaceCount(filter: filter)) ?? 0
        guard !Task.isCancelled, model.filter == filter else { return }
        for asset in loaded { assets[asset.id] = asset }
        entries = found; unanalysed = waiting
        if let focus, !found.contains(where: { $0.id == focus }) { self.focus = nil }
    }
}

/// One face: its tile from analysis, or, for a photo analysed on another Mac, cut from the library thumbnail.
struct FaceWallTile: View {
    let entry: CatalogFaceEntry
    let previews: PreviewStore?
    /// The library thumbnail shows the whole uncropped photo, so the face's bounds fit it.
    let cropsThumbnail: Bool
    @State private var image: CGImage?
    var body: some View {
        ZStack {
            Color.primary.opacity(0.06)
            if let image {
                Image(decorative: image, scale: 1).resizable().interpolation(.high).scaledToFill()
            } else {
                Image(systemName: "person.crop.square").font(.title2).foregroundStyle(.tertiary)
            }
        }
        .task(id: entry.id) {
            guard let previews else { return }
            if let data = try? await previews.faceTile(assetID: entry.assetID, index: entry.index), let tile = Self.decode(data) { image = tile; return }
            guard cropsThumbnail, let data = try? await previews.data(assetID: entry.assetID), let thumbnail = Self.decode(data) else { return }
            image = FaceCrops.tile(from: thumbnail, face: entry.face.bounds)
        }
    }
    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

/// Rows of the face grids, as an adaptive `LazyVGrid` lays them out (each section starts a row), for the up and down arrows.
enum FaceGridLayout {
    static func columns(width: CGFloat, side: CGFloat, spacing: CGFloat) -> Int {
        max(1, Int(((width + spacing) / (side + spacing)).rounded(.down)))
    }
    /// The tile `rows` rows from `index`, in the same column, or the last of a shorter row; the ends stop it.
    static func index(from index: Int, rows: Int, sections: [Int], columns: Int) -> Int {
        var ranges: [Range<Int>] = []
        var start = 0
        for count in sections {
            for row in stride(from: start, to: start + count, by: columns) { ranges.append(row..<min(row + columns, start + count)) }
            start += count
        }
        guard let current = ranges.firstIndex(where: { $0.contains(index) }) else { return index }
        let target = ranges[min(max(0, current + rows), ranges.count - 1)]
        return min(target.lowerBound + index - ranges[current].lowerBound, target.upperBound - 1)
    }
}

/// The face at actual pixels from the original, over the wall.
struct FaceLoupe: View {
    let entry: CatalogFaceEntry
    let asset: CatalogAsset?
    let root: URL?
    let close: () -> Void
    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?
    @State private var failed = false
    var body: some View {
        ZStack {
            Color.black.opacity(0.75).onTapGesture(perform: close)
            if let image {
                Image(decorative: image, scale: displayScale).interpolation(.none)
            } else if failed {
                Text(L10n.tr("The original isn’t available.")).foregroundStyle(.white.opacity(0.7))
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: entry.id) {
            image = nil; failed = false
            guard let asset, case .available(let url) = asset.availability(catalog: root) else { failed = true; return }
            let bounds = entry.face.bounds
            let cut = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                // Head and shoulders, at actual pixels unless that is wider than the loupe.
                return autoreleasepool { FaceCrops.tiles(at: url, faces: [bounds], pixels: 1200).first ?? nil }
            }.value
            guard !Task.isCancelled else { return }
            if let cut { image = cut } else { failed = true }
        }
    }
}
