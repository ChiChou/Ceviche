import AppKit
import SwiftUI
import CevicheCore

/// What the History panel works on: the photo open in Develop (`EditorModel`) or the one selected in the Library
/// (`CatalogModel`), each reading and changing the catalog's revisions and snapshots for its photo.
@MainActor protocol HistorySource: ObservableObject {
    /// The photo whose history shows; the panel reloads when it changes.
    var historySubjectID: String? { get }
    var historySubjectAvailable: Bool { get }
    var historyBusy: Bool { get }
    /// Whether the development differs from the original, so Reset All Edits has something to do.
    var canResetEdits: Bool { get }
    /// False for a standalone document, which has Undo but no catalog history.
    var keepsHistory: Bool { get }
    /// Set by Photo › New Snapshot… (⇧⌘N); the panel opens its name field and clears it.
    var snapshotNameRequested: Bool { get set }
    var history: [CatalogRevision] { get }
    var snapshots: [CatalogSnapshot] { get }
    func refreshHistory()
    func resetAllEdits()
    func revert(to revision: CatalogRevision)
    func takeSnapshot(named name: String)
    func applySnapshot(_ snapshot: CatalogSnapshot)
    func renameSnapshot(_ snapshot: CatalogSnapshot, to name: String)
    func deleteSnapshot(_ snapshot: CatalogSnapshot)
}

/// Named snapshots above automatic history. Snapshot names rename in place; their thumbnail and Apply button
/// restore the snapshot. Automatic history rows retain their click-to-revert behavior.
struct HistoryPanel<Model: HistorySource>: View {
    @ObservedObject var model: Model
    @State private var newSnapshotName: String?
    @State private var renaming: String?
    @State private var confirmingReset = false
    @FocusState private var nameFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.keepsHistory {
                snapshotSection
                historySection
            } else {
                resetButton
                Text(L10n.tr("History and snapshots are kept for photos in the library. Standalone documents use Undo and Redo."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .alert(L10n.tr("Reset All Edits?"), isPresented: $confirmingReset) {
            Button(L10n.tr("Reset All Edits"), role: .destructive, action: model.resetAllEdits)
            Button(L10n.tr("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.tr("Every adjustment, crop and mask returns to the camera defaults. Originals are not changed."))
        }
        .onAppear { model.refreshHistory(); startRequestedSnapshot() }
        .onChange(of: model.snapshotNameRequested) { _, _ in startRequestedSnapshot() }
        .onChange(of: model.historySubjectID) { _, _ in model.refreshHistory() }
    }

    private func startRequestedSnapshot() {
        guard model.snapshotNameRequested else { return }
        model.snapshotNameRequested = false
        guard model.keepsHistory, model.historySubjectAvailable, !model.historyBusy, newSnapshotName == nil else { return }
        newSnapshotName = L10n.tr("Snapshot \(model.snapshots.count + 1)"); nameFocused = true
    }

    private var snapshotSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionTitle(L10n.tr("Snapshots"), count: model.snapshots.count)
                Spacer()
                Button { newSnapshotName = L10n.tr("Snapshot \(model.snapshots.count + 1)"); nameFocused = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).disabled(!model.historySubjectAvailable || model.historyBusy || newSnapshotName != nil)
                    .help(L10n.tr("Save the current development as a snapshot. Snapshots are kept until you delete them.")).accessibilityLabel(L10n.tr("New snapshot"))
            }
            if let name = newSnapshotName {
                HStack(spacing: 6) {
                    TextField(L10n.tr("Name"), text: Binding(get: { name }, set: { newSnapshotName = $0 })).textFieldStyle(.formField).focused($nameFocused)
                        .onSubmit(commitSnapshot)
                    Button(L10n.tr("Save"), action: commitSnapshot).keyboardShortcut(.defaultAction).buttonStyle(.primaryAction)
                    Button(L10n.tr("Cancel")) { newSnapshotName = nil }.keyboardShortcut(.cancelAction).buttonStyle(.secondaryAction)
                }.controlSize(.small)
            }
            ForEach(model.snapshots) { snapshot in
                HistoryRow(thumbnail: snapshot.thumbnail, title: snapshot.name, date: snapshot.createdAt, icon: "camera", action: L10n.tr("Restore"),
                           renameEditing: Binding(get: { renaming == snapshot.id }, set: { renaming = $0 ? snapshot.id : nil }),
                           rename: { model.renameSnapshot(snapshot, to: $0) }) { model.applySnapshot(snapshot) }
                    .id("\(model.historySubjectID ?? "")/\(snapshot.id)")
                    .disabled(model.historyBusy)
                    .contextMenu {
                        Button(L10n.tr("Restore Snapshot")) { model.applySnapshot(snapshot) }
                        Button(L10n.tr("Rename…")) { renaming = snapshot.id }
                        Divider()
                        Button(L10n.tr("Delete Snapshot"), role: .destructive) { model.deleteSnapshot(snapshot) }
                    }
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                sectionTitle(L10n.tr("History"), count: model.history.count)
                    .help(L10n.tr("Older steps are combined by hour, then by day. Snapshots and milestones are kept."))
            }.padding(.bottom, 2)
            ForEach(Array(model.history.enumerated()), id: \.element.id) { index, entry in
                let step = HistoryStep(entry.summary)
                HistoryRow(thumbnail: entry.thumbnail, title: step.title, date: entry.createdAt, icon: step.icon,
                           action: index == 0 ? nil : L10n.tr("Restore"), current: index == 0) { model.revert(to: entry) }
                    .contextMenu {
                        Button(L10n.tr("Restore This Step")) { model.revert(to: entry) }.disabled(index == 0)
                    }
            }
            resetButton.padding(.top, 8)
        }
    }
    /// Back to the original development, after a confirmation: a full-width button below the steps, away from the rows.
    private var resetButton: some View {
        Button { confirmingReset = true } label: { Text(L10n.tr("Reset All Edits")).frame(maxWidth: .infinity) }
            .buttonStyle(.secondaryAction)
            .disabled(!model.historySubjectAvailable || model.historyBusy || !model.canResetEdits)
    }
    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title).textCase(.uppercase).font(.system(size: 10, weight: .semibold)).tracking(1.2)
            Text(L10n.tr("\(count)")).font(.system(size: 10)).monospacedDigit().foregroundStyle(.tertiary)
        }
    }
    private func commitSnapshot() {
        guard let name = newSnapshotName else { return }
        model.takeSnapshot(named: name); newSnapshotName = nil
    }
}

/// A step as the panel shows it. Steps are stored as sentences ("Applied preset “Bright”", "Reverted to “…”"); the
/// panel shows what the step is by a symbol and names it by the thing itself, so a revert of a preset reads as that
/// preset, not as a quotation inside a quotation.
struct HistoryStep {
    let title: String
    let icon: String?
    private static let mark = "\u{1}"
    /// The name inside a stored sentence made from `template`, when `summary` is one.
    private static func name(in summary: String, _ template: String) -> String? {
        let parts = template.components(separatedBy: mark)
        guard parts.count == 2, summary.count > parts[0].count + parts[1].count, summary.hasPrefix(parts[0]), summary.hasSuffix(parts[1]) else { return nil }
        return String(summary.dropFirst(parts[0].count).dropLast(parts[1].count))
    }
    init(_ summary: String) {
        if let inner = Self.name(in: summary, L10n.tr("Reverted to “\(Self.mark)”")) {
            title = HistoryStep(inner).title; icon = "arrow.uturn.backward"
        } else if let name = LookKind.allCases.lazy.compactMap({ Self.name(in: summary, $0.appliedSummary(Self.mark)) }).first {
            title = name; icon = ToolTab.looks.icon
        } else if summary == L10n.tr("Original development") {
            title = L10n.tr("Original"); icon = "photo"
        } else if summary == L10n.tr("Saved development") {
            title = L10n.tr("Saved"); icon = nil
        } else {
            title = summary; icon = nil
        }
    }
}

private struct HistoryRow: View {
    let thumbnail: Data?
    let title: String
    let date: Date
    var icon: String?
    var action: String?
    var current = false
    var renameEditing: Binding<Bool> = .constant(false)
    var rename: ((String) -> Void)?
    let perform: () -> Void
    @State private var hovering = false
    var body: some View {
        Group {
            if rename != nil { rowContent }
            else {
                Button(action: { if action != nil { perform() } }) { rowContent }.buttonStyle(.plain)
                    .accessibilityLabel(title)
            }
        }
        .onHover { hovering = $0 }
        .help(date.localized(date: .abbreviated, time: .shortened))
    }
    private var rowContent: some View {
            HStack(spacing: 10) {
                Group {
                    if rename != nil {
                        Button(action: perform) { thumbnailView }.buttonStyle(.plain)
                            .accessibilityLabel(action ?? L10n.tr("Restore"))
                    } else { thumbnailView }
                }.frame(width: 44, height: 30).clipped()
                HStack(spacing: 5) {
                    if let icon { Image(systemName: icon).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary).frame(width: 12) }
                    if let rename {
                        InlineRenameLabel(name: title, editing: renameEditing, fontSize: 11, commit: rename)
                    } else {
                        Text(title).font(.system(size: 11, weight: current ? .semibold : .regular)).lineLimit(2)
                    }
                }
                Spacer(minLength: 6)
                // The time gives way to the action under the pointer, Restore for a snapshot as for a step; a snapshot's
                // is a button, since a click on its name renames it.
                if let action, rename != nil, hovering {
                    Button(action, action: perform).buttonStyle(.plain).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.accent)
                } else if let action, hovering {
                    Text(action).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.accent)
                } else {
                    Text(current ? L10n.tr("Now") : date.localizedRelativeShort()).font(.system(size: 10)).monospacedDigit()
                        .foregroundStyle(current ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary)).lineLimit(1).fixedSize()
                }
            }
            .padding(.vertical, 4).padding(.horizontal, 6).contentShape(Rectangle())
            .background(current ? Theme.accent.opacity(0.1) : hovering ? Theme.ink.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))

    }
    @ViewBuilder private var thumbnailView: some View {
        if let thumbnail, let image = NSImage(data: thumbnail) { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
        else { Theme.ink.opacity(0.05).overlay(Image(systemName: "photo").font(.system(size: 10)).foregroundStyle(.tertiary)) }
    }

}
