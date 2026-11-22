import SwiftUI
import AppKit
import CevicheCore

/// Settings › Watermarks: the saved watermarks, to create, change or delete outside an export.
struct WatermarkPreferences: View {
    @ObservedObject private var store = WatermarkStore.shared
    @State private var editing: WatermarkEditing?
    @State private var deleting: Watermark?
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                if store.watermarks.isEmpty {
                    Text(L10n.tr("No watermarks yet. Create one from text or from an image with transparency."))
                        .foregroundStyle(.secondary)
                }
                ForEach(store.watermarks) { watermark in
                    HStack(spacing: 10) {
                        WatermarkThumbnail(watermark: watermark)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(watermark.name)
                            Text(summary(watermark)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L10n.tr("Edit…")) { editing = WatermarkEditing(watermark: watermark, isNew: false) }
                        Button { deleting = watermark } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help(L10n.tr("Delete")).accessibilityLabel(L10n.tr("Delete \(watermark.name)"))
                    }
                }
            } header: {
                Text(L10n.tr("Watermarks"))
            } footer: {
                Text(L10n.tr("Kept on this Mac and shared by every catalog; they are not synced to iCloud. Choose one under Watermark in the export dialog."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button(L10n.tr("New Watermark…")) { editing = WatermarkEditing(watermark: store.newWatermark(), isNew: true) }
                    Button(L10n.tr("Show in Finder")) {
                        try? FileManager.default.createDirectory(at: store.library.root, withIntermediateDirectories: true)
                        NSWorkspace.shared.showInFinder([store.library.root])
                    }
                    Spacer()
                }
                if let error { Text(error).font(.caption).foregroundStyle(Theme.error) }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { item in
            WatermarkEditorDialog(original: item.watermark, isNew: item.isNew, backdrop: nil, saved: { _ in }, deleted: { _ in })
        }
        .confirmationDialog(deleting.map { L10n.tr("Delete the watermark “\($0.name)”?") } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(L10n.tr("Delete"), role: .destructive) {
                if let watermark = deleting { do { try store.delete(watermark.id); error = nil } catch { self.error = error.localizedDescription } }
                deleting = nil
            }
        } message: { Text(L10n.tr("It is removed from every catalog on this Mac.")) }
    }

    private func summary(_ watermark: Watermark) -> String {
        let source = watermark.text != nil ? L10n.tr("Text") : L10n.tr("Image")
        let placement = watermark.layout == .corner ? watermark.corner.title : L10n.tr("Tiled \(Int(watermark.angle.rounded()))°")
        return L10n.tr("\(source) - \(placement) - \(Int((watermark.opacity * 100).rounded()))% opacity")
    }
}

/// The watermark alone on a dark tile, so white logos and text show.
private struct WatermarkThumbnail: View {
    let watermark: Watermark
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Color(white: 0.18))
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(4) }
        }
        .frame(width: 64, height: 40)
        .task(id: watermark) { image = WatermarkPreview.thumbnail(watermark) }
    }
}
