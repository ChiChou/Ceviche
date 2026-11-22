import XCTest
import CoreImage
@testable import CevicheCore

/// Render cost of Volume against the projective geometry it sits beside. Opt-in and slow: set CEVICHE_VOLUME_BENCH to a
/// wide-angle RAW and run in release (`swift test -c release --filter VolumeBenchmarkTests`). Prints medians.
final class VolumeBenchmarkTests: XCTestCase {
    private func median(_ runs: Int, _ body: () throws -> Void) rethrows -> Double {
        var times: [Double] = []
        for _ in 0..<runs { let t = Date(); try body(); times.append(Date().timeIntervalSince(t) * 1000) }
        return times.sorted()[times.count / 2]
    }
    private func volume(_ mode: VolumeMode, _ amount: Double) -> VolumeCorrection {
        var v = VolumeCorrection(); v.mode = mode; v.amount = amount; v.focalLength = 14; return v
    }

    func testKernelAlongsidePerspectiveAtFullSize() throws {
        guard ProcessInfo.processInfo.environment["CEVICHE_VOLUME_BENCH"] != nil else { throw XCTSkip("set CEVICHE_VOLUME_BENCH") }
        let size = CGSize(width: 9504, height: 6336)
        let source = CIFilter(name: "CIRandomGenerator")!.outputImage!.cropped(to: CGRect(origin: .zero, size: size))
        let context = CIContext(options: [.workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])
        var bitmap = [UInt16](repeating: 0, count: Int(size.width * size.height) * 4)
        func render(_ geometry: GeometryAdjustments) throws -> Double {
            let image = try GeometryPlan(size: size, settings: geometry, quarterTurns: 0).apply(to: source)
            return median(5) { context.render(image, toBitmap: &bitmap, rowBytes: Int(size.width) * 8, bounds: CGRect(origin: .zero, size: size), format: .RGBAh, colorSpace: nil) }
        }
        var straight = GeometryAdjustments(); straight.straighten = 3
        print(String(format: "BENCH full 60 MP  random source only %.0f ms", try render(GeometryAdjustments())))
        print(String(format: "BENCH full 60 MP  straighten 3°     %.0f ms", try render(straight)))
        for mode in VolumeMode.allCases {
            var g = GeometryAdjustments(); g.volume = volume(mode, 50)
            print(String(format: "BENCH full 60 MP  volume %@ %.0f ms", mode.rawValue, try render(g)))
            g.straighten = 3
            print(String(format: "BENCH full 60 MP  volume %@ + straighten %.0f ms", mode.rawValue, try render(g)))
        }
    }

    func testPreviewAndExportOfARealPhoto() async throws {
        guard let path = ProcessInfo.processInfo.environment["CEVICHE_VOLUME_BENCH"], FileManager.default.fileExists(atPath: path) else { throw XCTSkip("set CEVICHE_VOLUME_BENCH") }
        let renderer = try RawRenderer(sourceURL: URL(fileURLWithPath: path))
        let base = await renderer.info.defaults
        func timed(_ runs: Int, _ body: (Int) async throws -> Void) async rethrows -> Double {
            var times: [Double] = []
            for i in 0..<runs { let t = Date(); try await body(i); times.append(Date().timeIntervalSince(t) * 1000) }
            return times.sorted()[times.count / 2]
        }
        // Every run differs a little, as while a slider is dragged, so no cached preview is reused.
        func preview(_ change: @escaping (inout Adjustments, Double) -> Void) async throws -> Double {
            _ = try await renderer.preview(base)
            return try await timed(9) { i in var a = base; change(&a, Double(i) * 0.01); _ = try await renderer.preview(a) }
        }
        print(String(format: "BENCH preview  unchanged geometry  %.0f ms", try await preview { a, d in a.exposure = d }))
        print(String(format: "BENCH preview  straighten dragged   %.0f ms", try await preview { a, d in a.geometry.straighten = 2 + d }))
        for mode in VolumeMode.allCases {
            print(String(format: "BENCH preview  volume %@ dragged %.0f ms", mode.rawValue, try await preview { a, d in a.geometry.volume = self.volume(mode, 40 + d) }))
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("volume-bench.tif")
        defer { try? FileManager.default.removeItem(at: out) }
        func export(_ change: (inout Adjustments) -> Void) async throws -> Double {
            var a = base; change(&a)
            let adjustments = a
            return try await timed(3) { _ in try? FileManager.default.removeItem(at: out); try await renderer.export(to: out, adjustments: adjustments, format: .tiff) }
        }
        print(String(format: "BENCH export TIFF  straighten 3°   %.0f ms", try await export { $0.geometry.straighten = 3 }))
        print(String(format: "BENCH export TIFF  volume spherical %.0f ms", try await export { $0.geometry.volume = volume(.spherical, 50) }))
        print(String(format: "BENCH export TIFF  volume horizontal %.0f ms", try await export { $0.geometry.volume = volume(.horizontal, 50) }))
    }

    /// What runs on the CPU for each slider step: the plan and Constrain Crop's fit.
    func testCropFittingPerStep() throws {
        guard ProcessInfo.processInfo.environment["CEVICHE_VOLUME_BENCH"] != nil else { throw XCTSkip("set CEVICHE_VOLUME_BENCH") }
        let size = CGSize(width: 9504, height: 6336)
        var straight = GeometryAdjustments(); straight.straighten = 3
        var bent = GeometryAdjustments(); bent.volume = volume(.spherical, 50)
        for (name, g) in [("straighten", straight), ("volume", bent)] {
            let plan = median(9) { _ = try? GeometryPlan(size: size, settings: g, quarterTurns: 0) }
            let fits = median(9) { _ = g.cropFitsImage(sourceSize: size, quarterTurns: 0) }
            let fit = median(5) { _ = g.constrainedCrop(after: GeometryAdjustments(), previousQuarterTurns: 0, sourceSize: size, quarterTurns: 0) }
            print(String(format: "BENCH cpu %@  plan %.2f ms  fits %.2f ms  constrain %.1f ms", name, plan, fits, fit))
        }
    }
}
