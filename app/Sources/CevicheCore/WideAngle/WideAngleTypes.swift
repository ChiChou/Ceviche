import CoreGraphics
import Foundation

/// How Wide-Angle Faces corrects a photo.
public struct WideAngleSettings: Codable, Equatable, Sendable {
    /// 0–1: how far heads (and bodies) move from the lens's stretch toward their true shape.
    public var strength = 1.0
    /// Whether each person's body follows their head, so a corrected head never sits on a still-stretched body.
    public var bodies = true
    /// 0–1: how firmly bodies follow, against keeping the background around them as shot.
    public var bodyAmount = 0.5
    /// 0–1: how firmly the background keeps straight lines, against moving with the people.
    public var straightLines = 0.5
    /// What a rendered photo's copy is saved as; a RAW's is always a DNG.
    public var format = ProcessedFormat.original
    public init() {}

    // Settings remembered before a field existed keep the rest.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        strength = try c.decodeIfPresent(Double.self, forKey: .strength) ?? strength
        bodies = try c.decodeIfPresent(Bool.self, forKey: .bodies) ?? bodies
        bodyAmount = try c.decodeIfPresent(Double.self, forKey: .bodyAmount) ?? bodyAmount
        straightLines = try c.decodeIfPresent(Double.self, forKey: .straightLines) ?? straightLines
        // HEIC and JPEG, offered before, are Original now.
        format = (try? c.decodeIfPresent(ProcessedFormat.self, forKey: .format)) ?? format
    }
}

/// One person Wide-Angle Faces knows about, in fractions of the photo's width and height from the top left.
public struct WideAnglePerson: Identifiable, Equatable, Sendable {
    public var id: Int
    /// The middle of the head, hair included.
    public var head: CGPoint
    /// Half the head's width and height.
    public var headRadius: CGSize
    /// Roughly where the person stands, head to feet.
    public var body: CGRect
    /// Corrected (true) or left as shot.
    public var enabled = true
    /// Placed by a click on the photo rather than found.
    public var added = false

    public init(id: Int, head: CGPoint, headRadius: CGSize, body: CGRect, enabled: Bool = true, added: Bool = false) {
        self.id = id; self.head = head; self.headRadius = headRadius; self.body = body; self.enabled = enabled; self.added = added
    }

    /// A person placed by hand at `head`, as big as `like` (the median head found), or a twentieth of the photo's height.
    public static func placed(id: Int, at head: CGPoint, like: CGSize?, aspect: Double) -> WideAnglePerson {
        let r = like ?? CGSize(width: 0.025 / aspect, height: 0.03)
        let face = CGSize(width: r.width / 0.85, height: r.height / 0.95)
        let body = CGRect(x: head.x - 1.6 * face.width, y: head.y, width: 3.2 * face.width, height: 7 * face.height)
        return WideAnglePerson(id: id, head: head, headRadius: r, body: body.intersection(CGRect(x: 0, y: 0, width: 1, height: 1)), added: true)
    }
}

/// The people found in a photo and where people are, at the size they were looked for at.
public struct WideAngleAnalysis: Sendable {
    public var people: [WideAnglePerson]
    /// 0–1 per pixel of a small grid, rows top down: where Vision sees people.
    var mask: [Float]
    var maskWidth: Int
    var maskHeight: Int
    /// Width over height of the photo.
    public var aspect: Double

    func mask(at p: CGPoint) -> Float {
        guard maskWidth > 0, maskHeight > 0 else { return 0 }
        let x = min(maskWidth - 1, max(0, Int(p.x * Double(maskWidth)))), y = min(maskHeight - 1, max(0, Int(p.y * Double(maskHeight))))
        return mask[y * maskWidth + x]
    }
    /// The median head among those found, for one placed by hand.
    public var typicalHead: CGSize? {
        let found = people.filter { !$0.added }.map(\.headRadius)
        guard !found.isEmpty else { return nil }
        let w = found.map(\.width).sorted(), h = found.map(\.height).sorted()
        return CGSize(width: w[w.count / 2], height: h[h.count / 2])
    }
}

/// The solved mesh in fractions of the photo from the top left: where each grid point of the photo as shot goes.
public struct WideAngleMesh: Sendable {
    public var columns: Int
    public var rows: Int
    /// Grid points as shot, row by row.
    public var source: [CGPoint]
    /// Where they land.
    public var target: [CGPoint]
}

/// Where the mesh moves a point (fractions of the photo from the top left), and back.
extension WideAngleMesh {
    public func forward(_ q: CGPoint) -> CGPoint {
        let fi = min(max(q.x * Double(columns - 1), 0), Double(columns - 1) - 1e-6)
        let fj = min(max(q.y * Double(rows - 1), 0), Double(rows - 1) - 1e-6)
        let i = Int(fi), j = Int(fj), u = fi - Double(i), t = fj - Double(j), k = j * columns + i
        func mix(_ a: CGPoint, _ b: CGPoint, _ s: Double) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * s, y: a.y + (b.y - a.y) * s) }
        return mix(mix(target[k], target[k + 1], u), mix(target[k + columns], target[k + columns + 1], u), t)
    }
    public func backward(_ q: CGPoint) -> CGPoint {
        var s = q
        for _ in 0..<8 { let f = forward(s); s = CGPoint(x: s.x - (f.x - q.x), y: s.y - (f.y - q.y)) }
        return s
    }
}
