import Foundation
import CoreGraphics

/// An ID photo as the user set it up: the spec, where the head is in the developed photo, and how it is printed. It
/// lives only while the tool is open; nothing of it is kept on the photo.
///
/// The crop follows from two points: the crown (top of the hair) and the bottom of the chin. Their distance sets the
/// scale, so the head is `headSize` of the way through the spec's range; the line between them is the head's vertical,
/// which levels a tilted head and centres it.
public struct IDPhotoLayout: Equatable, Sendable {
    public var spec: IDPhotoSpec
    /// In the developed photo, as fractions of its width and height from the top left.
    public var crown: CGPoint
    public var chin: CGPoint
    /// Midway between the pupils; nil when no face was found, and the eyes are then taken to be halfway up the head.
    public var eyes: CGPoint?
    /// Where the head's height falls in the spec's range: 0 the smallest allowed, 1 the largest.
    public var headSize = 0.5
    /// Moves the head down the frame from where the spec centres it, in millimetres.
    public var offsetMM = 0.0
    /// A solid colour in place of the photo's background; nil keeps the background as shot.
    public var background: IDPhotoBackground?
    public var sheet = IDPhotoSheet()

    public init(spec: IDPhotoSpec, crown: CGPoint, chin: CGPoint, eyes: CGPoint? = nil) {
        self.spec = spec; self.crown = crown; self.chin = chin; self.eyes = eyes
    }

    /// Whether the settings a batch shares (document, background and paper; not copies, which are each photo's)
    /// are the same.
    public func sharesSettings(with other: IDPhotoLayout) -> Bool {
        var mine = sheet, theirs = other.sheet; mine.copies = nil; theirs.copies = nil
        return spec == other.spec && background == other.background && mine == theirs
    }
    /// Takes `other`'s shared settings, keeping this photo's markers, head size, position and copies.
    public mutating func adoptSettings(of other: IDPhotoLayout) {
        if spec != other.spec { spec = other.spec; headSize = 0.5; offsetMM = 0 }
        background = other.background
        let copies = sheet.copies; sheet = other.sheet; sheet.copies = copies
    }

    /// The frame on a photo `size` pixels big (any scale of the developed photo; the markers are fractions).
    public func frame(in size: CGSize) -> IDPhotoFrame { IDPhotoFrame(layout: self, size: size) }
}

/// Where the print sits on the developed photo, in that photo's pixels (top-left origin), and where the head's lines fall on
/// the print, in millimetres from its top.
public struct IDPhotoFrame: Sendable {
    public let spec: IDPhotoSpec
    public let size: CGSize
    public let headMM: Double
    public let crownMM: Double
    /// Photo pixels per millimetre of print.
    public let scale: Double
    /// Unit vectors in the photo for the print's up and right.
    let up: CGVector, right: CGVector
    let crownPixel: CGPoint
    /// Fraction of the head height from chin to eyes.
    let eyeFraction: Double

    init(layout: IDPhotoLayout, size: CGSize) {
        spec = layout.spec; self.size = size
        let crown = CGPoint(x: layout.crown.x * size.width, y: layout.crown.y * size.height)
        let chin = CGPoint(x: layout.chin.x * size.width, y: layout.chin.y * size.height)
        let dx = crown.x - chin.x, dy = crown.y - chin.y
        let length = max(1, hypot(dx, dy))
        up = CGVector(dx: dx / length, dy: dy / length)
        right = CGVector(dx: -up.dy, dy: up.dx)
        crownPixel = crown
        if let eyes = layout.eyes {
            let e = CGPoint(x: eyes.x * size.width, y: eyes.y * size.height)
            eyeFraction = min(0.8, max(0.3, Double(((e.x - chin.x) * up.dx + (e.y - chin.y) * up.dy) / length)))
        } else {
            eyeFraction = 0.5
        }
        let range = layout.spec.headRange
        headMM = range.lowerBound + (range.upperBound - range.lowerBound) * min(1, max(0, layout.headSize))
        scale = Double(length) / headMM
        crownMM = Self.crown(spec: layout.spec, head: headMM, eyeFraction: eyeFraction) + layout.offsetMM
    }

    /// The crown's distance from the top that meets every limit the spec sets, in the middle of what is allowed.
    static func crown(spec: IDPhotoSpec, head: Double, eyeFraction: Double) -> Double {
        var low = 0.0, high = spec.heightMM - head
        var constrained = false
        if let crown = spec.crownRange { low = max(low, crown.lowerBound); high = min(high, crown.upperBound); constrained = true }
        if let eye = spec.eyeRange {
            // The eyes sit (1 - eyeFraction) of the head below the crown.
            let below = (1 - eyeFraction) * head
            low = max(low, spec.heightMM - eye.upperBound - below); high = min(high, spec.heightMM - eye.lowerBound - below)
            constrained = true
        }
        if !constrained { return (spec.heightMM - head) * 0.4 }
        if low <= high { return (low + high) / 2 }
        // The limits disagree for this face; the crown limit is the one officials measure first.
        return spec.crownRange.map { ($0.lowerBound + $0.upperBound) / 2 } ?? (low + high) / 2
    }

    public var chinMM: Double { crownMM + headMM }
    public var eyeMM: Double { crownMM + (1 - eyeFraction) * headMM }
    public var eyeFromBottomMM: Double { spec.heightMM - eyeMM }

    /// The photo pixel under a point of the print, in millimetres from its top left.
    public func photoPoint(mm point: CGPoint) -> CGPoint {
        let x = (point.x - spec.widthMM / 2) * scale, y = (point.y - crownMM) * scale
        return CGPoint(x: crownPixel.x + x * right.dx - y * up.dx, y: crownPixel.y + x * right.dy - y * up.dy)
    }
    /// The point of the print over a photo pixel.
    public func printPoint(photo point: CGPoint) -> CGPoint {
        let dx = point.x - crownPixel.x, dy = point.y - crownPixel.y
        let x = (dx * right.dx + dy * right.dy) / scale, y = -(dx * up.dx + dy * up.dy) / scale
        return CGPoint(x: x + spec.widthMM / 2, y: y + crownMM)
    }
    /// The print's corners on the photo: top left, top right, bottom right, bottom left.
    public var corners: [CGPoint] {
        [CGPoint(x: 0, y: 0), CGPoint(x: spec.widthMM, y: 0), CGPoint(x: spec.widthMM, y: spec.heightMM), CGPoint(x: 0, y: spec.heightMM)].map(photoPoint)
    }
    /// The print runs past the photo's edges, where it is filled with the background.
    public var outsidePhoto: Bool {
        corners.contains { $0.x < -0.5 || $0.y < -0.5 || $0.x > size.width + 0.5 || $0.y > size.height + 0.5 }
    }
    /// How much the head's vertical leans, in degrees; the print levels it.
    public var tiltDegrees: Double { atan2(Double(up.dx), Double(-up.dy)) * 180 / .pi }

    /// The transform from print pixels at `pixelsPerMM` to this photo's pixels, both in Core Image's bottom-left
    /// coordinates.
    public func printToPhoto(pixelsPerMM: Double, printHeight: Double) -> CGAffineTransform {
        func map(_ x: Double, _ y: Double) -> CGPoint {
            let p = photoPoint(mm: CGPoint(x: x / pixelsPerMM, y: (printHeight - y) / pixelsPerMM))
            return CGPoint(x: p.x, y: size.height - p.y)
        }
        let o = map(0, 0), a = map(1, 0), b = map(0, 1)
        return CGAffineTransform(a: a.x - o.x, b: a.y - o.y, c: b.x - o.x, d: b.y - o.y, tx: o.x, ty: o.y)
    }

    /// The spec's lines: each measured value and whether it is in range (nil when the spec sets no range).
    public var headInRange: Bool { spec.headRange.contains(headMM.rounded(toPlaces: 1)) }
    public var crownInRange: Bool? { spec.crownRange?.contains(crownMM.rounded(toPlaces: 1)) }
    public var eyeInRange: Bool? { spec.eyeRange?.contains(eyeFromBottomMM.rounded(toPlaces: 1)) }
}

/// White balance set in the ID Photo tool, saved to the photo's development.
public struct IDPhotoWhiteBalance: Equatable, Sendable {
    public var temperature: Double, warmth: Double, tint: Double
    public init(temperature: Double, warmth: Double, tint: Double) { self.temperature = temperature; self.warmth = warmth; self.tint = tint }
    public func apply(to adjustments: inout Adjustments) { adjustments.temperature = temperature; adjustments.warmth = warmth; adjustments.tint = tint }
}

/// The print laid out on paper: as many copies as fit, with cut guides.
public struct IDPhotoSheet: Equatable, Sendable {
    /// Photo paper as labs, kiosks and photo printers take it, smallest first; A4 and Letter as inkjet photo paper.
    public enum Paper: String, CaseIterable, Sendable, Identifiable {
        case single, photoL, photo4x6, photo10x15, postcard, photo5x7, photo13x18, photo6x8, photo8x10, a4, letter
        public var id: String { rawValue }
        /// Portrait, in millimetres.
        public var sizeMM: CGSize? {
            switch self {
            case .single: nil
            case .photoL: CGSize(width: 89, height: 127)
            case .photo4x6: CGSize(width: 101.6, height: 152.4)
            case .photo10x15: CGSize(width: 100, height: 150)
            case .postcard: CGSize(width: 100, height: 148)
            case .photo5x7: CGSize(width: 127, height: 177.8)
            case .photo13x18: CGSize(width: 130, height: 180)
            case .photo6x8: CGSize(width: 152.4, height: 203.2)
            case .photo8x10: CGSize(width: 203.2, height: 254)
            case .a4: CGSize(width: 210, height: 297)
            case .letter: CGSize(width: 215.9, height: 279.4)
            }
        }
        public var title: String {
            switch self {
            case .single: L10n.tr("Single Photo")
            case .photoL: L10n.tr("L (89 × 127 mm)")
            case .photo4x6: "4 × 6 in"
            case .photo10x15: "10 × 15 cm"
            case .postcard: L10n.tr("Postcard (100 × 148 mm)")
            case .photo5x7: "5 × 7 in"
            case .photo13x18: "13 × 18 cm"
            case .photo6x8: "6 × 8 in"
            case .photo8x10: "8 × 10 in"
            case .a4: "A4"
            case .letter: L10n.tr("US Letter")
            }
        }
        /// What photo shops print ID photos on where the user is: L in East Asia, 4 × 6 in in North America,
        /// 10 × 15 cm elsewhere.
        public static func standard(for region: String?) -> Paper {
            switch region {
            case "JP", "CN", "KR", "TW", "HK", "MO": .photoL
            case "US", "CA", "PH", "MX": .photo4x6
            default: .photo10x15
            }
        }
    }
    /// How close the copies sit. Labs and kiosks trim a millimetre or more off each edge and need room to cut;
    /// edge to edge fits more, for printing at home or a shop that cuts the sheet itself.
    public enum Spacing: String, CaseIterable, Sendable, Identifiable {
        case lab, edgeToEdge
        public var id: String { rawValue }
        public var marginMM: Double { self == .lab ? 4 : 0 }
        public var gapMM: Double { self == .lab ? 3 : 0 }
        public var title: String { self == .lab ? L10n.tr("Lab") : L10n.tr("Edge to Edge") }
    }
    public var paper = Paper.standard(for: Locale.current.region?.identifier)
    public var spacing = Spacing.lab
    public var cutGuides = true
    /// Copies on the sheet; nil fills it.
    public var copies: Int?
    public init() {}

    /// Several photos' copies over as many sheets as they need: which photo goes in each place of each sheet, by
    /// index into `copies`. A photo's copies stay on one sheet when they fit on it, so a sheet can be cut and handed
    /// to one person; empty places are left at the end.
    public func pages(copies: [Int], spec: IDPhotoSpec) -> [[Int]] {
        var full = self; full.copies = nil
        guard let capacity = full.arrangement(for: spec)?.origins.count, capacity > 0 else { return [] }
        var pages: [[Int]] = [], current: [Int] = []
        for (photo, count) in copies.enumerated() where count > 0 {
            // Start a new sheet rather than split copies that would fit on one.
            if !current.isEmpty, current.count + count > capacity, count <= capacity { pages.append(current); current = [] }
            for _ in 0..<count {
                if current.count == capacity { pages.append(current); current = [] }
                current.append(photo)
            }
        }
        if !current.isEmpty { pages.append(current) }
        return pages
    }

    /// The paper's size and each copy's top-left corner on it, in millimetres; nil for a single photo.
    public func arrangement(for spec: IDPhotoSpec) -> (paper: CGSize, origins: [CGPoint])? {
        guard let portrait = paper.sizeMM else { return nil }
        let margin = spacing.marginMM, gap = spacing.gapMM
        func fit(_ paper: CGSize) -> (CGSize, Int, Int) {
            // A hair of slack, so 2 × 2 in photos fill a 4 × 6 in sheet exactly despite rounding.
            let columns = Int((paper.width - 2 * margin + gap) / (spec.widthMM + gap) + 1e-6)
            let rows = Int((paper.height - 2 * margin + gap) / (spec.heightMM + gap) + 1e-6)
            return (paper, max(0, columns), max(0, rows))
        }
        let tall = fit(portrait), wide = fit(CGSize(width: portrait.height, height: portrait.width))
        let (size, columns, rows) = wide.1 * wide.2 > tall.1 * tall.2 ? wide : tall
        let total = min(columns * rows, copies ?? .max)
        guard total > 0 else { return (size, []) }
        let usedRows = Int((Double(total) / Double(columns)).rounded(.up))
        let blockWidth = Double(min(total, columns)) * (spec.widthMM + gap) - gap
        let blockHeight = Double(usedRows) * (spec.heightMM + gap) - gap
        let left = max(0, (size.width - blockWidth) / 2), top = max(0, (size.height - blockHeight) / 2)
        let origins = (0..<total).map { index in
            CGPoint(x: left + Double(index % columns) * (spec.widthMM + gap), y: top + Double(index / columns) * (spec.heightMM + gap))
        }
        return (size, origins)
    }
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10, Double(places))
        return (self * factor).rounded() / factor
    }
}
