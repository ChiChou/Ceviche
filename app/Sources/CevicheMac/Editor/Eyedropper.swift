import SwiftUI
import CevicheCore

/// Tools that can take a color from the photo itself rather than the system color panel, which can sample
/// anything on screen, including colors that are not in the file.
enum EyedropperTarget: Equatable {
    case whiteBalance, pointColor, selectiveColor, printBalance
    case grading(GradingRange)
    case defringe(Defringe.Band)
    var prompt: String {
        switch self {
        case .whiteBalance: return L10n.tr("Click something that should be neutral gray")
        case .printBalance: return L10n.tr("Click something that should print neutral gray")
        case .pointColor: return L10n.tr("Click a color to target")
        case .selectiveColor: return L10n.tr("Click a color to choose its band")
        case .grading(let range): return L10n.tr("Click a color for the \(range.title.lowercased()) tint")
        case .defringe(.purple): return L10n.tr("Click a purple fringe")
        case .defringe(.green): return L10n.tr("Click a green fringe")
        }
    }
    var accessibilityLabel: String {
        if case .defringe = self { return prompt }
        return L10n.tr("Pick color from photo")
    }
    /// HSV hue in 0..<1 (0 for neutral colors).
    static func hue(_ rgb: [Double]) -> Double {
        guard rgb.count >= 3 else { return 0 }
        let r = rgb[0], g = rgb[1], b = rgb[2], high = max(r, g, b), low = min(r, g, b), delta = high - low
        guard delta > 1e-6 else { return 0 }
        var h: Double
        if high == r { h = (g - b) / delta } else if high == g { h = 2 + (b - r) / delta } else { h = 4 + (r - g) / delta }
        h /= 6
        return h < 0 ? h + 1 : h
    }
    /// The selective-color band whose center hue is circularly closest.
    static func nearestBand(hue: Double) -> Int {
        let centers = [0.0, 30, 60, 120, 180, 240, 270, 300]
        let degrees = hue * 360
        return centers.indices.min { a, b in
            func distance(_ c: Double) -> Double { let d = abs(degrees - c).truncatingRemainder(dividingBy: 360); return min(d, 360 - d) }
            return distance(centers[a]) < distance(centers[b])
        } ?? 0
    }
}

/// Arms the photo eyedropper for one tool; highlighted while waiting for the click.
struct EyedropperButton: View {
    @ObservedObject var model: EditorModel
    let target: EyedropperTarget
    var body: some View {
        let active = model.eyedropper == target
        Button { model.toggleEyedropper(target) } label: {
            Image(systemName: "eyedropper").font(.system(size: 11)).frame(width: 22, height: 20)
                .background(active ? Theme.accent.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                .foregroundStyle(active ? Theme.accent : .secondary).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!model.hasImage)
            .help(active ? L10n.tr("Cancel picking (Esc)") : target.prompt).accessibilityLabel(target.accessibilityLabel)
            .accessibilityAddTraits(active ? .isSelected : [])
    }
}

extension MaskKind {
    /// Masks computed from the whole photo when added (Object instead waits for a click).
    static let generatedOnPhoto: Set<MaskKind> = [.subject, .background, .sky, .depth, .scene, .people]
    /// The downloadable model the kind runs on; Sky also works from a RAW's embedded matte without one.
    var model: BundledModel? {
        switch self { case .depth: return .depth; case .scene: return .scene; case .sky: return .sky; default: return nil }
    }
    /// Whether this Mac can create the mask now; model-backed kinds need their model installed (Settings › Models),
    /// and Object needs the Vision segmentation that arrived with macOS 27.
    var modelAvailable: Bool {
        switch self {
        case .depth: return BundledModel.depth.isAvailable
        case .scene: return BundledModel.scene.isAvailable
        case .object: if #available(macOS 27, *) { return true } else { return false }
        default: return true
        }
    }
}
