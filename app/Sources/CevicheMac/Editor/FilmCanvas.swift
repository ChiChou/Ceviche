import SwiftUI
import CevicheCore

/// Over the canvas while Darkroom prints a film: the view picker, and the strip or ring-around in place of the photo.
/// Clicking a band or a print takes its setting and centres the next one on it, as on the darkroom bench. The ring
/// is there for a medium that takes a color balance.
struct PrintCanvas: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        ZStack {
            if model.eyedropper == nil {
                switch model.printView {
                case .photo: Color.clear.allowsHitTesting(false)
                case .strip: PrintStrip(model: model).background(Theme.imageSurround)
                case .ring:
                    if model.adjustments.film?.output?.hasBalance == true { PrintRing(model: model).background(Theme.imageSurround) }
                    else { Color.clear.allowsHitTesting(false) }
                }
                VStack { PrintViewBar(model: model); Spacer() }.padding(.top, 18)
            }
        }
    }
}

private struct PrintViewBar: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        PhotoBar {
            let balanced = model.adjustments.film?.output?.hasBalance == true
            ForEach(EditorModel.PrintView.allCases.filter { $0 != .ring || balanced }, id: \.self) { view in
                PhotoBarChoice(title: L10n.key(view.rawValue), selected: model.printView == view) { model.printView = view }
            }
            if model.printView == .strip || (model.printView == .ring && balanced) {
                PhotoBarDivider()
                if model.printView == .strip {
                    ForEach(EditorModel.printStripSteps, id: \.self) { step in
                        PhotoBarChoice(title: Self.stops(step), selected: model.printStripStep == step) { model.printStripStep = step }
                    }
                } else {
                    ForEach(EditorModel.printRingSteps, id: \.self) { step in
                        PhotoBarChoice(title: String(format: "%.0f CC", locale: Locale.current, step), selected: model.printRingStep == step) { model.printRingStep = step }
                    }
                }
            }
        }
    }
    static func stops(_ step: Double) -> String {
        switch step { case 1.0 / 3: return "⅓ EV"; case 0.5: return "½ EV"; default: return String(format: "%g EV", locale: Locale.current, step) }
    }
}

/// What a proof is rendered from: a new one is made when any of it changes.
private struct ProofKey: Equatable {
    var adjustments: Adjustments
    var step: Double
    var size: Double
}

/// The photo printed in five bands, two steps either side of the current exposure.
private struct PrintStrip: View {
    @ObservedObject var model: EditorModel
    @State private var image: CGImage?
    @State private var rendering = false
    private var steps: [Double] { [-2.0, -1, 0, 1, 2].map { $0 * model.printStripStep } }
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 8) {
                Spacer(minLength: 64)
                if let image {
                    let aspect = Double(image.width) / Double(image.height)
                    let width = min(geometry.size.width - 48, (geometry.size.height - 120) * aspect)
                    Image(decorative: image, scale: 1).resizable().aspectRatio(aspect, contentMode: .fit).frame(width: width)
                        .overlay { bands }
                    HStack(spacing: 0) {
                        ForEach(steps, id: \.self) { step in
                            Text(label(step)).font(.system(size: 11, weight: step == 0 ? .semibold : .regular)).monospacedDigit()
                                .foregroundStyle(step == 0 ? .primary : .secondary).frame(maxWidth: .infinity)
                        }
                    }.frame(width: width)
                }
                Spacer(minLength: 24)
            }.frame(maxWidth: .infinity)
            .overlay { if image == nil || rendering { ProgressView().controlSize(.small) } }
        }
        .task(id: ProofKey(adjustments: model.displayAdjustments, step: model.printStripStep, size: 0)) { await render() }
    }
    private func render() async {
        // A film under the pointer is proofed too, as the photo view shows it.
        let snapshot = model.displayAdjustments
        var shared = snapshot; shared.film?.printExposure = 0
        let center = snapshot.film?.printExposure ?? 0
        let exposures = steps.map { min(5, max(-5, center + $0)) }, keys = exposures.map { Int(($0 * 1000).rounded()) }
        // The model keeps whole prints by exposure while everything else about the photo stays (`FilmProofs`), so a
        // step along the strip prints only the exposures the last strips lacked.
        if shared != model.filmProofs.stripBase {
            // A change the prints share (a slider being dragged) waits for a pause, then starts afresh.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            model.filmProofs.startStrip(shared)
        }
        let missing = Array(Set(keys.filter { model.filmProofs.strip.peek($0) == nil }))
        if !missing.isEmpty {
            rendering = true
            let images = await model.filmPrints(snapshot, exposures: missing.map { Double($0) / 1000 })
            guard !Task.isCancelled, model.filmProofs.stripBase == shared, images.count == missing.count else { rendering = false; return }
            for (key, print) in zip(missing, images) { model.filmProofs.keep(print, exposure: key) }
        }
        model.filmProofs.use(exposures: keys)
        let prints = keys.compactMap { model.filmProofs.strip.peek($0) }
        image = prints.count == keys.count ? Self.strip(prints) : nil
        rendering = false
    }
    /// Band i of the strip cut from print i.
    private static func strip(_ prints: [CGImage]) -> CGImage? {
        guard let first = prints.first, let space = first.colorSpace,
              let context = CGContext(data: nil, width: first.width, height: first.height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let width = Double(first.width), height = Double(first.height)
        for (index, print) in prints.enumerated() {
            let left = (width * Double(index) / Double(prints.count)).rounded(), right = (width * Double(index + 1) / Double(prints.count)).rounded()
            context.saveGState()
            context.clip(to: CGRect(x: left, y: 0, width: right - left, height: height))
            context.draw(print, in: CGRect(x: 0, y: 0, width: width, height: height))
            context.restoreGState()
        }
        return context.makeImage()
    }
    private var bands: some View {
        HStack(spacing: 0) {
            ForEach(steps, id: \.self) { step in
                Button { choose(step) } label: { Rectangle().fill(.clear).contentShape(Rectangle()) }.buttonStyle(.plain)
                    .overlay(alignment: .leading) { if step != steps.first { Rectangle().fill(.white.opacity(0.5)).frame(width: 1) } }
                    .help(label(step)).accessibilityLabel(label(step))
            }
        }
    }
    private func label(_ step: Double) -> String { String(format: "%+.1f EV", locale: Locale.current, (model.adjustments.film?.printExposure ?? 0) + step) }
    private func choose(_ step: Double) {
        guard step != 0 else { return }
        model.editFilm { $0.printExposure = min(3, max(-3, $0.printExposure + step)) }
    }
}

/// Nine prints: Y across, M down, the current filtration in the middle. Prints are kept by their filtration, so
/// moving the centre to a neighbour renders only the prints it doesn't share with the last ring.
private struct PrintRing: View {
    @ObservedObject var model: EditorModel
    /// A print's absolute filtration, and what every print shares: the photo's settings without the filtration and the
    /// render size. The model keeps the prints (`FilmProofs`).
    private typealias Cell = EditorModel.FilmProofs.Balance
    private typealias Base = EditorModel.FilmProofs.RingBase
    private var prints: LRUCache<Cell, CGImage> { model.filmProofs.ring }
    @State private var rendering = false
    @State private var aspect = 1.5
    private var cells: [Cell] {
        let film = model.adjustments.film, step = model.printRingStep
        return [1.0, 0, -1].flatMap { m in [-1.0, 0, 1].map { y in
            Cell(yellow: min(50, max(-50, (film?.yellow ?? 0) + y * step)), magenta: min(50, max(-50, (film?.magenta ?? 0) + m * step)))
        } }
    }
    var body: some View {
        GeometryReader { geometry in
            let spacing = 10.0
            // Cells fit three across and three down below the view bar, with room for their labels.
            let width = min((geometry.size.width - 48 - 2 * spacing) / 3, (geometry.size.height - 110 - 2 * spacing - 3 * 18) / 3 * aspect)
            // Rendered at twice the cell for Retina, in 100-pixel steps so small resizes reuse the prints.
            let size = max(200, (width * 2 / 100).rounded(.up) * 100)
            VStack {
                Spacer(minLength: 64)
                Grid(horizontalSpacing: spacing, verticalSpacing: spacing) {
                    ForEach(0..<3, id: \.self) { row in
                        GridRow { ForEach(0..<3, id: \.self) { column in cell(row * 3 + column, width: width) } }
                    }
                }
                Spacer(minLength: 24)
            }.frame(maxWidth: .infinity)
            .task(id: ProofKey(adjustments: model.displayAdjustments, step: model.printRingStep, size: size)) { await render(size: size) }
        }
    }
    private func render(size: Double) async {
        // A film under the pointer is proofed too, as the photo view shows it.
        let snapshot = model.displayAdjustments
        var shared = snapshot; shared.film?.yellow = 0; shared.film?.magenta = 0
        let next = Base(adjustments: shared, size: size)
        if next != model.filmProofs.ringBase {
            // A change the prints share (a slider being dragged) waits for a pause, then starts the ring afresh.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            model.filmProofs.startRing(next)
        }
        let cells = self.cells
        model.filmProofs.use(balances: cells)
        let missing = Array(Set(cells.filter { prints.peek($0) == nil }))
        guard !missing.isEmpty else { return }
        rendering = true
        let images = await model.filmRingAround(snapshot, filtrations: missing.map { ($0.yellow, $0.magenta) }, size: size)
        guard !Task.isCancelled, model.filmProofs.ringBase == next, images.count == missing.count else { rendering = false; return }
        // The last few rings stay, for stepping back and forth.
        for (cell, image) in zip(missing, images) { model.filmProofs.keep(image, balance: cell) }
        if let first = images.first { aspect = Double(first.width) / Double(first.height) }
        rendering = false
    }
    private func cell(_ index: Int, width: Double) -> some View {
        let cell = cells[index]
        return Button { choose(cell) } label: {
            VStack(spacing: 4) {
                Group {
                    if let image = prints.peek(cell) {
                        Image(decorative: image, scale: 1).resizable().aspectRatio(aspect, contentMode: .fit)
                    } else {
                        Rectangle().fill(Theme.ink.opacity(0.06)).aspectRatio(aspect, contentMode: .fit).overlay { ProgressView().controlSize(.small) }
                    }
                }
                .frame(width: max(0, width))
                .overlay(Rectangle().strokeBorder(index == 4 ? Theme.accent : .clear, lineWidth: 2))
                Text(label(cell)).font(.system(size: 11, weight: index == 4 ? .semibold : .regular)).monospacedDigit()
                    .foregroundStyle(index == 4 ? .primary : .secondary)
            }
        }.buttonStyle(.plain).disabled(index == 4).accessibilityLabel(label(cell))
    }
    private func label(_ cell: Cell) -> String { String(format: "Y %+.0f  M %+.0f", locale: Locale.current, cell.yellow, cell.magenta) }
    private func choose(_ cell: Cell) { model.editFilm { $0.yellow = cell.yellow; $0.magenta = cell.magenta } }
}
