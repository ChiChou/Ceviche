import Foundation
import CoreGraphics
import CoreImage
import Metal
import simd

/// Preview-size copies of every photo in a temporary file, as half floats: slot 0 as shot, slot 1 on the anchor's sky
/// (NaN where the photo has no sky). Mapped into memory for reading, so long sequences don't need to fit in RAM.
final class NightSkyCache: @unchecked Sendable {
    let url: URL
    let width: Int, height: Int
    let slots: Int
    var values: Int { width * height * 3 }
    private var handle: FileHandle?
    private var mapped: Data?

    init(count: Int, width: Int, height: Int, slots: Int) throws {
        self.width = width; self.height = height; self.slots = slots
        url = FileManager.default.temporaryDirectory.appendingPathComponent("Ceviche Night Sky \(UUID().uuidString).cache")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw PanoramaError.message(L10n.tr("Can’t write to \(url.deletingLastPathComponent().path)."))
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(count * width * height * 3 * slots * 2))
        self.handle = handle
    }
    deinit { try? handle?.close(); mapped = nil; try? FileManager.default.removeItem(at: url) }

    func write(_ floats: [Float], frame: Int, slot: Int) throws {
        precondition(floats.count == values)
        guard let handle else { preconditionFailure("NightSkyCache written after finish()") }
        try handle.seek(toOffset: UInt64((frame * slots + slot) * values * 2))
        try floats.map { Float16($0) }.withUnsafeBytes { try handle.write(contentsOf: Data($0)) }
    }

    func finish() throws {
        try handle?.close(); handle = nil
        mapped = try Data(contentsOf: url, options: .alwaysMapped)
    }

    /// Replaces `slot` of `frames` once finished, each made from the frame's as-shot copy, then maps the file again.
    func rewrite(_ frames: [Int], slot: Int, _ make: (Int, [Float]) throws -> [Float]) throws {
        guard let mapped else { throw PanoramaError.message(L10n.tr("Analyze the photos first.")) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try mapped.withUnsafeBytes { raw in
            let all = raw.bindMemory(to: Float16.self)
            for i in frames {
                let start = i * slots * values
                let made = try make(i, all[start..<(start + values)].map(Float.init))
                precondition(made.count == values)
                try handle.seek(toOffset: UInt64((i * slots + slot) * values * 2))
                try made.map { Float16($0) }.withUnsafeBytes { try handle.write(contentsOf: Data($0)) }
            }
        }
        self.mapped = try Data(contentsOf: url, options: .alwaysMapped)
    }

    struct Reader {
        let all: UnsafeBufferPointer<Float16>
        let width: Int, height: Int, slots: Int
        func copy(_ frame: Int, _ slot: Int) -> UnsafeBufferPointer<Float16> {
            let values = width * height * 3, start = (frame * slots + slot) * values
            return UnsafeBufferPointer(rebasing: all[start..<(start + values)])
        }
        @inline(__always) func pixel(_ copy: UnsafeBufferPointer<Float16>, _ p: Int) -> SIMD3<Float> {
            SIMD3(Float(copy[p * 3]), Float(copy[p * 3 + 1]), Float(copy[p * 3 + 2]))
        }
        /// Bilinear at `point` (pixel centers at integers); nil outside the copy or where a corner has no sample.
        func bilinear(_ frame: Int, _ slot: Int, _ point: SIMD2<Double>) -> SIMD3<Float>? {
            guard point.x >= 0, point.y >= 0, point.x <= Double(width - 1), point.y <= Double(height - 1) else { return nil }
            let copy = copy(frame, slot)
            let x0 = min(width - 2, Int(point.x)), y0 = min(height - 2, Int(point.y))
            let fx = Float(point.x - Double(x0)), fy = Float(point.y - Double(y0))
            let a = pixel(copy, y0 * width + x0), b = pixel(copy, y0 * width + x0 + 1)
            let c = pixel(copy, (y0 + 1) * width + x0), d = pixel(copy, (y0 + 1) * width + x0 + 1)
            let v = (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
            return v.x.isFinite && v.y.isFinite && v.z.isFinite ? v : nil
        }
    }

    func read(_ body: (Reader) throws -> Void) throws {
        guard let mapped else { throw PanoramaError.message(L10n.tr("Analyze the photos first.")) }
        try mapped.withUnsafeBytes { raw in
            try body(Reader(all: raw.bindMemory(to: Float16.self), width: width, height: height, slots: slots))
        }
    }
}

/// What a set of photos needs before a night-sky tool can stack them.
public enum NightSkyPhotos {
    /// The photos that can't be stacked with the rest, by position in `urls`, with why: of another kind (RAW among
    /// processed photos or the other way round), from another camera, or of another size than most of them. Reads only
    /// the files' metadata, so the photos can be left out before analysis starts.
    public static func unstackable(_ urls: [URL]) throws -> [Int: String] {
        var read = [NightSkyFrameMetadata?](repeating: nil, count: urls.count)
        var failure: Error?
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: urls.count) { i in
            do { let m = try NightSkyFrameMetadata.read(urls[i]); lock.withLock { read[i] = m } } catch { lock.withLock { failure = error } }
        }
        if let failure { throw failure }
        let frames = read.map { $0! }
        // The value most photos share; among equally common ones, the first to appear.
        func usual<T: Hashable>(_ values: [T?]) -> T? {
            let present = values.compactMap { $0 }, counts = present.reduce(into: [T: Int]()) { $0[$1, default: 0] += 1 }
            return present.reduce(nil as T?) { best, value in best.map { counts[value]! > counts[$0]! ? value : $0 } ?? value }
        }
        // Processed files often lose the camera on the way through an editor; only the ones that name it count.
        let cameras = frames.map { m -> String? in
            let name = "\(m.base.make) \(m.base.model)".trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
        let sizes = frames.map { "\($0.base.width) × \($0.base.height)" }
        let kind = usual(frames.map(\.base.isRAW)), camera = usual(cameras), size = usual(sizes)
        var reasons: [Int: String] = [:]
        for i in frames.indices {
            if frames[i].base.isRAW != kind {
                reasons[i] = frames[i].base.isRAW ? L10n.tr("RAW among processed photos") : L10n.tr("Processed among RAW photos")
            } else if let own = cameras[i], own != camera {
                // Results Ceviche merged name it as their camera.
                reasons[i] = frames[i].base.make == "Ceviche" ? L10n.tr("A merged result, not a photo") : L10n.tr("Other camera: \(own)")
            } else if sizes[i] != size {
                reasons[i] = L10n.tr("Other size: \(sizes[i])")
            }
        }
        return reasons
    }

}
