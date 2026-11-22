import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// A line of text used as a watermark, always white (the watermark's opacity sets how faint it is; anything more elaborate
/// is an image watermark). It is drawn at the size each export needs, so it stays sharp at any resolution.
public struct WatermarkText: Codable, Hashable, Sendable {
    public var string: String
    /// A PostScript font name; an unknown one falls back to the system's default face.
    public var fontName = "HelveticaNeue-Bold"
    /// A soft dark shadow, so light text stays readable over bright areas.
    public var shadow = true
    public init(string: String) { self.string = string }

    enum CodingKeys: String, CodingKey { case string, fontName, shadow }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        string = try c.decode(String.self, forKey: .string)
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName) ?? "HelveticaNeue-Bold"
        shadow = try c.decodeIfPresent(Bool.self, forKey: .shadow) ?? true
    }

    /// The text on a transparent background, `longEdge` pixels on its long side (shadow included), in sRGB.
    public func rendered(longEdge: Double) throws -> CGImage {
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        func line(_ size: Double) -> CTLine {
            let font = CTFontCreateWithName(fontName as CFString, size, nil)
            let color = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]))
        }
        // Measured at 100 pt, then drawn at the size that gives the requested long edge.
        let probe = CTLineGetBoundsWithOptions(line(100), .useGlyphPathBounds)
        guard !text.isEmpty, probe.width > 0, probe.height > 0 else {
            throw EditorError.invalidDocument(L10n.tr("Enter the text for the watermark."))
        }
        let padding = shadow ? 0.12 : 0.02
        let size = 100 * min(16_384, max(4, longEdge)) / (max(probe.width, probe.height) + 2 * padding * probe.height)
        let drawn = line(size), bounds = CTLineGetBoundsWithOptions(drawn, .useGlyphPathBounds)
        let pad = (padding * bounds.height).rounded(.up)
        let width = Int((bounds.width + 2 * pad).rounded(.up)), height = Int((bounds.height + 2 * pad).rounded(.up))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw EditorError.render }
        if shadow {
            context.setShadow(offset: CGSize(width: 0, height: -bounds.height * 0.03), blur: bounds.height * 0.08,
                              color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.55))
        }
        context.textPosition = CGPoint(x: pad - bounds.minX, y: pad - bounds.minY)
        CTLineDraw(drawn, context)
        guard let image = context.makeImage() else { throw EditorError.render }
        return image
    }
}

/// An image or a line of text stamped on exports: tiled across the photo on a turned grid and faded, or placed in one corner.
/// Sizes are fractions of the export's short edge, so the dialog's preview, batch exports of any size and the full-size
/// file all match.
public struct Watermark: Codable, Hashable, Sendable, Identifiable {
    public enum Layout: String, Codable, CaseIterable, Sendable {
        case tiled, corner
        public var title: String { self == .tiled ? L10n.tr("Tiled") : L10n.tr("Corner") }
    }
    public enum Corner: String, Codable, CaseIterable, Sendable {
        case topLeft, topRight, bottomLeft, bottomRight
        public var title: String {
            switch self {
            case .topLeft: return L10n.tr("Top left")
            case .topRight: return L10n.tr("Top right")
            case .bottomLeft: return L10n.tr("Bottom left")
            case .bottomRight: return L10n.tr("Bottom right")
            }
        }
        public var isLeft: Bool { self == .topLeft || self == .bottomLeft }
        public var isTop: Bool { self == .topLeft || self == .topRight }
    }
    public var id = UUID()
    public var name = ""
    /// The image, inside the watermark library's folder once saved; nil for a text watermark.
    public var image: URL?
    /// The text, for a watermark made from text rather than an image.
    public var text: WatermarkText?
    public var layout = Layout.corner
    public var corner = Corner.bottomRight
    /// The watermark's long edge as a fraction of the export's short edge.
    public var scale = 0.2
    public var opacity = 1.0
    /// In a corner, the distance from the edges; tiled, the gap between watermarks. A fraction of the export's short edge.
    public var spacing = 0.03
    /// How far the tiled pattern is turned, in degrees counterclockwise; 0 keeps its rows level.
    public var angle = 45.0
    public init(name: String, image: URL) { self.name = name; self.image = image }
    public init(name: String, text: WatermarkText) { self.name = name; self.text = text }

    public static let scaleRange = 0.02...1.0
    public static let opacityRange = 0.05...1.0
    public static let spacingRange = 0.0...1.0
    public static let angleRange = -180.0...180.0
    /// Each layout's look when it is chosen: a faded pattern, or a solid mark near the edge.
    static func defaults(_ layout: Layout) -> (scale: Double, opacity: Double, spacing: Double) {
        layout == .tiled ? (0.25, 0.25, 0.2) : (0.2, 1, 0.03)
    }
    /// Switches the layout; values still at the other layout's defaults take the new one's, values the user set are kept.
    public mutating func setLayout(_ layout: Layout) {
        guard layout != self.layout else { return }
        let old = Self.defaults(self.layout), new = Self.defaults(layout)
        if scale == old.scale { scale = new.scale }
        if opacity == old.opacity { opacity = new.opacity }
        if spacing == old.spacing { spacing = new.spacing }
        self.layout = layout
    }

    enum CodingKeys: String, CodingKey { case id, name, image, text, layout, corner, scale, opacity, spacing, angle }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        image = try c.decodeIfPresent(URL.self, forKey: .image)
        text = try c.decodeIfPresent(WatermarkText.self, forKey: .text)
        layout = (try? c.decodeIfPresent(Layout.self, forKey: .layout)) ?? .corner
        corner = (try? c.decodeIfPresent(Corner.self, forKey: .corner)) ?? .bottomRight
        let defaults = Self.defaults(layout)
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? defaults.scale
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? defaults.opacity
        spacing = try c.decodeIfPresent(Double.self, forKey: .spacing) ?? defaults.spacing
        angle = try c.decodeIfPresent(Double.self, forKey: .angle) ?? 45
    }

    public func validate() throws {
        guard Self.scaleRange.contains(scale), Self.opacityRange.contains(opacity), Self.spacingRange.contains(spacing), Self.angleRange.contains(angle) else {
            throw EditorError.invalidDocument(L10n.tr("The watermark's size, opacity, spacing or angle is out of range."))
        }
        guard (image == nil) != (text == nil) else { throw EditorError.invalidDocument(L10n.tr("Choose an image or enter text for the watermark.")) }
        if let text, text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw EditorError.invalidDocument(L10n.tr("Enter the text for the watermark."))
        }
    }

    /// The watermark itself with its long edge about `longEdge` pixels: the image, or the text drawn at that size.
    func mark(longEdge: Double) throws -> CIImage {
        if let text { return CIImage(cgImage: try text.rendered(longEdge: longEdge)) }
        guard let image, let source = CIImage(contentsOf: image, options: [.applyOrientationProperty: true]), !source.extent.isEmpty,
              !source.extent.isInfinite else {
            throw EditorError.invalidDocument(L10n.tr("The watermark image “\(name)” could not be read."))
        }
        return source
    }

    /// `photo` with the watermark over it, on the same extent.
    public func composited(over photo: CIImage) throws -> CIImage {
        try validate()
        let extent = photo.extent
        let short = min(extent.width, extent.height)
        guard short >= 1 else { return photo }
        let source = try mark(longEdge: scale * short)
        let factor = max(1, scale * short) / max(source.extent.width, source.extent.height)
        var mark = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: factor, y: factor), highQualityDownsample: true)
        if opacity < 1 {
            mark = mark.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)])
        }
        let width = mark.extent.width, height = mark.extent.height, gap = spacing * short
        switch layout {
        case .corner:
            let x = corner.isLeft ? extent.minX + gap : extent.maxX - gap - width
            let y = corner.isTop ? extent.maxY - gap - height : extent.minY + gap
            mark = mark.transformed(by: CGAffineTransform(translationX: x.rounded(), y: y.rounded()))
        case .tiled:
            // Two rows per tile, the second shifted half a cell, so the marks stagger; whole-pixel cells tile without seams.
            let cell = CGSize(width: (width + gap).rounded(.up), height: (height + gap).rounded(.up))
            let bounds = CGRect(x: 0, y: 0, width: cell.width, height: cell.height * 2)
            var tile = mark.composited(over: CIImage(color: .clear).cropped(to: bounds))
            for dx in [cell.width / 2, -cell.width / 2] {
                tile = mark.transformed(by: CGAffineTransform(translationX: dx, y: cell.height)).composited(over: tile)
            }
            let tiler = CIFilter.affineTile(); tiler.inputImage = tile.cropped(to: bounds); tiler.transform = .identity
            guard let pattern = tiler.outputImage else { throw EditorError.render }
            // One mark sits on the photo's center; the pattern turns about it.
            let center = CGPoint(x: extent.midX, y: extent.midY)
            let turn = CGAffineTransform(translationX: -width / 2, y: -height / 2)
                .concatenating(CGAffineTransform(rotationAngle: angle * .pi / 180))
                .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
            mark = pattern.transformed(by: turn)
        }
        return mark.composited(over: photo).cropped(to: extent)
    }
}

/// Watermarks saved for reuse. They live in this Mac's Application Support folder, beside the catalogs rather than in
/// one, so every library shares them, and they never sync to iCloud. Images are copied in, so the originals can move.
public struct WatermarkLibrary: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root.standardizedFileURL }
    public static var standard: WatermarkLibrary { WatermarkLibrary(root: LookLibrary.localRoot.appendingPathComponent("Watermarks", isDirectory: true)) }
    /// Image formats that can carry transparency, the only ones accepted as watermarks.
    public static let imageTypes: [UTType] = [.png, .tiff, .heic, .heif, .webP] + ["public.avif", "public.jpeg-xl"].compactMap { UTType($0) }
    private var index: URL { root.appendingPathComponent("Watermarks.json") }

    /// In the order they were created. Images are found in this folder whatever path was recorded.
    public func watermarks() -> [Watermark] {
        stored().items.map { var watermark = $0; watermark.image = $0.image.map { root.appendingPathComponent($0.lastPathComponent) }; return watermark }
    }
    /// The index as saved, keeping the entries this build can't read.
    private func stored() -> SavedList<Watermark> { SavedList(try? Data(contentsOf: index)) }
    public func watermark(id: UUID) -> Watermark? { watermarks().first { $0.id == id } }

    /// Copies an image in under a new name, rejecting formats without transparency and files that do not decode.
    public func importImage(_ source: URL) throws -> URL {
        guard let type = UTType(filenameExtension: source.pathExtension), Self.imageTypes.contains(where: { type.conforms(to: $0) }) else {
            throw EditorError.invalidDocument(L10n.tr("Choose a PNG, TIFF, HEIC, WebP, AVIF or JPEG XL image; watermarks need a format with transparency."))
        }
        guard let reader = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(reader) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(reader, 0, nil) as? [CFString: Any],
              (properties[kCGImagePropertyPixelWidth] as? Int ?? 0) > 0 else {
            throw EditorError.invalidDocument(L10n.tr("\(source.lastPathComponent) could not be read as an image."))
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent(UUID().uuidString.lowercased()).appendingPathExtension(source.pathExtension.lowercased())
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    /// Adds the watermark, or replaces the one with its ID; an image it no longer uses is removed.
    public func save(_ watermark: Watermark) throws {
        try watermark.validate()
        if let image = watermark.image, !holds(image) || !FileManager.default.fileExists(atPath: image.path) {
            throw EditorError.invalidDocument(L10n.tr("Import the watermark image into the library before saving it."))
        }
        var all = stored()
        if let index = all.items.firstIndex(where: { $0.id == watermark.id }) {
            let replaced = all.items[index].image.map { root.appendingPathComponent($0.lastPathComponent) }
            all.items[index] = watermark
            try all.write(to: self.index)
            if let replaced, replaced.lastPathComponent != watermark.image?.lastPathComponent { discardImage(replaced) }
        } else {
            all.items.append(watermark)
            try all.write(to: index)
        }
    }

    public func delete(_ id: UUID) throws {
        var all = stored()
        guard let index = all.items.firstIndex(where: { $0.id == id }) else { return }
        let removed = all.items.remove(at: index)
        try all.write(to: self.index)
        if let image = removed.image { discardImage(root.appendingPathComponent(image.lastPathComponent)) }
    }

    /// Removes an imported image no saved watermark uses, such as one picked for a watermark that was then cancelled.
    public func discardImage(_ url: URL) {
        // An entry this build can't read may use it too.
        let all = stored()
        guard holds(url), all.isComplete, !all.items.contains(where: { $0.image?.lastPathComponent == url.lastPathComponent }) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes images left behind by watermarks that were never saved, for example when the dialog closed mid-edit.
    public func pruneImages() {
        // Only when every entry could be read: one that can't still uses its image.
        let all = stored()
        guard all.isComplete else { return }
        let used = Set(all.items.compactMap(\.image?.lastPathComponent))
        guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
        // By name: the listing can spell the folder differently (/private/var for /var).
        for file in files where file.pathExtension != "json" && !used.contains(file.lastPathComponent) { try? FileManager.default.removeItem(at: file) }
    }

    private func holds(_ url: URL) -> Bool { url.deletingLastPathComponent().standardizedFileURL.path == root.path }

}
