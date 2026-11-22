import AppKit
import SwiftUI
import CevicheCore

/// Lives behind the Export control, outside the transient preset menu.
struct PhotoShareAnchor: NSViewRepresentable {
    final class View: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> View { View() }
    func updateNSView(_ nsView: View, context: Context) {}

    static func find(in view: NSView) -> NSView? {
        guard !view.isHiddenOrHasHiddenAncestor else { return nil }
        if view is View, !view.visibleRect.isEmpty { return view }
        return view.subviews.lazy.compactMap { find(in: $0) }.first
    }
}

/// Owns the temporary exports until the selected sharing service finishes reading them.
@MainActor
final class PhotoShare: NSObject, @preconcurrency NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    private static var active: [UUID: PhotoShare] = [:]
    private let id = UUID()
    let folder: URL
    private let reportError: (String) -> Void
    private var picker: NSSharingServicePicker?

    static var settings: ExportSettings {
        var settings = ExportSettings()
        settings.select(.heif)
        settings.depth = 8
        settings.quality = 0.9
        settings.profile.preset = .displayP3
        settings.includeMetadata = true
        settings.includeLocation = true
        settings.preserveAlpha = false
        return settings
    }

    init(reportError: @escaping (String) -> Void) throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("Ceviche-Share-\(UUID().uuidString)", isDirectory: true)
        self.reportError = reportError
        super.init()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    static func export(reportError: @escaping (String) -> Void,
                       render: @escaping @MainActor (URL) async throws -> [URL]) {
        guard let view = (NSApp.keyWindow ?? NSApp.mainWindow)?.contentView else { return }
        ActivityCenter.shared.start(.exporting, title: L10n.tr("Preparing to share…")) { job in
            var session: PhotoShare?
            do {
                let share = try PhotoShare(reportError: reportError)
                session = share
                let files = try await render(share.folder)
                try Task.checkCancellation()
                guard !files.isEmpty, view.window != nil else {
                    share.finish()
                    ActivityCenter.shared.finish(job, outcome: .stopped)
                    return
                }
                active[share.id] = share
                let picker = NSSharingServicePicker(items: files)
                share.picker = picker
                picker.delegate = share
                // Resolve after rendering: the menu is gone and the Export control may have moved.
                let anchor = PhotoShareAnchor.find(in: view) ?? view
                let rect = anchor === view
                    ? NSRect(x: view.bounds.midX, y: view.isFlipped ? view.bounds.minY + 32 : view.bounds.maxY - 32, width: 1, height: 1)
                    : anchor.bounds
                picker.show(relativeTo: rect, of: anchor, preferredEdge: anchor.isFlipped ? .maxY : .minY)
                ActivityCenter.shared.finish(job, title: L10n.tr("Share…"), outcome: .done(""))
            } catch is CancellationError {
                session?.finish()
                ActivityCenter.shared.finish(job, outcome: .stopped)
            } catch {
                session?.finish()
                reportError(error.localizedDescription)
                ActivityCenter.shared.finish(job, outcome: .failed(error.localizedDescription))
            }
        }
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        if service == nil { finish() }
    }
    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, delegateFor sharingService: NSSharingService) -> (any NSSharingServiceDelegate)? { self }
    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) { finish() }
    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        if (error as NSError).code != NSUserCancelledError { reportError(error.localizedDescription) }
        finish()
    }
    func finish() {
        try? FileManager.default.removeItem(at: folder)
        picker = nil
        Self.active[id] = nil
    }
}
