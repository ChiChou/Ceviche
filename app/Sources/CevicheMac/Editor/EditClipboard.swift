import SwiftUI
import CevicheCore

struct EditCopyDraft: Identifiable {
    let id = UUID()
    var transfer: EditTransfer
    /// Sync Edits: the photos the chosen edits go to, leaving the clipboard alone. Empty for Copy Selected Edits.
    var syncTargets: [CatalogAsset] = []
}

/// What a copy takes from the photo.
enum EditCopy {
    /// Copy Edits (⌘C): every setting, so pasting makes the destination match the source.
    case everything
    /// Copy Changed Edits (⌥⌘C): only what differs from the source's camera defaults; the destination keeps the rest.
    case edited
    /// Copy Selected Edits… (⇧⌘C): the groups chosen in the dialog.
    case choosing
}

extension EditorModel {
    /// The groups Copy Selected Edits and Sync Edits start with: the last choice made there, or development and white balance.
    var copyEditItems: Set<EditTransferItem> {
        get {
            guard let names = preferences.stringArray(forKey: "copyEditItems") else { return EditTransferItem.defaults }
            return Set(names.compactMap(EditTransferItem.init(rawValue:)))
        }
        set { preferences.set(newValue.map(\.rawValue).sorted(), forKey: "copyEditItems") }
    }
    func copyEdits(_ copy: EditCopy = .everything) {
        guard hasImage, !busy else { return }
        endMask(); endGesture()
        captureEdits(adjustments, baseline: info?.defaults ?? Adjustments(), name: info?.filename ?? L10n.tr("Photo"), copy)
    }
    /// `baseline` is the source photo's camera defaults, which decide what counts as edited.
    func captureEdits(_ settings: Adjustments, baseline: Adjustments, name: String, _ copy: EditCopy = .everything) {
        let items: Set<EditTransferItem>
        switch copy {
        case .everything: items = Set(EditTransferItem.allCases)
        case .edited: items = EditTransferItem.edited(in: settings, from: baseline)
        case .choosing: items = copyEditItems
        }
        let transfer = EditTransfer(sourceName: name, adjustments: settings, baseline: baseline, items: items)
        if copy == .choosing { editCopyDraft = EditCopyDraft(transfer: transfer) }
        else { copiedEdits = transfer }
    }
    /// Pastes `transfer`, or the copied edits.
    func pasteEdits(_ transfer: EditTransfer? = nil) {
        guard hasImage, !busy, let copiedEdits = transfer ?? copiedEdits else { return }
        do {
            endMask(); endGesture()
            let result = try copiedEdits.applying(to: adjustments)
            setAdjustmentTarget(nil); selectedMaskID = nil; selectedComponentID = nil; maskTool = nil
            selectedRetouchID = nil; guideDraft = nil
            edit { $0 = result }
            if adjustments.geometry.needsUprightAnalysis { analyzeUpright() }
        } catch { self.error = error.localizedDescription }
    }
}

/// Copy and Paste Edits from the Photo menu and ⌘C/⌘V: the selected photo in the Library, the open one elsewhere.
extension CatalogModel {
    /// Edits are copied from one photo: never with several selected, in the Library or the filmstrip, a folded group
    /// counting as all its photos.
    func canCopyEdits(editor: EditorModel) -> Bool {
        let targets = cullingTargets(editor: editor)
        return !editor.busy && !catalogBusy && targets.count <= 1 && (showingLibrary ? targets.count == 1 && filter.area == .library : editor.hasImage)
    }
    func copyCurrentEdits(editor: EditorModel, _ copy: EditCopy = .everything) {
        guard canCopyEdits(editor: editor) else { return }
        if showingLibrary, let asset = cullingTargets(editor: editor).first { Task { await copyEdits(from: asset, editor: editor, copy) } }
        else { editor.copyEdits(copy); noteCopiedEdits(copy) }
    }
    /// The toast for a copy made at once; Copy Selected Edits… shows it when its sheet's Copy is clicked.
    func noteCopiedEdits(_ copy: EditCopy) {
        if copy != .choosing { notice = L10n.tr("Edits copied") }
    }
    func canPasteEdits(editor: EditorModel) -> Bool {
        editor.copiedEdits != nil && !editor.busy && !catalogBusy
            && (showingLibrary ? !cullingTargets(editor: editor).isEmpty && filter.area == .library : editor.hasImage)
    }
    /// Sync Edits: the active photo's edits, with groups chosen in the copy sheet, go to the rest of the selection.
    func canSyncEdits(editor: EditorModel) -> Bool {
        showingLibrary && filter.area == .library && !editor.busy && !catalogBusy && selected != nil && cullingTargets(editor: editor).count > 1
    }
    func requestSyncEdits(from source: CatalogAsset? = nil, editor: EditorModel) {
        let targets = cullingTargets(editor: editor).filter { $0.inLibrary }
        guard let source = source ?? selected, targets.count > 1, !catalogBusy, !editor.busy else { return }
        Task {
            guard let settings = await developedSettings(of: source) else { return }
            editor.editCopyDraft = EditCopyDraft(transfer: EditTransfer(sourceName: source.filename, adjustments: settings, baseline: source.info.defaults, items: editor.copyEditItems),
                                                 syncTargets: targets.filter { $0.id != source.id })
        }
    }
    func syncEdits(_ transfer: EditTransfer, to targets: [CatalogAsset], editor: EditorModel) {
        Task { await pasteEdits(to: targets, editor: editor, transfer: transfer) }
    }
    /// The Library selection, or in Detail and Compare the photos selected in the filmstrip (the open one through the editor).
    func pasteCopiedEdits(editor: EditorModel) {
        guard canPasteEdits(editor: editor) else { return }
        let targets = cullingTargets(editor: editor)
        if showingLibrary || targets.count > 1 { Task { await pasteEdits(to: targets, editor: editor) } }
        else { editor.pasteEdits() }
    }
}

struct CopyEditsSheet: View {
    @ObservedObject var editor: EditorModel
    @State var draft: EditCopyDraft
    /// Starts Sync Edits with the chosen groups.
    var sync: (EditTransfer, [CatalogAsset]) -> Void = { _, _ in }
    /// After Copy.
    var copied: () -> Void = {}
    private var syncing: Bool { !draft.syncTargets.isEmpty }
    @State private var expanded: Set<EditTransferSection> = []
    private var items: Set<EditTransferItem> {
        get { draft.transfer.items }
        nonmutating set { draft.transfer.items = newValue }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: syncing ? L10n.tr("Sync Edits") : L10n.tr("Copy Edits"))
            HStack {
                Text(draft.transfer.sourceName).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                ActionMenu(L10n.tr("Select")) {
                    Button(L10n.tr("All")) { items = Set(EditTransferItem.allCases) }
                    Button(L10n.tr("Modified")) { items = Set(EditTransferItem.allCases.filter(modified)) }
                    Button(L10n.tr("Development Only")) { items = EditTransferItem.defaults }
                    Button(L10n.tr("None")) { items = [] }
                }
            }
            Rule()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(EditTransferSection.allCases) { section in sectionRows(section) }
                }.padding(.vertical, 2)
            }.frame(height: 400)
            Rule()
            if items.contains(.masks) {
                Text(L10n.tr("Masks keep their positions; subject and sky selections are not regenerated.")).font(.caption).foregroundStyle(.secondary)
            }
            if syncing {
                Text(L10n.tr("The chosen edits replace the same edits on the other selected photos.")).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(L10n.tr("Cancel")) { editor.editCopyDraft = nil }.keyboardShortcut(.cancelAction).buttonStyle(.secondaryAction)
                Button(syncing ? (draft.syncTargets.count == 1 ? L10n.tr("Sync 1 Photo") : L10n.tr("Sync \(draft.syncTargets.count) Photos")) : L10n.tr("Copy")) {
                    editor.copyEditItems = items; editor.editCopyDraft = nil
                    if syncing { sync(draft.transfer, draft.syncTargets) } else { editor.copiedEdits = draft.transfer; copied() }
                }.buttonStyle(.primaryAction).keyboardShortcut(.defaultAction).disabled(items.isEmpty)
            }.controlSize(.large)
        }.padding(24).frame(width: 380).background(Theme.panel)
        .onAppear {
            expanded = Set(EditTransferSection.allCases.filter { section in
                let chosen = section.items.filter(items.contains).count
                return chosen > 0 && chosen < section.items.count
            })
        }
    }
    @ViewBuilder private func sectionRows(_ section: EditTransferSection) -> some View {
        let members = section.items
        let chosen = members.filter(items.contains).count
        if members.count == 1, let item = members.first {
            CopyEditRow(title: item.localizedTitle, detail: detail(item), state: items.contains(item) ? .on : .off, dimmed: !modified(item)) { toggle([item]) }
        } else {
            let isOpen = expanded.contains(section)
            CopyEditRow(title: section.localizedTitle, detail: nil, state: chosen == 0 ? .off : chosen == members.count ? .on : .mixed,
                        dimmed: !members.contains(where: modified), disclosure: isOpen) { toggle(members) } disclose: {
                withAnimation(.easeOut(duration: 0.15)) { if isOpen { expanded.remove(section) } else { expanded.insert(section) } }
            }
            if isOpen {
                ForEach(members) { item in
                    CopyEditRow(title: item.localizedTitle, detail: detail(item), state: items.contains(item) ? .on : .off, dimmed: !modified(item)) { toggle([item]) }
                        .padding(.leading, 26)
                }
            }
        }
    }
    /// A partly chosen section is completed first; a complete one is cleared.
    private func toggle(_ members: [EditTransferItem]) {
        if members.allSatisfy(items.contains) { items.subtract(members) } else { items.formUnion(members) }
    }
    private func modified(_ item: EditTransferItem) -> Bool { draft.transfer.isModified(item) }
    private func detail(_ item: EditTransferItem) -> String? {
        let a = draft.transfer.adjustments
        switch item {
        case .masks: return a.masks.isEmpty ? nil : "\(a.masks.count)"
        case .brushStrokes: let n = a.retouch.filter { $0.group == .drawn }.count; return n == 0 ? nil : "\(n)"
        case .dustSpots: let n = a.retouch.filter { $0.group == .dust }.count; return n == 0 ? nil : "\(n)"
        case .faceSpots: let n = a.retouch.filter { $0.group == .face }.count; return n == 0 ? nil : "\(n)"
        case .people: let n = a.retouch.filter { $0.group == .people }.count; return n == 0 ? nil : "\(n)"
        default: return nil
        }
    }
}

/// One line of the Copy Edits tree: a checkbox, its title, and for a section the disclosure chevron.
private struct CopyEditRow: View {
    enum State { case on, off, mixed }
    let title: String
    let detail: String?
    let state: State
    let dimmed: Bool
    var disclosure: Bool? = nil
    let toggle: () -> Void
    var disclose: () -> Void = {}
    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    Image(systemName: state == .on ? "checkmark.square.fill" : state == .mixed ? "minus.square.fill" : "square")
                        .font(.system(size: 16)).foregroundStyle(state == .off ? .secondary : Theme.accent)
                    Text(title).foregroundStyle(dimmed ? .secondary : .primary)
                    if let detail { Text(detail).font(.caption).monospacedDigit().foregroundStyle(.secondary) }
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, minHeight: 26, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityValue(state == .on ? L10n.tr("Selected") : state == .mixed ? L10n.tr("Partly selected") : L10n.tr("Not selected"))
            if let disclosure {
                Button(action: disclose) {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(disclosure ? 90 : 0)).frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(disclosure ? L10n.tr("Collapse \(title)") : L10n.tr("Expand \(title)"))
            }
        }
    }
}

/// Copy and Paste Edits in the bottom bar, acting on the Library selection or the open photo like ⌘C and ⌘V. A wide bar
/// names the copy button.
struct EditClipboardControls: View {
    @ObservedObject var catalog: CatalogModel
    @ObservedObject var editor: EditorModel
    var showsTitle = false
    var body: some View {
        HStack(spacing: 4) {
            Menu {
                Button(L10n.tr("Copy Changed Edits")) { catalog.copyCurrentEdits(editor: editor, .edited) }
                Button(L10n.tr("Copy Selected Edits…")) { catalog.copyCurrentEdits(editor: editor, .choosing) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "doc.on.doc")
                    if showsTitle { Text(L10n.tr("Copy All Edits")) }
                }.font(.system(size: 13)).frame(height: 28)
            } primaryAction: { catalog.copyCurrentEdits(editor: editor) }
                .menuStyle(.borderlessButton).fixedSize().focusable(false).disabled(!catalog.canCopyEdits(editor: editor))
                .help(L10n.tr("Copy Edits (⌘C); hold for Copy Changed Edits (⌥⌘C) or Copy Selected Edits… (⇧⌘C)")).accessibilityLabel(L10n.tr("Copy edits"))
            Button { catalog.pasteCopiedEdits(editor: editor) } label: {
                Image(systemName: "doc.on.clipboard").font(.system(size: 13)).frame(width: 28, height: 28).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!catalog.canPasteEdits(editor: editor))
                .help(editor.copiedEdits.map { L10n.tr("Paste Edits from \($0.sourceName) (⌘V)") } ?? L10n.tr("Paste Edits (⌘V)")).accessibilityLabel(L10n.tr("Paste edits"))
        }
    }
}
