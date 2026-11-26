import Foundation
import CoreImage
import ImageIO
import simd

/// One photo of a bracketed panorama, as its grouping shows it.
public struct HDRPanoramaPhoto: Identifiable, Sendable {
    public let index: Int
    public let filename: String
    /// log2(exposure time × ISO / f-number²) as recorded; nil when the camera recorded none.
    public let stops: Double?
    public let thumbnail: CGImage?
    public var id: Int { index }
}

/// A bracketed panorama's photos in capture order, split into one bracket per camera position.
public struct HDRPanoramaGrouping: @unchecked Sendable {
    public let photos: [HDRPanoramaPhoto]
    /// The photos that begin a position; always has 0.
    public var starts: Set<Int>
    /// Starts whose first photo shows the same view as the photo before it: two brackets at one position.
    public let sameView: Set<Int>

    public var groups: [[Int]] {
        var groups: [[Int]] = []
        for k in photos.indices { if starts.contains(k) || groups.isEmpty { groups.append([k]) } else { groups[groups.count - 1].append(k) } }
        return groups
    }
    /// The bracket size most positions have.
    public var usualSize: Int {
        var counts: [Int: Int] = [:]
        for group in groups { counts[group.count, default: 0] += 1 }
        return counts.max { ($0.value, $0.key) < ($1.value, $1.key) }?.key ?? 0
    }
    /// Positions (from 0) whose bracket isn't the usual size: a frame may be missing.
    public var oddPositions: [Int] { let usual = usualSize; return groups.indices.filter { groups[$0].count != usual } }
    /// Positions (from 0) that begin with the view the position before ends with.
    public var repeatedPositions: [Int] { groups.indices.filter { sameView.contains(groups[$0][0]) && starts.contains(groups[$0][0]) } }
    public var canMerge: Bool { groups.count >= 2 && groups.contains { $0.count >= 2 } }
}

/// Takes a bracketed panorama to one linear DNG: each position's bracket is merged to HDR, then the merges are stitched,
/// all in memory. Against stitching each exposure and merging the canvases this is twice as fast, never ghosts on
/// handheld brackets and takes brackets with a frame missing. Every bracket is developed with one white balance and
/// evened out by its recorded exposure before stitching, since auto ISO and auto white balance change from one
/// position to the next.
public final class HDRPanoramaMerger: @unchecked Sendable {
    /// In capture order.
    public private(set) var urls: [URL]
    private var shots: [Shot] = []
    /// Each photo's own retouching by URL, burnt in when the full-size result is rendered; aligning goes without it.
    public var retouch: [URL: [RetouchStroke]] = [:]
    /// A fresh context each time: Core Image keeps every surface a context used until the context goes.
    private var context: CIContext { Self.makeContext() }
    private static func makeContext() -> CIContext {
        CIContext(options: [.workingColorSpace: PanoramaDecoder.space, .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])
    }

    public init(urls: [URL]) throws {
        guard urls.count >= 4 else { throw PanoramaError.message(L10n.tr("Choose the brackets of at least two positions.")) }
        self.urls = urls
    }

    // MARK: Grouping

    struct Shot {
        var url: URL
        /// Capture time in seconds, with the camera's fractions of a second.
        var time: Double
        var exposureTime: Double?
        var stops: Double?
    }

    static func shot(_ url: URL) -> Shot {
        let properties = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] } ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        func number(_ key: CFString) -> Double? {
            let value = exif[key as String]
            return (value as? NSNumber)?.doubleValue ?? (value as? [NSNumber])?.first?.doubleValue
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let stamp = (exif[kCGImagePropertyExifDateTimeOriginal as String] as? String).flatMap { formatter.date(from: String($0.prefix(19))) }
        let fraction = (exif[kCGImagePropertyExifSubsecTimeOriginal as String] as? String).flatMap { Double("0." + $0.trimmingCharacters(in: .whitespaces)) } ?? 0
        let time = number(kCGImagePropertyExifExposureTime).flatMap { $0 > 0 ? $0 : nil }
        let aperture = number(kCGImagePropertyExifFNumber).flatMap { $0 > 0 ? $0 : nil }
        let iso = number(kCGImagePropertyExifISOSpeedRatings).flatMap { $0 > 0 ? $0 : nil } ?? 100
        return Shot(url: url, time: (stamp?.timeIntervalSinceReferenceDate ?? 0) + fraction, exposureTime: time,
                    stops: time.flatMap { t in aperture.map { log2(t * iso / ($0 * $0)) } })
    }

    /// Splits photos in capture order into brackets. A new bracket starts at a pause well above the usual one (four
    /// times the median, and at least 2 s more), when a photo repeats an exposure the bracket already has, or at a
    /// boundary the pictures force.
    static func segment(_ shots: [Shot], forced: Set<Int> = []) -> [[Int]] {
        guard !shots.isEmpty else { return [] }
        let gaps = [0] + (1..<shots.count).map { shots[$0].time - (shots[$0 - 1].time + (shots[$0 - 1].exposureTime ?? 0)) }
        let sorted = gaps.dropFirst().sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let threshold = sorted.isEmpty ? Double.infinity : max(4 * median, median + 2)
        var groups: [[Int]] = [[0]]
        for k in 1..<shots.count {
            let repeats = shots[k].stops.map { stops in groups[groups.count - 1].contains { shots[$0].stops.map { abs($0 - stops) < 0.2 } ?? false } } ?? false
            if forced.contains(k) || gaps[k] > threshold || repeats { groups.append([k]) } else { groups[groups.count - 1].append(k) }
        }
        return groups
    }

    /// Whether photos look like a bracket at each position, from their recorded times and exposures alone, without
    /// decoding them: at least two positions, and half of them, hold photos at least about a stop apart. A panorama
    /// whose auto exposure drifts makes one such run at most.
    public static func looksBracketed(_ urls: [URL]) -> Bool {
        guard urls.count >= 4 else { return false }
        return bracketed(urls.map(shot).sorted { ($0.time, $0.url.lastPathComponent) < ($1.time, $1.url.lastPathComponent) })
    }

    static func bracketed(_ shots: [Shot]) -> Bool {
        let groups = segment(shots)
        let spread = groups.filter { group in
            let stops = group.compactMap { shots[$0].stops }
            return stops.count >= 2 && stops.max()! - stops.min()! >= 0.9
        }
        return spread.count >= 2 && spread.count * 2 >= groups.count
    }

    enum Verdict { case same, moved, unsure }

    /// The recorded times and exposures propose the brackets; the pictures confirm them or split them, never join them.
    public func group(progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) throws -> HDRPanoramaGrouping {
        progress(0, L10n.tr("Reading photos…"))
        let ordered = urls.map(Self.shot).sorted { ($0.time, $0.url.lastPathComponent) < ($1.time, $1.url.lastPathComponent) }
        urls = ordered.map(\.url); shots = ordered
        let count = shots.count
        let cameras = Set(try urls.map { url -> String in let m = try HDRMergeDecoder.metadata(url); return "\(m.make) \(m.model)" })
        if cameras.count > 1 { throw PanoramaError.message(L10n.tr("These photos come from different cameras. Panoramas need photos from one camera.")) }

        // Each photo small, as detail ranks: any exposure change that keeps the order of tones leaves them alone.
        var planes = [LuminancePlane?](repeating: nil, count: count), flat = [Double](repeating: 0, count: count)
        var thumbnails = [CGImage?](repeating: nil, count: count)
        var failure: Error?
        let lock = NSLock()
        var done = 0
        let urls = self.urls, context = self.context
        let middle = try HDRMergeDecoder.metadata(urls[count / 2])
        DispatchQueue.concurrentPerform(iterations: count) { i in
            guard !Task.isCancelled else { return }
            do {
                let metadata = try HDRMergeDecoder.metadata(urls[i])
                let frame = try HDRMergeDecoder.decode(urls[i], metadata: metadata, longEdge: 480, whiteBalance: (middle.temperature, middle.tint), context: context)
                let (plane, share) = Self.rankEqualized(LuminancePlane(frame, longEdge: 320))
                let picture = HDRMergeFinishing.picture(PanoramaRaster(width: frame.width, height: frame.height, rgba: Self.brightened(frame.pixels)), maxDimension: 240)
                let finished = lock.withLock { planes[i] = plane; flat[i] = share; thumbnails[i] = picture; done += 1; return done }
                progress(0.9 * Double(finished) / Double(count), L10n.tr("Reading \(urls[i].lastPathComponent)"))
            } catch { lock.withLock { failure = error } }
        }
        if Task.isCancelled { throw CancellationError() }
        if let failure { throw failure }
        var cache: [Int: Verdict] = [:]
        func check(_ i: Int, _ j: Int) -> Verdict {
            if let cached = cache[i * count + j] { return cached }
            let (correlation, atEdge) = Self.correlate(planes[i]!, planes[j]!, reach: 10)
            let verdict: Verdict = max(flat[i], flat[j]) > 0.5 ? .unsure : atEdge ? .moved : correlation >= 0.2 ? .same : correlation < 0.12 ? .moved : .unsure
            cache[i * count + j] = verdict
            return verdict
        }
        progress(0.92, L10n.tr("Grouping brackets"))
        var forced = Set<Int>(), groups = Self.segment(shots)
        // A split changes which exposures share a bracket, so repeat until nothing more splits.
        for _ in 0..<count {
            var changed = false
            for group in groups { for (i, j) in zip(group, group.dropFirst()) where check(i, j) == .moved && !forced.contains(j) { forced.insert(j); changed = true } }
            if !changed { break }
            groups = Self.segment(shots, forced: forced)
        }
        let sameView = Set(zip(groups, groups.dropFirst()).compactMap { a, b in check(a.last!, b.first!) == .same ? b.first! : nil })
        let photos = shots.indices.map { HDRPanoramaPhoto(index: $0, filename: urls[$0].lastPathComponent, stops: shots[$0].stops, thumbnail: thumbnails[$0]) }
        progress(1, "")
        return HDRPanoramaGrouping(photos: photos, starts: Set(groups.map { $0[0] }), sameView: sameView)
    }

    /// A linear frame lifted so its median sits at a mid tone: brackets several stops apart all show their picture.
    private static func brightened(_ pixels: [Float]) -> [Float] {
        var luminance: [Float] = []
        luminance.reserveCapacity(pixels.count / 64)
        for p in stride(from: 0, to: pixels.count, by: 64) { luminance.append(0.2126 * pixels[p] + 0.7152 * pixels[p + 1] + 0.0722 * pixels[p + 2]) }
        luminance.sort()
        let gain = min(64, max(0.25, 0.18 / max(1e-4, luminance[luminance.count / 2])))
        return pixels.map { $0 * gain }
    }

    /// Each pixel replaced by its rank among the frame's pixels, less its neighbourhood's mean rank, and the share of
    /// the frame in its largest flat tone (black or clipped): above half, the picture can't say whether the camera moved.
    static func rankEqualized(_ plane: LuminancePlane) -> (LuminancePlane, flat: Double) {
        let n = plane.values.count
        let order = plane.values.indices.sorted { plane.values[$0] < plane.values[$1] }
        var ranks = [Float](repeating: 0, count: n)
        var start = 0, largest = 0
        while start < n {
            var end = start
            // Within 1 % counts as a tie, so a clipped sky or a black shadow becomes one flat tone.
            while end + 1 < n, plane.values[order[end + 1]] <= plane.values[order[start]] * 1.01 + 1e-5 { end += 1 }
            let rank = Float(start + end) / 2 / Float(max(1, n - 1))
            for k in start...end { ranks[order[k]] = rank }
            largest = max(largest, end - start + 1)
            start = end + 1
        }
        // Detail only, so the sky-above-ground layout every view of a landscape shares doesn't correlate.
        let mean = HDRMerger.boxBlur(ranks, width: plane.width, height: plane.height, radius: 4)
        return (LuminancePlane(width: plane.width, height: plane.height, values: zip(ranks, mean).map { $0 - $1 }), Double(largest) / Double(n))
    }

    /// The best normalized cross-correlation of b against a over whole-pixel shifts up to `reach`, and whether it sits at
    /// the edge of the search: then the views differ by more than the search covers.
    static func correlate(_ a: LuminancePlane, _ b: LuminancePlane, reach: Int) -> (Double, atEdge: Bool) {
        guard a.width == b.width, a.height == b.height, a.width > 4 * reach, a.height > 4 * reach else { return (0, true) }
        let w = a.width, h = a.height, margin = reach + 2, side = 2 * reach + 1
        var scores = [Double](repeating: 0, count: side * side)
        scores.withUnsafeMutableBufferPointer { scores in
            let scores = scores
            DispatchQueue.concurrentPerform(iterations: side * side) { k in
                let dx = k % side - reach, dy = k / side - reach
                var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0, n = 0.0
                for y in margin..<(h - margin) { for x in margin..<(w - margin) {
                    let u = Double(a.values[y * w + x]), v = Double(b.values[(y + dy) * w + x + dx])
                    sa += u; sb += v; saa += u * u; sbb += v * v; sab += u * v; n += 1
                } }
                let covariance = sab / n - sa / n * sb / n, va = saa / n - sa * sa / (n * n), vb = sbb / n - sb * sb / (n * n)
                scores[k] = va > 1e-9 && vb > 1e-9 ? covariance / sqrt(va * vb) : 0
            }
        }
        let best = scores.indices.max { scores[$0] < scores[$1] }!
        let dx = best % side - reach, dy = best / side - reach
        return (scores[best], abs(dx) == reach || abs(dy) == reach)
    }

    // MARK: Merge

    /// Analyzes every bracket and returns the panorama of their merges, ready to align. `groups` are indices into
    /// `urls`, as the grouping gave them or as corrected; a position may be a single photo.
    public func panorama(groups: [[Int]], deghosting: HDRDeghosting = .medium, progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) throws -> PanoramaMerger {
        guard groups.count >= 2 else { throw PanoramaError.message(L10n.tr("Choose the brackets of at least two positions.")) }
        if shots.isEmpty { shots = urls.map(Self.shot) }
        let middle = try HDRMergeDecoder.metadata(urls[urls.count / 2])
        let whiteBalance = (temperature: middle.temperature, tint: middle.tint)
        // The reference of each bracket: its middle exposure as recorded. Judged by the pictures alone, a very wide
        // bracket's darkest frame can win, and the merge develops black.
        let references = groups.map { group -> Int in
            let known = group.filter { shots[$0].stops != nil }
            return known.count == group.count ? known.sorted { shots[$0].stops! < shots[$1].stops! }[group.count / 2] : group[group.count / 2]
        }
        let recorded = references.compactMap { shots[$0].stops }.sorted()
        let common = recorded.count == references.count ? recorded[recorded.count / 2] : nil

        var inputs: [PanoramaInput] = []
        for (g, group) in groups.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            progress(Double(g) / Double(groups.count), L10n.tr("Merging bracket \(g + 1) of \(groups.count)"))
            let reference = references[g], referenceURL = urls[reference]
            var metadata = try PanoramaDecoder.metadata(referenceURL)
            // Evened out by the recorded exposure: the panorama's own gain solve only takes off what is left. On its
            // own it finds no constraint at dusk and stops at two stops.
            let factor = common.flatMap { c in shots[reference].stops.map { exp2(c - $0) } } ?? 1
            if group.count == 1 {
                let strokes = retouch[referenceURL] ?? []
                inputs.append(PanoramaInput(metadata: metadata, exposureFactor: factor) { longEdge in
                    let frame = try PanoramaDecoder.decode(referenceURL, longEdge: longEdge, whiteBalance: whiteBalance, context: Self.makeContext(),
                                                         retouch: longEdge == nil ? strokes : [])
                    return PanoramaFrame(width: frame.width, height: frame.height, pixels: Self.scaled(frame.pixels, by: Float(factor)))
                })
                continue
            }
            let merger = try HDRMerger(urls: group.map { urls[$0] })
            merger.sharedWhiteBalance = whiteBalance
            // The positions are stitched on the brackets as shot; the retouching goes into the full-size merge only.
            let strokes = retouch
            let analysis = try merger.analyze()
            var settings = HDRMergeSettings()
            settings.deghosting = deghosting
            if let index = merger.urls.firstIndex(of: referenceURL), index != analysis.suggestedReference { settings.reference = index }
            let reduced = try merger.previewRaster(settings)
            metadata.width = analysis.width; metadata.height = analysis.height
            let small = PanoramaFrame(width: reduced.width, height: reduced.height, pixels: Self.scaled(reduced.rgba, by: Float(factor)))
            // Aligned without deghosting: in wind-blown foliage it falls back to one exposure, whose noisy shadows match
            // far worse between positions. Deghosting is for the pixels, not the geometry.
            var aligning = settings; aligning.deghosting = .off
            let unghosted = deghosting == .off ? reduced : try merger.previewRaster(aligning)
            let registration = deghosting == .off ? small
                : PanoramaFrame(width: unghosted.width, height: unghosted.height, pixels: Self.scaled(unghosted.rgba, by: Float(factor)))
            let merged = settings
            inputs.append(PanoramaInput(metadata: metadata, exposureFactor: factor, decode: { longEdge in
                if longEdge != nil { return small }
                merger.retouch = strokes
                let (raster, _, _) = try merger.mergedRaster(merged, engine: .gpu)
                return PanoramaFrame(width: raster.width, height: raster.height, pixels: Self.scaled(raster.rgba, by: Float(factor)))
            }, registration: { registration }))
        }
        progress(1, "")
        let panorama = try PanoramaMerger(urls: references.map { urls[$0] }, inputs: inputs)
        panorama.process = "HDR Panorama"; panorama.keepsExposure = false
        return panorama
    }

    private static func scaled(_ pixels: consuming [Float], by factor: Float) -> [Float] {
        guard factor != 1 else { return pixels }
        pixels.withUnsafeMutableBufferPointer { px in
            let px = px
            DispatchQueue.concurrentPerform(iterations: 64) { band in
                for p in stride(from: band * 4, to: px.count, by: 64 * 4) { px[p] *= factor; px[p + 1] *= factor; px[p + 2] *= factor }
            }
        }
        return pixels
    }
}
