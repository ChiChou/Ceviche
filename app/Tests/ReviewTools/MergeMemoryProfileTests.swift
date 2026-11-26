import XCTest
import Darwin
@testable import CevicheCore

/// Where a Focus Stack's or an HDR Panorama's memory goes: runs `CEVICHE_MERGE_MEMORY_TOOL` (`focus` or `hdrpano`) on
/// the photos in `CEVICHE_MERGE_MEMORY_SAMPLES` (the first `CEVICHE_MERGE_MEMORY_LIMIT`), sampling the footprint every
/// 20 ms, and prints the footprint at the start and the peak of each step. `CEVICHE_MERGE_MEMORY_MAP=0` keeps the
/// full-size buffers in memory to compare. Skipped without samples.
final class MergeMemoryProfileTests: XCTestCase {
    private static func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var step = "start"
        private(set) var order: [String] = ["start"]
        private(set) var peaks: [String: Double] = [:]
        private(set) var starts: [String: Double] = [:]
        private(set) var times: [String: Date] = [:]
        private var running = true
        func set(_ name: String) {
            lock.lock(); defer { lock.unlock() }
            if name != step, !order.contains(name) { order.append(name); starts[name] = MergeMemoryProfileTests.footprint(); times[name] = Date() }
            step = name
        }
        func sample() {
            let now = MergeMemoryProfileTests.footprint()
            lock.lock(); peaks[step] = max(peaks[step] ?? 0, now); lock.unlock()
        }
        func stop() { lock.lock(); running = false; lock.unlock() }
        var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    }

    func testMemoryPerStep() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let folder = environment["CEVICHE_MERGE_MEMORY_SAMPLES"] else { throw XCTSkip("Set CEVICHE_MERGE_MEMORY_SAMPLES to a folder of RAW photos") }
        let limit = environment["CEVICHE_MERGE_MEMORY_LIMIT"].flatMap(Int.init) ?? .max
        if let map = environment["CEVICHE_MERGE_MEMORY_MAP"] { MappedBuffer.enabled = map == "1" }
        defer { MappedBuffer.enabled = true }
        let urls = Array(try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil)
            .filter { CatalogImporter.supported($0) }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }.prefix(limit))
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("merge-memory-\(UUID().uuidString).dng")
        defer { try? FileManager.default.removeItem(at: output) }
        let recorder = Recorder()
        let sampler = Thread { while recorder.isRunning { recorder.sample(); Thread.sleep(forTimeInterval: 0.02) } }
        sampler.start()
        let start = Date()
        if environment["CEVICHE_MERGE_MEMORY_TOOL"] == "hdrpano" {
            recorder.set("brackets")
            let merger = try autoreleasepool { () throws -> PanoramaMerger in
                let brackets = try HDRPanoramaMerger(urls: urls)
                return try brackets.panorama(groups: try brackets.group().groups)
            }
            var settings = PanoramaSettings()
            recorder.set("align")
            settings.projection = try autoreleasepool { try merger.align().suggested }
            recorder.set("preview")
            _ = try autoreleasepool { try merger.preview(settings) }
            recorder.set("merge")
            try autoreleasepool { try merger.merge(settings, to: output) }
        } else {
            let stacker = try FocusStacker(urls: urls)
            recorder.set("analyze")
            _ = try autoreleasepool { try stacker.analyze() }
            recorder.set("preview")
            _ = try autoreleasepool { try stacker.preview(FocusStackSettings()) }
            recorder.set("merge")
            try autoreleasepool { try stacker.merge(FocusStackSettings(), to: output) }
        }
        recorder.set("done")
        Thread.sleep(forTimeInterval: 0.2)
        recorder.stop()
        print(String(format: "MERGEMEM %d photos, %.1f s", urls.count, Date().timeIntervalSince(start)))
        let order = recorder.order
        for (i, step) in order.enumerated() {
            guard let peak = recorder.peaks[step] else { continue }
            let seconds = i + 1 < order.count ? (recorder.times[order[i + 1]] ?? Date()).timeIntervalSince(recorder.times[step] ?? start) : 0
            print(String(format: "MERGEMEM %7.0f → %7.0f MB %6.1f s  %@", recorder.starts[step] ?? 0, peak, seconds, step))
        }
    }
}
