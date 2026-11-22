import Foundation

/// Parameters needed by the dense (per-pixel) stage.
struct DenseParameters: Equatable {
    var smoothingRadius: Int
    var adaptiveBlockSize: Int
    var adaptiveOffset: Int
    var globalDarkRatio: Double
    var dilationRadius: Int

    init(_ p: DustRemovalParameters) {
        smoothingRadius = p.smoothingRadius
        adaptiveBlockSize = p.adaptiveBlockSize
        adaptiveOffset = p.adaptiveOffset
        globalDarkRatio = p.globalDarkRatio
        dilationRadius = p.dilationRadius
    }
}

/// Output of the dense stage. `sample` reads back small rectangles of the grey image and the
/// adaptive-threshold seeds for per-blob tests.
struct DenseOutput {
    var combined: BinaryImage
    /// (x, y, width, height) -> row-major grey and seed (0/255) bytes of that rectangle.
    var sample: (Int, Int, Int, Int) -> (gray: [UInt8], seeds: [UInt8])
}

/// Global threshold the reference implementation uses: `int(int(mean) / 1.2)`, computed from a 256-bin histogram.
/// Returns -1 when the guard is disabled.
func globalDarkThreshold(histogram: [UInt64], pixelCount: Int, parameters p: DenseParameters) -> Int {
    guard p.globalDarkRatio > 0 else { return -1 }
    var sum: UInt64 = 0
    for i in 0..<256 { sum += UInt64(i) * histogram[i] }
    let mean = Double(sum) / Double(pixelCount)
    return Int(Double(Int(mean)) / p.globalDarkRatio)
}

/// Runs `body(rowStart, rowEnd)` over disjoint row bands on all cores.
func parallelRows(_ height: Int, minRowsPerChunk: Int = 64, _ body: (Int, Int) -> Void) {
    let cores = ProcessInfo.processInfo.activeProcessorCount
    let chunk = max(minRowsPerChunk, (height + cores * 4 - 1) / (cores * 4))
    let chunks = (height + chunk - 1) / chunk
    if chunks <= 1 { body(0, height); return }
    DispatchQueue.concurrentPerform(iterations: chunks) { c in
        body(c * chunk, min(height, (c + 1) * chunk))
    }
}
