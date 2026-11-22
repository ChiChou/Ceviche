import SwiftUI
import AppKit
import CevicheCore

/// Develop's view of a latent image: it has no pixels to edit, so it shows the preview its tool saved and a card that
/// says what it is and opens that tool. The editing panels stay hidden while it shows.
struct LatentDetailView: View {
    @ObservedObject var catalog: CatalogModel
    @ObservedObject var editor: EditorModel
    let asset: CatalogAsset
    /// The secondary window shows the picture alone.
    var opensTool = true
    private struct Loaded { var image: NSImage?; var tool: String?; var photos = 0; var width = 0; var height = 0 }
    @State private var loaded: Loaded?
    @State private var hovering = false
    var body: some View {
        ZStack {
            Theme.imageSurround
            if let image = loaded?.image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(24)
            } else if loaded == nil {
                ProgressView().controlSize(.small)
            }
        }
        .overlay {
            if opensTool, let loaded, let tool = loaded.tool { card(loaded, tool: tool) }
        }
        .openPhotoContextMenu(catalog: catalog, editor: editor)
        // Runs again when the tool closes, since the workspace comes back with what it saved.
        .task(id: asset.id) { await load() }
    }
    /// The preview is only a picture of the work: the card says what the cell is and how to carry on with it.
    private func card(_ loaded: Loaded, tool: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "circle.bottomhalf.filled").font(.system(size: 22, weight: .medium)).foregroundStyle(Theme.accent)
                .frame(width: 48, height: 48).background(Theme.accent.opacity(0.16), in: Circle())
            VStack(spacing: 6) {
                Text(L10n.tr("Latent Image")).font(.title3.weight(.semibold))
                Text(facts(loaded)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(L10n.tr("This document was created by \(tool) with your previous settings and sources. Open it to pick up where you left off, change anything and export again."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(L10n.tr("Open in \(tool)")) { catalog.openLatent(asset) }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!catalog.canStartJob || catalog.toolOpen)
                .brightness(hovering ? 0.08 : 0)
                .onHover { hovering = $0 }
        }
        .multilineTextAlignment(.center).frame(width: 340).padding(.horizontal, 28).padding(.vertical, 24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
        .environment(\.colorScheme, .dark)
    }
    private func facts(_ loaded: Loaded) -> String {
        let photos = loaded.photos == 1 ? L10n.tr("1 photo") : L10n.tr("\(loaded.photos) photos")
        guard loaded.width > 0, loaded.height > 0 else { return photos }
        return photos + "  ·  " + "\(loaded.width) × \(loaded.height)"
    }
    private func load() async {
        loaded = nil
        guard let url = try? await catalog.resolveOriginal(asset) else { loaded = Loaded(); return }
        let result = await Task.detached(priority: .userInitiated) { () -> Loaded in
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let image = NSImage(contentsOf: LatentImage.previewURL(in: url))
            guard let latent = try? LatentImage.load(url) else { return Loaded(image: image) }
            return Loaded(image: image, tool: latent.type, photos: latent.sources.count, width: latent.width, height: latent.height)
        }.value
        guard !Task.isCancelled else { return }
        // The tool's name is read on the main actor; until then `tool` holds the latent image's type.
        loaded = result; loaded?.tool = result.tool.flatMap(Self.toolTitle)
    }
    static func toolTitle(_ type: String) -> String? {
        switch type {
        case LatentImage.creativeFilters: L10n.tr("Creative Filters")
        case LatentImage.panorama: L10n.tr("Panorama Merge")
        case LatentImage.focusStack: L10n.tr("Focus Stack")
        case LatentImage.timelapse: L10n.tr("Timelapse Video")
        default: NightSkyTool(rawValue: type)?.title
        }
    }
}
