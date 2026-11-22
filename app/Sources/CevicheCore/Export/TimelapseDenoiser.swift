#if os(macOS)
import Foundation
import CoreGraphics
import simd

/// One export pass owns one bounded cache. Only original developed photos enter it; merged outputs never do.
/// macOS only: this cache allowance does not establish an iPad RAW-decoder or jetsam budget.
public actor TimelapseDenoiser {
    private let gpu: TimelapseDenoiseGPU
    private let skyCache: TimelapseSkyCache
    private var frames: [Int: TimelapseDenoiseGPU.Frame] = [:]
    public nonisolated let windowSize: Int
    var cachedCount: Int { frames.count }
    private(set) var lastAcceptedNeighbors = 0

    public init(size: CGSize, skyCache: TimelapseSkyCache? = nil) throws {
        gpu = try TimelapseDenoiseGPU(size: size)
        self.skyCache = try skyCache ?? TimelapseSkyCache()
        windowSize = Self.fittingWindow(size: size, allowance: min(3_000_000_000, MemoryBudget.bytes / 8))
    }

    /// Sources + means + masks, accumulation/result, and two compositor photos. Decoder/model/analysis memory is
    /// additional; use only a fraction of the Mac's RAM, never its entire capacity, for these persistent textures.
    static func fittingWindow(size: CGSize, allowance: Double) -> Int {
        [5, 3].first { size.width * size.height * Double($0 * 18 + 40) <= allowance } ?? 1
    }

    /// Captures are already in the video's chosen order. Never bridge missing/duplicate times, a capture gap,
    /// another camera or another source size. Image registration provides the independent framing check.
    public nonisolated static func window(around index: Int, captures: [TimelapseCapture], count: Int = 5, interval: Double?) -> [Int] {
        guard captures.indices.contains(index) else { return [] }
        let radius = max(0, min(2, (count - 1) / 2))
        guard radius > 0, let interval, interval.isFinite, interval > 0 else { return [index] }
        func adjacent(_ a: Int, _ b: Int) -> Bool {
            let first = captures[a], second = captures[b]
            guard let ta = first.date, let tb = second.date,
                  !first.camera.isEmpty, first.camera == second.camera,
                  let size = first.size, size == second.size else { return false }
            let delta = tb.timeIntervalSince(ta)
            return delta >= 0.001 && delta <= interval * TimelapseSeries.gapFactor
        }
        var result = [index]
        for direction in [-1, 1] {
            var previous = index
            for distance in 1...radius {
                let next = index + direction * distance
                guard captures.indices.contains(next), adjacent(min(previous, next), max(previous, next)) else { break }
                result.append(next); previous = next
            }
        }
        return result.sorted()
    }

    public func retain(_ indices: [Int]) {
        let keep = Set(indices.prefix(windowSize))
        frames = frames.filter { keep.contains($0.key) }
    }
    public func contains(_ index: Int) -> Bool { frames[index] != nil }
    public func prepare(_ photo: TimelapsePhoto, at index: Int, maskKey: String? = nil) throws {
        try Task.checkCancellation()
        guard frames[index] != nil || frames.count < windowSize else { throw EditorError.render }
        frames[index] = try autoreleasepool { try gpu.prepare(photo, skyCache: skyCache, maskKey: maskKey ?? String(index)) }
    }
    public func render(_ index: Int, window: [Int]) throws -> TimelapsePhoto {
        lastAcceptedNeighbors = 0
        try Task.checkCancellation()
        guard let reference = frames[index] else { throw EditorError.render }
        var neighbors: [TimelapseDenoiseGPU.Neighbor] = []
        for other in window where other != index {
            try Task.checkCancellation()
            guard let frame = frames[other], reference.stars.count >= 12, frame.stars.count >= 12 else { continue }
            let alignment: NightSkyAlignment
            do { alignment = try NightSkyRegistration.align(source: frame.stars, reference: reference.stars, width: gpu.width) }
            catch is CancellationError { throw CancellationError() }
            catch { continue } // Insufficient or inconsistent stars leave this photo untouched.
            guard Self.accepts(alignment, size: CGSize(width: gpu.width, height: gpu.height)) else { continue }
            neighbors.append(.init(frame: frame, alignment: alignment))
        }
        lastAcceptedNeighbors = neighbors.count
        return try autoreleasepool { try gpu.photo(gpu.merge(reference: reference, neighbors: neighbors)) }
    }
    /// Reject camera moves even if some stars still match. Within the surviving overlap, both sky masks and the
    /// per-pixel noise test must agree before a neighbor contributes.
    static func accepts(_ alignment: NightSkyAlignment, size: CGSize) -> Bool {
        guard alignment.matches >= 12, alignment.heldOutP95.isFinite, alignment.heldOutP95 <= 0.75 else { return false }
        let limit = min(size.width, size.height) * 0.03
        return [SIMD2(0.0, 0.0), SIMD2(size.width - 1, 0), SIMD2(0, size.height - 1), SIMD2(size.width - 1, size.height - 1)].allSatisfy {
            let mapped = alignment.sourcePoint($0)
            return mapped.x.isFinite && mapped.y.isFinite && simd_distance(mapped, $0) <= limit
        }
    }
    public func preview(_ photo: TimelapsePhoto, size: CGSize) throws -> CGImage { try gpu.preview(photo, size: size) }
    public func clear() { frames.removeAll(); gpu.clear() }
}
#endif
