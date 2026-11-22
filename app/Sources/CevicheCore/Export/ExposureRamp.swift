import Foundation
import CoreImage

/// Evens out the light of a timelapse: finds where it changes fast, such as sunset into night, and works out an
/// Exposure for every frame so the change is gentler and frame-to-frame flicker goes away.
///
/// Brightness is in EV and measured before each photo's own Exposure (`RawRenderer.sceneBrightness`), so a frame
/// shown with Exposure `e` ends up at `measured + e`, and a correction in EV is exactly a change of the slider.
public struct ExposureRamp: Sendable, Equatable {
    public struct Options: Sendable, Equatable, Codable {
        /// How much of the scene's change in light the video keeps: 1 leaves it as shot, 0 holds it level.
        public var keep = 0.3
        /// Follow the smoothed light rather than each frame's own, which removes flicker.
        public var deflicker = true
        /// Frames the light is smoothed over; 0 picks one from the length of the series.
        public var smoothing = 0
        public init() {}
    }
    /// A run of frames whose light keeps moving the same way.
    public struct Transition: Sendable, Equatable {
        public var start: Int
        public var end: Int
        /// In EV, negative when it gets darker.
        public var change: Double
    }

    /// Each frame's light before its own Exposure, in EV.
    public let measured: [Double]
    /// Each frame's Exposure now.
    public let current: [Double]
    /// The light with flicker removed.
    public let smoothed: [Double]
    public let window: Int
    public let transitions: [Transition]

    /// The smallest steady change, in EV per frame, that counts as part of a transition.
    static let movingRate = 0.02
    /// A transition must change the light by at least this much, in EV.
    static let minimumChange = 1.0
    public static let exposureRange = -5.0...5.0

    public init(measured: [Double], current: [Double], smoothing: Int = 0) {
        precondition(measured.count == current.count)
        self.measured = measured; self.current = current
        let window = smoothing > 0 ? smoothing : Self.automaticWindow(count: measured.count)
        self.window = window
        smoothed = Self.smooth(measured, window: window)
        transitions = Self.transitions(in: smoothed)
    }
    /// About a twelfth of the series, odd and between 5 and 41 frames: long enough to average out flicker, short
    /// enough to follow a sunset.
    public static func automaticWindow(count: Int) -> Int {
        let window = min(41, max(5, count / 12))
        return window % 2 == 0 ? window + 1 : window
    }

    /// A running median, which ignores single odd frames, followed by a running mean of the same width, which
    /// rounds off the median's steps. Windows shrink at the ends so the first and last frames follow their own light.
    public static func smooth(_ values: [Double], window: Int) -> [Double] {
        guard values.count > 2, window > 1 else { return values }
        func running(_ values: [Double], _ combine: ([Double]) -> Double) -> [Double] {
            values.indices.map { index in
                let half = min(window / 2, index, values.count - 1 - index)
                return combine(Array(values[(index - half)...(index + half)]))
            }
        }
        let median = running(values) { slice in let sorted = slice.sorted(); return sorted[sorted.count / 2] }
        return running(median) { $0.reduce(0, +) / Double($0.count) }
    }

    /// Runs of frames moving one way at `movingRate` or faster, allowing two slower frames inside a run, that add up
    /// to `minimumChange` or more.
    static func transitions(in smoothed: [Double]) -> [Transition] {
        guard smoothed.count > 2 else { return [] }
        var found: [Transition] = []
        var start: Int?, sign = 0.0, last = 0, pause = 0
        func close() {
            if let begin = start, abs(smoothed[last] - smoothed[begin]) >= minimumChange {
                found.append(Transition(start: begin, end: last, change: smoothed[last] - smoothed[begin]))
            }
            start = nil; pause = 0
        }
        for index in 1..<smoothed.count {
            let step = smoothed[index] - smoothed[index - 1]
            let moving = abs(step) >= movingRate
            if moving, start != nil, (step < 0 ? -1.0 : 1.0) == sign { last = index; pause = 0; continue }
            if moving { close(); start = index - 1; sign = step < 0 ? -1 : 1; last = index; continue }
            if start != nil { pause += 1; if pause > 2 { close() } }
        }
        close()
        return found
    }

    /// The Exposure each frame needs so its light follows `options`, measured against `reference`, whose Exposure
    /// stays as it is unless a keyframe moves it. `keyframes` are offsets in EV drawn onto the target curve at frames
    /// (see `offsets`). Values stay inside the slider's range; `clamped` counts the frames that hit it.
    public func exposures(reference: Int, options: Options, keyframes: [Int: Double] = [:]) -> (values: [Double], clamped: Int) {
        guard measured.indices.contains(reference) else { return (current, 0) }
        let keep = min(1, max(0, options.keep))
        let look = measured[reference] + current[reference]
        let offset = Self.offsets(keyframes, count: measured.count)
        var clamped = 0
        let values = measured.indices.map { index -> Double in
            let trend = smoothed[index] - smoothed[reference]
            let base = index == reference ? current[index]
                : options.deflicker ? look + keep * trend - measured[index] : current[reference] - (1 - keep) * trend
            let wanted = base + offset[index]
            let value = min(Self.exposureRange.upperBound, max(Self.exposureRange.lowerBound, wanted))
            if value != wanted { clamped += 1 }
            if index == reference && offset[index] == 0 { return current[index] }
            // Two decimals, as the slider shows them.
            return (value * 100).rounded() / 100
        }
        return (values, clamped)
    }

    /// The offset in EV at every frame from keyframes drawn on the curve: each keyframe's own value at its frame,
    /// easing between neighbouring keyframes (smoothstep, so the curve leaves and reaches each one level and never
    /// overshoots), and held at the first and last keyframe's value beyond them.
    public static func offsets(_ keyframes: [Int: Double], count: Int) -> [Double] {
        let keys = keyframes.filter { (0..<count).contains($0.key) }.sorted { $0.key < $1.key }
        guard let first = keys.first, let last = keys.last else { return [Double](repeating: 0, count: count) }
        return (0..<count).map { index in
            if index <= first.key { return first.value }
            if index >= last.key { return last.value }
            let upper = keys.firstIndex { $0.key >= index }!
            let a = keys[upper - 1], b = keys[upper]
            let t = Double(index - a.key) / Double(b.key - a.key)
            return a.value + (b.value - a.value) * t * t * (3 - 2 * t)
        }
    }
    /// The light each frame ends up with at `exposures`.
    public func result(_ exposures: [Double]) -> [Double] { zip(measured, exposures).map(+) }
}

extension RawRenderer {
    /// The photo's light before its Exposure and tone curve, in EV: the average of log luminance from a small linear
    /// decode with the photo's white balance, leaving out the darkest and brightest 2% so stars, lamps and borders
    /// don't steer it. Comparable between frames of one series, not an absolute scene value.
    public func sceneBrightness(_ adjustments: Adjustments) throws -> Double {
        let a = adjustments.effective(defaults: info.defaults)
        let limit = 192.0
        var image: CIImage
        switch source {
        case .raw(let raw):
            raw.scaleFactor = Float(min(1, limit / Double(max(info.width, info.height))))
            raw.neutralTemperature = Float(a.temperature)
            raw.neutralTint = Float(a.tint)
            raw.exposure = 0
            raw.boostAmount = 0
            // Keeps a bright day sky above 1.0 rather than clipping it, so its light measures true.
            raw.extendedDynamicRangeAmount = 1
            guard let output = raw.outputImage else { throw EditorError.decode }
            image = output
            if image.extent.width > limit * 1.5 || image.extent.height > limit * 1.5 { image = Self.scaled(image, limit: limit) }
        case .bitmap(let bitmap):
            image = Self.scaled(bitmap, limit: limit)
        }
        try Task.checkCancellation()
        let bounds = image.extent.integral
        let width = Int(bounds.width), height = Int(bounds.height)
        guard width > 0, height > 0 else { throw EditorError.render }
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            context.render(image, toBitmap: bytes.baseAddress!, rowBytes: width * 16, bounds: bounds, format: .RGBAf,
                           colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        }
        var logs: [Double] = []; logs.reserveCapacity(width * height)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let y = 0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1]) + 0.0722 * Double(pixels[index + 2])
            logs.append(log2(max(y, 1e-6)))
        }
        logs.sort()
        let trim = logs.count / 50
        let kept = logs[trim..<(logs.count - trim)]
        return kept.reduce(0, +) / Double(max(1, kept.count))
    }
}
