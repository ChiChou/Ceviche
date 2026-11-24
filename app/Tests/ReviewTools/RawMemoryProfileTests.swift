import XCTest
import Darwin
import CoreImage
import Metal
@testable import CevicheCore

/// Replays a Develop session on one RAW (slider previews, the fitted detail the canvas settles on, a 1:1 tile) and
/// prints the process footprint after each step. CEVICHE_MEMORY_RAW=<file>.
final class RawMemoryProfileTests: XCTestCase {
    static func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
    static func vm() {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/footprint"); p.arguments = ["\(getpid())"]
        try? p.run(); p.waitUntilExit()
    }
    func log(_ step: String) { print(String(format: "MEM %8.0f MB  %@", Self.footprint(), step)) }

    func testEditSession() async throws {
        guard let path = ProcessInfo.processInfo.environment["CEVICHE_MEMORY_RAW"] else { throw XCTSkip("Set CEVICHE_MEMORY_RAW") }
        let fitted = Double(ProcessInfo.processInfo.environment["CEVICHE_MEMORY_WIDTH"] ?? "3000")!
        log("start")
        if ProcessInfo.processInfo.environment["CEVICHE_MEMORY_DECODE_ONLY"] != nil {
            do {
            let raw = CIRAWFilter(imageURL: URL(fileURLWithPath: path))!
            raw.scaleFactor = 0.5
            let ctx = CIContext(mtlDevice: MTLCreateSystemDefaultDevice()!, options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
            let img = raw.outputImage!
            _ = ctx.createCGImage(img, from: img.extent, format: .RGBA16, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            log("plain CIRAWFilter half-size render \(img.extent.size)")
            raw.scaleFactor = 1
            let full = raw.outputImage!
            _ = ctx.createCGImage(full, from: CGRect(x: 0, y: 0, width: 1000, height: 1000), format: .RGBA16, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            log("plain CIRAWFilter full-size 1000px tile")
            ctx.clearCaches(); log("clearCaches")
            ctx.reclaimResources(); log("reclaimResources")
            }
            log("context and filter released")
            try await Task.sleep(for: .seconds(2)); log("2 s later")
            Self.vm(); return
        }
        if let folder = DecodeCache.folder { try? FileManager.default.removeItem(at: folder); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let renderer = try RawRenderer(sourceURL: URL(fileURLWithPath: path))
        log("open \(renderer.info.width)×\(renderer.info.height)")
        var a = Adjustments()
        let t0 = ContinuousClock.now
        _ = try await renderer.preview(a); log("first preview  \(ContinuousClock.now - t0)")
        if let job = try await renderer.prepareDetail(a, region: CGRect(x: 0, y: 0, width: 1, height: 1), photoWidth: fitted) { _ = try job.render() }
        log("fitted detail at \(Int(fitted)) px")
        let steps: [(String, (inout Adjustments) -> Void)] = [
            ("exposure", { $0.exposure += 0.1 }), ("contrast", { $0.contrast += 4 }), ("highlights", { $0.highlights -= 8 }),
            ("shadows", { $0.shadows += 6 }), ("clarity", { $0.clarity += 5 }), ("texture", { $0.texture += 4 }),
            ("dehaze", { $0.dehaze += 3 }), ("vibrance", { $0.vibrance += 4 }), ("sharpness", { $0.sharpness += 8 }),
            ("noise reduction", { $0.noiseReduction += 6 }), ("vignette", { $0.vignette -= 4 })
        ]
        for (name, change) in steps {
            let clock = ContinuousClock.now
            for _ in 1...5 { change(&a); _ = try await renderer.preview(a) }
            log("  previews: \(name)  \(Int((ContinuousClock.now - clock).components.attoseconds / 5_000_000_000_000_000 + (ContinuousClock.now - clock).components.seconds * 200)) ms/preview")
            let t = ContinuousClock.now
            defer { _ = t }
            if let job = try await renderer.prepareDetail(a, region: CGRect(x: 0, y: 0, width: 1, height: 1), photoWidth: fitted) { _ = try job.render() }
            log("  fitted detail: \(name)  \(ContinuousClock.now - t)")
            try await Task.sleep(for: .milliseconds(1500)); log("  settled: \(name)")
        }
        for (i, origin) in [(0.1, 0.1), (0.4, 0.4), (0.7, 0.2)].enumerated() {
            if let job = try await renderer.prepareDetail(a, region: CGRect(x: origin.0, y: origin.1, width: 0.2, height: 0.2), photoWidth: nil) { _ = try job.render() }
            log("1:1 tile \(i)")
        }
        try await Task.sleep(for: .seconds(2)); log("idle 2 s")
        await renderer.releaseCaches(); try await Task.sleep(for: .seconds(2)); log("releaseCaches, 2 s")
        Self.vm()
        // Reopened with the same edit: the half-level decode should come from the cache.
        let again = try RawRenderer(sourceURL: URL(fileURLWithPath: path))
        let t2 = ContinuousClock.now
        _ = try await again.preview(a); log("reopen, first preview  \(ContinuousClock.now - t2)")
        let t3 = ContinuousClock.now
        let fresh = try RawRenderer(sourceURL: URL(fileURLWithPath: path))
        var other = a; other.temperature = 5000
        _ = try await fresh.preview(other); log("open with an uncached white balance, first preview  \(ContinuousClock.now - t3)")
    }
}

