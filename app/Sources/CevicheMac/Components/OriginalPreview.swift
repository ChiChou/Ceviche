import SwiftUI
import ImageIO
import CevicheCore

/// One photo as shot, undeveloped, on a `ZoomCanvas`: pinch, ⌘-scroll or click to zoom, drag or scroll to move. It
/// shows the library thumbnail until the image the culling measure reads (the camera preview where it is large enough)
/// arrives, and the whole original once zoomed in, so 100% is the file's own pixels. `overlay` lies over the picture
/// at its shown size, as on the canvas.
struct OriginalPreview<Overlay: View>: View {
    let asset: CatalogAsset
    let root: URL?
    let previews: PreviewStore?
    /// Each new target zooms to its part of the photo.
    var target: ZoomTarget? = nil
    @ViewBuilder var overlay: (CGSize) -> Overlay

    /// What was read, tagged with its photo, so a photo never shows another's picture while its own is read.
    @State private var loaded: (asset: String, image: OriginalPreviewImage)?
    @State private var whole: (asset: String, image: CGImage)?
    /// The photo zoomed in on, if any.
    @State private var zoomedIn: String?

    var body: some View {
        let id = asset.id
        let measured = loaded?.asset == id ? loaded?.image : OriginalPreviewImage.cache.object(forKey: id as NSString)
        let original = whole?.asset == id ? whole?.image : OriginalPreviewImage.wholes.object(forKey: id as NSString)?.image
        ZStack {
            if let measured {
                // A canvas of its own for each photo: it opens fitted, or on the target it is given.
                ZoomCanvas(image: original ?? measured.image, fullSize: original == nil ? measured.fullSize : nil, target: target,
                           onZoom: { zoomedIn = $0 > 1.01 ? id : nil }, clickZooms: true, overlay: overlay)
                    .id(id)
                    .overlay(alignment: .bottomLeading) {
                        if needsWhole(measured) && original == nil {
                            ProgressView().controlSize(.mini).padding(12).help(L10n.tr("Loading the original for full detail…"))
                        }
                    }
            } else {
                Theme.imageSurround
                CatalogThumbnail(asset: asset, previews: previews).padding(28)
                if url == nil {
                    Label(L10n.tr("The original isn’t on this Mac."), systemImage: "exclamationmark.triangle")
                        .padding(.horizontal, 10).padding(.vertical, 5).background(.black.opacity(0.6), in: Capsule()).environment(\.colorScheme, .dark)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .task(id: id) {
            if let cached = OriginalPreviewImage.cache.object(forKey: id as NSString) { loaded = (id, cached); return }
            guard let url else { return }
            let result = await Task.detached(priority: .userInitiated) { () -> OriginalPreviewImage? in
                guard !Task.isCancelled else { return nil }
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = ImageDecode.analysisImage(source, url: url, pixelSize: PhotoQualityAnalyzer.pixelSize, minimum: PhotoQualityAnalyzer.previewMinimum)
                else { return nil }
                return OriginalPreviewImage(image: image, fullSize: OriginalPreviewImage.uprightSize(source))
            }.value
            guard !Task.isCancelled, let result else { return }
            OriginalPreviewImage.cache.setObject(result, forKey: id as NSString, cost: result.image.bytesPerRow * result.image.height)
            loaded = (id, result)
        }
        // The original whole only once it is needed: a large RAW takes a second or two and a few hundred MB.
        .task(id: WholeKey(asset: id, wanted: measured.map(needsWhole) ?? false)) {
            guard let measured, needsWhole(measured), original == nil, let url else { return }
            let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                guard !Task.isCancelled else { return nil }
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                return FaceCrops.whole(at: url)
            }.value
            guard !Task.isCancelled, let image else { return }
            OriginalPreviewImage.wholes.setObject(OriginalPreviewImage(image: image, fullSize: nil), forKey: id as NSString, cost: image.bytesPerRow * image.height)
            whole = (id, image)
        }
    }

    private struct WholeKey: Equatable { let asset: String; let wanted: Bool }
    /// Zoomed in on this photo past what the measured-size image holds.
    private func needsWhole(_ measured: OriginalPreviewImage) -> Bool {
        guard zoomedIn == asset.id, let full = measured.fullSize else { return false }
        return max(full.width, full.height) > CGFloat(max(measured.image.width, measured.image.height)) * 1.1
    }
    private var url: URL? {
        guard case .available(let url) = asset.availability(catalog: root) else { return nil }
        return url
    }
}

/// The image a preview shows until it is zoomed in, and the original's size it stands for.
final class OriginalPreviewImage: @unchecked Sendable {
    let image: CGImage
    let fullSize: CGSize?
    init(image: CGImage, fullSize: CGSize?) { self.image = image; self.fullSize = fullSize }

    /// The photos looked at last, at the size they were measured.
    @MainActor static let cache: NSCache<NSString, OriginalPreviewImage> = {
        let cache = NSCache<NSString, OriginalPreviewImage>(); cache.countLimit = 12; cache.totalCostLimit = 256 << 20; return cache
    }()
    /// The last few originals read whole, for stepping back and forth through a burst zoomed in.
    @MainActor static let wholes: NSCache<NSString, OriginalPreviewImage> = {
        let cache = NSCache<NSString, OriginalPreviewImage>(); cache.countLimit = 3; cache.totalCostLimit = 600 << 20; return cache
    }()

    /// The original's size in pixels as it stands upright, from the file's header.
    static func uprightSize(_ source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        let turned = [5, 6, 7, 8].contains(properties[kCGImagePropertyOrientation] as? Int ?? 1)
        return turned ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }
}

extension OriginalPreview where Overlay == EmptyView {
    init(asset: CatalogAsset, root: URL?, previews: PreviewStore?, target: ZoomTarget? = nil) {
        self.init(asset: asset, root: root, previews: previews, target: target, overlay: { _ in EmptyView() })
    }
}
