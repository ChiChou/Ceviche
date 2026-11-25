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
