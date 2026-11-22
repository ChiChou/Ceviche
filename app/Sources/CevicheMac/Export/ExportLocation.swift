import SwiftUI
import AppKit
import CevicheCore

/// The top of a Library export: the folder, and what to do when a file of the same name is already there.
struct ExportLocation: View {
    @ObservedObject var session: CatalogExportSession
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ExportRow(L10n.tr("Folder")) {
                HStack(spacing: 8) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(session.destination.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? L10n.tr("Chosen when you export"))
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(session.destination == nil ? .secondary : .primary)
                        .help(session.destination?.path ?? "")
                        // A long path truncates instead of widening the dialog.
                        .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 4)
                    Button(L10n.tr("Choose…"), action: session.chooseDestination).controlSize(.small)
                }
            }
            ExportRow(L10n.tr("If a file exists")) {
                PanelPicker(title: L10n.tr("If a file exists"), selection: $session.existing, options: Array(ExistingFilePolicy.allCases), label: \.title)
            }
        }
        .font(.system(size: 12))
    }
}
