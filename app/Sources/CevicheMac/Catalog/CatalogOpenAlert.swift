import SwiftUI
import CevicheCore

extension View {
    /// Asks what to do with a catalog that didn't open as usual, instead of a passing error toast: show it read-only,
    /// or leave it closed. One from before the current schema can't be opened at all.
    func catalogOpenAlert(_ catalog: CatalogModel) -> some View {
        let failure = catalog.catalogOpenFailure
        let title = switch failure?.reason {
        case .newer: L10n.tr("Catalog from a Newer Version")
        default: L10n.tr("Can’t Open Catalog")
        }
        let message = switch failure?.reason {
        case .newer: L10n.tr("Update Ceviche to edit it, or open it read-only; nothing in it changes.")
        case .unreadable(let reason): L10n.tr("\(reason)\n\nOpen it read-only to look through it and export what it holds; nothing in it changes.")
        default: failure?.reason.errorDescription ?? ""
        }
        return alert(title, isPresented: Binding(get: { catalog.catalogOpenFailure != nil }, set: { if !$0 { catalog.catalogOpenFailure = nil } })) {
            if let failure, failure.reason.canOpenReadOnly {
                Button(L10n.tr("Open Read-Only")) {
                    catalog.catalogOpenFailure = nil
                    Task { await catalog.openCatalog(failure.root, folderIndex: failure.folderIndex, readOnly: true) }
                }
                Button(L10n.tr("Cancel"), role: .cancel) { catalog.catalogOpenFailure = nil }
            } else {
                Button(L10n.tr("OK")) { catalog.catalogOpenFailure = nil }
            }
        } message: { Text(message) }
    }
}
