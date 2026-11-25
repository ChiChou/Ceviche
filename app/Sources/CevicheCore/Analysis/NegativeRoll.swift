import Foundation

/// What Convert Negative settled for one scan; whatever is nil is found when converting.
public struct NegativeChoice: Sendable {
    public var frame: FrameQuad?
    public var film: NegativeFilm?
    public var orientation: NegativeOrientation
    /// Film base picked on unexposed film, at an exposure of 1.
    public var base: SIMD3<Float>?
    /// The scan's inversion from its roll, used instead of measuring the scan alone.
    public var inversion: NegativeInversion?
    /// Printed on paper rather than inverted.
    public var print: NegativePrint?

    public init(frame: FrameQuad? = nil, film: NegativeFilm? = nil, orientation: NegativeOrientation = NegativeOrientation(),
                base: SIMD3<Float>? = nil, inversion: NegativeInversion? = nil, print: NegativePrint? = nil) {
        self.frame = frame; self.film = film; self.orientation = orientation; self.base = base; self.inversion = inversion; self.print = print
    }
}

/// What a roll's scans share in Convert Negative: the film, the orientation and the film base set on any of them.
public struct NegativeRollShared: Equatable, Sendable {
    public var film: NegativeFilm
    public var orientation: NegativeOrientation
    public var base: SIMD3<Float>?
    public init(film: NegativeFilm, orientation: NegativeOrientation, base: SIMD3<Float>?) { self.film = film; self.orientation = orientation; self.base = base }
}

/// Convert Negative's decisions for a selection balanced as rolls: which scans to measure, how the samples become
/// one inversion per roll, and what each scan is converted with. The apps hold the state and run the work.
public enum NegativeRoll {
    /// `scans` in order, split where a scan in `starts` begins a roll; nil keeps them as one roll.
    public static func rolls<Scan>(_ scans: [Scan], id: (Scan) -> String, starts: Set<String>?) -> [[Scan]] {
        guard let starts else { return scans.isEmpty ? [] : [scans] }
        var rolls: [[Scan]] = []
        for scan in scans { if rolls.isEmpty || starts.contains(id(scan)) { rolls.append([scan]) } else { rolls[rolls.count - 1].append(scan) } }
        return rolls
    }

    /// Whether a scan is measured (again): it has no sample yet, or its sample was taken in another frame than the one
    /// it will be converted in. `frame` is nil for a scan never looked at, which keeps the sample it has.
    public static func needsSample(_ sample: NegativeSample?, frame: FrameQuad?) -> Bool {
        guard let sample else { return true }
        return frame.map { $0 != sample.frame } ?? false
    }

    /// One roll to balance: its measured scans by ID, with the film and base set on it.
    public struct Group: Sendable {
        public var scans: [(id: String, sample: NegativeSample)]
        public var film: NegativeFilm?
        public var base: SIMD3<Float>?
        public init(scans: [(id: String, sample: NegativeSample)], film: NegativeFilm?, base: SIMD3<Float>?) { self.scans = scans; self.film = film; self.base = base }
    }

    public struct Balance: Sendable {
        /// Each scan's inversion from its roll.
        public var inversions: [String: NegativeInversion]
        /// Scans whose film base doesn't match their roll's, converted on their own.
        public var apart: Set<String>
        /// The rolls the scans look like, by ID: a proposal to split the selection, never applied by itself.
        public var proposed: [[String]]
    }

    /// The groups to balance: each roll's measured scans with the film and base `shared` gives for its first scan (a
    /// roll never looked at is measured as it comes). Rolls with nothing measured are left out.
    public static func groups(_ rolls: [[String]], samples: [String: NegativeSample], shared: (String) -> NegativeRollShared?) -> [Group] {
        rolls.map { roll in
            let set = roll.first.flatMap(shared)
            return Group(scans: roll.compactMap { id in samples[id].map { (id, $0) } }, film: set?.film, base: set?.base)
        }.filter { !$0.scans.isEmpty }
    }

    /// Balances each roll on its own, and proposes the rolls `scans` (the measured scans to convert, in order) look like.
    public static func balance(_ groups: [Group], scans: [(id: String, scan: NegativeRollScan)]) -> Balance {
        var inversions: [String: NegativeInversion] = [:], apart = Set<String>()
        for group in groups {
            let balanced = NegativeConverter.balance(group.scans.map(\.sample), film: group.film, base: group.base)
            for (scan, inversion) in zip(group.scans, balanced.inversions) { inversions[scan.id] = inversion }
            apart.formUnion(balanced.apart.map { group.scans[$0].id })
        }
        let proposed = NegativeRolls.rolls(scans.map(\.scan)).map { $0.map { scans[$0].id } }
        return Balance(inversions: inversions, apart: apart, proposed: proposed)
    }

    /// What a measured scan tells the roll proposal: its capture, its session's settings and its comparable base.
    public static func rollScan(_ sample: NegativeSample, session: (captured: Date?, settings: String, camera: String)) -> NegativeRollScan {
        NegativeRollScan(captured: session.captured, settings: session.settings, camera: session.camera, base: sample.comparableBase)
    }

    /// Every scan's choices as converting takes them. `kept` are the choices made on each scan looked at. In a roll
    /// (`inversions` not nil) each scan takes its roll's shared film, orientation and base (a roll never looked at
    /// converts as measured, upright), its own frame or else the one it was measured in, and its inversion from the
    /// roll. `print` goes to every scan.
    public static func choices(_ ids: [String], kept: [String: NegativeChoice], samples: [String: NegativeSample],
                               inversions: [String: NegativeInversion]?, shared: (String) -> NegativeRollShared?,
                               print: NegativePrint?) -> [String: NegativeChoice] {
        var all = kept
        if let inversions {
            for id in ids {
                let set = shared(id)
                all[id] = NegativeChoice(frame: kept[id]?.frame ?? samples[id]?.frame, film: set?.film,
                                         orientation: set?.orientation ?? NegativeOrientation(), base: set?.base, inversion: inversions[id])
            }
        }
        for id in ids { all[id, default: NegativeChoice()].print = print }
        return all
    }
}

extension NegativeConverter {
    /// Converts `source` into a positive DNG at `url` with what Convert Negative settled for it.
    public static func convert(_ source: URL, to url: URL, choice: NegativeChoice,
                               progress: (Double, String) -> Void = { _, _ in }, cancelled: () -> Bool = { false }) throws {
        try convert(source, to: url, frame: choice.frame, film: choice.film, orientation: choice.orientation, base: choice.base,
                    inversion: choice.inversion, print: choice.print, progress: progress, cancelled: cancelled)
    }

    /// Where the positive of `source` goes in `directory`: its name with the suffix, numbered when that is taken.
    public static func destination(for source: URL, in directory: URL) -> URL {
        let stem = source.deletingPathExtension().lastPathComponent
        var destination = directory.appendingPathComponent("\(stem)-\(suffix).dng")
        var number = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(stem)-\(suffix)-\(number).dng"); number += 1
        }
        return destination
    }
}
