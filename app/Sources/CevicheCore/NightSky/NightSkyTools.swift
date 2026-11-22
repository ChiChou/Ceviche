import Foundation
import CoreGraphics
import simd

/// One dab of a brush over the preview: its center in fractions of the photo's width and height, its radius in fractions
/// of the width. A dab correcting the sky adds sky where `sky` is true and takes it away where false.
public struct NightSkyStroke: Codable, Equatable, Sendable {
    public var x: Double, y: Double, radius: Double
    public var sky: Bool?
    public init(x: Double, y: Double, radius: Double, sky: Bool? = nil) { self.x = x; self.y = y; self.radius = radius; self.sky = sky }
}

/// Why a photo is suggested for leaving out.
public enum NightSkyFrameNote: Sendable, Equatable {
    /// Its stars couldn't be matched to the reference, so its sky can't be aligned.
    case unaligned(String)
    /// Far fewer stars than the other photos: cloud, haze, dew or a bump.
    case fewStars
    /// A much brighter sky than the other photos: moonrise, dawn, a passing light.
    case brightSky
    /// Stars larger than in the other photos: the camera moved during the exposure, or focus drifted.
    case blurred

    public var text: String {
        switch self {
        case .unaligned(let reason): L10n.tr("Couldn’t align: \(reason)")
        case .fewStars: L10n.tr("Few stars: cloud, haze or dew")
        case .brightSky: L10n.tr("Brighter sky than the other photos")
        case .blurred: L10n.tr("Blurred stars: the camera may have moved")
        }
    }
}

/// How a photo stands out from the rest of the series, as the timelapse's check finds it. Unlike a note, it doesn't
/// leave the photo out: pauses and settings are often intended.
public enum NightSkySeriesMark: Sendable, Equatable {
    /// The first photo after a pause longer than the usual interval.
    case pause(Double)
    /// In a run shot faster than the usual interval, as before the intervalometer was set.
    case faster
    /// Taken at the same moment as the photo before it.
    case sameTime
    case missingTime
    /// A shutter time other than most of the series': each exposure draws a longer or shorter piece of trail, so the
    /// trails' pace changes.
    case otherExposure(String, usual: String)
    /// Aperture or focal length other than most of the series'. ISO only scales brightness, so it doesn't count.
    case otherSettings(String)

    public var text: String {
        switch self {
        case .pause(let seconds): L10n.tr("After a \(NightSkySeriesMark.duration(seconds)) pause")
        case .faster: L10n.tr("Shot faster than the rest")
        case .sameTime: L10n.tr("Same time as the photo before")
        case .missingTime: L10n.tr("No capture time")
        case .otherExposure(let own, let usual): L10n.tr("Exposure time \(own), not \(usual)")
        case .otherSettings(let settings): L10n.tr("Other settings: \(settings)")
        }
    }
    static func duration(_ seconds: Double) -> String {
        Duration.seconds(seconds.rounded()).localized(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
    }
}

/// What analysis found about one photo of a night sequence.
public struct NightSkyFrameInfo: Sendable, Identifiable {
    public var id: Int { index }
    /// Position in capture order.
    public let index: Int
    public let filename: String
    /// Seconds from the first photo's start, when capture times are recorded.
    public let time: Double?
    public let starCount: Int
    /// 95th percentile error of withheld stars after alignment, in full-size pixels; nil when not aligned or not needed.
    public let alignmentError: Double?
    public let note: NightSkyFrameNote?
    public let series: [NightSkySeriesMark]
    /// A small picture of the photo as shot, brightened like the preview.
    public let thumbnail: CGImage?
    public var isAligned: Bool { alignmentError != nil }
}

/// A line found in one photo: a meteor, or an aircraft or satellite when it continues across photos.
public struct NightSkyLineInfo: Sendable, Identifiable {
    public let id: Int
    public let frame: Int
    /// In full-size pixels.
    public let length: Double
    public let kind: NightSkyLineKind
    /// The aircraft or satellite a track belongs to, shared by its pieces across photos; nil for other lines.
    public let group: Int?
    /// A close-up of the line in its photo.
    public let thumbnail: CGImage?
}

/// A tool's choice of which lines go into its result: those chosen or turned down by hand, by line id, and the rest by
/// what detection took them for.
public protocol NightSkyLineChoosing {
    /// Lines chosen or turned down by hand, by line id.
    var choices: [Int: Bool] { get set }
    /// Whether a line detection took for `kind` goes into the result unless chosen otherwise.
    static func includesByDefault(_ kind: NightSkyLineKind) -> Bool
}

extension NightSkyLineChoosing {
    public func includes(_ line: NightSkyLineInfo) -> Bool { includes(line.id, kind: line.kind) }
    public func includes(_ id: Int, kind: NightSkyLineKind) -> Bool { choices[id] ?? Self.includesByDefault(kind) }
    /// Keeps the hand choices after analyzing again only when the same lines were found, as ids count them in order;
    /// otherwise an id could name a different line, so detection decides again.
    public mutating func keepChoices(from old: [NightSkyLineInfo], to new: [NightSkyLineInfo]) {
        if !Self.sameLines(old, new) { choices = [:] }
    }
    /// Whether analyzing again would turn the hand choices down: there are some, and other lines were found.
    public func losesChoices(from old: [NightSkyLineInfo], to new: [NightSkyLineInfo]) -> Bool {
        !choices.isEmpty && !Self.sameLines(old, new)
    }
    static func sameLines(_ old: [NightSkyLineInfo], _ new: [NightSkyLineInfo]) -> Bool {
        old.count == new.count && zip(old, new).allSatisfy { $0.frame == $1.frame && $0.kind == $1.kind && abs($0.length - $1.length) < 2 }
    }
}

/// The timing of a sequence, from capture times.
public struct NightSkyTiming: Sendable {
    /// From the first photo's start to the last one's end, in seconds.
    public let span: Double
    /// The usual time from one photo's start to the next one's.
    public let interval: Double
    /// Pauses longer than twice the usual interval.
    public let gaps: Int

    init?(_ metadata: [NightSkyFrameMetadata]) {
        let times = metadata.compactMap(\.time)
        guard times.count == metadata.count, times.count >= 2 else { return nil }
        let steps = zip(times.dropFirst(), times).map { $0 - $1 }.sorted()
        let usual = steps[steps.count / 2]
        interval = usual
        gaps = steps.filter { $0 > 2 * usual + 1 }.count
        span = times.last! - times.first! + (metadata.last!.exposure ?? 0)
    }
}

/// A picture of a tool's result at preview size, brightened for viewing; the merged file keeps the linear values.
public struct NightSkyPreview: @unchecked Sendable {
    /// Brightened for viewing; the app replaces it with the preview developed like the result.
    public var image: CGImage
    /// Lines over the preview as start and end points in fractions of its width and height, for drawing outlines.
    public let lines: [(id: Int, start: CGPoint, end: CGPoint)]
    /// Grayscale, white where the tool treats the scene as sky.
    public let sky: CGImage?
    /// The photo the result is based on, whose edits it takes.
    public let base: Int
    /// The linear values `image` was drawn from, interleaved RGB, and what the result's DNG says of the photos.
    let values: [Float]
    /// The photo the result is based on, whose camera the DNG names.
    let baseURL: URL
    let width: Int, height: Int
    let metadata: PanoramaFrameMetadata

    private var writer: ToolResultWriter {
        ToolResultWriter(dng: PanoramaDNGWriter(metadata: metadata, kind: .nightSky, source: .merge(baseURL, process: PanoramaDNGWriter.Kind.nightSky.rawValue)), source: baseURL)
    }
    /// The extension the preview's file needs: DNG for RAW photos, TIFF for processed ones.
    public var fileExtension: String { writer.previewExtension }
    /// Writes the preview as the result's file at preview size, so it develops with the same edits and tone response.
    /// `url`'s extension is `fileExtension`.
    public func write(to url: URL) throws {
        var rgba = [Float](repeating: 1, count: width * height * 4)
        for p in 0..<width * height { for c in 0..<3 { rgba[4 * p + c] = values[3 * p + c] } }
        try writer.write(PanoramaRaster(width: width, height: height, rgba: rgba), to: url)
    }
}

extension NightSkyAnalyzer {
    /// Per photo, with suggestions to leave out photos whose sky is much worse than the rest.
    func frameInfos() -> [NightSkyFrameInfo] {
        let countMedian = NightSkyStars.median(starCounts.map(Double.init))
        let backgroundMedian = NightSkyStars.median(backgrounds.map(Double.init))
        // Twilight and moonrise brighten the sky gradually, so a photo also counts as brighter when it stands well above
        // the sequence's usual spread, not only when it is several times the median.
        let backgroundSpread = 1.4826 * NightSkyStars.median(backgrounds.map { abs(Double($0) - backgroundMedian) })
        let radiusMedian = NightSkyStars.median(starRadii)
        let start = metadata.compactMap(\.time).min()
        let series = Self.seriesMarks(metadata)
        return metadata.indices.map { i in
            var note: NightSkyFrameNote?
            if space == .sky, alignments[i] == nil { note = .unaligned(failures[i] ?? L10n.tr("no matching stars")) }
            else if countMedian >= 40, Double(starCounts[i]) < 0.35 * countMedian { note = .fewStars }
            else if backgroundMedian > 0, Double(backgrounds[i]) > 2.5 * backgroundMedian
                        || Double(backgrounds[i]) > max(1.5 * backgroundMedian, backgroundMedian + 6 * backgroundSpread) { note = .brightSky }
            else if radiusMedian > 0, starRadii[i] > 1.25 * radiusMedian { note = .blurred }
            return NightSkyFrameInfo(index: i, filename: metadata[i].filename, time: start.flatMap { s in metadata[i].time.map { $0 - s } },
                                     starCount: starCounts[i], alignmentError: space == .sky ? alignments[i].map { $0.heldOutP95 * scale } : nil,
                                     note: note, series: series[i], thumbnail: thumbnails[i])
        }
    }

    /// Per photo, what the timelapse's series check finds, and exposure settings other than most of the series'.
    static func seriesMarks(_ metadata: [NightSkyFrameMetadata]) -> [[NightSkySeriesMark]] {
        // Another camera is refused when the photos are opened, so only times are compared here.
        let captures = metadata.map { TimelapseCapture(filename: $0.filename, date: $0.time.map { Date(timeIntervalSinceReferenceDate: $0) }) }
        let found = TimelapseSeries(captures)
        var marks = [[NightSkySeriesMark]](repeating: [], count: metadata.count)
        for (position, index) in found.order.enumerated() {
            marks[index] = found.marks[position].compactMap { mark in
                switch mark {
                case .afterGap(let seconds, _): .pause(seconds)
                case .faster: .faster
                case .sameTime: .sameTime
                case .missingTime: .missingTime
                case .otherCamera, .otherSize: nil // Opening refuses other cameras and sizes.
                }
            }
        }
        // Against what most photos share; among equally common values, the first to appear.
        func usual(_ values: [String?]) -> String? {
            let present = values.compactMap { $0 }, counts = present.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
            return present.reduce(nil as String?) { best, value in best.map { counts[value]! > counts[$0]! ? value : $0 } ?? value }
        }
        let exposures = metadata.map { $0.exposure.flatMap { $0 > 0 ? Self.exposureText($0) : nil } }, optics = metadata.map(optics)
        let usualExposure = usual(exposures), usualOptics = usual(optics)
        for i in metadata.indices {
            if let own = exposures[i], let usualExposure, own != usualExposure { marks[i].append(.otherExposure(own, usual: usualExposure)) }
            if let own = optics[i], own != usualOptics { marks[i].append(.otherSettings(own)) }
        }
        return marks
    }

    static func exposureText(_ t: Double) -> String {
        t >= 1 ? "\(t.formatted(.number.precision(.fractionLength(0...1)))) s" : "1/\(Int((1 / t).rounded())) s"
    }
    /// Aperture and focal length as the camera recorded them; nil when it recorded neither.
    static func optics(_ m: NightSkyFrameMetadata) -> String? {
        var parts: [String] = []
        if let f = m.fNumber, f > 0 { parts.append("f/\(f.formatted(.number.precision(.fractionLength(0...1))))") }
        if let focal = m.focalLength35mm, focal > 0 { parts.append("\(Int(focal.rounded())) mm") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    func lineInfos() -> [NightSkyLineInfo] {
        lines.enumerated().map { k, line in
            NightSkyLineInfo(id: k, frame: line.frame, length: line.length * scale, kind: line.kind, group: line.group, thumbnail: try? linePicture(line, size: 120))
        }
    }

    func picture(_ rgb: [Float], lines: [(Int, NightSkyLine)], base: Int, asCaptured: Bool = false) throws -> NightSkyPreview {
        guard let image = NightSkyFinishing.picture(rgb, channels: 3, width: previewWidth, height: previewHeight, exposure: displayExposure) else {
            throw PanoramaError.message(L10n.tr("The preview could not be drawn."))
        }
        let w = Double(analysisWidth), h = Double(analysisHeight)
        let outlines = lines.map { id, line -> (id: Int, start: CGPoint, end: CGPoint) in
            func place(_ p: SIMD2<Double>) -> SIMD2<Double> {
                guard space == .sky else { return p }
                if asCaptured { return line.frame == anchor ? p : alignments[line.frame]?.sourcePoint(p) ?? p }
                return pointOnBase(p, base: base)
            }
            let a = place(line.start), b = place(line.end)
            return (id, CGPoint(x: (a.x + 0.5) / w, y: (a.y + 0.5) / h), CGPoint(x: (b.x + 0.5) / w, y: (b.y + 0.5) / h))
        }
        return NightSkyPreview(image: image, lines: outlines, sky: HDRMergeFinishing.mask(previewProbability, width: previewWidth, height: previewHeight),
                               base: base, values: rgb, baseURL: urls[base], width: previewWidth, height: previewHeight, metadata: metadata[base].base.panorama)
    }

    /// Renders the plan at full size and writes it to `url`: a linear DNG named after the tool for RAW photos, else as
    /// `url`'s extension names.
    func write(_ plan: Plan, kind: PanoramaDNGWriter.Kind, to url: URL, progress: @escaping @Sendable (Double, String) -> Void) throws {
        let raster = try render(plan, engine: .gpu, progress: { progress(0.85 * $0, $1) })
        if Task.isCancelled { throw CancellationError() }
        var base = metadata[plan.base].base.panorama
        base.captureTime = PanoramaFrameMetadata.captureTime(after: metadata.map(\.base.captureTime)) ?? base.captureTime
        let writer = ToolResultWriter(dng: PanoramaDNGWriter(metadata: base, kind: kind,
                                                             preview: raster.rgba.withUnsafeBufferPointer { NightSkyFinishing.picture($0, channels: 4, width: raster.width, height: raster.height, exposure: displayExposure, maxDimension: 1024) },
                                                             source: .merge(urls[plan.base], process: kind.rawValue)), source: urls[plan.base])
        let size = "\(raster.width.formatted()) × \(raster.height.formatted())", format = url.pathExtension.uppercased()
        try writer.write(raster, to: url, progress: { progress(0.85 + 0.15 * $0, L10n.tr("Writing \(size) \(format)")) }, cancelled: { Task.isCancelled })
        progress(1, L10n.tr("Saved"))
    }

    /// The default reference: the aligned photo nearest the middle that isn't suggested for leaving out, so a bumped or
    /// clouded photo never sets the framing and moment by default.
    var defaultReference: Int {
        let notes = frameInfos().map(\.note)
        return metadata.indices.filter { alignments[$0] != nil && notes[$0] == nil }.min { abs($0 - anchor) < abs($1 - anchor) } ?? anchor
    }

    func requireAnalysis() throws {
        guard !gains.isEmpty, !thumbnails.isEmpty else { throw PanoramaError.message(L10n.tr("Analyze the photos first.")) }
    }
}

// MARK: Star Trails

public struct StarTrailsSettings: Codable, Equatable, Sendable {
    /// Areas painted to come from one photo alone (the reference, the base, or the sky photo): something that moved, or
    /// a skyline the boundary gets wrong.
    public var photoRegions: [NightSkyStroke] = []
    /// Full-size pixels to move the sky's boundary by: out into the ground when positive, in toward the sky when negative.
    public var skyEdge = 0
    /// Everything counts as sky, for a photo without ground or a sky the finder gets wrong.
    public var allSky = false
    /// Painted corrections to the sky, in order: dabs that add sky and dabs that take it away.
    public var skyStrokes: [NightSkyStroke] = []
    /// Photos left out, by capture-order index.
    public var excluded: Set<Int> = []
    /// Keeps each trail's color from the photo where it was brightest, instead of each channel's brightest value.
    public var keepStarColors = false
    /// Lines kept or left out by hand, by line id; the rest follow the default (lines that continue across photos, as
    /// aircraft and satellites do, left out; meteors and the rest kept).
    public var choices: [Int: Bool] = [:]
    /// Draws the stars' motion through the pauses between exposures. Drawn, not captured light; off by default.
    public var fillGaps = false
    /// The sky behind the trails: every photo's brightest (the literal maximum), or one photo's sky with the trails over it.
    public var sky = StarTrailsSky.brightest
    /// The photo whose sky the trails are drawn over; nil for the middle one.
    public var skyPhoto: Int?
    public init() {}
}

extension StarTrailsSettings: NightSkyLineChoosing {
    /// A shaken photo's lines are its own smeared stars, part of the trails; only aircraft and satellites are left out.
    public static func includesByDefault(_ kind: NightSkyLineKind) -> Bool { kind != .track }
}

public enum StarTrailsSky: String, Codable, CaseIterable, Sendable, Identifiable {
    /// The literal maximum: changing aurora and glow accumulate with the stars.
    case brightest
    /// One photo's sky (an aurora at its best, a sky before dawn), with each photo's stars above their local background.
    case onePhoto
    public var id: String { rawValue }
    public var title: String { self == .brightest ? L10n.tr("Brightest") : L10n.tr("One Photo") }
}

/// How Star Trails' video draws the trails.
public enum StarTrailsVideoTrails: String, Codable, CaseIterable, Sendable, Identifiable {
    /// As the exposures recorded them: each pause between photos stays a gap unless Fill Gaps draws it.
    case dashed
    /// Every pause drawn in, with a slight glow around the stars and trails.
    case smooth
    public var id: String { rawValue }
    public var title: String { self == .dashed ? L10n.tr("Dashed") : L10n.tr("Smooth") }
}

/// How long a kept meteor stays in Star Trails' video, instead of staying to the end as in the still: `hold` frames at
/// full strength from its photo, then out over `fade` frames (none: gone at once).
public struct StarTrailsMeteorFade: Codable, Equatable, Sendable {
    public var hold: Int
    public var fade: Int
    public init(hold: Int, fade: Int) { self.hold = max(1, hold); self.fade = max(0, fade) }
    /// Frames from the meteor's photo until it is gone.
    public var length: Int { hold + fade }
    /// The meteor's strength `age` frames after its photo: 1 while it holds, then falling to 0. The frames are linear
    /// light, where an even ramp looks to hang on and then drop; easing out as the display's gamma undoes it fades evenly.
    public func strength(age: Int) -> Float {
        guard age >= 0 else { return 0 }
        guard age >= hold else { return 1 }
        let step = age - hold + 1
        guard step <= fade else { return 0 }
        return pow(1 - Float(step) / Float(fade + 1), 2.2)
    }
}

/// How strongly Smooth trails glow: how much of the stars' blurred light is added back.
public enum StarTrailsVideoGlow: String, Codable, CaseIterable, Sendable, Identifiable {
    case light, medium, strong
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .light: return L10n.tr("Light", context: "glow")
        case .medium: return L10n.tr("Medium", context: "glow")
        case .strong: return L10n.tr("Strong", context: "glow")
        }
    }
    var strength: Float {
        switch self {
        case .light: return 0.75
        case .medium: return 1.5
        case .strong: return 3
        }
    }
}

public struct StarTrailsAnalysis: Sendable {
    public let frames: [NightSkyFrameInfo]
    public let lines: [NightSkyLineInfo]
    public let timing: NightSkyTiming?
    public let width: Int, height: Int
    public let skyModelInstalled: Bool
    /// Photos suggested for leaving out.
    public var suggestedExclusions: Set<Int> { Set(frames.filter { $0.note != nil }.map(\.index)) }
}

/// Star trails: every photo's light kept where it was brightest, in the camera's own frame, so the stars' movement draws
/// trails while the ground is averaged for low noise. The literal per-channel maximum is the default; Keep Star Colors
/// takes each pixel's color whole from the photo where it was brightest instead. Gaps between exposures stay gaps.
public final class StarTrailsMerger: @unchecked Sendable {
    private let analyzer: NightSkyAnalyzer
    public private(set) var analysis: StarTrailsAnalysis?
    public var urls: [URL] { analyzer.urls }

    public init(urls: [URL]) throws { analyzer = try NightSkyAnalyzer(urls: urls, space: .camera) }

    /// Analyzes with everything as sky or the sky corrected by `skyStrokes`, for finding and aligning stars; analyzing
    /// again with other corrections reuses the sky found the first time.
    public func analyze(allSky: Bool = false, skyStrokes: [NightSkyStroke] = [], progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) throws -> StarTrailsAnalysis {
        analyzer.skyCorrection = NightSkyAnalyzer.SkyShape(everything: allSky, strokes: skyStrokes.filter { $0.sky != nil })
        try analyzer.analyze(progress: progress)
        return restoredAnalysis()
    }

    public func saveAnalysis(to directory: URL) throws { try analyzer.saveAnalysis(to: directory) }
    public func restoreAnalysis(from directory: URL, progress: @escaping @Sendable (Double, String) -> Void) throws -> StarTrailsAnalysis {
        try analyzer.restoreAnalysis(from: directory, progress: progress)
        return restoredAnalysis()
    }
    /// What analysis found, to take back with `reuse` after analyzing again.
    public func analysisSnapshot() throws -> Data { try analyzer.encodedResults() }
    public func reuse(_ snapshot: Data) throws -> StarTrailsAnalysis {
        try analyzer.reuse(snapshot)
        return restoredAnalysis()
    }
    private func restoredAnalysis() -> StarTrailsAnalysis {
        let result = StarTrailsAnalysis(frames: analyzer.frameInfos(), lines: analyzer.lineInfos(), timing: NightSkyTiming(analyzer.metadata),
                                        width: analyzer.width, height: analyzer.height, skyModelInstalled: analyzer.skyModelInstalled)
        analysis = result
        return result
    }

    func plan(_ settings: StarTrailsSettings) throws -> NightSkyAnalyzer.Plan {
        try analyzer.requireAnalysis()
        let included = Set(analyzer.urls.indices).subtracting(settings.excluded)
        guard included.count >= 2 else { throw PanoramaError.message(L10n.tr("Include at least two photos.")) }
        var plan = NightSkyAnalyzer.Plan(base: analyzer.anchor, ground: included, peak: included, peakMode: settings.keepStarColors ? .color : .channels)
        plan.skyShape = NightSkyAnalyzer.SkyShape(edge: settings.skyEdge, everything: settings.allSky, strokes: settings.skyStrokes)
        if settings.sky == .onePhoto { plan.peakOverPhoto = settings.skyPhoto.flatMap { included.contains($0) ? $0 : nil } ?? included.sorted()[included.count / 2] }
        plan.regions = settings.photoRegions
        plan.regionPhoto = plan.peakOverPhoto ?? included.sorted()[included.count / 2]
        for (id, line) in analyzer.lines.enumerated() where !settings.includes(id, kind: line.kind) {
            plan.peakExclusions[line.frame, default: []].append(line)
        }
        if settings.fillGaps {
            let order = included.sorted()
            for (i, j) in zip(order, order.dropFirst()) {
                let steps = analyzer.gapSteps(from: i, to: j)
                if !steps.isEmpty { plan.gapFill[i] = (j, steps) }
            }
        }
        return plan
    }

    /// How many pauses between included photos Fill Gaps draws, for the record of what was drawn rather than captured.
    public func filledGaps(_ settings: StarTrailsSettings) -> Int {
        var drawn = settings; drawn.fillGaps = true
        return (try? plan(drawn).gapFill.count) ?? 0
    }

    public func preview(_ settings: StarTrailsSettings) throws -> NightSkyPreview {
        let plan = try plan(settings)
        let shown = analyzer.lines.enumerated().filter { !settings.excluded.contains($0.element.frame) }.map { ($0.offset, $0.element) }
        return try analyzer.picture(try analyzer.preview(plan), lines: shown, base: plan.base)
    }
    func previewValues(_ settings: StarTrailsSettings) throws -> [Float] { try analyzer.preview(plan(settings)) }

    public func merge(_ settings: StarTrailsSettings, to url: URL, progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) throws {
        try analyzer.write(plan(settings), kind: .starTrails, to: url, progress: progress)
    }
    func render(_ settings: StarTrailsSettings, engine: NightSkyAnalyzer.Engine) throws -> PanoramaRaster {
        try analyzer.render(plan(settings), engine: engine, progress: { _, _ in })
    }
    /// One movie frame per included photo, building to the complete stack, as a file that is removed once `frame`
    /// returns, no longer on its long edge than `longEdge`, the last no longer than `lastLongEdge` when given. Frames
    /// `wanted` turns down are stacked but not written.
    public func animation(_ settings: StarTrailsSettings, trails: StarTrailsVideoTrails = .dashed, glow: StarTrailsVideoGlow = .medium, meteorFade: StarTrailsMeteorFade? = nil,
                          longEdge: Int? = nil, lastLongEdge: Int? = nil, frames wanted: @escaping @Sendable (Int) -> Bool = { _ in true },
                          progress: @escaping @Sendable (String) -> Void = { _ in }, frame: @escaping @Sendable (Int, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try plan(settings).base
        let metadata = analyzer.metadata[base].base.panorama, source = DNGSourceMetadata.merge(analyzer.urls[base], process: PanoramaDNGWriter.Kind.starTrails.rawValue)
        // A DNG for RAW photos, a TIFF for processed ones.
        let writer = ToolResultWriter(dng: PanoramaDNGWriter(metadata: metadata, kind: .starTrails, source: source), source: analyzer.urls[base])
        try await animationFrames(settings, trails: trails, glow: glow, meteorFade: meteorFade, longEdge: longEdge, lastLongEdge: lastLongEdge,
                                  frames: wanted, progress: progress) { index, raster in
            let url = directory.appendingPathComponent("\(index).\(writer.previewExtension)")
            defer { try? FileManager.default.removeItem(at: url) }
            try writer.write(raster, to: url, cancelled: { Task.isCancelled })
            try await frame(index, url)
        }
    }
    /// The animation's frames as linear rasters. Smooth draws in every pause, whatever Fill Gaps says, and glows by `glow`.
    /// With `meteorFade`, the meteors kept fade out of the frames after their own instead of staying.
    /// `progress` names each photo developed for the ground, which comes before the first frame.
    func animationFrames(_ settings: StarTrailsSettings, trails: StarTrailsVideoTrails, glow: StarTrailsVideoGlow = .medium, meteorFade: StarTrailsMeteorFade? = nil,
                         longEdge: Int? = nil, lastLongEdge: Int? = nil, frames wanted: (Int) -> Bool = { _ in true },
                         progress: (String) -> Void = { _ in }, frame: (Int, PanoramaRaster) async throws -> Void) async throws {
        var settings = settings
        if trails == .smooth { settings.fillGaps = true }
        var plan = try plan(settings)
        var fading: [NightSkyLine] = []
        if meteorFade != nil {
            fading = analyzer.lines.enumerated().filter { id, line in
                line.kind == .meteor && settings.includes(id, kind: line.kind) && !settings.excluded.contains(line.frame)
            }.map(\.element)
            // Out of the brightest-of stack, where they would stay; each frame adds them back as they fade.
            for line in fading { plan.peakExclusions[line.frame, default: []].append(line) }
        }
        try await analyzer.trailAnimation(plan, glow: trails == .smooth ? glow.strength : nil, fading: meteorFade.map { (fading, $0) },
                                          longEdge: longEdge, lastLongEdge: lastLongEdge, frames: wanted, progress: progress, frame: frame)
    }

    var internalAnalyzer: NightSkyAnalyzer { analyzer }
}

// MARK: Night Sky Denoise

public enum NightSkyGround: String, Codable, CaseIterable, Sendable, Identifiable {
    /// The mean of the included photos, for low noise when nothing on the ground moved.
    case average
    /// The reference photo alone, for a ground with moving things such as people or cars.
    case reference
    public var id: String { rawValue }
    public var title: String { self == .average ? L10n.tr("Average") : L10n.tr("Base Photo") }
}

public struct NightSkyDenoiseSettings: Codable, Equatable, Sendable {
    /// Areas painted to come from one photo alone (the reference, the base, or the sky photo): something that moved, or
    /// a skyline the boundary gets wrong.
    public var photoRegions: [NightSkyStroke] = []
    /// Full-size pixels to move the sky's boundary by: out into the ground when positive, in toward the sky when negative.
    public var skyEdge = 0
    /// Everything counts as sky, for a photo without ground or a sky the finder gets wrong.
    public var allSky = false
    /// Painted corrections to the sky, in order: dabs that add sky and dabs that take it away.
    public var skyStrokes: [NightSkyStroke] = []
    public var excluded: Set<Int> = []
    /// The photo whose framing and moment the stars are aligned to; nil for the middle one.
    public var reference: Int?
    public var ground = NightSkyGround.average
    /// Averages the sky a second time without samples far from the other photos at that pixel: satellites and planes
    /// too faint to be found as lines, hot pixels, passing lights. Off by default; the plain mean is the baseline.
    public var rejectOutliers = false
    public init() {}
}

public struct NightSkyDenoiseAnalysis: Sendable {
    public let frames: [NightSkyFrameInfo]
    public let lines: [NightSkyLineInfo]
    public let timing: NightSkyTiming?
    public let suggestedReference: Int
    public let width: Int, height: Int
    public let skyModelInstalled: Bool
    public var suggestedExclusions: Set<Int> { Set(frames.filter { $0.note != nil }.map(\.index)) }
}

/// Night sky noise reduction: the sky of every photo aligned by its stars to one moment and averaged in linear light, the
/// ground averaged separately in its own place, so stars stay points and the foreground stays sharp. Lines from
/// meteors, aircraft and satellites are left out of the photo they cross instead of being averaged in as faint streaks.
/// No sample is rejected for being bright, so faint stars survive.
public final class NightSkyDenoiser: @unchecked Sendable {
    private let analyzer: NightSkyAnalyzer
    public private(set) var analysis: NightSkyDenoiseAnalysis?
    public var urls: [URL] { analyzer.urls }

    public init(urls: [URL]) throws { analyzer = try NightSkyAnalyzer(urls: urls, space: .sky) }

    /// Analyzes with everything as sky or the sky corrected by `skyStrokes`, for finding and aligning stars; analyzing
    /// again with other corrections reuses the sky found the first time.
    public func analyze(allSky: Bool = false, skyStrokes: [NightSkyStroke] = [], progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) throws -> NightSkyDenoiseAnalysis {
        analyzer.skyCorrection = NightSkyAnalyzer.SkyShape(everything: allSky, strokes: skyStrokes.filter { $0.sky != nil })
        try analyzer.analyze(progress: progress)
        return restoredAnalysis()
    }

    public func saveAnalysis(to directory: URL) throws { try analyzer.saveAnalysis(to: directory) }
    public func restoreAnalysis(from directory: URL, progress: @escaping @Sendable (Double, String) -> Void) throws -> NightSkyDenoiseAnalysis {
        try analyzer.restoreAnalysis(from: directory, progress: progress)
        return restoredAnalysis()
    }
    /// What analysis found, to take back with `reuse` after analyzing again.
    public func analysisSnapshot() throws -> Data { try analyzer.encodedResults() }
    public func reuse(_ snapshot: Data) throws -> NightSkyDenoiseAnalysis {
        try analyzer.reuse(snapshot)
        return restoredAnalysis()
    }
    private func restoredAnalysis() -> NightSkyDenoiseAnalysis {
        let result = NightSkyDenoiseAnalysis(frames: analyzer.frameInfos(), lines: analyzer.lineInfos(), timing: NightSkyTiming(analyzer.metadata),
                                             suggestedReference: analyzer.defaultReference, width: analyzer.width, height: analyzer.height,
                                             skyModelInstalled: analyzer.skyModelInstalled)
        analysis = result
        return result
    }

    func plan(_ settings: NightSkyDenoiseSettings) throws -> NightSkyAnalyzer.Plan {
        try analyzer.requireAnalysis()
        let included = Set(analyzer.urls.indices).subtracting(settings.excluded)
        var reference = settings.reference ?? analysis?.suggestedReference ?? analyzer.anchor
        if !included.contains(reference) || analyzer.alignments[reference] == nil {
            reference = included.filter { analyzer.alignments[$0] != nil }.min { abs($0 - analyzer.anchor) < abs($1 - analyzer.anchor) } ?? analyzer.anchor
        }
        let sky = included.filter { analyzer.alignments[$0] != nil }
        guard sky.count >= 2 else { throw PanoramaError.message(L10n.tr("Include at least two photos whose stars could be aligned.")) }
        var plan = NightSkyAnalyzer.Plan(base: reference, sky: sky, ground: settings.ground == .average ? included : [reference])
        plan.rejectOutliers = settings.rejectOutliers
        plan.skyShape = NightSkyAnalyzer.SkyShape(edge: settings.skyEdge, everything: settings.allSky, strokes: settings.skyStrokes)
        plan.regions = settings.photoRegions; plan.regionPhoto = reference
        for line in analyzer.lines { plan.skyExclusions[line.frame, default: []].append(line) }
        return plan
    }

    public func preview(_ settings: NightSkyDenoiseSettings) throws -> NightSkyPreview {
        let plan = try plan(settings)
        return try analyzer.picture(try analyzer.preview(plan), lines: [], base: plan.base)
    }
    /// (Σw)² / Σw² over the photos stacked into the sky: how many equally weighted photos the stack is worth. A support
    /// figure, not a measured noise reduction: resampling and unequal noise make real gains smaller.
    public func effectivePhotos(_ settings: NightSkyDenoiseSettings) -> Double {
        guard let plan = try? plan(settings) else { return 0 }
        let w = plan.sky.map { Double(analyzer.weights[$0]) }
        let squares = w.reduce(0) { $0 + $1 * $1 }
        return squares > 0 ? pow(w.reduce(0, +), 2) / squares : 0
    }
    /// The reference photo alone at preview size, for comparing.
    public func referencePicture(_ settings: NightSkyDenoiseSettings) throws -> NightSkyPreview {
        let base = try plan(settings).base
        return try analyzer.picture(try analyzer.preview(NightSkyAnalyzer.Plan(base: base, ground: [base])), lines: [], base: base)
    }
    func previewValues(_ settings: NightSkyDenoiseSettings) throws -> [Float] { try analyzer.preview(plan(settings)) }
    /// The reference alone at preview size.
    func referenceValues(_ settings: NightSkyDenoiseSettings) throws -> [Float] {
        let base = try plan(settings).base
        return try analyzer.preview(NightSkyAnalyzer.Plan(base: base, ground: [base]))
    }

    public func merge(_ settings: NightSkyDenoiseSettings, to url: URL, progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) throws {
        try analyzer.write(plan(settings), kind: .nightSky, to: url, progress: progress)
    }
    func render(_ settings: NightSkyDenoiseSettings, engine: NightSkyAnalyzer.Engine) throws -> PanoramaRaster {
        try analyzer.render(plan(settings), engine: engine, progress: { _, _ in })
    }
    var internalAnalyzer: NightSkyAnalyzer { analyzer }
}

// MARK: Meteor Shower

public struct MeteorShowerSettings: Codable, Equatable, Sendable {
    /// Areas painted to come from one photo alone (the reference, the base, or the sky photo): something that moved, or
    /// a skyline the boundary gets wrong.
    public var photoRegions: [NightSkyStroke] = []
    /// Full-size pixels to move the sky's boundary by: out into the ground when positive, in toward the sky when negative.
    public var skyEdge = 0
    /// Everything counts as sky, for a photo without ground or a sky the finder gets wrong.
    public var allSky = false
    /// Painted corrections to the sky, in order: dabs that add sky and dabs that take it away.
    public var skyStrokes: [NightSkyStroke] = []
    /// The photo that supplies the ground and where the stars are; nil for the middle one.
    public var base: Int?
    /// Lines chosen or turned down by hand, by line id; the rest follow the default (likely meteors in, the rest out).
    public var choices: [Int: Bool] = [:]
    /// How many photos' sky is averaged, aligned to the base: the base and the photos taken nearest it. 1 keeps the
    /// base photo's own sky. Neighbors in time differ least from the base: the sky glow, the clouds and the stars'
    /// positions have barely changed, so the average lowers noise without smearing anything.
    public var skyPhotos = 1
    /// Photos left out of the averaged sky; the next nearest takes the place of each.
    public var excluded: Set<Int> = []
    /// Keeps each meteor where the camera recorded it instead of moving it with the stars to the base photo's sky.
    public var asCaptured = false
    public init() {}
}

extension MeteorShowerSettings: NightSkyLineChoosing {
    public static func includesByDefault(_ kind: NightSkyLineKind) -> Bool { kind == .meteor }
}

public struct MeteorShowerAnalysis: Sendable {
    public let frames: [NightSkyFrameInfo]
    /// Every line found, in capture order.
    public let lines: [NightSkyLineInfo]
    public let timing: NightSkyTiming?
    public let suggestedBase: Int
    public let width: Int, height: Int
    public let skyModelInstalled: Bool
    /// Photos suggested for leaving out of the averaged sky.
    public var suggestedExclusions: Set<Int> { Set(frames.filter { $0.note != nil }.map(\.index)) }
    /// The photos with at least one line, in capture order.
    public var framesWithLines: [Int] { Array(Set(lines.map(\.frame))).sorted() }
    /// The photos whose sky is averaged around `base`: the base, then the aligned photos not left out, nearest in capture
    /// time first (in capture order without times), `settings.skyPhotos` in all.
    public func skyFrames(base: Int, _ settings: MeteorShowerSettings) -> [Int] {
        let candidates = frames.filter { $0.index != base && $0.isAligned && !settings.excluded.contains($0.index) }
        let baseTime = frames[base].time
        func distance(_ frame: NightSkyFrameInfo) -> Double {
            if let baseTime, let time = frame.time { return abs(time - baseTime) }
            return Double(abs(frame.index - base))
        }
        let nearest = candidates.sorted { (distance($0), $0.index) < (distance($1), $1.index) }.prefix(max(0, settings.skyPhotos - 1))
        return ([base] + nearest.map(\.index)).sorted()
    }
}

/// Meteor shower: the meteors from every photo gathered onto one base photo. Each meteor keeps its own measured pixels,
/// moved with the stars to where the sky stood in the base photo, so the shower radiates as it would have looked at that
/// moment; the ground is the base photo's. The sky can stay the base photo's or be averaged with the photos taken nearest it.
public final class MeteorShowerMerger: @unchecked Sendable {
    private let analyzer: NightSkyAnalyzer
    public private(set) var analysis: MeteorShowerAnalysis?
    public var urls: [URL] { analyzer.urls }

    public init(urls: [URL]) throws { analyzer = try NightSkyAnalyzer(urls: urls, space: .sky) }

    /// Analyzes with everything as sky or the sky corrected by `skyStrokes`, for finding and aligning stars; analyzing
    /// again with other corrections reuses the sky found the first time.
    public func analyze(allSky: Bool = false, skyStrokes: [NightSkyStroke] = [], progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) throws -> MeteorShowerAnalysis {
        analyzer.skyCorrection = NightSkyAnalyzer.SkyShape(everything: allSky, strokes: skyStrokes.filter { $0.sky != nil })
        try analyzer.analyze(progress: progress)
        return restoredAnalysis()
    }

    public func saveAnalysis(to directory: URL) throws { try analyzer.saveAnalysis(to: directory) }
    public func restoreAnalysis(from directory: URL, progress: @escaping @Sendable (Double, String) -> Void) throws -> MeteorShowerAnalysis {
        try analyzer.restoreAnalysis(from: directory, progress: progress)
        return restoredAnalysis()
    }
    /// What analysis found, to take back with `reuse` after analyzing again.
    public func analysisSnapshot() throws -> Data { try analyzer.encodedResults() }
    public func reuse(_ snapshot: Data) throws -> MeteorShowerAnalysis {
        try analyzer.reuse(snapshot)
        return restoredAnalysis()
    }
    private func restoredAnalysis() -> MeteorShowerAnalysis {
        let result = MeteorShowerAnalysis(frames: analyzer.frameInfos(), lines: analyzer.lineInfos(), timing: NightSkyTiming(analyzer.metadata),
                                          suggestedBase: analyzer.defaultReference, width: analyzer.width, height: analyzer.height,
                                          skyModelInstalled: analyzer.skyModelInstalled)
        analysis = result
        return result
    }

    func plan(_ settings: MeteorShowerSettings) throws -> NightSkyAnalyzer.Plan {
        try analyzer.requireAnalysis()
        guard let analysis else { throw PanoramaError.message(L10n.tr("Analyze the photos first.")) }
        var base = settings.base ?? analysis.suggestedBase
        if analyzer.alignments[base] == nil { base = analyzer.anchor }
        var plan = NightSkyAnalyzer.Plan(base: base, ground: [base])
        plan.skyShape = NightSkyAnalyzer.SkyShape(edge: settings.skyEdge, everything: settings.allSky, strokes: settings.skyStrokes)
        plan.regions = settings.photoRegions; plan.regionPhoto = base
        if settings.skyPhotos > 1 {
            plan.sky = Set(analysis.skyFrames(base: base, settings))
            // Only what agrees with the base photo is averaged in, so a skyline detail taken for sky stays the base's own.
            plan.rejectOutliers = true; plan.agreeWithBase = true
            for line in analyzer.lines { plan.skyExclusions[line.frame, default: []].append(line) }
        }
        plan.restore = analysis.lines.filter { settings.includes($0) && analyzer.alignments[$0.frame] != nil }.map { analyzer.lines[$0.id] }
        if settings.asCaptured {
            // Lines are found on the anchor's sky; as captured they go back to where their own photo recorded them.
            plan.restoreAsCaptured = true
            plan.restore = plan.restore.map { line in
                var line = line
                if line.frame != analyzer.anchor, let alignment = analyzer.alignments[line.frame] {
                    line.start = alignment.sourcePoint(line.start); line.end = alignment.sourcePoint(line.end)
                }
                return line
            }
        }
        return plan
    }

    public func preview(_ settings: MeteorShowerSettings) throws -> NightSkyPreview {
        let plan = try plan(settings)
        return try analyzer.picture(try analyzer.preview(plan), lines: analyzer.lines.enumerated().map { ($0.offset, $0.element) }, base: plan.base,
                                    asCaptured: settings.asCaptured)
    }
    func previewValues(_ settings: MeteorShowerSettings) throws -> [Float] { try analyzer.preview(plan(settings)) }

    public func merge(_ settings: MeteorShowerSettings, to url: URL, progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) throws {
        try analyzer.write(plan(settings), kind: .meteorShower, to: url, progress: progress)
    }
    func render(_ settings: MeteorShowerSettings, engine: NightSkyAnalyzer.Engine) throws -> PanoramaRaster {
        try analyzer.render(plan(settings), engine: engine, progress: { _, _ in })
    }
    var internalAnalyzer: NightSkyAnalyzer { analyzer }
}
