import CoreGraphics
import CoreImage
import Foundation

/// How a tool's result takes the edits of the photo it is based on, and the photos' own retouching a merge burns in:
/// one implementation for the Mac and iPad apps, so a merge, a denoise or a corrected copy comes out the same on both.
public enum MergeDevelopment {
    /// The development of a result in `renderer` from the source photo's `saved` edits, as Paste Edits copies them (lens
    /// correction is already in the pixels). A RAW's merge was developed at the source's as-shot white balance and is
    /// stored with a neutral one, so its white balance carries as its change from as shot, and any difference in
    /// brightness with the same sliders is made up with exposure. A processed photo's result is encoded back through the
    /// photo's own profile, so its edits carry as they are. A result that keeps the source's framing pixel for pixel
    /// also takes what is placed on the picture, `placed`, and keeps the source's exposure.
    public static func carried(_ saved: Adjustments, sourceName: String, source: URL, onto renderer: RawRenderer,
                               placed: Set<EditTransferItem> = []) async throws -> Adjustments {
        let defaults = renderer.info.defaults
        let items = EditTransferItem.defaults.subtracting([.lensCorrection]).union(placed)
        guard renderer.info.isRAW else {
            return try EditTransfer(sourceName: sourceName, adjustments: saved, items: items).applying(to: defaults)
        }
        let original = try await Task.detached { try RawRenderer(sourceURL: source) }.value
        let asShot = original.info.defaults
        var carried = saved
        carried.temperature = min(50000, max(2000, 1e6 / (1e6 / defaults.temperature + 1e6 / saved.temperature - 1e6 / asShot.temperature)))
        carried.tint = min(150, max(-150, defaults.tint + saved.tint - asShot.tint))
        var edit = try EditTransfer(sourceName: sourceName, adjustments: carried, items: items).applying(to: defaults)
        if placed.isEmpty { edit.exposure += try await exposureMatching(renderer, edit, to: original, saved) }
        return edit
    }

    /// A merge result's edits from its base photo (`photo`, its file at `source`, its saved edits `saved`) for the result
    /// at `copy`, and the defaults they are saved against. Nil when the base has no edits of its own (the result stays at
    /// its defaults; Auto is one tap away in Develop) or they come to the defaults.
    public static func merged(from photo: CatalogAsset, saved: Adjustments?, source: URL, copy: URL,
                              placed: Set<EditTransferItem> = []) async throws -> (Adjustments, Adjustments)? {
        guard let saved else { return nil }
        let renderer = try await Task.detached(priority: .userInitiated) { try RawRenderer(sourceURL: copy) }.value
        let edit = try await carried(saved, sourceName: photo.filename, source: source, onto: renderer, placed: placed)
        return edit == renderer.info.defaults ? nil : (edit, renderer.info.defaults)
    }

    /// The edits a corrected copy of one photo takes (Wide-Angle Faces, AI Noise Reduction), in `renderer` (the copy's).
    /// A processed photo's copy has the photo's own rendering, tone and white balance: its edits carry as they are, lens
    /// correction included, and matching brightness would only answer the change in composition. A RAW's carry as a
    /// merge's do; an unedited RAW's copy is brought to the photo's brightness as shot. Edits placed on the picture
    /// (masks, crops) stay behind.
    public static func copied(from photo: CatalogAsset, saved: Adjustments?, source: URL, onto renderer: RawRenderer) async throws -> Adjustments {
        let defaults = renderer.info.defaults
        if !CatalogImporter.rawExtensions.contains((photo.filename as NSString).pathExtension.lowercased()) {
            return try saved.map { try EditTransfer(sourceName: photo.filename, adjustments: $0, items: EditTransferItem.defaults).applying(to: defaults) } ?? defaults
        }
        if let saved { return try await carried(saved, sourceName: photo.filename, source: source, onto: renderer) }
        let original = try await Task.detached { try RawRenderer(sourceURL: source) }.value
        var edit = defaults
        edit.exposure += try await exposureMatching(renderer, edit, to: original, original.info.defaults)
        return edit
    }

    /// The exposure change that brings `renderer`'s picture with `edit` to the mean brightness of `target` with `targetEdit`.
    public static func exposureMatching(_ renderer: RawRenderer, _ edit: Adjustments, to target: RawRenderer, _ targetEdit: Adjustments) async throws -> Double {
        func brightness(_ image: CGImage) -> Double {
            let picture = CIImage(cgImage: image)
            guard let mean = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: picture, kCIInputExtentKey: CIVector(cgRect: picture.extent)])?.outputImage else { return 0 }
            var pixel = [Float](repeating: 0, count: 4)
            CIContext().render(mean, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf,
                               colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return 0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2])
        }
        let goal = brightness(try await target.displayImage(targetEdit, maxDimension: 512, sdr: true))
        // Brightness rises with exposure, so halving the interval converges; a hundredth of a stop is close enough.
        var low = -2.0, high = 2.0
        for _ in 0..<9 {
            var trial = edit
            trial.exposure += (low + high) / 2
            if brightness(try await renderer.displayImage(trial, maxDimension: 512, sdr: true)) < goal { low = (low + high) / 2 } else { high = (low + high) / 2 }
        }
        return ((low + high) / 2 * 100).rounded() / 100
    }
}

extension CatalogStore {
    /// Each photo's own retouching by its original's URL, AI fills included, for a merge to burn into the photo before
    /// aligning: dust, removed objects and face spots are in each photo's own place, not their place in the result.
    public func retouching(of assets: [CatalogAsset], at urls: [URL]) async -> [URL: [RetouchStroke]] {
        var found: [URL: [RetouchStroke]] = [:]
        for (asset, url) in zip(assets, urls) {
            if let saved = try? await savedAdjustments(of: asset), !saved.retouch.isEmpty { found[url] = saved.retouch }
        }
        return found
    }
}

/// Shows a merge tool's preview as its result will be saved: with the edits of the photo the result is based on. One per
/// tool screen; it reads each base photo's edits once.
@MainActor
public final class MergePreviewDeveloper {
    public var store: CatalogStore?
    private let assets: [CatalogAsset]
    /// What is placed on the picture and carries too, for a result that keeps the base photo's framing pixel for pixel.
    public let placed: Set<EditTransferItem>
    /// Each base photo's edits as the preview's file takes them; nil inside for a photo with none.
    private var edits: [String: Adjustments?] = [:]

    public init(assets: [CatalogAsset], placed: Set<EditTransferItem> = [], store: CatalogStore? = nil) {
        self.assets = assets; self.placed = placed; self.store = store
    }

    /// The catalog's photo for one of the tool's originals; nil for a file made on the way, such as a merged bracket.
    public func asset(for url: URL?) -> CatalogAsset? {
        guard let url else { return nil }
        return assets.first { $0.filename == url.lastPathComponent }
    }

    /// `source` developed with the edits of the photo at `base`, as large as `size`; nil when that photo has no edits
    /// or developing fails, and the preview stays as drawn.
    public func image(_ source: MergePreviewSource?, base: URL?, size: Int) async -> CGImage? {
        guard let source, let store, let base, let asset = asset(for: base) else { return nil }
        if case .some(.none) = edits[asset.id] { return nil }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Ceviche Merge Preview \(UUID().uuidString).\(source.fileExtension)")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            let renderer = try await Task.detached(priority: .userInitiated) { try source.write(to: file); return try RawRenderer(sourceURL: file) }.value
            let edit: Adjustments
            if case .some(.some(let found)) = edits[asset.id] { edit = found } else {
                guard let saved = try await store.savedAdjustments(of: store.asset(asset.id)) else { edits[asset.id] = .some(nil); return nil }
                edit = try await MergeDevelopment.carried(saved, sourceName: asset.filename, source: base, onto: renderer, placed: placed)
                edits[asset.id] = .some(edit)
            }
            return try await renderer.displayImage(edit, maxDimension: Double(size), sdr: true)
        } catch { return nil }
    }
}
