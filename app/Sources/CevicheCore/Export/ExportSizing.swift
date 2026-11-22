import Foundation
import CoreGraphics

public enum ExportSizePreset: String, CaseIterable, Sendable, Codable {
    public var localizedTitle: String { L10n.key(rawValue) }

    case original = "Original", small = "Small", medium = "Medium", large = "Large", custom = "Custom"

    public var longEdge: Int? {
        switch self {
        case .small: return 1600
        case .medium: return 2560
        case .large: return 3840
        case .original, .custom: return nil
        }
    }
}

public struct ExportDimensions: Hashable, Sendable, Codable {
    public var width: Int
    public var height: Int
    public var size: CGSize { CGSize(width: width, height: height) }
    public var label: String { L10n.tr("\(width) × \(height) px") }
    public init(width: Int, height: Int) { self.width = width; self.height = height }
}

/// Dimensions refer to the final cropped and rotated photograph, never the RAW sensor size.
public struct ExportSizing: Equatable, Sendable, Codable {
    public static let maximumDimension = 32768
    public static let maximumPixelCount = 200_000_000
    public var preset: ExportSizePreset = .original
    public var width = 1
    public var height = 1
    /// With the Original preset, shrinks photos whose long edge exceeds this; never enlarges. Set by export presets.
    public var longEdge: Int?
    /// Exact output pixels for services with fixed sizes: the photo is center-cropped to this aspect
    /// ratio, then scaled to these dimensions. Set by export presets.
    public var frame: ExportDimensions?
    /// Off ("Don't enlarge", the default): a size larger than the photo exports at the photo's own size. Fixed frames
    /// always apply.
    public var allowsEnlarging = false
    public init() {}
    /// The centered region of `source` with `frame`'s aspect ratio, or the whole image without a frame.
    public func cropRect(for source: CGSize) -> CGRect {
        guard let frame, frame.width > 0, frame.height > 0, source.width > 0, source.height > 0 else { return CGRect(origin: .zero, size: source) }
        let target = Double(frame.width) / Double(frame.height)
        var size = source
        if source.width / source.height > target { size.width = (source.height * target).rounded(.down) }
        else { size.height = (source.width / target).rounded(.down) }
        return CGRect(x: ((source.width - size.width) / 2).rounded(.down), y: ((source.height - size.height) / 2).rounded(.down), width: size.width, height: size.height)
    }

    public func dimensions(for source: CGSize) throws -> ExportDimensions {
        guard source.width.isFinite, source.height.isFinite,
              source.width >= 1, source.height >= 1,
              source.width < CGFloat(Int.max), source.height < CGFloat(Int.max) else {
            throw EditorError.invalidDocument(L10n.tr("The photograph has no valid export dimensions."))
        }
        let original = ExportDimensions(width: Int(source.width.rounded()), height: Int(source.height.rounded()))
        if let frame, frame.width >= 1, frame.height >= 1 { return frame }
        if preset == .original {
            guard let longEdge, longEdge >= 1, max(original.width, original.height) > longEdge else { return original }
            let scale = Double(longEdge) / max(source.width, source.height)
            return ExportDimensions(width: max(1, Int((source.width * scale).rounded())), height: max(1, Int((source.height * scale).rounded())))
        }
        if let edge = preset.longEdge {
            let scale = Double(edge) / max(source.width, source.height)
            if !allowsEnlarging, scale > 1 { return original }
            return ExportDimensions(width: max(1, Int((source.width * scale).rounded())),
                                    height: max(1, Int((source.height * scale).rounded())))
        }
        try validate()
        // Keep the edge the user typed: recompute only when the stored pair no longer matches this
        // source's proportions (for example after a crop), otherwise a typed height drifts by rounding.
        var resolved = self
        if abs(linked(width, multiplier: source.height / source.width) - height) > 1,
           abs(linked(height, multiplier: source.width / source.height) - width) > 1 { resolved.updateSource(source) }
        try resolved.validate()
        if !allowsEnlarging, resolved.width > original.width || resolved.height > original.height { return original }
        return ExportDimensions(width: resolved.width, height: resolved.height)
    }

    public func validate() throws {
        guard preset == .custom else { return }
        guard (1...Self.maximumDimension).contains(width), (1...Self.maximumDimension).contains(height) else {
            throw EditorError.invalidDocument(L10n.tr("Enter whole-number dimensions from 1 to \(Self.maximumDimension) px."))
        }
        guard width * height <= Self.maximumPixelCount else {
            throw EditorError.invalidDocument(L10n.tr("Choose an export size of 200 megapixels or less."))
        }
    }

    public mutating func select(_ value: ExportSizePreset, source: CGSize) {
        // Entering Custom starts at the currently displayed dimensions.
        if value == .custom, let current = try? dimensions(for: source) {
            width = current.width; height = current.height
        }
        preset = value
    }

    public mutating func setWidth(_ value: Int, source: CGSize) {
        if let current = try? dimensions(for: source) { height = current.height }
        preset = .custom; width = value
        height = linked(value, multiplier: source.height / source.width)
    }

    public mutating func setHeight(_ value: Int, source: CGSize) {
        if let current = try? dimensions(for: source) { width = current.width }
        preset = .custom; height = value
        width = linked(value, multiplier: source.width / source.height)
    }

    public mutating func updateSource(_ source: CGSize) {
        if preset == .custom { height = linked(width, multiplier: source.height / source.width) }
    }

    private func linked(_ value: Int, multiplier: Double) -> Int {
        let result = (Double(value) * multiplier).rounded()
        guard value > 0, result.isFinite, result < Double(Int.max), result >= 0 else { return 0 }
        return max(1, Int(result))
    }
}
