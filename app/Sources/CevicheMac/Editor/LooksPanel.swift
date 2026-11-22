import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CevicheCore

/// The Looks tab in Develop: the camera profile and LUT on the photo, the look library as a scrolling list or as
/// thumbnails of the photo under each look, and search, the view and import at the bottom. Resting the pointer on a
/// look previews it; clicking applies it as one undo step. Camera profiles are left out of the library: presets that
/// name one still find it, and one on the photo still shows its card.
struct LooksPanel: View {
    @ObservedObject var model: EditorModel
    let catalog: CatalogModel
    @State private var hovered: LookFile?
    var body: some View {
        VStack(spacing: 0) {
            if hasApplied || model.lookNotes != nil {
                VStack(spacing: 8) {
                    appliedSection
                    if let notes = model.lookNotes { notesBanner(notes) }
                }.padding(10)
                Rule()
            }
            LookBrowser(model: model, library: LookLibrary.current(editor: model, catalog: catalog), catalog: catalog, hovered: $hovered,
                        applied: model.isOnPhoto,
                        apply: { look in Task { await model.applyLook(look.url, kind: look.kind, reportInline: true) } },
                        report: { model.error = $0 })
        }
        .disabled(!model.hasImage || model.busy).opacity(model.hasImage ? 1 : 0.4)
        .onChange(of: hovered) { _, look in model.previewLook(look) }
        .onDisappear { hovered = nil; model.endLookPreview() }
    }

    /// A look's camera profile. A chart profile is a calibration, not a look: Develop's Camera Profile row has it.
    private var lookProfile: CameraProfile? { model.adjustments.cameraProfile.flatMap { $0.hasCalibration ? nil : $0 } }

    private var hasApplied: Bool { model.presetOnPhoto != nil || lookProfile != nil || model.adjustments.look != nil || model.adjustments.lut != nil }

    /// The preset just applied, and the camera profile, imported look and LUT on the photo, each a card laid out like the
    /// Develop sections.
    @ViewBuilder private var appliedSection: some View {
        if hasApplied {
            VStack(spacing: 8) {
                // Until anything else is edited, the preset's strength can still be set.
                if let preset = model.presetOnPhoto {
                    AppliedLookCard(icon: "slider.horizontal.3", kind: L10n.tr("Preset"), name: preset.name,
                                    enabled: Binding(get: { preset.enabled }, set: { model.setPresetEnabled($0) }),
                                    amount: Binding(get: { preset.amount * 100 }, set: { model.setPresetAmount($0 / 100) }),
                                    model: model, remove: model.removePreset) { EmptyView() }
                }
                if let profile = lookProfile {
                    AppliedLookCard(icon: "camera.aperture", kind: L10n.tr("Camera profile"), name: profile.name,
                                    enabled: Binding(get: { profile.enabled }, set: { on in model.edit { $0.cameraProfile?.enabled = on } }),
                                    amount: Binding(get: { profile.amount * 100 }, set: { value in model.edit { $0.cameraProfile?.amount = value / 100 } }),
                                    model: model, remove: { model.edit { $0.cameraProfile = nil } }) {
                        if !(model.info?.isRAW ?? true) {
                            Text(L10n.tr("RAW only")).font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                    }
                }
                if let look = model.adjustments.look {
                    AppliedLookCard(icon: "camera.filters", kind: L10n.tr("Look"), name: look.name,
                                    enabled: Binding(get: { look.enabled }, set: { on in model.edit { $0.look?.enabled = on } }),
                                    amount: Binding(get: { look.amount * 100 }, set: { value in model.edit { $0.look?.amount = value / 100 } }),
                                    model: model, remove: { model.edit { $0.look = nil } }) { EmptyView() }
                }
                if let lut = model.adjustments.lut {
                    AppliedLookCard(icon: "cube", kind: L10n.tr("LUT"), name: lut.name,
                                    enabled: Binding(get: { lut.enabled }, set: { on in model.edit { $0.lut?.enabled = on } }),
                                    amount: Binding(get: { lut.amount * 100 }, set: { value in model.edit { $0.lut?.amount = value / 100 } }),
                                    model: model, remove: { model.edit { $0.lut = nil } }) {
                        PanelPicker(title: L10n.tr("Color space"), selection: Binding(get: { lut.space }, set: { space in model.edit { $0.lut?.space = space } }),
                                    options: LUTColorSpace.allCases, label: \.rawValue)
                            .controlSize(.small).font(.system(size: 11)).help(L10n.tr("Color space"))
                    }
                }
            }
        }
    }
    private func notesBanner(_ notes: LookNotes) -> some View {
        LookNotesBanner(notes: notes) { model.lookNotes = nil }.id(notes)
    }
}

/// The look library in two tabs, the looks that come with the app and the person's own, each one level of groups,
/// scrolling above search and import.
private struct LookBrowser: View {
    @ObservedObject var model: EditorModel
    let library: LookLibrary
    let catalog: CatalogModel
    @Binding var hovered: LookFile?
    let applied: (LookFile) -> Bool
    let apply: (LookFile) -> Void
    let report: (String) -> Void
    @State private var trees: [LookKind: [LookNode]] = [:]
    @State private var search = ""
    @State private var dropTargeted = false
    @State private var importing = false
    @AppStorage("looksThumbnails") private var thumbnails = false
    @AppStorage("looksShelf") private var shelf = LookShelf.builtIn
    /// The open built-in category, and the person's open folders one per line, so they open again at the next launch.
    @AppStorage("looksOpenBuiltIn") private var openBuiltIn = ""
    @AppStorage("looksOpenFolders") private var openOwnFolders = ""
    /// The kinds listed: camera profiles are mostly referenced by presets, not looks to pick on their own.
    nonisolated private static let kinds: [LookKind] = [.presets, .luts]
    var body: some View {
        VStack(spacing: 0) {
            FormSegments(title: L10n.tr("Looks"), selection: $shelf, options: LookShelf.allCases, label: \.title, equalWidths: true)
                .fixedSize().controlSize(.small).padding(.top, 12).padding(.bottom, 4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !query.isEmpty { results } else if shelf == .builtIn { builtIn } else { mine }
                }.padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
            }
            Rule()
            HStack(spacing: 6) {
                TextField(L10n.tr("Search looks"), text: $search).textFieldStyle(.formField).controlSize(.small)
                FormSegments(title: L10n.tr("View"), selection: $thumbnails, options: [false, true],
                             label: { $0 ? L10n.tr("Thumbnails") : L10n.tr("List") }, icon: { $0 ? "square.grid.2x2" : "list.bullet" }).fixedSize()
                Button(action: model.requestPresetSave) { Image(systemName: "square.and.arrow.down") }.buttonStyle(.secondaryAction).controlSize(.small)
                    .help(L10n.tr("Save Preset…")).accessibilityLabel(L10n.tr("Save Preset…"))
                Button(action: chooseImport) { Image(systemName: "plus") }.buttonStyle(.secondaryAction).controlSize(.small)
                    .disabled(importing).help(L10n.tr("Import Looks…")).accessibilityLabel(L10n.tr("Import Looks…"))
                Button { NSWorkspace.shared.showInFinder([library.root]) } label: { Image(systemName: "folder") }
                    .buttonStyle(.secondaryAction).controlSize(.small).help(L10n.tr("Show in Finder")).accessibilityLabel(L10n.tr("Show in Finder"))
            }.controlSize(.small).padding(.horizontal, 12).padding(.vertical, 10)
        }
        .overlay {
            if dropTargeted { RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.accent, lineWidth: 2).padding(6).allowsHitTesting(false) }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: drop)
        .onAppear(perform: reload)
        .onChange(of: library.root) { _, _ in reload() }
        // A preset just saved is the person's own: show it there.
        .onChange(of: model.savedPresets) { _, _ in shelf = .mine; reload() }
        // Files added, renamed or removed in Finder show the next time Ceviche comes forward.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in reload() }
    }

    // MARK: Built-in

    /// The app's presets: one level of category folders (laid out at build time by presets/bundle-presets.py).
    private var builtInGroups: [LookGroup] {
        guard let root = (trees[.presets] ?? []).first(where: { LookLibrary.isBuiltIn($0.url) }) else { return [] }
        return (root.children ?? []).filter(\.isFolder).map {
            LookGroup(id: $0.name, title: $0.name, folder: $0.url, kind: .presets, files: ($0.children ?? []).filter { !$0.isFolder })
        }
    }
    /// One category open at a time: opening another closes it.
    @ViewBuilder private var builtIn: some View {
        ForEach(builtInGroups) { group in
            let open = openBuiltIn == group.id
            LookGroupHeader(title: group.title, count: group.files.count, depth: 0, folder: nil, open: open) {
                withAnimation(.easeInOut(duration: 0.15)) { openBuiltIn = open ? "" : group.id }
            }
            if open { looks(group.files, kind: .presets, depth: 0, detail: { _ in nil }) }
        }
    }

    // MARK: Mine

    /// The person's own presets and LUTs as the folders they keep them in.
    private func own(_ kind: LookKind) -> [LookNode] { (trees[kind] ?? []).filter { !LookLibrary.isBuiltIn($0.url) } }
    @ViewBuilder private var mine: some View {
        let kinds = [LookKind.presets, .luts].filter { !own($0).isEmpty }
        if kinds.isEmpty {
            Text(L10n.tr("Saved and imported looks appear here.")).font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 24)
        } else {
            ForEach(kinds) { kind in
                Text(kind.localizedTitle).textCase(.uppercase).font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                    .padding(.top, kind == kinds.first ? 0 : 12).padding(.bottom, 4).accessibilityAddTraits(.isHeader)
                tree(own(kind), kind: kind, depth: 0)
            }
        }
    }
    /// Folders open in place, any number at once; files as rows or, in thumbnails, a grid under their folder.
    private func tree(_ nodes: [LookNode], kind: LookKind, depth: Int) -> AnyView {
        let folders = nodes.filter(\.isFolder), files = nodes.filter { !$0.isFolder }
        return AnyView(Group {
            ForEach(folders) { node in
                let key = folderKey(node.url, kind: kind), open = openFolders.contains(key)
                LookGroupHeader(title: node.name, count: Self.fileCount(node), depth: depth, folder: node.url, open: open) {
                    withAnimation(.easeInOut(duration: 0.15)) { setFolder(key, open: !open) }
                }
                if open, let children = node.children { tree(children, kind: kind, depth: depth + 1) }
            }
            looks(files, kind: kind, depth: depth, detail: { _ in nil })
        })
    }
    private static func fileCount(_ node: LookNode) -> Int { node.children?.reduce(0) { $0 + fileCount($1) } ?? 1 }
    /// A folder's path inside its kind's folder, which is what is remembered open.
    private func folderKey(_ url: URL, kind: LookKind) -> String {
        let base = library.folder(kind).resolvingSymlinksInPath().pathComponents, parts = url.resolvingSymlinksInPath().pathComponents
        return kind.rawValue + ":" + (parts.starts(with: base) ? parts.dropFirst(base.count).joined(separator: "/") : url.path)
    }
    private var openFolders: Set<String> { Set(openOwnFolders.split(separator: "\n").map(String.init)) }
    private func setFolder(_ key: String, open: Bool) {
        var keys = openFolders
        if open { keys.insert(key) } else { keys.remove(key) }
        openOwnFolders = keys.sorted().joined(separator: "\n")
    }

    // MARK: Search

    /// While searching, every match in the tab as one list, each with where it is kept.
    @ViewBuilder private var results: some View {
        let matches = searchable.filter { $0.node.name.localizedStandardContains(query) }
        if matches.isEmpty {
            Text(L10n.tr("No matches")).font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 24)
        } else {
            let places = Dictionary(matches.map { ($0.node.url, $0.place) }, uniquingKeysWith: { first, _ in first })
            ForEach([LookKind.presets, .luts].filter { kind in matches.contains { $0.kind == kind } }) { kind in
                looks(matches.filter { $0.kind == kind }.map(\.node), kind: kind, depth: 0, detail: { places[$0.url] ?? nil })
            }
        }
    }
    private var searchable: [(node: LookNode, kind: LookKind, place: String?)] {
        if shelf == .builtIn { return builtInGroups.flatMap { group in group.files.map { ($0, LookKind.presets, Optional(group.title)) } } }
        func walk(_ nodes: [LookNode], kind: LookKind, path: [String]) -> [(node: LookNode, kind: LookKind, place: String?)] {
            nodes.flatMap { node in
                node.children.map { walk($0, kind: kind, path: path + [node.name]) } ?? [(node, kind, path.isEmpty ? nil : path.joined(separator: " › "))]
            }
        }
        return [LookKind.presets, .luts].flatMap { walk(own($0), kind: $0, path: []) }
    }

    /// Rows, or in thumbnails a grid of prints of the photo under each look.
    @ViewBuilder private func looks(_ files: [LookNode], kind: LookKind, depth: Int, detail: @escaping (LookNode) -> String?) -> some View {
        if thumbnails {
            if !files.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], alignment: .leading, spacing: 8) {
                    ForEach(files) { node in
                        let look = LookFile(url: node.url, kind: kind)
                        LookTile(model: model, name: node.name, look: look, applied: applied(look), hovered: $hovered, apply: apply, trash: trashAction(node.url))
                    }
                }.padding(.leading, 16 + CGFloat(depth) * 14).padding(.vertical, 4)
            }
        } else {
            ForEach(files) { node in
                let look = LookFile(url: node.url, kind: kind)
                LookRow(name: node.name, detail: detail(node), depth: depth, look: look, applied: applied(look), hovered: $hovered, apply: apply, trash: trashAction(node.url))
            }
        }
    }
    /// The app's own presets stay.
    private func trashAction(_ url: URL) -> ((LookFile) -> Void)? { LookLibrary.isBuiltIn(url) ? nil : trash }

    private var query: String { search.trimmingCharacters(in: .whitespaces) }
    private func reload() {
        let library = library
        Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                return Dictionary(uniqueKeysWithValues: Self.kinds.map { ($0, (try? library.tree($0)) ?? []) })
            }.value
            trees = loaded
        }
    }
    private func trash(_ look: LookFile) {
        do { try library.trash([look.url]); if hovered == look { hovered = nil } } catch { report(error.localizedDescription) }
        reload()
    }
    private func chooseImport() {
        let types: [UTType] = [.folder] + LookKind.allCases.flatMap(\.extensions).sorted().compactMap { UTType(filenameExtension: $0) }
        Task {
            guard let urls = await FileChooser.open(FileOpenRequest(types: types, folders: true, multiple: true, prompt: L10n.tr("Import"))) else { return }
            importLooks(urls)
        }
    }
    private func drop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty, !importing else { return false }
        Task {
            var urls: [URL] = []
            for provider in fileProviders {
                if let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier),
                   let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { urls.append(url) }
            }
            if !urls.isEmpty { importLooks(urls) }
        }
        return true
    }
    /// Copies files in, each to its own kind's folder; a folder keeps its structure.
    private func importLooks(_ urls: [URL]) {
        importing = true
        let library = library
        Task {
            defer { importing = false }
            do {
                let summary = try await Task.detached(priority: .userInitiated) {
                    let summary = try library.importItems(urls, kind: .presets)
                    // Indexed as at launch, so sidecars naming a new profile find it.
                    if summary.copied[.profiles, default: 0] > 0 { CameraProfileLibrary.shared.reload(folders: LookLibrary.profileFolders) }
                    return summary
                }.value
                reload()
                if summary.total > 0 { shelf = .mine }
                if !summary.skipped.isEmpty {
                    report((summary.total == 0 ? L10n.tr("Nothing was imported.") : L10n.tr("\(summary.total) looks imported; some files were skipped."))
                        + "\n" + summary.skipped.prefix(5).joined(separator: "\n"))
                } else if summary.total > 0 {
                    catalog.notice = summary.total == 1 ? L10n.tr("1 look imported") : L10n.tr("\(summary.total) looks imported")
                }
            } catch { report(error.localizedDescription) }
        }
    }
}

/// What the last look applied here could not carry over; the notes open in place.
private struct LookNotesBanner: View {
    let notes: LookNotes
    let dismiss: () -> Void
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(L10n.tr("Some settings differ")).font(.system(size: 11))
                        Spacer(minLength: 0)
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).help(expanded ? L10n.tr("Hide Details") : L10n.tr("Show Details"))
                    .accessibilityValue(expanded ? L10n.tr("Hide Details") : L10n.tr("Show Details"))
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(L10n.tr("Dismiss")).accessibilityLabel(L10n.tr("Dismiss"))
            }
            if expanded { ReportNotes(report: notes.report).padding(.leading, 19) }
        }
        .padding(10).card()
    }
}

/// The preset just applied, or the camera profile or LUT on the photo: its name, `accessory`, removal and on/off in the
/// header, as the Develop sections have them, then Amount.
private struct AppliedLookCard<Accessory: View>: View {
    let icon: String
    let kind: String
    let name: String
    @Binding var enabled: Bool
    @Binding var amount: Double
    @ObservedObject var model: EditorModel
    let remove: () -> Void
    @ViewBuilder let accessory: () -> Accessory
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16).help(kind)
                Text(name).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle).help(name)
                Spacer(minLength: 4)
                accessory().disabled(!enabled).opacity(enabled ? 1 : 0.4)
                Button(action: remove) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(L10n.tr("Remove from This Photo")).accessibilityLabel(L10n.tr("Remove \(name)"))
                Button { enabled.toggle() } label: {
                    Image(systemName: enabled ? "checkmark.circle.fill" : "circle").font(.system(size: 15)).foregroundStyle(enabled ? Theme.accent : .secondary)
                }.buttonStyle(.plain).help(enabled ? L10n.tr("Turn Off") : L10n.tr("Turn On"))
                    .accessibilityLabel(L10n.tr("Enable \(name)")).accessibilityValue(enabled ? L10n.tr("On") : L10n.tr("Off"))
            }
            AdjustmentSlider(title: "Amount", value: $amount, range: 0...100, unit: "%",
                             editing: { active in if active { model.beginGesture() } else { model.endGesture() } }, reset: { amount = 100 })
                .disabled(!enabled).opacity(enabled ? 1 : 0.4)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .card()
        .accessibilityElement(children: .contain).accessibilityLabel("\(kind), \(name)")
    }
}

/// Which looks the panel lists: those that come with the app, or the person's own, saved or imported.
enum LookShelf: String, CaseIterable, Hashable {
    case builtIn, mine
    var title: String { self == .builtIn ? L10n.tr("Built-in") : L10n.tr("Mine") }
}

/// A built-in category: one of the folders the app's presets ship in.
struct LookGroup: Identifiable {
    let id: String
    let title: String
    let folder: URL
    let kind: LookKind
    let files: [LookNode]
}

/// A built-in category or one of the person's folders: a chevron, the name and how many looks are in it.
private struct LookGroupHeader: View {
    let title: String
    let count: Int
    let depth: Int
    /// The person's own folder, offered in Finder; nil for a built-in category.
    let folder: URL?
    let open: Bool
    let toggle: () -> Void
    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary).frame(width: 10)
                if folder != nil { Image(systemName: "folder").font(.system(size: 10)).foregroundStyle(.secondary) }
                Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text(L10n.tr("\(count)")).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.leading, CGFloat(depth) * 14).padding(.vertical, 5).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { if let folder { Button(L10n.tr("Show in Finder")) { NSWorkspace.shared.showInFinder([folder]) } } }
        .accessibilityLabel(title).accessibilityValue(open ? L10n.tr("Expanded") : L10n.tr("Collapsed"))
    }
}

/// A look as a small print of the photo under it, made when the tile scrolls into view and again a moment after the
/// edit changes.
private struct LookTile: View {
    @ObservedObject var model: EditorModel
    let name: String
    let look: LookFile
    let applied: Bool
    @Binding var hovered: LookFile?
    let apply: (LookFile) -> Void
    /// Nil for the app's own presets, which stay.
    let trash: ((LookFile) -> Void)?
    private var isHovered: Bool { hovered == look }
    var body: some View {
        let image = model.lookThumbnails[look.url]?.image
        Button { apply(look) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Theme.ink.opacity(0.06)
                    .aspectRatio(1.5, contentMode: .fit)
                    .overlay { if let image { Image(decorative: image, scale: 2).resizable().scaledToFill().transition(.opacity) } }
                    .clipped()
                    .selectionRing(applied ? Theme.accent : isHovered ? Theme.ink.opacity(0.35) : nil)
                    .animation(.easeOut(duration: 0.2), value: image != nil)
                Text(name).font(.system(size: 10, weight: applied ? .semibold : .regular)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(applied ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in if inside { hovered = look } else if hovered == look { hovered = nil } }
        // In view: made now, then again once an edit settles.
        .task(id: model.adjustments) {
            if model.lookThumbnails[look.url] != nil { try? await Task.sleep(for: .milliseconds(400)) }
            guard !Task.isCancelled else { return }
            model.requestLookThumbnail(look)
        }
        .onDisappear { model.cancelLookThumbnail(look) }
        .help(look.url.lastPathComponent)
        .contextMenu {
            Button(L10n.tr("Apply")) { apply(look) }
            Button(L10n.tr("Show in Finder")) { NSWorkspace.shared.showInFinder([look.url]) }
            if let trash {
                Divider()
                Button(L10n.tr("Move to Trash"), role: .destructive) { trash(look) }
            }
        }
        .accessibilityLabel(name).accessibilityHint(L10n.tr("Applies this look to the photo"))
        .accessibilityAddTraits(applied ? .isSelected : [])
    }
}

private struct LookRow: View {
    let name: String
    let detail: String?
    let depth: Int
    let look: LookFile
    /// On the photo: marked like a selected row, with a check.
    let applied: Bool
    @Binding var hovered: LookFile?
    let apply: (LookFile) -> Void
    /// Nil for the app's own presets, which stay.
    let trash: ((LookFile) -> Void)?
    private var isHovered: Bool { hovered == look }
    var body: some View {
        Button { apply(look) } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 11, weight: applied ? .semibold : .regular)).lineLimit(1).truncationMode(.middle)
                    if let detail { Text(detail).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head) }
                }
                Spacer(minLength: 4)
                if applied { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.accent) }
            }
            .padding(.leading, 16 + CGFloat(depth) * 14).padding(.trailing, 6).padding(.vertical, 4).contentShape(Rectangle())
            .background(applied ? Theme.accent.opacity(isHovered ? 0.22 : 0.16) : isHovered ? Theme.ink.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        }
        .buttonStyle(.plain)
        // Leaving one row for the next can arrive after the next row's entry, so only the row being left clears it.
        .onHover { inside in if inside { hovered = look } else if hovered == look { hovered = nil } }
        .help(look.url.lastPathComponent)
        .contextMenu {
            Button(L10n.tr("Apply")) { apply(look) }
            Button(L10n.tr("Show in Finder")) { NSWorkspace.shared.showInFinder([look.url]) }
            if let trash {
                Divider()
                Button(L10n.tr("Move to Trash"), role: .destructive) { trash(look) }
            }
        }
        .accessibilityLabel(name).accessibilityHint(L10n.tr("Applies this look to the photo"))
        .accessibilityAddTraits(applied ? .isSelected : [])
    }
}
