import CoreImage
import CoreML
import Foundation

/// The sky network (U²-Net, converted by models/convert_sky.py with its input normalization built in), run in-process: a
/// 320 × 320 RGB input in encoded sRGB and a sky probability map of the same size. Masks keep that small map;
/// `MaskRefinement.sky` refines it against the photo when rendering.
public final class SkyMaskModel: @unchecked Sendable {
    /// Side length of the square network input and output.
    public static let size = 320
    /// Tensor names that models/convert_sky.py assigns.
    static let inputName = "modelInput", outputName = "modelOutput"
    private let model: MLModel
    private init(model: MLModel) throws {
        self.model = model
        let input: [NSNumber] = [1, 3, Self.size as NSNumber, Self.size as NSNumber], output: [NSNumber] = [1, 1, Self.size as NSNumber, Self.size as NSNumber]
        guard model.modelDescription.inputDescriptionsByName[Self.inputName]?.multiArrayConstraint?.shape == input,
              model.modelDescription.outputDescriptionsByName[Self.outputName]?.multiArrayConstraint?.shape == output else {
            throw EditorError.invalidDocument(L10n.tr("Expected a sky model with \(Self.size) × \(Self.size) RGB input."))
        }
    }
    private static let lock = NSLock()
    private static var bundled: SkyMaskModel?
    /// The build ships a compiled model. Load it once, with no runtime compilation or file picker.
    public static func loadBundled() throws -> SkyMaskModel {
        try lock.withLock {
            if let bundled { return bundled }
            let loaded = try SkyMaskModel(model: BundledModelCache.shared.model(.sky, computeUnits: .cpuAndGPU))
            bundled = loaded
            return loaded
        }
    }
    /// The network's sky probabilities as a single-channel float 320 × 320 image. The photo is reduced to the
    /// network input as encoded sRGB values, matching the training data.
    public func coarseMask(for image: CIImage, context: CIContext) throws -> CIImage {
        let size = Self.size
        let data = try predict(Self.preprocess(image, context: context)).withUnsafeBytes { Data($0) }
        return CIImage(bitmapData: data, bytesPerRow: size * 4, size: CGSize(width: size, height: size), format: .Rf, colorSpace: nil)
    }
    /// Float NCHW `[1,3,320,320]` values in `[0,1]`.
    static func preprocess(_ image: CIImage, context: CIContext) throws -> [Float] {
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: sRGB) else { throw EditorError.render }
        let numeric = CIImage(cgImage: cg, options: [.colorSpace: NSNull()])
        let resized = resample(numeric, to: CGSize(width: size, height: size))
        var pixels = [Float](repeating: 0, count: size * size * 4)
        pixels.withUnsafeMutableBytes {
            context.render(resized, toBitmap: $0.baseAddress!, rowBytes: size * 16, bounds: CGRect(x: 0, y: 0, width: size, height: size), format: .RGBAf, colorSpace: nil)
        }
        var planes = [Float](repeating: 0, count: 3 * size * size)
        for channel in 0..<3 {
            for i in 0..<size * size { planes[channel * size * size + i] = min(1, max(0, pixels[i * 4 + channel])) }
        }
        return planes
    }
    /// Runs the network on NCHW input planes, returning row-major 320 × 320 sky probabilities.
    func predict(_ planes: [Float]) throws -> [Float] {
        let size = Self.size
        guard planes.count == 3 * size * size else { throw EditorError.render }
        let input = MLMultiArray(MLShapedArray(scalars: planes, shape: [1, 3, size, size]))
        let prediction = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [Self.inputName: input]))
        guard let output = prediction.featureValue(for: Self.outputName)?.multiArrayValue, output.count == size * size else { throw EditorError.render }
        // Converting copies in logical order, independent of the output's strides and scalar type.
        return MLShapedArray<Float>(converting: output).scalars
    }
    /// Lanczos-resamples with the origin at zero, replicating edge pixels so borders do not fade toward transparent black.
    static func resample(_ image: CIImage, to size: CGSize) -> CIImage {
        let extent = image.extent
        return image.clampedToExtent().applyingFilter("CILanczosScaleTransform", parameters: [
            "inputScale": size.height / extent.height,
            "inputAspectRatio": (size.width / extent.width) / (size.height / extent.height)])
        .cropped(to: CGRect(origin: .zero, size: size))
    }
}
