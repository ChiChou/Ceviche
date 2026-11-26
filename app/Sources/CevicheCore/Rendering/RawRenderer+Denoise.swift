import CoreImage
import Foundation

/// AI Noise Reduction seen in Develop: the photo's ordinary renders, with the decoded photo put through NAFNet before
/// any edit and the decoder's own noise reduction off, as the denoised copy will have it. Core Image runs the network
/// only on the region it renders, so a screen-size preview runs it on that preview and a zoomed-in view on the file's
/// pixels in view, which is quick enough to compare while looking around the photo. The whole frame is denoised by
/// `PhotoDenoiser` once a strength is chosen.
extension RawRenderer {
    /// The edits with the decoder's noise reduction off, which the network takes the place of.
    public static func denoising(_ adjustments: Adjustments) -> Adjustments {
        var a = adjustments
        a.noiseReduction = 0
        if a.colorNoiseReduction != nil { a.colorNoiseReduction = 0 }
        return a
    }
    /// `displayImage` with the decoded photo denoised; `runs` keeps the network's tiles between calls.
    public func denoisedDisplayImage(_ adjustments: Adjustments, maxDimension: Double, sdr: Bool = false, runs: DenoiseRuns) throws -> CGImage {
        decodedFilter = { try runs.denoised($0) }
        defer { decodedFilter = nil }
        return try displayImage(Self.denoising(adjustments), maxDimension: maxDimension, sdr: sdr)
    }
    /// `prepareDetail` with the decoded photo denoised. The graph holds the network, so `render` runs it outside the actor.
    public func prepareDenoisedDetail(_ adjustments: Adjustments, sdr: Bool = false, region: CGRect, photoWidth: Double? = nil,
                                      maxPixels: Int = 16_000_000, runs: DenoiseRuns) throws -> DetailRender? {
        decodedFilter = { try runs.denoised($0) }
        defer { decodedFilter = nil }
        return try prepareDetail(Self.denoising(adjustments), sdr: sdr, region: region, photoWidth: photoWidth, maxPixels: maxPixels)
    }
}

/// The network's tiles kept for each size the photo is decoded at (a preview, half or full size), so moving around a
/// zoomed photo runs only the tiles newly in view. Make a new one when the photo or what is decoded changes.
public final class DenoiseRuns: @unchecked Sendable {
    private let lock = NSLock()
    private var runs: [Int: DenoiseRun] = [:]
    public init() {}
    func denoised(_ image: CIImage) throws -> CIImage {
        let key = Int(image.extent.width.rounded())
        let run = lock.withLock {
            if let run = runs[key] { return run }
            // 48 tiles, about 70 MB, at each size: a phone's screen of them, and some around it.
            let run = DenoiseRun(keptTiles: 48)
            runs[key] = run
            return run
        }
        return try NAFNetDenoiseKernel.denoised(image, amount: 100, run: run)
    }
}
