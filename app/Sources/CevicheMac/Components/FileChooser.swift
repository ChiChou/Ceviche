import SwiftUI
import UniformTypeIdentifiers
import CevicheCore
#if os(macOS)
import AppKit
#endif

/// What to let the user open: files, folders or both, of some types.
struct FileOpenRequest {
    var types: [UTType] = []
    var files = true
    var folders = false
    var multiple = false
    var createFolders = false
    var message: String?
    var prompt: String?
    var directory: URL?
    /// Extra controls under the panel on macOS, such as Copy or Reference for an import.
    var accessory: AnyView?
}

/// Where to save one file.
struct FileSaveRequest {
    var name: String
    var types: [UTType] = []
    var message: String?
    var prompt: String?
    var directory: URL?
}

/// A yes-or-no question before an action that can't be taken back.
struct ConfirmationRequest {
    var title: String
    var message: String
    var action: String
    var destructive = false
}

/// Asks the user for files, a place to save and confirmations, so models never present AppKit panels themselves.
/// Results are async: on macOS the panels run modally and answer at once; an iPad shell answers from
/// `fileImporter`, `fileExporter` and `confirmationDialog` once the user is done.
@MainActor
enum FileChooser {
    /// The chosen URLs, or nil when cancelled.
    static func open(_ request: FileOpenRequest) async -> [URL]? {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = request.files; panel.canChooseDirectories = request.folders
        panel.allowsMultipleSelection = request.multiple; panel.canCreateDirectories = request.createFolders
        if !request.types.isEmpty { panel.allowedContentTypes = request.types }
        if let message = request.message { panel.message = message }
        if let prompt = request.prompt { panel.prompt = prompt }
        if let directory = request.directory { panel.directoryURL = directory }
        if let accessory = request.accessory {
            // Sized up front: a hosting view left at zero size still draws, but takes no clicks.
            let host = NSHostingView(rootView: accessory)
            host.frame.size = host.fittingSize
            panel.accessoryView = host; panel.isAccessoryViewDisclosed = true
        }
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return nil }
        panel.urls.forEach { FileAccess.shared.remember($0) }
        return panel.urls
        #else
        return await presenter?.open(request)
        #endif
    }
    static func openOne(_ request: FileOpenRequest) async -> URL? { await open(request)?.first }

    /// The URL to write, or nil when cancelled.
    static func save(_ request: FileSaveRequest) async -> URL? {
        #if os(macOS)
        let panel = NSSavePanel(); panel.canCreateDirectories = true
        panel.nameFieldStringValue = request.name
        if !request.types.isEmpty { panel.allowedContentTypes = request.types }
        if let message = request.message { panel.message = message }
        if let prompt = request.prompt { panel.prompt = prompt }
        if let directory = request.directory { panel.directoryURL = directory }
        guard panel.runModal() == .OK else { return nil }
        if let url = panel.url { FileAccess.shared.remember(url) }
        return panel.url
        #else
        return await presenter?.save(request)
        #endif
    }

    /// True when the user takes the action.
    static func confirm(_ request: ConfirmationRequest) async -> Bool {
        #if os(macOS)
        let alert = NSAlert()
        if request.destructive { alert.alertStyle = .warning }
        alert.messageText = request.title; alert.informativeText = request.message
        alert.addButton(withTitle: request.action); alert.addButton(withTitle: L10n.tr("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
        #else
        return await presenter?.confirm(request) ?? false
        #endif
    }

    #if !os(macOS)
    /// Installed by the iPad shell's root view, which presents the requests with SwiftUI.
    static var presenter: FileChooserPresenter?
    #endif
}

#if !os(macOS)
@MainActor
protocol FileChooserPresenter: AnyObject {
    func open(_ request: FileOpenRequest) async -> [URL]?
    func save(_ request: FileSaveRequest) async -> URL?
    func confirm(_ request: ConfirmationRequest) async -> Bool
}
#endif

extension UTType {
    static let xmp = UTType(filenameExtension: "xmp") ?? .xml
    static let iccProfiles = [UTType(filenameExtension: "icc") ?? .data, UTType(filenameExtension: "icm") ?? .data]
}
