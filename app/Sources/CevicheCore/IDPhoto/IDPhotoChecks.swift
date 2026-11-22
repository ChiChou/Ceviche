import Foundation

/// One line of the checklist. Thresholds are deliberately loose: a warning asks the photographer to look, a failure is
/// something an official would reject on sight.
public struct IDPhotoCheck: Identifiable, Sendable, Equatable {
    public enum Status: Int, Sendable, Comparable {
        case pass, unknown, warning, failure
        public static func < (a: Status, b: Status) -> Bool { a.rawValue < b.rawValue }
    }
    public var id: String
    public var title: String
    public var status: Status
    /// The measurement or what was seen, short.
    public var detail: String
    /// From Apple Intelligence rather than a measurement.
    public var advisory = false
}

public enum IDPhotoChecks {
    public static func evaluate(_ analysis: IDPhotoAnalysis, layout: IDPhotoLayout, photoSize: CGSize) -> [IDPhotoCheck] {
        let spec = layout.spec
        var checks: [IDPhotoCheck] = []
        func add(_ id: String, _ title: String, _ status: IDPhotoCheck.Status, _ detail: String) {
            checks.append(IDPhotoCheck(id: id, title: title, status: status, detail: detail))
        }
        func mm(_ value: Double) -> String { L10n.tr("\(value.formatted(.number.precision(.fractionLength(1)).locale(L10n.locale))) mm") }
        func degrees(_ value: Double) -> String { "\(Int(value.rounded()))°" }

        switch analysis.faces.count {
        case 0: add("face", L10n.tr("Face"), .failure, L10n.tr("None found"))
        case 1: add("face", L10n.tr("Face"), .pass, L10n.tr("One"))
        default: add("face", L10n.tr("Face"), .failure, L10n.tr("\(analysis.faces.count) faces"))
        }

        // Framing, from the layout.
        let frame = layout.frame(in: photoSize)
        add("head", L10n.tr("Head height"), frame.headInRange ? .pass : .failure, mm(frame.headMM))
        if let inRange = frame.crownInRange { add("crown", L10n.tr("Above head"), inRange ? .pass : .failure, mm(frame.crownMM)) }
        if let inRange = frame.eyeInRange { add("eyes", L10n.tr("Eye line"), inRange ? .pass : .failure, mm(frame.eyeFromBottomMM)) }
        if frame.outsidePhoto { add("edges", L10n.tr("Frame"), .warning, L10n.tr("Runs past the photo")) }
        // Source pixels per print pixel; below 1 the print is enlarged.
        let ratio = frame.scale / (spec.printDPI / 25.4)
        add("resolution", L10n.tr("Resolution"), ratio >= 1 ? .pass : ratio >= 0.7 ? .warning : .failure,
            ratio >= 1 ? L10n.tr("\(Int((spec.printDPI * min(ratio, 4)).rounded())) ppi available") : L10n.tr("Enlarged \(Int((100 / ratio).rounded()))%"))

        guard let face = analysis.face else { return checks }
        if abs(frame.tiltDegrees) >= 1 { add("tilt", L10n.tr("Tilt"), abs(frame.tiltDegrees) > 8 ? .warning : .pass, L10n.tr("Levelled \(degrees(frame.tiltDegrees))")) }
        if let yaw = face.yaw {
            add("yaw", L10n.tr("Facing camera"), abs(yaw) > 15 ? .failure : abs(yaw) > 7 ? .warning : .pass, L10n.tr("Turned \(degrees(abs(yaw)))"))
        }
        if let pitch = face.pitch, abs(pitch) > 12 {
            add("pitch", L10n.tr("Head level"), abs(pitch) > 20 ? .failure : .warning, L10n.tr("Tipped \(degrees(abs(pitch)))"))
        }
        if let open = face.eyeOpenness {
            add("eyesOpen", L10n.tr("Eyes open"), open < 0.1 ? .failure : open < 0.16 ? .warning : .pass, open < 0.1 ? L10n.tr("Closed") : open < 0.16 ? L10n.tr("Narrow") : L10n.tr("Open"))
        }
        if spec.mouthClosed, let mouth = face.mouthOpening {
            add("mouth", L10n.tr("Mouth closed"), mouth > 0.18 ? .failure : mouth > 0.08 ? .warning : .pass, mouth > 0.08 ? L10n.tr("Open") : L10n.tr("Closed"))
        }

        // What is worn.
        let labels = analysis.labels
        if (labels["sunglasses"] ?? 0) > 0.3 {
            add("glasses", L10n.tr("Glasses"), .failure, L10n.tr("Sunglasses"))
        } else if (labels["eyeglasses"] ?? 0) > 0.3 {
            switch spec.glasses {
            case .never: add("glasses", L10n.tr("Glasses"), .failure, L10n.tr("Not allowed"))
            case .discouraged: add("glasses", L10n.tr("Glasses"), .warning, L10n.tr("Remove if possible"))
            case .allowed: add("glasses", L10n.tr("Glasses"), .warning, L10n.tr("Check for glare and frames over the eyes"))
            }
        } else {
            add("glasses", L10n.tr("Glasses"), .pass, L10n.tr("None"))
        }
        // Not "hoodie": Vision can't tell a hood up from one down.
        let headwear = ["hat", "headgear", "baseball_hat", "cowboy_hat", "sunhat", "hardhat", "helmet"].map { labels[$0] ?? 0 }.max() ?? 0
        add("headwear", L10n.tr("Headwear"), headwear > 0.35 ? .failure : headwear > 0.15 ? .warning : .pass,
            headwear > 0.15 ? L10n.tr("Religious or medical only") : L10n.tr("None"))
        if (labels["headphones"] ?? 0) > 0.2 { add("headphones", L10n.tr("Headphones"), .failure, L10n.tr("Remove")) }

        // Light.
        if let side = face.sideLightStops {
            add("shadows", L10n.tr("Even light"), side > 1 ? .failure : side > 0.5 ? .warning : .pass,
                L10n.tr("\(side.formatted(.number.precision(.fractionLength(1)).locale(L10n.locale))) stops side to side"))
        }
        let exposure: IDPhotoCheck.Status = face.brightness < 0.18 || face.brightness > 0.85 || face.clipped > 0.1 ? .failure
            : face.brightness < 0.28 || face.brightness > 0.75 || face.clipped > 0.03 ? .warning : .pass
        add("exposure", L10n.tr("Face exposure"), exposure, face.clipped > 0.03 ? L10n.tr("Clipped") : face.brightness < 0.28 ? L10n.tr("Dark") : face.brightness > 0.75 ? L10n.tr("Bright") : L10n.tr("Good"))
        if let skin = face.skin, let cast = colourCast(skin: skin, wall: analysis.background?.color) {
            add("cast", L10n.tr("White balance"), cast == 0 ? .pass : .warning,
                cast > 0 ? L10n.tr("Warm") : cast < 0 ? L10n.tr("Cool") : L10n.tr("Neutral"))
        }
        if let quality = face.quality {
            add("quality", L10n.tr("Sharpness"), quality < 0.25 ? .warning : .pass, "\(Int((quality * 100).rounded()))")
        }

        if layout.background != nil { add("background", L10n.tr("Background"), .pass, L10n.tr("Replaced")) }
        else if let (color, spread) = analysis.background { checks.append(background(color: color, spread: spread, spec: spec)) }
        else { add("background", L10n.tr("Background"), .unknown, L10n.tr("Not measured")) }
        return checks
    }

    /// +1 when the light made the skin warm, −1 cool, 0 neutral. Skin alone can't tell a cast from a skin tone, so the
    /// wall behind, when it's plain enough to be meant as white or grey, has to lean the same way; a very strong
    /// lean in the skin is enough on its own. Ratios are of sRGB red to blue on the cheeks.
    static func colourCast(skin: SIMD3<Double>, wall: SIMD3<Double>?) -> Int? {
        guard skin.z > 0.02 else { return nil }
        let ratio = skin.x / skin.z
        let wallLean = wall.map { $0.x - $0.z } ?? 0   // red minus blue: warm walls are positive
        if ratio > 2.4 || ratio > 2.0 && wallLean > 0.04 { return 1 }
        if ratio < 1.0 || ratio < 1.2 && wallLean < -0.04 { return -1 }
        return 0
    }

    static func background(color: SIMD3<Double>, spread: Double, spec: IDPhotoSpec) -> IDPhotoCheck {
        let luma = Pixels.luma(color), chroma = color.max() - color.min()
        let blue = color.z > color.x + 0.04 && color.z > color.y
        var status = IDPhotoCheck.Status.pass, detail = L10n.tr("Plain")
        if spread > 0.12 { status = .failure; detail = L10n.tr("Busy") }
        else if spread > 0.06 { status = .warning; detail = L10n.tr("Uneven") }
        let wanted: Bool
        switch spec.background {
        case .white: wanted = luma > 0.85 && chroma < 0.08
        case .offWhite: wanted = luma > 0.78 && chroma < 0.12
        case .lightGrey: wanted = luma > 0.55 && luma < 0.92 && chroma < 0.08
        case .lightBlue: wanted = blue && luma > 0.45
        case .whiteOrLight: wanted = luma > 0.6 && chroma < 0.12
        }
        if !wanted && status != .failure {
            status = luma < 0.45 || chroma > 0.2 ? .failure : .warning
            detail = luma < 0.6 ? L10n.tr("Too dark") : chroma > 0.08 ? L10n.tr("Coloured") : L10n.tr("Not white")
        }
        return IDPhotoCheck(id: "background", title: L10n.tr("Background"), status: status, detail: detail)
    }
}
