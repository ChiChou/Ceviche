import SwiftUI
import CevicheCore

/// The Library inspector without a selection: the open catalog at a glance. Its name (double-click to rename) and
/// place, how many photos and of what kind, and backing it up.
struct CatalogOverviewPanel: View {
    @ObservedObject var model: CatalogModel
    @State private var overview: CatalogOverview?
    @State private var renaming = false
    var body: some View {
        ScrollView {
            if let manifest = model.manifest, let root = model.root {
                VStack(alignment: .leading, spacing: 18) {
                    // The catalog: its name and where it is.
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 7) {
                            Image(systemName: manifest.kind == .cloud ? "icloud" : "folder").font(.system(size: 13)).foregroundStyle(.secondary)
                            InlineRenameLabel(name: manifest.name, editing: $renaming, fontSize: 14, semibold: true) { model.renameOpenCatalog(to: $0) }
                            Spacer(minLength: 0)
                        }.disabled(model.catalogBusy)
                        Button { NSWorkspace.shared.showInFinder([root]) } label: {
                            HStack(spacing: 4) {
                                Text((root.path as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                                Image(systemName: "arrow.up.forward").font(.system(size: 8, weight: .semibold))
                            }.font(.system(size: 11)).foregroundStyle(.secondary).contentShape(Rectangle())
                        }.buttonStyle(.plain).help(L10n.tr("Show in Finder")).accessibilityLabel(L10n.tr("Show in Finder"))
                    }
                    // Plain rows, as the photo's own Info is: a count is read, not announced.
                    InfoSection(L10n.tr("Photos")) {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                            count(L10n.tr("All Photos"), overview?.photos)
                            count(L10n.tr("RAW"), overview?.raw)
                            count(L10n.tr("Edited"), overview?.edited)
                            count(L10n.tr("Picked"), overview?.picked)
                            count(L10n.tr("Rejected"), overview?.rejected)
                            count(L10n.tr("Archived"), model.archiveCount)
                            count(L10n.tr("In Trash"), model.trashCount)
                        }
                    }
                    InfoSection(L10n.tr("Catalog")) {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                            row(L10n.tr("Type"), manifest.kind.title)
                            if let span = overview.flatMap(captureSpan) { row(L10n.tr("Captured"), span) }
                            row(L10n.tr("Created"), manifest.createdAt.localized(date: .abbreviated, time: .omitted))
                            if manifest.kind == .cloud {
                                row(L10n.tr("Sync"), model.syncState.map(CatalogStatusBar.text) ?? L10n.tr("Saved on This Mac"))
                                    .help((model.syncState.map(CatalogStatusBar.detail) ?? L10n.tr("Your catalog is saved locally. iCloud sync will resume when available."))
                                          + "\n" + L10n.tr("Original photos stay in their current locations and are not uploaded to iCloud."))
                            }
                        }
                    }
                    // The index of browsed folders is a cache: nothing to back up or to show.
                    if !model.isFolderIndex { actions }
                }.padding(16)
            }
        }
        // Clearing the selection brings the panel back, so flags set meanwhile are counted then.
        .task(id: "\(model.root?.path ?? "")|\(model.total)|\(model.trashCount)|\(model.recentEditsCount)") { await load() }
    }

    /// Backing up (the catalog alone, or with its originals), and syncing now for an iCloud catalog.
    private var actions: some View {
        HStack(spacing: 8) {
            Menu {
                Button(L10n.tr("Back Up Catalog…")) { model.backup() }
                Button(L10n.tr("Back Up Catalog with Originals…")) { model.backupWithOriginals() }
            } label: {
                HStack(spacing: 5) { Text(L10n.tr("Back Up")); Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary) }.frame(maxWidth: .infinity)
            }.menuStyle(.button).menuIndicator(.hidden).disabled(model.catalogBusy)
            if BuildFeatures.iCloud, model.manifest?.kind == .cloud {
                Button(action: model.syncNow) { Text(L10n.tr("Sync Now")).frame(maxWidth: .infinity) }.disabled(model.store == nil)
            }
        }.buttonStyle(.secondaryAction)
    }

    /// A count in its row; a zero is dimmed so the counts that say something stand out.
    private func count(_ title: String, _ value: Int?) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value.map { $0.formatted() } ?? "–").monospacedDigit().foregroundStyle((value ?? 0) == 0 ? .tertiary : .primary)
                .textSelection(.enabled).gridColumnAlignment(.trailing).frame(maxWidth: .infinity, alignment: .trailing)
        }.font(.system(size: 12))
    }

    private func row(_ title: String, _ value: String?) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value ?? "–").monospacedDigit().textSelection(.enabled).gridColumnAlignment(.trailing).frame(maxWidth: .infinity, alignment: .trailing)
        }.font(.system(size: 12))
    }

    /// "Mar 2019 – Nov 2026", or one month when every photo shares it.
    private func captureSpan(_ overview: CatalogOverview) -> String? {
        CaptureSpan.months(overview.firstDay, overview.lastDay)
    }

    private func load() async {
        guard let store = model.store else { overview = nil; return }
        overview = try? await store.overview()
    }
}

/// First to last capture day (stored as yyyy-MM-dd) in the reader's own date format, as every panel shows it.
enum CaptureSpan {
    /// A catalog's span, by month.
    static func months(_ first: String?, _ last: String?) -> String? {
        span(first, last) { $0.localized(Date.FormatStyle.dateTime.month(.abbreviated).year()) }
    }
    /// A folder's span, by day, like the Archive's.
    static func days(_ first: String?, _ last: String?) -> String? {
        span(first, last) { $0.localized(date: .abbreviated, time: .omitted) }
    }
    private static func span(_ first: String?, _ last: String?, _ format: (Date) -> String) -> String? {
        let parse = Date.ISO8601FormatStyle(timeZone: .current).year().month().day()
        guard let start = first.flatMap({ try? Date($0, strategy: parse) }), let end = last.flatMap({ try? Date($0, strategy: parse) }) else { return nil }
        let a = format(start), b = format(end)
        return a == b ? a : "\(a) – \(b)"
    }
}
