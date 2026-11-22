import Foundation

/// All tunable knobs of the dust removal pipeline.
///
/// The defaults reproduce the original Python/OpenCV reference implementation
/// (adaptive mean threshold 19/10, global threshold mean/1.2, three 10x10
/// "magnification" passes and contours with fewer than 50 vertices).
///
/// For a UI, bind a single slider to `init(dustRadius:)` and optionally expose the
/// individual fields as advanced controls.
public struct DustRemovalParameters: Equatable, Sendable, Codable {

    // MARK: Detection

    /// Radius of a box blur applied to the grey image before thresholding. 0 = none (the
    /// reference implementation). 1 or 2 suppresses single-pixel sensor noise on high-ISO frames without
    /// affecting dust spots, which are soft discs several pixels across.
    public var smoothingRadius: Int = 0

    /// Window size (pixels, odd) of the adaptive mean threshold. Larger windows catch larger spots.
    public var adaptiveBlockSize: Int = 19

    /// How much darker than the local mean a pixel must be to count as "dust" (0...255).
    /// Lower values are more sensitive and pick up fainter spots (and more noise).
    public var adaptiveOffset: Int = 10

    /// Global dark threshold: pixels darker than `mean / globalDarkRatio` are treated as
    /// "scene structure" and merged with their neighbours so they are never inpainted.
    /// 0 disables it (recommended for night skies, where the sky itself is the darkest thing).
    public var globalDarkRatio: Double = 1.2

    /// Radius (pixels) of the square dilation applied to the adaptive mask
    /// (the reference implementation's three 10x10 passes ≈ radius 14). It merges nearby edge responses
    /// into large blobs so only isolated spots survive the shape test.
    public var dilationRadius: Int = 14

    /// Blobs whose simplified outer contour has this many vertices or more are rejected
    /// as scene structure (the reference implementation's `len(c) < 50`).
    public var maxContourVertices: Int = 50

    /// Reject blobs whose bounding box is larger than this on either side (pixels).
    /// 0 means automatic: a quarter of the shorter image side, which stops a dark frame from
    /// being treated as one giant "spot".
    public var maxBlobSize: Int = 0

    /// Minimum contrast (grey levels) between a blob's dark seed pixels and the median of the
    /// ring around it. Dust is darker than its surroundings; the ring an adaptive threshold
    /// draws around a bright star or a cloud edge is not. 0 disables the test.
    public var minContrast: Int = 4

    /// Minimum number of adaptive-threshold seed pixels a blob must contain. Blobs with none come
    /// from the global dark threshold alone (specks in shadows, fragments of a dark sky) and are
    /// not dust. Faint daytime dust can have as few as 1-10 seeds, so keep this low. 0 disables it.
    public var minSeedPixels: Int = 1

    /// Reject blobs whose brightest pixel exceeds the surrounding ring median by more than this
    /// (grey levels): a bright star or a cloud edge inside the blob. Dust never contains bright
    /// pixels (measured max 41 on the samples, stars 70-117). 0 disables the test.
    public var maxBrightExcess: Int = 50

    /// Reject blobs whose bounding box is smaller than this on both sides (pixels).
    public var minBlobSize: Int = 0

    public init() {}

    /// Derives every detection size from an expected dust spot radius.
    /// `dustRadius == 6` reproduces the reference defaults.
    public init(dustRadius: Double, sensitivity: Int = 10) {
        let r = max(1.0, dustRadius)
        adaptiveBlockSize = 2 * Int((1.5 * r).rounded()) + 1
        adaptiveOffset = sensitivity
        dilationRadius = max(1, Int((2.33 * r).rounded()))
        // Vertex count of a staircase boundary grows with the blob perimeter.
        maxContourVertices = max(8, Int((2.5 * (r + Double(dilationRadius))).rounded()))
        maxBlobSize = 0
    }
}

/// One accepted dust blob (in image pixel coordinates).
public struct DustBlob: Equatable, Sendable, Codable, Identifiable {
    /// Index of the blob in `DustDetection.blobs`; stable for one detection run.
    public var id: Int
    public var minX: Int
    public var minY: Int
    public var maxX: Int
    public var maxY: Int
    public var area: Int
    public var contourVertices: Int
    /// Darkness of the seed pixels relative to the surrounding ring (grey levels).
    public var contrast: Int
    /// Number of adaptive-threshold seed pixels inside the blob.
    public var seedPixels: Int
    /// Brightest pixel inside the blob relative to the surrounding ring median (grey levels).
    public var brightExcess: Int
    /// Bounding box of the seed pixels: the spot itself, without the dilation that merged it into a blob.
    public var seedMinX: Int
    public var seedMinY: Int
    public var seedMaxX: Int
    public var seedMaxY: Int
}

/// Result of one `DustRemover.detect` run.
public struct DustDetection: Sendable {
    /// The accepted dust blobs, in raster order of their first pixel.
    public var blobs: [DustBlob]
}

