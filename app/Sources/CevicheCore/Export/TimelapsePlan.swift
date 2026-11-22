import Foundation

/// Which photos make each video frame. One frame per photo is the plain sequence; following capture time places the
/// photos on the video's clock by when they were taken, so a burst plays at the series' pace instead of slowing down
/// and a pause is filled instead of jumping.
public struct TimelapsePlan: Equatable, Sendable {
    public struct Frame: Equatable, Sendable {
        /// A photo's position in the series.
        public var photo: Int
        /// The photo after it, mixed in by `weight` (0 shows `photo` alone).
        public var next: Int?
        public var weight: Double
        public init(photo: Int, next: Int? = nil, weight: Double = 0) { self.photo = photo; self.next = next; self.weight = weight }
        public var photos: [Int] { next.map { [photo, $0] } ?? [photo] }
        /// The photo that shows most.
        public var dominant: Int { weight > 0.5 ? next ?? photo : photo }
    }
    public let frames: [Frame]
    /// A video frame count past which the settings are surely a mistake: an hour at 60 fps.
    public static let maximumFrames = 216_000

    public init(photos: Int) { frames = (0..<photos).map { Frame(photo: $0) } }

    /// `times` are the photos' capture times in series order, nil where a photo records none; such photos follow the
    /// one before at `usual` seconds. Each frame covers `step` seconds, and pauses longer than `pauseLimit` seconds are
    /// shortened to it. A pause of zero, a repeat of the same moment, takes no video time.
    public init(times: [Date?], usual: Double, step: Double, fill: TimelapseFill, pauseLimit: Double?) throws {
        guard !times.isEmpty else { frames = []; return }
        let usual = max(0.001, usual), step = max(0.001, step)
        // Where each photo sits on the video's clock, in seconds of real time from the first.
        var positions = [0.0], last = times[0]
        for time in times.dropFirst() {
            var pause = usual
            if let time, let previous = last { pause = max(0, time.timeIntervalSince(previous)) }
            if let pauseLimit { pause = min(pause, max(0, pauseLimit)) }
            positions.append(positions.last! + pause)
            if time != nil { last = time } else if let previous = last { last = previous.addingTimeInterval(usual) }
        }
        let count = Int((positions.last! / step).rounded(.down)) + 1
        guard count <= Self.maximumFrames else {
            throw EditorError.invalidDocument(L10n.tr("These settings make \(count) frames. Let each frame cover more time or shorten the pauses."))
        }
        var frames: [Frame] = [], segment = 0
        frames.reserveCapacity(count)
        for index in 0..<count {
            let at = Double(index) * step
            while segment + 1 < positions.count && positions[segment + 1] <= at { segment += 1 }
            guard segment + 1 < positions.count else { frames.append(Frame(photo: positions.count - 1)); continue }
            let weight = (at - positions[segment]) / (positions[segment + 1] - positions[segment])
            switch fill {
            case .hold: frames.append(Frame(photo: weight > 0.5 ? segment + 1 : segment))
            case .blend: frames.append(weight < 0.0001 ? Frame(photo: segment) : Frame(photo: segment, next: segment + 1, weight: weight))
            }
        }
        self.frames = frames
    }

    /// The plan the settings ask for, for a series read from `captures` in playing order.
    public init(settings: TimelapseSettings, captures: [TimelapseCapture], interval: Double?) throws {
        guard settings.timing == .captureTime else { self.init(photos: captures.count); return }
        let usual = interval ?? 1
        try self.init(times: captures.map(\.date), usual: usual, step: settings.frameStep ?? usual, fill: settings.fill,
                      pauseLimit: settings.pauseLimit.map { $0 * usual })
    }

    /// How many video frames show each photo most, for the filmstrip: 0 where a photo is skipped.
    public var uses: [Int: Int] { frames.reduce(into: [:]) { $0[$1.dominant, default: 0] += 1 } }
}
