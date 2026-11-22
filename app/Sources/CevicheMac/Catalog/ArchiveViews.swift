import SwiftUI
import CevicheCore

/// What can happen to archived photos: back to the library, originals moved or copied to a folder with an XMP, or into the
/// Trash like any other photo. Remove from Library… is the same as in the library: the records go, and the files too if
/// the person ticks the box.
struct ArchiveActions: View {
    @ObservedObject var model: CatalogModel
    @ObservedObject var editor: EditorModel
    let targets: [CatalogAsset]
    /// The whole archive: Move All to Folder… and Move All to Trash.
    var all = false
    var body: some View {
        VStack(spacing: 8) {
            if !all {
                Button { Task { await model.unarchive(targets) } } label: { Text(L10n.tr("Unarchive")).frame(maxWidth: .infinity) }
                    .buttonStyle(.primaryAction).help(L10n.tr("Put back in the library"))
            }
            Button { model.requestMoveToFolder(targets) } label: { Text(all ? L10n.tr("Move All to Folder…") : L10n.tr("Move to Folder…")).frame(maxWidth: .infinity) }
                .buttonStyle(all ? .primaryAction : .secondaryAction)
                .help(L10n.tr("Move the originals to a folder with their edits as XMP, and remove them from the catalog"))
            Button { model.exportOriginals(targets) } label: { Text(all ? L10n.tr("Copy All to Folder…") : L10n.tr("Copy to Folder…")).frame(maxWidth: .infinity) }
                .buttonStyle(.secondaryAction)
                .help(L10n.tr("Copy the originals to a folder with their edits as XMP, and keep them in the archive"))
            Button { Task { await model.moveToTrash(targets, editor: editor) } } label: {
                Text(all ? L10n.tr("Move All to Trash") : L10n.tr("Move to Trash")).frame(maxWidth: .infinity)
            }.buttonStyle(.secondaryAction)
            if !all {
                Button(role: .destructive) { Task { await model.requestPermanentDeletion(targets, editor: editor) } } label: {
                    Text(L10n.tr("Remove from Library…")).frame(maxWidth: .infinity)
                }
                .buttonStyle(.destructiveAction)
                .help(L10n.tr("Remove the photo with its edits and history, and choose whether the original file goes too (⌥⌘⌫)"))
            }
        }
        .controlSize(.large).disabled(targets.isEmpty || model.catalogBusy || editor.busy)
    }
}

/// The archive with nothing selected: what is in it, and the actions for all of it.
struct ArchiveOverviewPanel: View {
    @ObservedObject var model: CatalogModel
    @ObservedObject var editor: EditorModel
    @State private var photos: [CatalogAsset] = []
    @State private var summary: ArchiveSummary?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(L10n.tr("Archived"), systemImage: "archivebox").font(.headline)
                    Text(model.archiveCount == 1 ? L10n.tr("1 photo") : L10n.tr("\(model.archiveCount.formatted()) photos"))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                if let summary {
                    InfoSection(L10n.tr("Files")) {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                            row(L10n.tr("Size"), ByteCountFormatter.string(fromByteCount: summary.bytes, countStyle: .file))
                            ForEach(summary.types, id: \.type) { row($0.type, $0.count.formatted()) }
                            row(L10n.tr("In catalog folder"), summary.copies.formatted())
                            row(L10n.tr("Referenced"), summary.references.formatted())
                            if summary.offline > 0 { row(L10n.tr("Not on this Mac"), summary.offline.formatted(), warning: true) }
                        }
                    }
                    InfoSection(L10n.tr("Dates")) {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                            if let captured = span(summary.captured) { row(L10n.tr("Captured"), captured) }
                            if let archived = span(summary.archived) { row(L10n.tr("Archived"), archived) }
                        }
                    }
                }
                ArchiveActions(model: model, editor: editor, targets: photos, all: true)
                Text(L10n.tr("Archived photos stay out of the library with their files untouched. Recovered from the Trash, they come back here."))
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }.padding(16).frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task(id: model.archiveCount) { await load() }
    }
    private func load() async {
        guard let store = model.store else { return }
        var filter = CatalogFilter(); filter.area = .archive
        guard let found = try? await store.assets(filter: filter) else { return }
        photos = found
        let root = model.root
        // Availability looks at each file, which on a share takes a while.
        summary = await Task.detached(priority: .utility) { ArchiveSummary(found, root: root) }.value
    }
    private func span(_ range: ClosedRange<Date>?) -> String? {
        guard let range else { return nil }
        let start = range.lowerBound.localized(date: .abbreviated, time: .omitted), end = range.upperBound.localized(date: .abbreviated, time: .omitted)
        return start == end ? start : start + " – " + end
    }
    private func row(_ title: String, _ value: String, warning: Bool = false) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit().foregroundStyle(warning ? Theme.warning : .primary)
                .gridColumnAlignment(.trailing).frame(maxWidth: .infinity, alignment: .trailing)
        }.font(.system(size: 11))
    }
}

/// Counts for the archive overview.
struct ArchiveSummary: Sendable {
    var bytes: Int64 = 0
    /// File types by count, most first.
    var types: [(type: String, count: Int)] = []
    var copies = 0, references = 0, offline = 0
    var captured: ClosedRange<Date>?
    var archived: ClosedRange<Date>?
    init(_ photos: [CatalogAsset], root: URL?) {
        var types: [String: Int] = [:]
        var captured: [Date] = [], archived: [Date] = []
        let parse = ISO8601DateFormatter(); parse.formatOptions = [.withFullDate]
        for photo in photos {
            bytes += photo.fileSize ?? 0
            types[(photo.filename as NSString).pathExtension.uppercased(), default: 0] += 1
            if photo.isCopy { copies += 1 } else { references += 1 }
            if photo.availability(catalog: root).localURL == nil { offline += 1 }
            if let day = parse.date(from: photo.captureDay) { captured.append(day) }
            if let date = photo.archivedAt { archived.append(date) }
        }
        self.types = types.map { (type: $0.key.isEmpty ? "–" : $0.key, count: $0.value) }.sorted { ($0.count, $1.type) > ($1.count, $0.type) }
        if let low = captured.min(), let high = captured.max() { self.captured = low...high }
        if let low = archived.min(), let high = archived.max() { self.archived = low...high }
    }
}
