import XCTest
import Darwin
@testable import CevicheCore

/// Where a night-sky merge's memory goes: runs Night Sky Noise Reduction (or `CEVICHE_NIGHT_SKY_TOOL=trails`) on the
/// photos in `CEVICHE_NIGHT_SKY_SAMPLES`, sampling the footprint every 20 ms, and prints the peak reached during each
/// step the tool reports through its progress. Skipped without samples.
final class NightSkyMemoryProfileTests: XCTestCase {
    private static func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    /// The peak per step, steps in the order first seen.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var step = "start"
        private(set) var order: [String] = ["start"]
        private(set) var peaks: [String: Double] = [:]
        /// The footprint when the step began, to tell what it adds from what it inherits.
        private(set) var starts: [String: Double] = [:]
        private var running = true
        func set(_ name: String) {
            lock.lock(); defer { lock.unlock() }
            // Numbered steps ("Analyzing 3 of 10") fold into one.
            let key = name.replacingOccurrences(of: "[0-9]+", with: "#", options: .regularExpression)
            if key != step {
                step = key
                if !order.contains(key) { order.append(key); starts[key] = NightSkyMemoryProfileTests.footprint() }
            }
        }
        func sample() {
            let now = NightSkyMemoryProfileTests.footprint()
            lock.lock(); peaks[step] = max(peaks[step] ?? 0, now); lock.unlock()
        }
        func stop() { lock.lock(); running = false; lock.unlock() }
        var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    }

    func testMemoryPerStep() throws {
        guard let folder = ProcessInfo.processInfo.environment["CEVICHE_NIGHT_SKY_SAMPLES"] else { throw XCTSkip("Set CEVICHE_NIGHT_SKY_SAMPLES to a folder of RAW photos") }
        let limit = ProcessInfo.processInfo.environment["CEVICHE_NIGHT_SKY_LIMIT"].flatMap(Int.init) ?? 10
        // CEVICHE_NIGHT_SKY_MAP_SUMS=1 puts the merge's sums in a mapped file as a phone does; =0 keeps them in memory.
        if let map = ProcessInfo.processInfo.environment["CEVICHE_NIGHT_SKY_MAP_SUMS"] { NightSkyGPU.mapsSums = map == "1" }
        defer { NightSkyGPU.mapsSums = nil }
        let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil)
            .filter { CatalogImporter.supported($0) }.sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(limit)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("night-memory-\(UUID().uuidString).dng")
        defer { try? FileManager.default.removeItem(at: output) }
        let recorder = Recorder()
        let sampler = Thread { while recorder.isRunning { recorder.sample(); Thread.sleep(forTimeInterval: 0.02) } }
        sampler.start()
        let progress: @Sendable (Double, String) -> Void = { _, step in recorder.set(step) }
        let start = Date()
        if ProcessInfo.processInfo.environment["CEVICHE_NIGHT_SKY_TOOL"] == "trails" {
            let merger = try StarTrailsMerger(urls: Array(urls))
            recorder.set("analyze")
            _ = try autoreleasepool { try merger.analyze(progress: progress) }
            recorder.set("merge")
            try autoreleasepool { try merger.merge(StarTrailsSettings(), to: output, progress: progress) }
        } else {
            let merger = try NightSkyDenoiser(urls: Array(urls))
            recorder.set("analyze")
            _ = try autoreleasepool { try merger.analyze(progress: progress) }
            recorder.set("merge")
            try autoreleasepool { try merger.merge(NightSkyDenoiseSettings(), to: output, progress: progress) }
        }
        recorder.set("done")
        Thread.sleep(forTimeInterval: 0.2)
        recorder.stop()
        let pixels = (try? RawRenderer(sourceURL: urls.first!).info).map { Double($0.width * $0.height) } ?? 0
        print(String(format: "NIGHTMEM %d photos, %.1f MP, %.1f s", urls.count, pixels / 1e6, Date().timeIntervalSince(start)))
        for step in recorder.order { if let peak = recorder.peaks[step] { print(String(format: "NIGHTMEM %7.0f → %7.0f MB  %@", recorder.starts[step] ?? 0, peak, step)) } }
    }

    /// The merge decoded in half floats against full floats, on the samples: the developed DNGs' mean and largest
    /// difference, in display values from 0 to 1.
    func testHalfFloatMergeMatchesFloat() throws {
        guard let folder = ProcessInfo.processInfo.environment["CEVICHE_NIGHT_SKY_SAMPLES"] else { throw XCTSkip("Set CEVICHE_NIGHT_SKY_SAMPLES to a folder of RAW photos") }
        let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil)
            .filter { CatalogImporter.supported($0) }.sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(6)
        let merger = try NightSkyDenoiser(urls: Array(urls))
        _ = try merger.analyze()
        func merged(float: Bool) throws -> [UInt8] {
            NightSkyAnalyzer.mergesInFloat = float
            defer { NightSkyAnalyzer.mergesInFloat = false }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("night-\(float ? "float" : "half")-\(UUID().uuidString).dng")
            defer { try? FileManager.default.removeItem(at: url) }
            try merger.merge(NightSkyDenoiseSettings(), to: url)
            let renderer = try RawRenderer(sourceURL: url)
            let image = try awaitResult { try await renderer.displayImage(renderer.info.defaults, maxDimension: 2048, sdr: true) }
            var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return pixels
        }
        let full = try merged(float: true), half = try merged(float: false)
        XCTAssertEqual(full.count, half.count)
        var total = 0.0, largest = 0
        for k in full.indices where k % 4 != 3 { let d = abs(Int(full[k]) - Int(half[k])); total += Double(d); largest = max(largest, d) }
        let mean = total / Double(full.count * 3 / 4)
        print(String(format: "NIGHTHALF mean %.3f, largest %d of 255", mean, largest))
        XCTAssertLessThan(mean, 0.5, "half floats change the merge by less than half an 8-bit step on average")
    }

    private func awaitResult<T>(_ work: @escaping () async throws -> T) throws -> T {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<T, Error>?
        Task { do { result = .success(try await work()) } catch { result = .failure(error) }; done.signal() }
        done.wait()
        return try result!.get()
    }
}
