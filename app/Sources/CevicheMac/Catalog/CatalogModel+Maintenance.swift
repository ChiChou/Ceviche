import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import CevicheCore

/// Restoring revisions, analysing, relinking and backing up the catalog.
extension CatalogModel {
    func restore(_ revision: CatalogRevision) {
        guard !catalogBusy, (selected?.inLibrary ?? true) else { return }
        Task {
            guard await flushMetadata(), let store else { return }
            do {
                // Reload from the store: a concurrent refresh may still hold the pre-restore copy.
                try await store.restore(revision); await reloadSelection()
                notice = L10n.tr("Earlier version restored")
            } catch { self.failure = Failure(L10n.tr("Couldn’t Restore the Earlier Version"), error) }
        }
    }
    func analyze() {
        guard let selected, selected.inLibrary, let store, !catalogBusy else { return }
        Task {
            do {
                try await store.enqueueAnalysis(assetID: selected.id, version: CatalogImporter.analysisVersion)
                indexer.workAvailable()
                indexing = try await store.analysisStatus(); selectedIndexError = nil
                notice = L10n.tr("Queued for analysis")
            } catch { self.error = error.localizedDescription }
        }
    }
    func relink() {
        guard let selected, selected.inLibrary, !selected.isLatent, let store, !catalogBusy else { return }
        Task {
            guard let url = await FileChooser.openOne(FileOpenRequest(message: L10n.tr("Choose the original file for this photo."))) else { return }
            if !selected.hasOriginalIdentity {
                guard await FileChooser.confirm(ConfirmationRequest(title: L10n.tr("Use This File as the Original?"),
                    message: L10n.tr("This photo has no recorded size or capture time, so the file can’t be checked. Choose the same photograph to keep masks and edits aligned."),
                    action: L10n.tr("Use This File"))) else { return }
            }
            maintenance = L10n.tr("Verifying \(url.lastPathComponent)…")
            defer { maintenance = nil }
            do { try await store.relink(url, assetID: selected.id, allowUnverified: !selected.hasOriginalIdentity); await refresh() }
            catch { self.failure = Failure(L10n.tr("Couldn’t Relink the Original"), error) }
        }
    }
    func backup() {
        guard let store, !catalogWideBusy else { return }
        Task {
            guard let destination = await FileChooser.save(FileSaveRequest(name: "Library Backup.cevichecatalog",
                message: L10n.tr("Backs up ratings, metadata, edits, and history. Back up your original photos separately."))),
                  await flushMetadata() else { return }
            maintenance = L10n.tr("Backing up catalog…")
            defer { maintenance = nil }
            do { try await store.backup(to: destination); notice = L10n.tr("Catalog backed up") }
            catch { self.failure = Failure(L10n.tr("Couldn’t Back Up the Catalog"), error) }
        }
    }
    /// A backup that opens anywhere with every photo: the catalog plus a copy of each original, referenced ones included.
    func backupWithOriginals() {
        guard let store, !catalogWideBusy else { return }
        Task {
            guard let destination = await FileChooser.save(FileSaveRequest(name: "Library Backup.cevichecatalog",
                message: L10n.tr("Includes a copy of every original, referenced ones too."))),
                  await flushMetadata() else { return }
            maintenance = L10n.tr("Backing up catalog…"); maintenanceProgress = 0
            defer { maintenance = nil; maintenanceDetail = nil; maintenanceProgress = nil }
            do {
                let result = try await store.backupWithOriginals(to: destination) { done, total in
                    Task { @MainActor in
                        guard total > 0 else { return }
                        self.maintenanceDetail = L10n.tr("\(done) of \(total) originals"); self.maintenanceProgress = Double(done) / Double(total)
                    }
                }
                if result.missing.isEmpty { notice = L10n.tr("Catalog and originals backed up") }
                else {
                    failure = Failure(L10n.tr("Some Originals Weren’t Backed Up"), L10n.tr("\(result.missing.count) offline originals not backed up: \(result.missing.prefix(5).joined(separator: ", "))"))
                }
            } catch { self.failure = Failure(L10n.tr("Couldn’t Back Up the Catalog"), error) }
        }
    }
}
