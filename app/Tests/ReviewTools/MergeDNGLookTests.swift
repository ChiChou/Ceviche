import XCTest
import CoreImage
import ImageIO
@testable import CevicheCore

/// How a merge DNG renders next to its source RAW, each with its defaults: 16-bit integer and half-float samples, and
/// the source camera named in the file. CEVICHE_MERGE_SAMPLES (a RAW photo's folder), CEVICHE_MERGE_OUTPUT.
final class MergeDNGLookTests: XCTestCase {
    func testMergeDNGLooksLikeItsRAW() async throws {
        guard let folder = ProcessInfo.processInfo.environment["CEVICHE_MERGE_SAMPLES"] else { throw XCTSkip() }
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CEVICHE_MERGE_OUTPUT"] ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let raw = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.uppercased() == "ARW" }.sorted { $0.path < $1.path }.first)
        let meta = try PanoramaDecoder.metadata(raw)
        let context = CIContext(options: [.workingColorSpace: PanoramaDecoder.space, .workingFormat: CIFormat.RGBAf])
        let frame = try PanoramaDecoder.decode(raw, longEdge: 2000, whiteBalance: (meta.temperature, meta.tint), context: context)
        let raster = PanoramaRaster(width: frame.width, height: frame.height, rgba: frame.pixels)
        let variants: [(String, PanoramaDNGWriter)] = [
            ("integer", { var w = PanoramaDNGWriter(metadata: meta, kind: .stack); w.floatingPoint = false; return w }()),
            ("half", PanoramaDNGWriter(metadata: meta, kind: .stack)),
            ("camera", PanoramaDNGWriter(metadata: meta, kind: .stack, source: DNGSourceMetadata(raw, process: "Stack"))),
        ]
        func stats(_ url: URL, _ name: String) async throws {
            let renderer = try RawRenderer(sourceURL: url)
            let image = try await renderer.displayImage(renderer.info.defaults, maxDimension: 1000, sdr: true)
            let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent("look-\(name).png") as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil); CGImageDestinationFinalize(destination)
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let cg = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            cg.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            var lum: [Double] = [], sat = 0.0
            for p in stride(from: 0, to: bytes.count, by: 4) {
                let r = Double(bytes[p]), g = Double(bytes[p + 1]), b = Double(bytes[p + 2])
                lum.append(0.2126 * r + 0.7152 * g + 0.0722 * b); let mx = max(r, g, b), mn = min(r, g, b); sat += mx > 0 ? (mx - mn) / mx : 0
            }
            lum.sort()
            let pct = [5, 25, 50, 75, 95].map { String(format: "%.0f", lum[lum.count * $0 / 100]) }.joined(separator: "/")
            print(String(format: "%-8@ L p5/25/50/75/95 %@  sat %.3f  camera %@ %@", name as NSString, pct as NSString, sat / Double(lum.count), renderer.info.camera as NSString, String(describing: renderer.info.sourceBitDepth) as NSString))
        }
        try await stats(raw, "raw")
        if let merged = ProcessInfo.processInfo.environment["CEVICHE_LOOK_DNG"] { try await stats(URL(fileURLWithPath: merged), "merged") }
        for (name, writer) in variants {
            let url = output.appendingPathComponent("look-\(name).dng")
            try? FileManager.default.removeItem(at: url)
            try writer.write(raster, to: url)
            do { try await stats(url, name) } catch { print(name, "failed:", error) }
        }
    }
}
