import AppKit
import CevicheCore

/// File drops copy originals by default; Option-Command links them, independently of the Import panel.
/// AppKit's link and copy operations give the drag its matching cursor, including on macOS 15.
@MainActor
struct PhotoImportDrop {
    let mode: CatalogImporter.ImportMode
    var operation: NSDragOperation { mode == .copy ? .copy : .link }

    init(modifiers: NSEvent.ModifierFlags) { mode = modifiers.contains([.option, .command]) ? .reference : .copy }

    func operation(for pasteboard: NSPasteboard, catalog: CatalogModel?) -> NSDragOperation {
        guard let catalog, catalog.store != nil, catalog.canStartJob, !Self.urls(in: pasteboard).isEmpty else { return [] }
        return operation
    }

    func performDrop(from pasteboard: NSPasteboard, catalog: CatalogModel?) -> Bool {
        guard operation(for: pasteboard, catalog: catalog) != [] else { return false }
        return catalog?.importFiles(Self.urls(in: pasteboard), mode: mode) ?? false
    }

    private static func urls(in pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}

/// The window handles file drops that no view claims; album and look-library drops keep their own destinations.
extension AppDelegate: NSDraggingDestination {
    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = PhotoImportDrop(modifiers: NSEvent.modifierFlags).operation(for: sender.draggingPasteboard, catalog: catalog)
        catalog?.photoDropTargeted = operation != []
        return operation
    }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    func draggingExited(_ sender: NSDraggingInfo?) { catalog?.photoDropTargeted = false }
    func wantsPeriodicDraggingUpdates() -> Bool { true }
    func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { draggingEntered(sender) != [] }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        catalog?.photoDropTargeted = false
        // Read modifiers again at release, so changing them while hovering also changes the import.
        return PhotoImportDrop(modifiers: NSEvent.modifierFlags).performDrop(from: sender.draggingPasteboard, catalog: catalog)
    }
}
