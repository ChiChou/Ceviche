import Foundation
import ImageIO

/// What a timelapse needs to know about one photo, read from its original's EXIF.
public struct TimelapseCapture: Sendable, Equatable {
    public var filename: String
    /// From DateTimeOriginal with its sub-seconds and offset; nil when the file records no capture time.
    public var date: Date?
    public var camera: String
    /// Pixel size as displayed (orientation applied).
    public var size: CGSize?
    public var make = ""
    public var model = ""
    /// Degrees north and east, and meters above sea level, from the GPS tags.
    public var location: (latitude: Double, longitude: Double, altitude: Double?)?
    public init(filename: String, date: Date?, camera: String = "", size: CGSize? = nil) {
        self.filename = filename; self.date = date; self.camera = camera; self.size = size
    }
    public static func == (a: TimelapseCapture, b: TimelapseCapture) -> Bool {
        a.filename == b.filename && a.date == b.date && a.camera == b.camera && a.size == b.size && a.make == b.make && a.model == b.model
            && a.location?.latitude == b.location?.latitude && a.location?.longitude == b.location?.longitude && a.location?.altitude == b.location?.altitude
    }

    /// Reads only the file's metadata, not its pixels.
    public static func read(_ url: URL, filename: String) -> TimelapseCapture {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return TimelapseCapture(filename: filename, date: nil) }
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let date = (exif[kCGImagePropertyExifDateTimeOriginal as String] as? String).flatMap {
            Self.date($0, subseconds: exif[kCGImagePropertyExifSubsecTimeOriginal as String] as? String,
                      offset: exif[kCGImagePropertyExifOffsetTimeOriginal as String] as? String)
        }
        var size: CGSize?
        if let width = properties[kCGImagePropertyPixelWidth as String] as? Int, let height = properties[kCGImagePropertyPixelHeight as String] as? Int {
            let turned = [5, 6, 7, 8].contains(properties[kCGImagePropertyOrientation as String] as? Int ?? 1)
            size = turned ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        }
        let make = (tiff[kCGImagePropertyTIFFMake as String] as? String ?? "").trimmingCharacters(in: .whitespaces.union(.controlCharacters))
        let model = (tiff[kCGImagePropertyTIFFModel as String] as? String ?? "").trimmingCharacters(in: .whitespaces.union(.controlCharacters))
        var capture = TimelapseCapture(filename: filename, date: date, camera: [make, model].filter { !$0.isEmpty }.joined(separator: " "), size: size)
        capture.make = make; capture.model = model
        let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]
        if let latitude = gps[kCGImagePropertyGPSLatitude as String] as? Double, let longitude = gps[kCGImagePropertyGPSLongitude as String] as? Double {
            let south = (gps[kCGImagePropertyGPSLatitudeRef as String] as? String) == "S", west = (gps[kCGImagePropertyGPSLongitudeRef as String] as? String) == "W"
            let altitude = (gps[kCGImagePropertyGPSAltitude as String] as? Double).map { (gps[kCGImagePropertyGPSAltitudeRef as String] as? Int) == 1 ? -$0 : $0 }
            capture.location = (south ? -latitude : latitude, west ? -longitude : longitude, altitude)
        }
        return capture
    }

    /// EXIF's "yyyy:MM:dd HH:mm:ss", plus SubSecTimeOriginal ("042" is 0.042 s) and OffsetTimeOriginal ("+02:00").
    /// Without an offset the time is read as UTC: only the intervals between frames matter.
    static func date(_ text: String, subseconds: String?, offset: String?) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = offset.flatMap(Self.timeZone) ?? TimeZone(secondsFromGMT: 0)
        guard let base = formatter.date(from: text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\0", with: "")) else { return nil }
        let digits = (subseconds ?? "").trimmingCharacters(in: .whitespaces).prefix { $0.isNumber }
        let fraction = digits.isEmpty ? 0 : (Double("0." + digits) ?? 0)
        return base.addingTimeInterval(fraction)
    }
    private static func timeZone(_ offset: String) -> TimeZone? {
        let parts = offset.trimmingCharacters(in: .whitespaces).dropFirst().split(separator: ":")
        guard let sign = offset.trimmingCharacters(in: .whitespaces).first, sign == "+" || sign == "-", parts.count == 2,
              let hours = Int(parts[0]), let minutes = Int(parts[1]) else { return nil }
        return TimeZone(secondsFromGMT: (sign == "-" ? -1 : 1) * (hours * 3600 + minutes * 60))
    }
}

/// The photos in capture order and what looks wrong with them as one sequence.
public struct TimelapseSeries: Sendable, Equatable {
    public enum Issue: Sendable, Equatable {
        /// Photos with no capture time, placed after the others in filename order.
        case missingTime([String])
        /// A pause longer than the usual interval, where frames are probably missing.
        case gap(after: String, before: String, seconds: Double, missingFrames: Int)
        /// Photos taken at the same moment, such as a duplicate import or a bracket.
        case sameTime([String])
        /// More than one camera.
        case cameras([String])
        /// Photos of different pixel sizes or orientations, which the crop frames differently.
        case sizes(Int)
        /// A run shot faster than the usual interval, where the video's motion slows down.
        case faster(from: String, to: String, seconds: Double, frames: Int)
    }
    /// What makes one frame stand out, for marking it among the others.
    public enum Mark: Sendable, Equatable {
        case missingTime
        /// The first frame after a gap.
        case afterGap(seconds: Double, missingFrames: Int)
        /// Taken at the same moment as the frame before it; the first of such frames is not marked.
        case sameTime
        /// In a run shot faster than the rest.
        case faster
        /// Shot with another camera than most of the series.
        case otherCamera(String)
        /// Of another pixel size or orientation than most of the series.
        case otherSize
    }
    /// Indexes into the captures, in capture order.
    public let order: [Int]
    public let issues: [Issue]
    /// Each frame's marks, in capture order as `order` is.
    public let marks: [[Mark]]
    /// The filenames in capture order.
    private let names: [String]
    /// The usual time between frames (the median), in seconds.
    public let interval: Double?
    /// From the first capture to the last.
    public let span: Double?

    /// A pause counts as a gap when it is this many times the usual interval.
    public static let gapFactor = 1.8

    public init(_ captures: [TimelapseCapture]) {
        let timed = captures.indices.filter { captures[$0].date != nil }
            .sorted { (captures[$0].date!, captures[$0].filename) < (captures[$1].date!, captures[$1].filename) }
        let untimed = captures.indices.filter { captures[$0].date == nil }.sorted { captures[$0].filename < captures[$1].filename }
        order = timed + untimed
        var issues: [Issue] = []
        var marks = [[Mark]](repeating: [], count: captures.count)
        if !untimed.isEmpty { issues.append(.missingTime(untimed.map { captures[$0].filename })) }
        for index in untimed { marks[index].append(.missingTime) }
        let steps = zip(timed, timed.dropFirst()).map { (from: $0, to: $1, seconds: captures[$1].date!.timeIntervalSince(captures[$0].date!)) }
        // Times shorter than a millisecond apart are the same moment; the camera records no finer.
        let same = steps.filter { $0.seconds < 0.001 }
        if !same.isEmpty {
            var names: [String] = []
            for step in same { for index in [step.from, step.to] where !names.contains(captures[index].filename) { names.append(captures[index].filename) } }
            issues.append(.sameTime(names))
            for step in same { marks[step.to].append(.sameTime) }
        }
        let positive = steps.map(\.seconds).filter { $0 >= 0.001 }.sorted()
        let median = positive.isEmpty ? nil : positive.count % 2 == 1 ? positive[positive.count / 2] : (positive[positive.count / 2 - 1] + positive[positive.count / 2]) / 2
        interval = median
        span = timed.count >= 2 ? captures[timed.last!].date!.timeIntervalSince(captures[timed.first!].date!) : nil
        if let median, positive.count >= 2 {
            for step in steps where step.seconds > median * Self.gapFactor && step.seconds - median >= 0.5 {
                let missing = max(1, Int((step.seconds / median).rounded()) - 1)
                issues.append(.gap(after: captures[step.from].filename, before: captures[step.to].filename, seconds: step.seconds, missingFrames: missing))
                marks[step.to].append(.afterGap(seconds: step.seconds, missingFrames: missing))
            }
        }
        // The opposite of a gap: a burst at a shorter interval, such as frames shot before the intervalometer was set.
        if let median, positive.count >= 2 {
            var run: [(from: Int, to: Int, seconds: Double)] = []
            func report() {
                if let first = run.first, let last = run.last {
                    let times = run.map(\.seconds).sorted()
                    issues.append(.faster(from: captures[first.from].filename, to: captures[last.to].filename, seconds: times[times.count / 2], frames: run.count + 1))
                    for index in [first.from] + run.map(\.to) where !marks[index].contains(.faster) { marks[index].append(.faster) }
                }
                run = []
            }
            for step in steps where step.seconds >= 0.001 {
                if step.seconds * Self.gapFactor < median && median - step.seconds >= 0.5 { run.append(step) } else { report() }
            }
            report()
        }
        let cameras = captures.map(\.camera).filter { !$0.isEmpty }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        if cameras.count > 1 {
            issues.append(.cameras(cameras))
            let usual = Self.mostCommon(captures.map(\.camera).filter { !$0.isEmpty })
            for index in captures.indices where !captures[index].camera.isEmpty && captures[index].camera != usual { marks[index].append(.otherCamera(captures[index].camera)) }
        }
        func key(_ size: CGSize) -> String { "\(Int(size.width))x\(Int(size.height))" }
        let sizes = Set(captures.compactMap(\.size).map(key))
        if sizes.count > 1 {
            issues.append(.sizes(sizes.count))
            let usual = Self.mostCommon(captures.compactMap(\.size).map(key))
            for index in captures.indices { if let size = captures[index].size, key(size) != usual { marks[index].append(.otherSize) } }
        }
        self.issues = issues
        self.marks = order.map { marks[$0] }
        names = order.map { captures[$0].filename }
    }

    /// The value most of `values` share; among equally common ones, the first to appear.
    private static func mostCommon(_ values: [String]) -> String? {
        let counts = values.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        var best: String?
        for value in values where best == nil || counts[value]! > counts[best!]! { best = value }
        return best
    }

    /// The positions in `order` of the frames an issue is about: the ones to select when removing them from the video.
    /// A gap's is the frame after it; the same moment's are the repeats, leaving the first.
    public func frames(for issue: Issue) -> [Int] {
        marks.indices.filter { position in
            marks[position].contains { mark in
                switch (issue, mark) {
                case (.missingTime, .missingTime), (.sameTime, .sameTime), (.cameras, .otherCamera), (.sizes, .otherSize): return true
                case (.gap(_, let before, _, _), .afterGap): return names[position] == before
                case (.faster(let from, let to, _, _), .faster):
                    // A series can have more than one burst; each is the run between its two names.
                    guard let start = names.firstIndex(of: from), let end = names[start...].firstIndex(of: to) else { return false }
                    return (start...end).contains(position)
                default: return false
                }
            }
        }
    }
}

/// What the movie records about where it came from: when the series began, where, and with what camera.
public struct TimelapseMetadata: Sendable {
    public var date: Date?
    public var location: (latitude: Double, longitude: Double, altitude: Double?)?
    public var make = ""
    public var model = ""
    public init() {}
    /// From the frames in playing order: the first capture time, and the first location and camera recorded.
    public init(_ captures: [TimelapseCapture]) {
        date = captures.lazy.compactMap(\.date).first
        location = captures.lazy.compactMap(\.location).first
        if let camera = captures.first(where: { !$0.make.isEmpty || !$0.model.isEmpty }) { make = camera.make; model = camera.model }
    }
    /// ISO 6709 as QuickTime stores it: "+46.4102+011.8440+2105.000/".
    var iso6709: String? {
        guard let location else { return nil }
        var text = String(format: "%+08.4f%+09.4f", location.latitude, location.longitude)
        if let altitude = location.altitude { text += String(format: "%+.3f", altitude) }
        return text + "/"
    }
}
