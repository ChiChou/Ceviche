import SwiftUI
import MapKit
import CevicheCore

/// The frozen plan the user confirms: every photo, and whether its file on disk goes with it.
struct CatalogDeletionConfirmation: View {
    @ObservedObject var model: CatalogModel
    let presented: CatalogDeletionBatch
    /// The live batch: its progress fills in while the sheet is up.
    private var plan: CatalogDeletionBatch { model.pendingDeletion.flatMap { $0.id == presented.id ? $0 : nil } ?? presented }
    private var entries: [CatalogRemovalEntry] { plan.removal.entries }
    /// Every photo is a copy the catalog made, so every file goes without asking. A list with referenced originals
    /// gets the checkbox, which decides for those files; copies go either way.
    private var allCopies: Bool { plan.removal.references.isEmpty }
    private var deletingFiles: Bool { allCopies || model.deleteReferencedFiles }
    private var working: Bool { plan.removing }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 30)).foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.title3.weight(.semibold))
                    Text(summary).fixedSize(horizontal: false, vertical: true)
                }
            }
            list
            .card()
            if !allCopies {
                Toggle(L10n.tr("Also delete the files from disk"), isOn: $model.deleteReferencedFiles).toggleStyle(.formCheckbox)
                    .disabled(working)
            }
            HStack(spacing: 10) {
                if plan.showsProgress { progress }
                Spacer()
                // No default action: Return does nothing here, Escape cancels, and only the destructive button carries color.
                Button(L10n.tr("Cancel"), action: model.cancelPermanentDeletion).keyboardShortcut(.cancelAction).buttonStyle(.secondaryAction)
                    .disabled(working)
                Button(deletingFiles ? L10n.tr("Delete Files and Photos") : L10n.tr("Remove from Library"), role: .destructive) { Task { await model.confirmPermanentDeletion() } }
                    .buttonStyle(.destructiveAction)
                    .disabled(working)
            }.controlSize(.large)
        }.padding(24).frame(width: 520).background(Theme.panel)
        .onExitCommand(perform: model.cancelPermanentDeletion)
        .interactiveDismissDisabled(working)
    }
    /// A few rows size the list to them. More take its full height and lay out only the rows in view, so a
    /// selection of hundreds opens as fast as one.
    @ViewBuilder private var list: some View {
        let content = ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
            if index > 0 { Rule() }
            row(entry)
        }
        if entries.count > 4 {
            ScrollView { LazyVStack(alignment: .leading, spacing: 0) { content } }.frame(height: 280)
        } else {
            ScrollView { VStack(alignment: .leading, spacing: 0) { content } }.frame(maxHeight: 280).fixedSize(horizontal: false, vertical: true)
        }
    }
    /// A bar with its count while referenced files go one by one; a spinner while only the records and copies go.
    @ViewBuilder private var progress: some View {
        if let step = plan.progress, step.total > 0 {
            Text(L10n.tr("Deleting files…")).font(.caption).foregroundStyle(.secondary)
            ProgressView(value: Double(step.done), total: Double(step.total)).progressViewStyle(.linear).tint(Theme.accent).frame(width: 120)
            Text(verbatim: "\(step.done.formatted()) / \(step.total.formatted())").font(.caption).foregroundStyle(.secondary).monospacedDigit()
        } else {
            ProgressView().controlSize(.small)
            Text(L10n.tr("Removing photos…")).font(.caption).foregroundStyle(.secondary)
        }
    }
    private var title: String {
        let count = entries.count
        if deletingFiles { return count == 1 ? L10n.tr("Delete the Photo Permanently?") : L10n.tr("Delete \(count) Photos Permanently?") }
        return count == 1 ? L10n.tr("Remove the Photo from the Library?") : L10n.tr("Remove \(count) Photos from the Library?")
    }
    private var summary: String {
        let count = entries.count
        let text = deletingFiles
            ? (count == 1 ? L10n.tr("The photo and its file are deleted, with its edits and history.") : L10n.tr("\(count) photos and their files are deleted, with their edits and history."))
            : (count == 1 ? L10n.tr("The photo is removed from the library and its albums with its edits and history.") : L10n.tr("\(count) photos are removed from the library and their albums with their edits and history."))
        return text + L10n.tr(" You can’t undo this.")
    }
    private func row(_ entry: CatalogRemovalEntry) -> some View {
        let location = OriginalLocation(locator: entry.locator)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "doc").foregroundStyle(.secondary).frame(width: 18).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.filename).fontWeight(.medium)
                location.text.font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            badge(entry.inTrash)
        }.padding(.horizontal, 12).padding(.vertical, 10)
    }
    private func badge(_ inTrash: Bool) -> some View {
        Text(inTrash ? L10n.tr("Trash") : L10n.tr("Library")).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.ink.opacity(0.08), in: Capsule())
    }
}
