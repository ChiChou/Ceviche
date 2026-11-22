import Foundation
import Vision

/// Why the culling assistant suggests rejecting a photo. Stored by raw value with the photo's quality report, so the
/// library can filter by the reason the assistant last gave.
public enum CullingIssue: String, Codable, CaseIterable, Sendable, Identifiable {
    case blurry, outOfFocus, overexposed, underexposed, eyesClosed
    /// A frame of a burst that is not the one kept.
    case burstAlternate
    /// A frame of a burst that is a copy of another, or the same moment again: not the one kept.
    case duplicate
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .blurry: return L10n.tr("Blurry")
        case .outOfFocus: return L10n.tr("Out of Focus")
        case .overexposed: return L10n.tr("Overexposed")
        case .underexposed: return L10n.tr("Underexposed")
        case .eyesClosed: return L10n.tr("Eyes Closed")
        case .burstAlternate: return L10n.tr("Similar Shot")
        case .duplicate: return L10n.tr("Duplicate", context: "culling issue")
        }
    }
}

/// How readily the assistant calls a photo a problem. Thresholds were set on the sample RAWs blurred and pushed
/// in exposure, and on RAW + JPEG portraits with soft backgrounds: the crispest detail of a sharp photo measures 0.84–0.97,
/// a Gaussian blur of 1, 2 and 4 pixels (at 2048 px) about 0.6, 0.45 and 0.3, an 8-pixel motion blur 0.46–0.62.
public enum CullingSensitivity: String, CaseIterable, Codable, Sendable, Identifiable {
    case relaxed, balanced, strict
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .relaxed: return L10n.tr("Relaxed")
        case .balanced: return L10n.tr("Moderate")
        case .strict: return L10n.tr("Strict")
        }
    }
    /// When even the photo's crispest detail is softer than this, the whole photo is blurry (shake, motion, a miss).
    var blur: Double { switch self { case .relaxed: 0.45; case .balanced: 0.55; case .strict: 0.65 } }
    /// A subject softer than this, in a photo with crisp detail elsewhere, is out of focus.
    var softSubject: Double { switch self { case .relaxed: 0.35; case .balanced: 0.45; case .strict: 0.55 } }
    /// An eye whose outline is flatter than this looks closed.
    var closedEye: Double { switch self { case .relaxed: 0.09; case .balanced: 0.12; case .strict: 0.15 } }
    /// More than this fraction clipped to white is overexposed.
    var clipped: Double { switch self { case .relaxed: 0.25; case .balanced: 0.15; case .strict: 0.08 } }
    /// Darker than this median, with nine tenths of the photo below `dark.bright`, is underexposed.
    var dark: (median: Double, bright: Double) { switch self { case .relaxed: (0.08, 0.2); case .balanced: (0.15, 0.3); case .strict: (0.2, 0.38) } }
    /// A dusk landscape or a low-key portrait is dark on purpose; a photo Vision rates this well keeps its exposure,
    /// except under Strict.
    var exposureVeto: Double? { self == .strict ? nil : 0.6 }
}

/// How the photo was exposed, from the catalog's EXIF: it says whether a dark picture is a dark scene or a mistake.
public struct ExposureSettings: Equatable, Sendable {
    public var exposureTime: Double?
    public var iso: Int?
    public var fNumber: Double?
    public var exposureBias: Double?
    public init(exposureTime: Double? = nil, iso: Int? = nil, fNumber: Double? = nil, exposureBias: Double? = nil) {
        self.exposureTime = exposureTime; self.iso = iso; self.fNumber = fNumber; self.exposureBias = exposureBias
    }
    public init(_ asset: CatalogAsset) {
        self.init(exposureTime: asset.exposureTime, iso: asset.iso, fNumber: asset.fNumber, exposureBias: asset.exposureBias)
    }
    /// The light the settings were chosen for, as EV at ISO 100: about 15 in sun, 12 overcast, 7–9 for floodlit
    /// buildings at night, 5–7 indoors, 2–4 at dusk and below 0 under stars. Nil when the EXIF lacks one of the three.
    public var sceneEV: Double? {
        guard let time = exposureTime, time > 0, let iso, iso > 0, let fNumber, fNumber > 0 else { return nil }
        return log2(fNumber * fNumber / time) - log2(Double(iso) / 100)
    }
    /// A dark picture is the scene as it was: settings already gathering this much light (a slow shutter, a high ISO,
    /// a wide aperture) mean night, dusk or a dim room, and an exposure dialled down a stop or more was asked for. On a
    /// 1,000-photo library every dark photo flagged was one of these (stars at EV −7, blue hour at 3–6, floodlit
    /// mosques at 7.3, silhouettes and a tunnel framing at 8 with −1.3); a daylight exposure (10 and up) that comes
    /// out dark still counts as a mistake.
    public var darkOnPurpose: Bool {
        if let bias = exposureBias, bias <= -1 { return true }
        return sceneEV.map { $0 < 9 } ?? false
    }
}

extension PhotoQualityReport {
    /// Faces large enough to judge whose eyes both look closed.
    public func closedEyes(_ sensitivity: CullingSensitivity) -> Int {
        faces.filter { face in
            face.bounds.width >= Face.judgedWidth && face.eyesClosed(below: sensitivity.closedEye)
        }.count
    }
    /// The problems that make the photo a candidate for rejection on its own, outside any burst. `exposure` keeps a
    /// night or deliberately dark photo from counting as underexposed.
    public func issues(_ sensitivity: CullingSensitivity, exposure: ExposureSettings? = nil) -> [CullingIssue] {
        var found: [CullingIssue] = []
        // A shallow depth of field leaves most of a sharp photo soft, so blur is judged on its crispest detail.
        let peak = peakSharpness ?? sharpness
        if let peak, peak < sensitivity.blur { found.append(.blurry) }
        // Focus landed elsewhere: the subject is soft while something else in the photo is crisp.
        else if let peak, subject != nil, let subjectSharpness, subjectSharpness < sensitivity.softSubject, peak - subjectSharpness >= 0.25 { found.append(.outOfFocus) }
        let vetoed = sensitivity.exposureVeto.map { (aesthetics ?? -1) >= $0 } ?? false
        if !vetoed {
            if highlights > sensitivity.clipped || (brightness > 0.75 && highlights > sensitivity.clipped / 3) { found.append(.overexposed) }
            else if brightness < sensitivity.dark.median && brightPercentile < sensitivity.dark.bright, exposure?.darkOnPurpose != true { found.append(.underexposed) }
        }
        if closedEyes(sensitivity) > 0 { found.append(.eyesClosed) }
        return found
    }
}

/// How close in time and content frames must be to count as one burst.
public struct BurstSettings: Equatable, Codable, Sendable {
    /// Longest pause between two frames of a burst, in seconds. EXIF without sub-seconds counts whole seconds.
    public var gap: Double = 3
    /// Largest feature-print distance between neighbouring frames. Measured on the samples: the same scene a few
    /// seconds apart is 0.1–0.4, a different one 0.5 and up.
    public var distance: Double = 0.35
    public init(gap: Double = 3, distance: Double = 0.35) { self.gap = gap; self.distance = distance }
}

public enum BurstDetector {
    public struct Frame: Sendable {
        public let date: Double?
        public let camera: String
        /// Shutter time in seconds; zero when unknown.
        public let exposure: Double
        /// In millimetres; nil when unknown. A series keeps one: zooming means a new composition.
        public let focalLength: Double?
        public init(date: Double?, camera: String, exposure: Double? = nil, focalLength: Double? = nil) {
            self.date = date; self.camera = camera; self.exposure = max(exposure ?? 0, 0); self.focalLength = focalLength
        }
    }
    /// A timelapse or night-sky sequence: frames shot at a steady interval, as an intervalometer or continuous drive
    /// with long exposures gives. It has no holes: a missing frame ends it.
    public struct Series: Equatable, Sendable {
        /// Seconds from the start of one frame to the next (the mean of the steps of one interval).
        public let interval: Double
        /// Frames the small holes inside the series leave out: dropped while culling, or never imported.
        public var missingFrames = 0
    }
    public struct Group: Equatable, Sendable {
        /// Indices into the frames, in capture order.
        public let members: [Int]
        /// Set when the frames are a sequence at a steady interval rather than a quick burst.
        public let series: Series?
    }

    /// Fewest frames a steady sequence needs to count as a series instead of a burst.
    public static let seriesMinimum = 10
    /// Most frames in a row a series can miss and go on: a few frames' jump hardly shows in a timelapse, a longer
    /// hole splits it into series of their own.
    public static let seriesMostMissing = 4
    /// Most intervals a hole between two runs of a series may span for a short run to join it.
    public static let seriesMostIntervals = 10
    /// Shortest interval of a series: faster than this is a burst at the camera's frame rate.
    public static let seriesMinimumInterval = 2.0
    /// Largest feature-print distance between neighbouring frames of a series, whatever the burst similarity: the scene
    /// drifts from frame to frame (stars, light), and on the samples a series' neighbours are 0.03–0.21 apart, a new
    /// composition 0.5 and up.
    public static let seriesDistance = 0.35

    /// Runs of frames shot by one camera in quick succession that show the same thing, as indices into `frames`
    /// in capture order. `distance` compares two frames' content; nil (no feature print) links frames at most a
    /// second apart on time alone. Frames without a capture time are never in a burst. The pause between two frames
    /// leaves out the longer of their exposures, since cameras stamp either the start or the end of one: a run of
    /// 30 s night frames is a burst, not 30 s pauses.
    public static func groups(_ frames: [Frame], settings: BurstSettings, distance: (Int, Int) -> Double?) -> [[Int]] {
        detect(frames, settings: settings, distance: distance).map(\.members)
    }

    /// Series first, then bursts among the frames left over, in capture order.
    public static func detect(_ frames: [Frame], settings: BurstSettings, distance: (Int, Int) -> Double?) -> [Group] {
        let order = frames.indices.filter { frames[$0].date != nil }.sorted { (frames[$0].date!, $0) < (frames[$1].date!, $1) }
        let found = series(order, frames: frames, distance: distance)
        let inSeries = Set(found.flatMap(\.members))
        let bursts = bursts(order.filter { !inSeries.contains($0) }, frames: frames, settings: settings, distance: distance)
        let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return (found + bursts.map { Group(members: $0, series: nil) }).sorted { position[$0.members[0]]! < position[$1.members[0]]! }
    }

    private static func bursts(_ order: [Int], frames: [Frame], settings: BurstSettings, distance: (Int, Int) -> Double?) -> [[Int]] {
        var groups: [[Int]] = [], run: [Int] = []
        for index in order {
            if let last = run.last, let gap = frames[index].date.flatMap({ date in frames[last].date.map {
                   date - $0 - max(frames[index].exposure, frames[last].exposure) } }),
               frames[index].camera == frames[last].camera, gap <= settings.gap,
               distance(last, index).map({ $0 <= settings.distance }) ?? (gap <= 1) {
                run.append(index)
            } else {
                if run.count > 1 { groups.append(run) }
                run = [index]
            }
        }
        if run.count > 1 { groups.append(run) }
        return groups
    }

    /// Two neighbouring groups the person merged, as one. A series stays a series at the interval of the first, and
    /// the pause between them adds the frames it leaves out to the missing ones.
    static func joined(_ first: Group, _ second: Group, frames: [Frame]) -> Group {
        let members = first.members + second.members
        guard let interval = (first.series ?? second.series)?.interval else { return Group(members: members, series: nil) }
        var missing = (first.series?.missingFrames ?? 0) + (second.series?.missingFrames ?? 0)
        if let end = frames[first.members.last!].date, let start = frames[second.members[0]].date {
            missing += max(0, Int(((start - end) / interval).rounded()) - 1)
        }
        return Group(members: members, series: Series(interval: interval, missingFrames: missing))
    }

    /// How far a step may stray from the interval: a second, as EXIF without sub-seconds rounds to whole seconds, or a
    /// tenth of the interval for long ones.
    static func tolerance(_ interval: Double) -> Double { max(1, interval * 0.1) }

    /// Steady sequences in `order` (capture order): each frame follows the one before after one interval, from the
    /// same camera at the same focal length showing the same scene. A longer pause, frames missing, ends the series.
    /// A run too short to be a series on its own is one when it sits a few whole intervals from a series at the same
    /// interval: the rest of the timelapse, cut short by missing frames. Exposure and ISO may change, as auto ISO and
    /// day-to-night ramps change them. Without feature prints, the timing alone decides.
    static func series(_ order: [Int], frames: [Frame], distance: (Int, Int) -> Double?) -> [Group] {
        func linked(_ a: Int, _ b: Int) -> Bool {
            guard frames[a].camera == frames[b].camera else { return false }
            if let first = frames[a].focalLength, let second = frames[b].focalLength, abs(first - second) > 0.5 { return false }
            return distance(a, b).map { $0 <= seriesDistance } ?? true
        }
        func step(_ a: Int, _ b: Int) -> Double { frames[b].date! - frames[a].date! }
        // Every steady run of two frames or more, as positions in `order`, the mean of its steps of one interval and
        // the frames its small holes miss.
        var runs: [(start: Int, end: Int, interval: Double, missing: Int)] = []
        var start = 0
        while start < order.count - 1 {
            var sum = 0.0, ones = 0, missing = 0, end = start
            while end + 1 < order.count, linked(order[end], order[end + 1]) {
                let seconds = step(order[end], order[end + 1])
                if ones == 0 {
                    // The first step sets the interval; later ones of one interval refine it.
                    guard seconds >= seriesMinimumInterval else { break }
                    ones = 1; sum = seconds
                } else {
                    // The mean, not the median: with whole-second stamps (16, 17, 17, 16…) it lands on the true interval.
                    let interval = sum / Double(ones), count = Int((seconds / interval).rounded())
                    guard count >= 1, count <= seriesMostMissing + 1, abs(seconds - Double(count) * interval) <= tolerance(interval)
                    else { break }
                    if count == 1 { ones += 1; sum += seconds } else { missing += count - 1 }
                }
                end += 1
            }
            if end > start {
                // A hole at the end belongs to the gap after the run, not to it.
                let interval = sum / Double(ones)
                while end > start + 1, case let count = Int((step(order[end - 1], order[end]) / interval).rounded()), count > 1 {
                    missing -= count - 1; end -= 1
                }
                runs.append((start, end, interval, missing))
                start = end + 1
            } else {
                start += 1
            }
        }
        // The interval of the timelapse each run belongs to: its own for a long run, the long run's for a short one
        // that joins it, as a few steps stamped in whole seconds are too coarse to measure a hole against.
        var timelapse: [Double?] = runs.map { $0.end - $0.start + 1 >= seriesMinimum ? $0.interval : nil }
        /// Whether a short run continues the timelapse of an accepted neighbour, with frames missing between them.
        func continues(_ short: Int, from accepted: Int) -> Bool {
            guard let interval = timelapse[accepted], abs(runs[short].interval - interval) <= tolerance(interval) else { return false }
            let (a, b) = short < accepted ? (runs[short], runs[accepted]) : (runs[accepted], runs[short])
            guard linked(order[a.end], order[b.start]) else { return false }
            let gap = step(order[a.end], order[b.start]), count = Int((gap / interval).rounded())
            return count >= 2 && count <= seriesMostIntervals && abs(gap - Double(count) * interval) <= tolerance(interval)
        }
        // Spread from the series to the short runs beside them, so a few short runs in a row all join.
        var changed = true
        while changed {
            changed = false
            for index in runs.indices where timelapse[index] == nil {
                if let neighbour = [index - 1, index + 1].first(where: { runs.indices.contains($0) && continues(index, from: $0) }) {
                    timelapse[index] = timelapse[neighbour]; changed = true
                }
            }
        }
        // Runs of one timelapse with a small hole between them are one series.
        var found: [Group] = []
        var last: (run: Int, missing: Int)?
        for index in runs.indices {
            guard let interval = timelapse[index] else { last = nil; continue }
            let members = Array(order[runs[index].start...runs[index].end])
            if let previous = last, previous.run == index - 1, timelapse[previous.run] != nil, linked(order[runs[previous.run].end], members[0]),
               case let gap = step(order[runs[previous.run].end], members[0]), case let count = Int((gap / interval).rounded()),
               count <= seriesMostMissing + 1, abs(gap - Double(count) * interval) <= tolerance(interval) {
                let missing = previous.missing + count - 1 + runs[index].missing
                let merged = found.removeLast()
                found.append(Group(members: merged.members + members, series: Series(interval: merged.series!.interval, missingFrames: missing)))
                last = (index, missing)
            } else {
                found.append(Group(members: members, series: Series(interval: interval, missingFrames: runs[index].missing)))
                last = (index, runs[index].missing)
            }
        }
        return found
    }
}

/// The assistant's proposal for a set of photos: what it found wrong with each, which frames form bursts and which
/// one of each it would keep, and the flag it suggests. It never deletes anything or touches ratings.
public struct CullingPlan: Sendable {
    public struct Photo: Sendable {
        public let id: String
        /// The flag the photo has now.
        public let review: ReviewState
        public let report: PhotoQualityReport?
        public let featurePrint: Data?
        /// Shutter time in seconds, from the catalog.
        public let exposureTime: Double?
        /// In millimetres, from the catalog.
        public let focalLength: Double?
        /// From the catalog, to tell a night photo from an underexposed one.
        public let exposure: ExposureSettings?
        public init(id: String, review: ReviewState, report: PhotoQualityReport?, featurePrint: Data?, exposureTime: Double? = nil, focalLength: Double? = nil,
                    exposure: ExposureSettings? = nil) {
            self.id = id; self.review = review; self.report = report; self.featurePrint = featurePrint; self.exposureTime = exposureTime
            self.focalLength = focalLength; self.exposure = exposure
        }
    }
    public struct Options: Equatable, Codable, Sendable {
        public var sensitivity = CullingSensitivity.balanced
        public var burst = BurstSettings()
        public init() {}
    }
    public struct Burst: Identifiable, Sendable {
        public var id: String { members[0] }
        /// In capture order.
        public let members: [String]
        /// The frame the assistant would keep.
        public let best: String
        /// Each frame's standing in the burst, 0 to 1; the best has the highest.
        public let scores: [String: Double]
        /// Set when the frames are a timelapse or night-sky sequence at a steady interval, not a quick burst.
        public var series: BurstDetector.Series? = nil
    }
    /// Quality problems per photo, plus `burstAlternate` or `duplicate` for the frames of a burst that are not kept.
    public var issues: [String: [CullingIssue]] = [:]
    public var bursts: [Burst] = []
    /// The flag the assistant suggests for each photo; `unreviewed` leaves an unflagged photo as it is.
    public var proposals: [String: ReviewState] = [:]

    /// `oneBurst` takes the photos, in the order given, as a single burst, as for a group the person made, instead of
    /// finding bursts by time and content; its best frame is picked even when it has problems.
    /// `joins` are the first frames of groups the person merged into the group before them, kept by frame as the groups
    /// are found again whenever the options change; a join whose frame no longer starts a group does nothing.
    public init(_ photos: [Photo], options: Options, oneBurst: Bool = false, joins: Set<String> = []) {
        for photo in photos { issues[photo.id] = photo.report?.issues(options.sensitivity, exposure: photo.exposure) ?? [] }
        let prints = photos.map { $0.featurePrint.flatMap(PhotoQualityAnalyzer.featurePrint) }
        func distance(_ a: Int, _ b: Int) -> Double? {
            guard let first = prints[a], let second = prints[b] else { return nil }
            var distance: Float = 0
            return (try? first.computeDistance(&distance, to: second)).map { Double(distance) }
        }
        let groups: [BurstDetector.Group]
        if oneBurst {
            groups = photos.count > 1 ? [BurstDetector.Group(members: Array(photos.indices), series: nil)] : []
        } else {
            let frames = photos.map {
                BurstDetector.Frame(date: $0.report?.captureDate, camera: $0.report?.camera ?? "", exposure: $0.exposureTime, focalLength: $0.focalLength)
            }
            let found = BurstDetector.detect(frames, settings: options.burst, distance: distance)
            var merged: [BurstDetector.Group] = []
            for group in found {
                if joins.contains(photos[group.members[0]].id), let previous = merged.last {
                    merged[merged.count - 1] = BurstDetector.joined(previous, group, frames: frames)
                } else {
                    merged.append(group)
                }
            }
            groups = merged
        }
        var inBurst: Set<String> = []
        // A copy, or another frame of the same moment: taken at the same time to the fraction of a second the camera
        // records, with nearly the same print.
        func duplicate(_ a: Int, _ b: Int) -> Bool {
            guard let date = photos[a].report?.captureDate, date == photos[b].report?.captureDate, let d = distance(a, b) else { return false }
            return d <= Self.duplicateDistance
        }
        for group in groups {
            let members = group.members.map { photos[$0] }
            let scores = Self.scores(members.map(\.report), sensitivity: options.sensitivity, exposures: members.map(\.exposure))
            let best = scores.indices.max { (scores[$0], -$0) < (scores[$1], -$1) } ?? 0
            let burst = Burst(members: members.map(\.id), best: members[best].id, scores: Dictionary(uniqueKeysWithValues: zip(members.map(\.id), scores)),
                              series: group.series)
            bursts.append(burst)
            // The person already chose a frame: the assistant's pick gives way, and the rest are alternates to it.
            let chosen = members.contains { $0.review == .accepted }
            for (index, member) in members.enumerated() {
                inBurst.insert(member.id)
                let alternate = chosen ? member.review != .accepted : index != best
                // A group the person made is there to keep one photo from, even when every frame has a problem.
                proposals[member.id] = !alternate && (oneBurst || issues[member.id, default: []].isEmpty) ? .accepted : .rejected
                if alternate {
                    let copy = group.members.contains { $0 != group.members[index] && duplicate($0, group.members[index]) }
                    issues[member.id, default: []].append(copy ? .duplicate : .burstAlternate)
                }
            }
        }
        for photo in photos {
            if !inBurst.contains(photo.id) {
                proposals[photo.id] = !issues[photo.id, default: []].isEmpty ? .rejected : .unreviewed
            }
            // Photos the person already picked or rejected keep their flag.
            if photo.review != .unreviewed { proposals[photo.id] = photo.review }
        }
    }

    /// Largest print distance between two frames of the same moment that count as duplicates. Measured on a night
    /// group: a copy saved again as JPEG 0.09, the next frame of a moving burst 0.21.
    public static let duplicateDistance = 0.15

    /// Ranks the frames of one burst against each other: the subject's focus counts most, then the faces (Vision's
    /// capture quality, closed eyes), then Vision's aesthetics, with the frame's own problems held against it.
    static func scores(_ reports: [PhotoQualityReport?], sensitivity: CullingSensitivity, exposures: [ExposureSettings?] = []) -> [Double] {
        let focus = reports.map { $0.flatMap { $0.subjectSharpness ?? $0.sharpness } ?? 0 }
        let sharpest = max(focus.max() ?? 0, 0.001)
        let faces = reports.map { report -> Double? in
            let judged = (report?.faces ?? []).filter { $0.bounds.width >= PhotoQualityReport.Face.judgedWidth }.compactMap(\.quality)
            return judged.isEmpty ? nil : judged.reduce(0, +) / Double(judged.count)
        }
        let hasFaces = faces.contains { $0 != nil }
        return reports.indices.map { index in
            guard let report = reports[index] else { return 0 }
            let aesthetics = ((report.aesthetics ?? 0) + 1) / 2
            var score = hasFaces ? 0.5 * focus[index] / sharpest + 0.25 * (faces[index] ?? 0) + 0.25 * aesthetics
                : 0.65 * focus[index] / sharpest + 0.35 * aesthetics
            let issues = report.issues(sensitivity, exposure: exposures.indices.contains(index) ? exposures[index] : nil)
            if issues.contains(.eyesClosed) { score -= 0.3 }
            if issues.contains(.blurry) || issues.contains(.outOfFocus) { score -= 0.3 }
            if issues.contains(.overexposed) || issues.contains(.underexposed) { score -= 0.2 }
            return max(0, min(1, score))
        }
    }
}
