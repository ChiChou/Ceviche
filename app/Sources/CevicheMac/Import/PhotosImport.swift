import SwiftUI
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers
import CevicheCore

/// A downloaded original is a lease: the importer removes staging only after making its catalog copy.
struct ImportedPhotoFile {
    let url: URL
    let directory: URL
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

/// The system picker grants only the selected items. Never request PhotoKit authorization
/// or fetch PHAssets: even limited-library access is unnecessary for this workflow.
struct PhotosImportPicker: ViewModifier {
    @ObservedObject var catalog: CatalogModel
    @State private var selection: [PhotosPickerItem] = []

    func body(content: Content) -> some View {
        content.photosPicker(isPresented: $catalog.showingPhotosImport, selection: $selection,
                             matching: .images, preferredItemEncoding: .current)
            .onChange(of: selection) { _, items in
                guard !items.isEmpty else { return }
                selection = [] // The same photo may be picked again after a failed transfer.
                catalog.importPhotos(items)
            }
    }
}

/// Copy within the receiving callback: the provider's URL expires when it returns.
/// A file representation preserves metadata and avoids loading large RAWs into Data.
struct PickedPhoto: Transferable {
    let file: ImportedPhotoFile

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            try stage(received.file)
        }
    }

    static func stage(_ source: URL) throws -> PickedPhoto {
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ceviche-Photos-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: destination)
            try Task.checkCancellation()
            return PickedPhoto(file: ImportedPhotoFile(url: destination, directory: directory))
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}

extension CatalogModel {
    func importPhotos(_ selection: [PhotosPickerItem]) {
        guard let store, canStartJob, !selection.isEmpty else { return }
        let items = selection.enumerated().map { index, item in
            // Picker identifiers aren't file paths, and selection doesn't expose filenames.
            // Keep each item separate until the provider supplies its actual file.
            ImportItem(url: nil, locator: nil, transferPath: "Photos/\(index)/\(L10n.tr("Photo"))", download: { report in
                try Task.checkCancellation()
                guard let photo = try await item.loadTransferable(type: PickedPhoto.self) else {
                    throw EditorError.invalidDocument(L10n.tr("Could not load photo."))
                }
                if Task.isCancelled { photo.file.remove(); throw CancellationError() }
                report(1)
                return photo.file
            })
        }
        activity.start(.importing, title: L10n.tr("Importing photos"), total: items.count) { [weak self] job in
            await self?.runImport(items, mode: .copy, store: store, job: job)
        }
    }
}
