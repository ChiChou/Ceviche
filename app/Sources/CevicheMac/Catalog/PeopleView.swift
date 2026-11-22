import SwiftUI
import AppKit
import CevicheCore

/// People: the overview of the Faces collection, its faces grouped by who they are (`PeopleGrouping`), one card per
/// person, named people first. Double-click a card (or Return) to open that person (`CatalogFilter.personID`): their
/// faces, or their photos in the wall and the grid. Drag a card onto another, or select several and choose Merge, to make
/// one person; faces in a person can be taken out or moved by hand, and grouping never moves them again. Faces nobody
/// holds are under Ungrouped; All Faces is the wall of every face.
struct PeopleView: View {
    @ObservedObject var model: CatalogModel
    @ObservedObject var editor: EditorModel
    @ObservedObject var analysis: AnalysisProgress
    @State private var entries: [CatalogFaceEntry] = []
    @State private var people: [String: CatalogPerson] = [:]
    @State private var summaries: [Summary] = []
    @State private var assets: [String: CatalogAsset] = [:]
    @State private var unanalysed = 0
    /// The card with the keyboard focus: a person's ID, or `ungrouped`.
    @State private var focus: String?
    @State private var chosen: Set<String> = []
    @State private var renaming: String?
    @State private var nameDraft = ""
    @State private var merging: Merge?
    @State private var ungrouping: Summary?
    @FocusState private var focused: Bool
    @FocusState private var nameFocused: Bool

    static let ungrouped = "ungrouped"
    static let allFaces = "allFaces"
    struct Summary: Identifiable, Equatable {
        let id: String
        let name: String?
        let cover: CatalogFaceEntry
        let faces: Int
        let photos: Int
    }
    struct Merge: Identifiable {
        let others: [String]
        let target: String
        var id: String { ([target] + others).joined(separator: "/") }
    }
    private struct LoadKey: Equatable {
        let filter: CatalogFilter
        let analysed: Int
        let people: Int
    }
    private var side: CGFloat { (model.tileSize * 0.75).rounded() }
    /// The collection without the person: the overview always shows everyone in it.
    private var baseFilter: CatalogFilter { var f = model.filter; f.personID = nil; return f }
    private var ungroupedEntries: [CatalogFaceEntry] { entries.filter { $0.personID == nil } }

    var body: some View {
        Group {
            if let person = model.filter.personID {
                PeopleFaceGrid(model: model, editor: editor, entries: entries.filter { $0.personID == person }, assets: assets,
                               people: summaries, current: person, edited: changed)
            } else if model.peopleSubpage == .ungrouped {
                VStack(spacing: 0) {
                    PeopleHeader(title: L10n.tr("Ungrouped"), count: ungroupedEntries.count) { model.peopleSubpage = nil }
                    PeopleFaceGrid(model: model, editor: editor, entries: ungroupedEntries, assets: assets, people: summaries, current: nil, edited: changed)
                }
            } else if model.peopleSubpage == .allFaces {
                VStack(spacing: 0) {
                    PeopleHeader(title: L10n.tr("All Faces"), count: entries.count) { model.peopleSubpage = nil }
                    FaceWallView(model: model, editor: editor, analysis: analysis)
                }
            } else {
                overview
            }
        }
        .background(Theme.canvas)
        .overlay(alignment: .bottom) { status }
        .task(id: LoadKey(filter: baseFilter, analysed: analysis.status.complete / 25, people: model.peopleStatus.generation)) { await load() }
        .alert(L10n.tr("Merge People?"), isPresented: Binding(get: { merging != nil }, set: { if !$0 { merging = nil } }), presenting: merging) { merge in
            Button(L10n.tr("Merge")) { perform { try await $0.mergePeople(merge.others, into: merge.target) } }
            Button(L10n.tr("Cancel"), role: .cancel) {}
        } message: { merge in
            Text(mergeMessage(merge))
        }
        .alert(L10n.tr("Ungroup?"), isPresented: Binding(get: { ungrouping != nil }, set: { if !$0 { ungrouping = nil } }), presenting: ungrouping) { summary in
            Button(L10n.tr("Ungroup")) { perform { try await $0.removePerson(summary.id) } }
            Button(L10n.tr("Cancel"), role: .cancel) {}
        } message: { summary in
            Text(summary.faces == 1 ? L10n.tr("Its face stays out of People until you move it.") : L10n.tr("Its \(summary.faces) faces stay out of People until you move them."))
        }
    }

    // MARK: Overview

    private var overview: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: side, maximum: side * 1.3), spacing: 14)], alignment: .leading, spacing: 14) {
                ForEach(summaries) { card($0) }
                if let first = ungroupedEntries.first { collectionCard(Self.ungrouped, title: L10n.tr("Ungrouped"), count: ungroupedEntries.count, cover: first, symbol: "questionmark") }
                if let first = entries.first { collectionCard(Self.allFaces, title: L10n.tr("All Faces"), count: entries.count, cover: first, symbol: "square.grid.3x3") }
            }.padding(14)
        }
        .focusable().focused($focused).focusEffectDisabled()
        .onKeyPress(.return) { if let focus { open(focus) }; return .handled }
        .onKeyPress(keys: [.leftArrow, .rightArrow], phases: [.down, .repeat]) { press in move(by: press.key == .leftArrow ? -1 : 1); return .handled }
        .onAppear { focused = true }
        .onTapGesture { chosen = []; focus = nil }
    }

    private func card(_ summary: Summary) -> some View {
        let highlighted = chosen.contains(summary.id) || focus == summary.id
        return VStack(alignment: .leading, spacing: 5) {
            FaceWallTile(entry: summary.cover, previews: model.previews, cropsThumbnail: assets[summary.cover.assetID]?.lastEditedAt == nil)
                .aspectRatio(1, contentMode: .fit).clipped()
                .selectionRing(highlighted ? Theme.accent : nil)
            HStack(spacing: 6) {
                if renaming == summary.id {
                    TextField(L10n.tr("Name"), text: $nameDraft).textFieldStyle(.plain).focused($nameFocused)
                        .onSubmit { commitName(summary.id) }
                        .onExitCommand { renaming = nil; focused = true }
                } else if let name = summary.name {
                    Text(name).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
                Text(summary.photos.formatted()).monospacedDigit().foregroundStyle(.secondary)
            }.font(.callout).frame(height: 18)
        }
        .contentShape(Rectangle())
        .help(summary.name ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(summary.name ?? L10n.tr("Unnamed"))
        .accessibilityValue(summary.photos == 1 ? L10n.tr("1 photo") : L10n.tr("\(summary.photos) photos"))
        .onTapGesture(count: 2) { open(summary.id) }
        .onTapGesture { if NSEvent.modifierFlags.contains(.command) { toggle(summary.id) } else { choose(summary.id) } }
        .draggable(PersonDrag(id: summary.id))
        .dropDestination(for: PersonDrag.self) { dropped, _ in
            let others = dropped.map(\.id).filter { $0 != summary.id }
            guard !others.isEmpty else { return false }
            merging = Merge(others: others, target: summary.id); return true
        }
        .contextMenu { menu(for: summary) }
    }

    @ViewBuilder private func menu(for summary: Summary) -> some View {
        let selection = chosen.contains(summary.id) ? chosen : [summary.id]
        Button(L10n.tr("Open")) { open(summary.id) }
        Button(summary.name == nil ? L10n.tr("Name…") : L10n.tr("Rename…")) { startRenaming(summary) }
        if selection.count > 1 {
            Button(L10n.tr("Merge \(selection.count) People")) {
                // Into the named one, else the one with most photos.
                let ordered = summaries.filter { selection.contains($0.id) }
                let target = ordered.first { $0.name != nil } ?? ordered.max { $0.photos < $1.photos }!
                merging = Merge(others: ordered.map(\.id).filter { $0 != target.id }, target: target.id)
            }
        }
        Divider()
        Button(L10n.tr("Ungroup")) { ungrouping = summary }.disabled(selection.count > 1)
    }

    /// A card for faces that are no one person's: Ungrouped, All Faces.
    private func collectionCard(_ id: String, title: String, count: Int, cover: CatalogFaceEntry, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            FaceWallTile(entry: cover, previews: model.previews, cropsThumbnail: assets[cover.assetID]?.lastEditedAt == nil)
                .aspectRatio(1, contentMode: .fit).clipped().opacity(0.45)
                .overlay { Image(systemName: symbol).font(.title.weight(.light)).foregroundStyle(.white.opacity(0.85)) }
                .selectionRing(focus == id ? Theme.accent : nil)
            HStack(spacing: 6) {
                Text(title).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(count.formatted()).monospacedDigit().foregroundStyle(.secondary)
            }.font(.callout).frame(height: 18)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine).accessibilityLabel(title)
        .onTapGesture(count: 2) { open(id) }
        .onTapGesture { choose(id) }
    }

    @ViewBuilder private var status: some View {
        Group {
            if model.peopleStatus.waiting > 0 {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(model.peopleStatus.waiting == 1 ? L10n.tr("1 face to group") : L10n.tr("\(model.peopleStatus.waiting.formatted()) faces to group")).monospacedDigit()
                }
            } else if unanalysed > 0 {
                Text(unanalysed == 1 ? L10n.tr("1 photo not analyzed yet") : L10n.tr("\(unanalysed.formatted()) photos not analyzed yet")).monospacedDigit()
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 5).background(.regularMaterial, in: Capsule()).padding(10)
        .opacity(model.peopleStatus.waiting > 0 || unanalysed > 0 ? 1 : 0)
    }

    // MARK: Actions

    private func mergeMessage(_ merge: Merge) -> String {
        if let name = summaries.first(where: { $0.id == merge.target })?.name { return L10n.tr("Their faces become “\(name)”.") }
        return L10n.tr("Their faces become one person.")
    }
    private func choose(_ id: String) {
        focus = id; chosen = people[id] == nil ? [] : [id]; focused = true
        if renaming != nil, renaming != id { renaming = nil }
    }
    private func toggle(_ id: String) {
        guard people[id] != nil else { return }
        if chosen.contains(id) { chosen.remove(id) } else { chosen.insert(id) }
        focus = id
    }
    private func move(by step: Int) {
        let ids = summaries.map(\.id) + (ungroupedEntries.isEmpty ? [] : [Self.ungrouped]) + (entries.isEmpty ? [] : [Self.allFaces])
        guard !ids.isEmpty else { return }
        let index = focus.flatMap { ids.firstIndex(of: $0) }.map { $0 + step } ?? 0
        choose(ids[min(max(0, index), ids.count - 1)])
    }
    private func open(_ id: String) {
        renaming = nil
        if id == Self.ungrouped { model.peopleSubpage = .ungrouped; return }
        if id == Self.allFaces { model.peopleSubpage = .allFaces; return }
        Task { await model.openPerson(id) }
    }
    private func startRenaming(_ summary: Summary) {
        nameDraft = summary.name ?? ""; renaming = summary.id
        DispatchQueue.main.async { nameFocused = true }
    }
    private func commitName(_ id: String) {
        let name = nameDraft
        renaming = nil; focused = true
        perform { try await $0.renamePerson(id, name: name) }
    }
    private func perform(_ change: @escaping (CatalogStore) async throws -> Void) {
        guard let store = model.store else { return }
        Task {
            do { try await change(store); changed() } catch { model.error = error.localizedDescription }
        }
    }
    private func changed() { model.peopleEdited() }

    private func load() async {
        guard let store = model.store else { return }
        let filter = baseFilter
        guard let found = try? await store.faceEntries(filter: filter), let everyone = try? await store.people() else { return }
        let missing = Array(Set(found.map(\.assetID)).subtracting(assets.keys))
        let loaded = (try? await store.assets(ids: missing)) ?? []
        let waiting = (try? await store.unanalysedFaceCount(filter: filter)) ?? 0
        guard !Task.isCancelled, baseFilter == filter else { return }
        for asset in loaded { assets[asset.id] = asset }
        entries = found; unanalysed = waiting
        people = Dictionary(everyone.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        summaries = Self.summaries(found, people: people)
        chosen = chosen.filter { people[$0] != nil }
        if let focus, people[focus] != nil, !summaries.contains(where: { $0.id == focus }) { self.focus = nil }
        if model.peopleSubpage == .ungrouped, ungroupedEntries.isEmpty { model.peopleSubpage = nil }
    }

    /// One summary per person with a face here: named people by name, then the others by how many photos they are in.
    static func summaries(_ entries: [CatalogFaceEntry], people: [String: CatalogPerson]) -> [Summary] {
        var byPerson: [String: [CatalogFaceEntry]] = [:]
        for entry in entries { if let person = entry.personID { byPerson[person, default: []].append(entry) } }
        return byPerson.compactMap { id, faces -> Summary? in
            // The clearest face: Vision's capture quality, then size.
            guard let cover = faces.max(by: { ($0.face.quality ?? 0, $0.face.bounds.width) < ($1.face.quality ?? 0, $1.face.bounds.width) }) else { return nil }
            return Summary(id: id, name: people[id]?.name, cover: cover, faces: faces.count, photos: Set(faces.map(\.assetID)).count)
        }.sorted { a, b in
            switch (a.name, b.name) {
            case let (x?, y?): return x.localizedStandardCompare(y) == .orderedAscending
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.photos != b.photos ? a.photos > b.photos : a.id < b.id
            }
        }
    }
}

/// A person card being dragged onto another to merge them.
struct PersonDrag: Codable, Transferable {
    let id: String
    static var transferRepresentation: some TransferRepresentation { CodableRepresentation(contentType: .data) }
}

/// The bar above a person: back to People, their name to edit, how many photos they are in, and their faces or photos.
struct PersonBar: View {
    @ObservedObject var model: CatalogModel
    let personID: String
    @State private var name = ""
    @State private var saved: String?
    @FocusState private var editing: Bool
    var body: some View {
        HStack(spacing: 8) {
            Button { back() } label: { Image(systemName: "chevron.left").frame(width: 22, height: 22).contentShape(Rectangle()) }
                .buttonStyle(.plain).help(L10n.tr("People")).accessibilityLabel(L10n.tr("Back to People"))
                .keyboardShortcut("[", modifiers: .command)
            TextField(L10n.tr("Add Name"), text: $name).textFieldStyle(.plain).font(.title3.weight(.semibold)).focused($editing)
                .onSubmit { save(); editing = false }
                .onChange(of: editing) { _, now in if !now { save() } }
                .frame(maxWidth: 320)
            Text(model.matchingCount == 1 ? L10n.tr("1 photo") : L10n.tr("\(model.matchingCount.formatted()) photos")).monospacedDigit().foregroundStyle(.secondary)
            Spacer()
            FormSegments(title: L10n.tr("Show"), selection: $model.personShowsFaces, options: [true, false],
                         label: { $0 ? L10n.tr("Faces") : L10n.tr("Photos") }).labelsHidden().fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.canvas)
        .overlay(alignment: .bottom) { Theme.hairline.frame(height: 1) }
        .task(id: personID) {
            let found = try? await model.store?.people().first { $0.id == personID }
            name = found?.name ?? ""; saved = found?.name
        }
    }
    private func back() { Task { await model.goUp() } }
    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (saved ?? ""), let store = model.store else { return }
        saved = trimmed.isEmpty ? nil : trimmed
        Task {
            do { try await store.renamePerson(personID, name: trimmed); model.peopleEdited() } catch { model.error = error.localizedDescription }
        }
    }
}

/// The title row of Ungrouped.
private struct PeopleHeader: View {
    let title: String
    let count: Int
    let back: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Button(action: back) { Image(systemName: "chevron.left").frame(width: 22, height: 22).contentShape(Rectangle()) }
                .buttonStyle(.plain).help(L10n.tr("People")).accessibilityLabel(L10n.tr("Back to People"))
                .keyboardShortcut("[", modifiers: .command)
            Text(title).font(.title3.weight(.semibold))
            Text(count.formatted()).monospacedDigit().foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .overlay(alignment: .bottom) { Theme.hairline.frame(height: 1) }
    }
}

/// The faces of one person, or of nobody: click or ⌘/⇧-click to select, double-click or Return to open the photo,
/// Space for the loupe. Selected faces can be taken out of the person, moved to someone named, or made a new person.
struct PeopleFaceGrid: View {
    @ObservedObject var model: CatalogModel
    @ObservedObject var editor: EditorModel
    let entries: [CatalogFaceEntry]
    let assets: [String: CatalogAsset]
    let people: [PeopleView.Summary]
    /// The person shown; nil for Ungrouped.
    let current: String?
    let edited: () -> Void
    @State private var selection: Set<String> = []
    @State private var anchor: String?
    @State private var loupe: CatalogFaceEntry?
    @FocusState private var focused: Bool
    private var side: CGFloat { (model.tileSize * 0.6).rounded() }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: side, maximum: side * 1.3), spacing: 2)], alignment: .leading, spacing: 2) {
                ForEach(entries) { tile($0) }
            }.padding(12)
        }
        .overlay { if let loupe { FaceLoupe(entry: loupe, asset: assets[loupe.assetID], root: model.root) { self.loupe = nil } } }
        .focusable().focused($focused).focusEffectDisabled()
        .onKeyPress(.space) { if let current = anchorEntry { loupe = loupe == nil ? current : nil }; return .handled }
        .onKeyPress(.escape) {
            if loupe != nil { loupe = nil; return .handled }
            if !selection.isEmpty { selection = []; return .handled }
            return .ignored
        }
        .onKeyPress(.return) { if let current = anchorEntry, let asset = assets[current.assetID] { model.develop(asset, editor: editor) }; return .handled }
        .onKeyPress(keys: [.leftArrow, .rightArrow], phases: [.down, .repeat]) { press in move(by: press.key == .leftArrow ? -1 : 1); return .handled }
        .onAppear { focused = true }
        .onChange(of: entries.map(\.id)) { _, ids in selection.formIntersection(ids) }
    }
    private var anchorEntry: CatalogFaceEntry? { anchor.flatMap { id in entries.first { $0.id == id } } }

    private func tile(_ entry: CatalogFaceEntry) -> some View {
        let asset = assets[entry.assetID]
        return FaceWallTile(entry: entry, previews: model.previews, cropsThumbnail: asset?.lastEditedAt == nil)
            .frame(minWidth: side, maxWidth: .infinity).aspectRatio(1, contentMode: .fit)
            .clipped()
            .selectionRing(selection.contains(entry.id) ? Theme.accent : nil)
            .overlay(alignment: .topTrailing) {
                // Placed by hand: grouping leaves it where it is.
                if entry.pinned, current != nil { Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.white).shadow(radius: 1).padding(4) }
            }
            .contentShape(Rectangle())
            .help(asset?.filename ?? "")
            .accessibilityLabel(asset?.filename ?? L10n.tr("Face"))
            .onTapGesture(count: 2) { if let asset { model.develop(asset, editor: editor) } }
            .onTapGesture {
                let flags = NSEvent.modifierFlags
                if flags.contains(.command) { toggle(entry) } else if flags.contains(.shift) { extend(to: entry) } else { choose(entry) }
            }
            .contextMenu { menu(for: entry) }
    }

    @ViewBuilder private func menu(for entry: CatalogFaceEntry) -> some View {
        let keys = (selection.contains(entry.id) ? entries.filter { selection.contains($0.id) } : [entry]).map(\.key)
        let count = keys.count
        if let asset = assets[entry.assetID] { Button(L10n.tr("Open Photo")) { model.develop(asset, editor: editor) } }
        Divider()
        let named = people.filter { $0.name != nil && $0.id != current }
        Menu(L10n.tr("Move To")) {
            ForEach(named) { person in Button(person.name ?? "") { assign(keys, to: person.id) } }
            if !named.isEmpty { Divider() }
            Button(L10n.tr("New Person")) { newPerson(keys) }
        }
        if current != nil {
            Button(count == 1 ? L10n.tr("Remove from Person") : L10n.tr("Remove \(count) Faces from Person")) { assign(keys, to: nil) }
        }
    }

    private func choose(_ entry: CatalogFaceEntry) {
        selection = [entry.id]; anchor = entry.id; focused = true
        if let asset = assets[entry.assetID] { model.select(asset) }
        if loupe != nil { loupe = entry }
    }
    private func toggle(_ entry: CatalogFaceEntry) {
        if selection.contains(entry.id) { selection.remove(entry.id) } else { selection.insert(entry.id) }
        anchor = entry.id
    }
    private func extend(to entry: CatalogFaceEntry) {
        guard let anchor, let from = entries.firstIndex(where: { $0.id == anchor }), let to = entries.firstIndex(where: { $0.id == entry.id }) else { choose(entry); return }
        selection = Set(entries[min(from, to)...max(from, to)].map(\.id))
    }
    private func move(by step: Int) {
        guard !entries.isEmpty else { return }
        let index = anchor.flatMap { id in entries.firstIndex { $0.id == id } }.map { $0 + step } ?? 0
        choose(entries[min(max(0, index), entries.count - 1)])
    }
    private func assign(_ keys: [CatalogFaceKey], to person: String?) {
        guard let store = model.store else { return }
        Task {
            do { try await store.assignFaces(keys, to: person); selection = []; edited() } catch { model.error = error.localizedDescription }
        }
    }
    private func newPerson(_ keys: [CatalogFaceKey]) {
        guard let store = model.store else { return }
        Task {
            do { try await store.newPerson(with: keys); selection = []; edited() } catch { model.error = error.localizedDescription }
        }
    }
}

/// The bar above a pin's photos on the Map: back to the Map, where they are, and how many.
struct PlaceBar: View {
    @ObservedObject var model: CatalogModel
    let area: CatalogMapArea
    /// The commonest place name of the photos shown.
    private var title: String {
        let names = model.assets.compactMap { asset -> String? in
            let parts = [asset.placeCity, asset.placeCountry].compactMap { $0 }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }
        let counts = Dictionary(names.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.max { $0.value < $1.value }?.key ?? String(format: "%.4f, %.4f", (area.south + area.north) / 2, (area.west + area.east) / 2)
    }
    var body: some View {
        HStack(spacing: 8) {
            Button { Task { await model.goUp() } } label: { Image(systemName: "chevron.left").frame(width: 22, height: 22).contentShape(Rectangle()) }
                .buttonStyle(.plain).help(L10n.tr("Map")).accessibilityLabel(L10n.tr("Back to Map"))
                .keyboardShortcut("[", modifiers: .command)
            Text(title).font(.title3.weight(.semibold)).lineLimit(1)
            Text(model.matchingCount == 1 ? L10n.tr("1 photo") : L10n.tr("\(model.matchingCount.formatted()) photos")).monospacedDigit().foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.canvas)
        .overlay(alignment: .bottom) { Theme.hairline.frame(height: 1) }
    }
}

/// Faces without the People model: a link to install it.
struct PeopleModelPrompt: View {
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        HStack(spacing: 8) {
            Text(L10n.tr("People needs a model that is not installed."))
            Button(L10n.tr("Get Model…")) { ModelPrompt.open(.faceIdentity, openSettings) }.buttonStyle(.link)
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 5).background(.regularMaterial, in: Capsule()).padding(10)
    }
}
