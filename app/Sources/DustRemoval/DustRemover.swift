import Foundation

/// Classic sensor-dust detector: adaptive threshold, dilation and a shape test, after the reference OpenCV
/// implementation. The dense stage runs on Accelerate, which is as fast as the GPU at photo sizes.
public final class DustRemover {
    public init() {}

    /// Finds the dust blobs in `image`.
    public func detect(in image: RGBAImage, parameters: DustRemovalParameters) throws -> DustDetection {
        let dense = try AccelerateDenseDetector.run(image, parameters: DenseParameters(parameters))
        let filter = ComponentFilter(maxContourVertices: parameters.maxContourVertices,
                                     maxBlobSize: parameters.maxBlobSize,
                                     minBlobSize: parameters.minBlobSize,
                                     minContrast: parameters.minContrast,
                                     minSeedPixels: parameters.minSeedPixels,
                                     maxBrightExcess: parameters.maxBrightExcess,
                                     ringWidth: max(4, parameters.dilationRadius))
        return DustDetection(blobs: dustBlobs(from: dense.combined, filter: filter, sample: dense.sample))
    }
}
