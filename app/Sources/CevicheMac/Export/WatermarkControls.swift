import SwiftUI
import AppKit
import CevicheCore

/// The saved watermarks, shared by every export dialog and the Watermarks settings.
@MainActor
final class WatermarkStore: ObservableObject {
    static let shared = WatermarkStore()
    let library: WatermarkLibrary
    @Published private(set) var watermarks: [Watermark]
    init(library: WatermarkLibrary = .standard) {
        self.library = library
        // Images picked for watermarks that were never saved are left behind when a dialog closes mid-edit.
        library.pruneImages()
        watermarks = library.watermarks()
    }
    func save(_ watermark: Watermark) throws { try library.save(watermark); watermarks = library.watermarks() }
    func delete(_ id: UUID) throws { try library.delete(id); watermarks = library.watermarks() }
    /// Asks for an image in a format with transparency and copies it into the library. The panel is a sheet on `window`:
    /// run as a modal window over a sheet, it never receives the keyboard.
    func chooseImage(for window: NSWindow?) async throws -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = WatermarkLibrary.imageTypes
        panel.prompt = L10n.tr("Choose"); panel.message = L10n.tr("Choose a watermark image")
        let response = if let window { await panel.beginSheetModal(for: window) } else { panel.runModal() }
        guard response == .OK, let url = panel.url else { return nil }
        return try library.importImage(url)
    }
    /// A text watermark to start from: a copyright line with this Mac user's name.
    func newWatermark() -> Watermark { Watermark(name: L10n.tr("Watermark \(watermarks.count + 1)"), text: Self.copyright()) }
    static func copyright() -> WatermarkText {
        let owner = NSFullUserName().isEmpty ? "" : " " + NSFullUserName()
        return WatermarkText(string: "© \(Calendar.current.component(.year, from: Date()))\(owner)")
    }
}

/// Which tab Settings shows; set before opening it on the Watermarks tab.
enum PreferencesTab: String { case general, watermarks, idPhoto, profiles, models, mcp; static let key = "preferencesTab" }

/// A watermark open in the editor dialog.
struct WatermarkEditing: Identifiable {
    let watermark: Watermark
    let isNew: Bool
    var id: UUID { watermark.id }
}

/// The export dialog's watermark row: None, the saved watermarks, New Watermark… and Manage Watermarks…, with a button
/// that edits the chosen one. Creating and editing happen in their own dialog.
struct WatermarkControls<Model: ExportTarget>: View {
    @ObservedObject var model: Model
    /// The photo as it exports, shown under the watermark while it is edited: made when the editor first opens.
    @State private var backdrop: CGImage?
    @ObservedObject private var store = WatermarkStore.shared
    @Environment(\.openSettings) private var openSettings
    @AppStorage(PreferencesTab.key) private var preferencesTab = PreferencesTab.general.rawValue
    @State private var editing: WatermarkEditing?

    private enum Choice: Hashable { case none, saved(UUID) }

    var body: some View {
        ExportRow(L10n.tr("Watermark")) {
            HStack(spacing: 6) {
                FormSelect(L10n.tr("Watermark"), selection: Binding(get: { choice }, set: choose),
                           valueLabel: model.exportSettings.watermark?.name ?? L10n.tr("None")) {
                    Text(L10n.tr("None")).tag(Choice.none)
                    ForEach(store.watermarks) { Text($0.name).tag(Choice.saved($0.id)) }
                }
                ActionMenu(L10n.tr("Watermark"), icon: "ellipsis") {
                    Button(L10n.tr("New Watermark…")) { edit(WatermarkEditing(watermark: store.newWatermark(), isNew: true)) }
                    Button(L10n.tr("Manage Watermarks…")) { preferencesTab = PreferencesTab.watermarks.rawValue; openSettings() }
                }
                if let current = model.exportSettings.watermark {
                    Button { edit(WatermarkEditing(watermark: current, isNew: false)) } label: { Image(systemName: "pencil") }
                        .buttonStyle(.borderless).help(L10n.tr("Edit this watermark")).accessibilityLabel(L10n.tr("Edit watermark"))
                }
            }
        }
        .sheet(item: $editing) { item in
            WatermarkEditorDialog(original: item.watermark, isNew: item.isNew, backdrop: backdrop,
                                  saved: { model.exportSettings.watermark = $0 },
                                  deleted: { if model.exportSettings.watermark?.id == $0 { model.exportSettings.watermark = nil } })
        }
        // Edits and deletions made elsewhere, such as in Settings, reach the export.
        .onChange(of: store.watermarks) { _, all in
            guard let current = model.exportSettings.watermark else { return }
            let latest = all.first { $0.id == current.id }
            if latest != current { model.exportSettings.watermark = latest }
        }
    }

    /// Opens the editor once there is a photo to lay the watermark over; without one it shows on a sample.
    private func edit(_ item: WatermarkEditing) {
        guard backdrop == nil else { editing = item; return }
        Task {
            backdrop = try? await model.makeExportPreview()
            editing = item
        }
    }
    private var choice: Choice { model.exportSettings.watermark.map { .saved($0.id) } ?? .none }

    private func choose(_ choice: Choice) {
        switch choice {
        case .none: model.exportSettings.watermark = nil
        case .saved(let id): model.exportSettings.watermark = store.watermarks.first { $0.id == id }
        }
    }
}
