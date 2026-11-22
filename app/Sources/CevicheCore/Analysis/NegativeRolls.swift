import Foundation
import CoreImage
import ImageIO
import simd

/// What grouping scans into rolls reads from one scan.
public struct NegativeRollScan: Sendable {
    public var captured: Date?
    /// What a scanning session keeps: camera, lens, focal length and a white balance set by hand.
    public var settings: String
    public var camera: String
    /// The film base at an exposure of 1 under one fixed white balance, so scans compare whatever each was shot at.
    public var base: SIMD3<Float>

    public init(captured: Date?, settings: String, camera: String, base: SIMD3<Float>) {
        self.captured = captured; self.settings = settings; self.camera = camera; self.base = base
    }

    /// The capture time and session settings of the scan at `url`.
    public static func session(_ url: URL) -> (captured: Date?, settings: String, camera: String) {
        let properties = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] } ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let stamp = (exif[kCGImagePropertyExifDateTimeOriginal as String] as? String).flatMap { formatter.date(from: String($0.prefix(19))) }
        let fraction = (exif[kCGImagePropertyExifSubsecTimeOriginal as String] as? String).flatMap { Double("0." + $0.trimmingCharacters(in: .whitespaces)) } ?? 0
        let camera = (tiff[kCGImagePropertyTIFFModel as String] as? String ?? "").trimmingCharacters(in: .whitespaces)
        var parts = [camera, exif[kCGImagePropertyExifLensModel as String] as? String ?? "",
                     (exif[kCGImagePropertyExifFocalLength as String] as? NSNumber).map { String(format: "%.0f", $0.doubleValue) } ?? ""]
        // A white balance set by hand stays put for a session; an automatic one changes with every frame.
        let manual = (exif[kCGImagePropertyExifWhiteBalance as String] as? NSNumber)?.intValue == 1
        if manual, let raw = CIRAWFilter(imageURL: url) {
            parts.append("\(Int((Double(raw.neutralTemperature) / 50).rounded()) * 50) K \(Int((Double(raw.neutralTint) / 2).rounded()) * 2)")
        } else { parts.append(manual ? "manual" : "auto") }
        return (stamp.map { $0.addingTimeInterval(fraction) }, parts.joined(separator: " / "), camera)
    }
}

/// Groups scans into rolls before Convert Negative balances them. A roll is scanned in one run, so in capture order a
/// new roll starts where the film base stops matching the roll so far or the session's settings change. A pause alone
/// doesn't start one: a roll is often scanned over two evenings. The base alone can't tell two rolls of one stock
/// apart, and time alone splits rolls and joins others; order, settings and base together were exact on real rolls.
public enum NegativeRolls {
    /// Bases match when two of the three channels are within a quarter stop, as Convert Negative tells another film
    /// in a roll. One channel alone may be clipped by the scan: red is, at the base of most colour negatives, since
    /// the decoder clips it whatever the white balance.
    static let tolerance: Float = 0.25

    static func matches(_ a: NegativeRollScan, _ b: NegativeRollScan) -> Bool {
        // A camera's colour isn't another camera's.
        guard a.camera == b.camera, a.base.min() > 0, b.base.min() > 0 else { return false }
        return (0..<3).map { abs(log2(a.base[$0] / b.base[$0])) }.sorted()[1] <= tolerance
    }

    /// The rolls, as indices into `scans` in capture order (scans without a time keep the order given). One scan that
    /// doesn't match while the next one does stays in its roll: a bad reading, or one frame to look at.
    public static func rolls(_ scans: [NegativeRollScan]) -> [[Int]] {
        let order = scans.indices.sorted { a, b in
            switch (scans[a].captured, scans[b].captured) {
            case let (x?, y?): return x != y ? x < y : a < b
            default: return a < b
            }
        }
        var rolls: [[Int]] = [], outliers = Set<Int>()
        func fits(_ i: Int) -> Bool {
            guard let roll = rolls.last else { return false }
            let typical = roll.filter { !outliers.contains($0) }
            let members = typical.isEmpty ? roll : typical
            // The member matching most others stands for the roll.
            let centre = members.max { a, b in members.filter { matches(scans[a], scans[$0]) }.count < members.filter { matches(scans[b], scans[$0]) }.count }!
            return matches(scans[i], scans[centre]) && scans[i].settings == scans[roll.last!].settings
        }
        for (k, i) in order.enumerated() {
            if fits(i) { rolls[rolls.count - 1].append(i) }
            else if let roll = rolls.last, k + 1 < order.count, scans[i].settings == scans[roll.last!].settings, fits(order[k + 1]) {
                rolls[rolls.count - 1].append(i); outliers.insert(i)
            } else { rolls.append([i]) }
        }
        return rolls
    }
}
