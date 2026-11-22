import Foundation
import CoreGraphics

public enum PanoramaProjection: String, Codable, CaseIterable, Sendable, Identifiable {
    case cylindrical, spherical, perspective
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .cylindrical: L10n.tr("Cylindrical")
        case .spherical: L10n.tr("Spherical")
        case .perspective: L10n.tr("Perspective")
        }
    }
    /// The compositor kernel's number for it.
    var code: Int {
        switch self {
        case .cylindrical: 0
        case .spherical: 1
        case .perspective: 2
        }
    }
}

/// The merge options a person chooses; everything else is decided from the photos.
public struct PanoramaSettings: Codable, Hashable, Sendable {
    public var projection: PanoramaProjection = .cylindrical
    /// How far the edges are bent out to the frame, 0 to 1 (`PanoramaWarp`).
    public var boundaryWarp = 0.0
    /// Crops to the largest rectangle the photos cover, after the warp.
    public var autoCrop = false
    /// Paints what the photos don't cover with the AI fill model; Auto Crop wins when both are on.
    public var fillEdges = false
    public init() {}
    /// Fill Edges needs the Remove brush's AI fill model.
    public static var canFillEdges: Bool { PanoramaEdgeFill.isAvailable }
}

public enum PanoramaError: LocalizedError {
    case message(String)
    public var errorDescription: String? { switch self { case .message(let text): return text } }
}

/// What alignment found: which photos joined, how well, and which projections can show them.
public struct PanoramaAlignment: Sendable {
    public let filenames: [String]
    /// Indices into `filenames` that are part of the panorama, in capture order.
    public let included: [Int]
    public let medianErrorPixels: Double
    public let p95ErrorPixels: Double
    public let available: Set<PanoramaProjection>
    public let suggested: PanoramaProjection
    public var excluded: [String] { filenames.indices.filter { !included.contains($0) }.map { filenames[$0] } }
}

public struct PanoramaPreview: @unchecked Sendable {
    /// sRGB with transparency where no photo reaches.
    public var image: CGImage
    /// The preview as the result's DNG, for developing it with the first photo's edits; nil before the photos are aligned.
    public let source: MergePreviewSource?
    public let settings: PanoramaSettings
}

/// RGBA float raster in linear extended sRGB; alpha is how much of the pixel the photos cover.
struct PanoramaRaster {
    var width: Int
    var height: Int
    var rgba: [Float]
    init(width: Int, height: Int, rgba: [Float]) {
        precondition(width > 0 && height > 0 && rgba.count == width * height * 4)
        self.width = width; self.height = height; self.rgba = rgba
    }
}
