import Foundation

/// The Glow filter's settings: highlights spread light into their surroundings, in one of several styles. Sizes are
/// fractions of the photo's long side, so a preview and the export glow alike. Applied by the Filters dialog, not kept
/// on the photo.
public struct Glow: Codable, Equatable, Sendable {
    /// How the light above the threshold spreads. Stored by number, so names can change.
    public enum Style: Int, Codable, CaseIterable, Sendable {
        /// A soft halo round each light, added to the picture. Not the Bloom filter, which is a lens's veiling glare.
        case halo
        /// A mist filter: highlights soften and veil their surroundings, with part of their light moved rather than
        /// added. Not the Diffusion filter, which spreads all of the light as a measured soft-focus filter does.
        case mist
        /// Film halation: a tight red-orange fringe round bright edges, from light reflected off the film base.
        case halation
        /// Shutter drag: lights smear along a direction, with a faint ghost of the scene.
        case motion
        /// A streak filter: each point of light drawn out into a thin line across the picture.
        case streak

        public var title: String {
            switch self {
            case .halo: L10n.tr("Halo")
            case .mist: L10n.tr("Mist")
            case .halation: L10n.tr("Halation")
            case .motion: L10n.tr("Motion")
            case .streak: L10n.tr("Streak")
            }
        }
        /// True for the styles that spread light along a direction.
        public var hasAngle: Bool { self == .motion || self == .streak }
    }

    public var enabled = true
    public var style = Style.halo
    /// How much of the light above the threshold spreads, in percent.
    public var amount = 30.0
    /// The spread's reach: a halo from 0.5 % to 10 % of the long side, a motion smear from 2 % to 20 %, a streak from
    /// 5 % to 40 %.
    public var size = 30.0
    /// The brightness the glow starts from, in percent of white.
    public var threshold = 60.0
    /// Motion's and Streak's direction in degrees, counter-clockwise from horizontal.
    public var angle = 0.0
    public init() {}

    enum CodingKeys: String, CodingKey { case enabled, style, amount, size, threshold, angle }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        style = try c.decodeIfPresent(Style.self, forKey: .style) ?? .halo
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 30
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 30
        threshold = try c.decodeIfPresent(Double.self, forKey: .threshold) ?? 60
        angle = try c.decodeIfPresent(Double.self, forKey: .angle) ?? 0
    }
    func validate() throws {
        guard [amount, size, threshold].allSatisfy({ $0.isFinite && (0...100).contains($0) }), angle.isFinite, (-90...90).contains(angle) else {
            throw EditorError.invalidDocument(L10n.tr("Invalid glow settings."))
        }
    }
    /// The halo's radius as a fraction of the long side.
    var radius: Double { 0.005 + size / 100 * 0.095 }
    /// How far Motion or Streak spreads light each way along its angle, as a fraction of the long side, and the size
    /// that reaches `fraction`.
    public static func reach(_ style: Style, size: Double) -> Double {
        style == .streak ? 0.05 + size / 100 * 0.35 : 0.02 + size / 100 * 0.18
    }
    public static func size(_ style: Style, reaching fraction: Double) -> Double {
        style == .streak ? (fraction - 0.05) / 0.35 * 100 : (fraction - 0.02) / 0.18 * 100
    }
}
