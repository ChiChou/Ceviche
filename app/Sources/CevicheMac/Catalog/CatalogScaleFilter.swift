import SwiftUI
import CevicheCore

/// A scale engraved like a lens barrel's, for focal length (`CatalogFocalFilter.ticks`) and the exposure settings
/// (`CatalogExposureScale.ticks`): numbers over hairlines, dots between. Two index marks under the scale snap
/// to any tick and light the ticks between them; double-click a tick to pick it alone. `range` holds the tick values, nil for all.
struct CatalogScaleFilter: View {
    let ticks: [CatalogScaleTick]
    @Binding var range: ClosedRange<Int>?
    /// What the scale filters, and how a range of it reads.
    let title: String
    let describe: (ClosedRange<Int>) -> String
    @State private var dragging: Handle?
    @State private var pointer: CGFloat = 0
    private enum Handle { case lower, upper }
    private let inset: CGFloat = 8
    /// Where the ticks end, with the numbers above and the handles below.
    private let baseline: CGFloat = 20

    private var all: ClosedRange<Int> { 0...(ticks.count - 1) }
    private var selection: ClosedRange<Int> {
        guard let range else { return all }
        let lower = ticks.firstIndex { $0.value >= range.lowerBound } ?? all.upperBound
        let upper = ticks.lastIndex { $0.value <= range.upperBound } ?? all.lowerBound
        return min(lower, upper)...max(lower, upper)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            GeometryReader { geometry in
                let width = geometry.size.width
                let selected = selection
                let refined = selected != all
                Canvas { context, _ in
                    // The numbers, kept inside the scale at its ends. Without room for all, every second (third…)
                    // numbered stop keeps its number, with both ends always; the others become dots.
                    let labelled = ticks.indices.filter { ticks[$0].label != nil }
                    var frames: [Int: (text: GraphicsContext.ResolvedText, frame: CGRect)] = [:]
                    for index in labelled {
                        let on = refined && selected.contains(index)
                        let text = context.resolve(Text(verbatim: ticks[index].label!).font(.system(size: 9)).monospacedDigit()
                            .foregroundColor(on ? Theme.accent : Theme.ink.opacity(0.6)))
                        let size = text.measure(in: CGSize(width: width, height: 20))
                        let centre = min(max(x(index, width), size.width / 2), width - size.width / 2)
                        frames[index] = (text, CGRect(x: centre - size.width / 2, y: baseline - 12 - size.height / 2, width: size.width, height: size.height))
                    }
                    func numbered(every step: Int) -> [Int] {
                        guard let last = labelled.last else { return [] }
                        var kept = stride(from: 0, to: labelled.count, by: step).map { labelled[$0] }
                        if kept.last != last { kept.append(last) }
                        return kept
                    }
                    func fits(_ kept: [Int]) -> Bool {
                        zip(kept, kept.dropFirst()).allSatisfy { a, b in frames[a]!.frame.maxX + 4 <= frames[b]!.frame.minX }
                    }
                    var kept = numbered(every: 1), step = 1
                    while !fits(kept), step < labelled.count {
                        step += 1; kept = numbered(every: step)
                        // The last number crowding the one before it gives way, not the end.
                        if !fits(kept), kept.count > 2 { let trimmed = Array(kept.dropLast(2)) + [kept.last!]; if fits(trimmed) { kept = trimmed } }
                    }
                    let shown = Set(kept)
                    // Engraved like an aperture ring: a hairline under each number, dots between.
                    for index in ticks.indices {
                        let at = x(index, width)
                        let on = refined && selected.contains(index)
                        let hairline = shown.contains(index)
                        let ink = on ? Theme.accent : Theme.ink.opacity(hairline ? 0.45 : 0.3)
                        if hairline {
                            context.fill(Path(CGRect(x: at - 0.5, y: baseline - 5, width: 1, height: 5)), with: .color(ink))
                            if let label = frames[index] { context.draw(label.text, in: label.frame) }
                        } else {
                            context.fill(Path(ellipseIn: CGRect(x: at - 0.75, y: baseline - 1.5, width: 1.5, height: 1.5)), with: .color(ink))
                        }
                    }
                    // The handles: short index marks under the scale, as on the lens's mount.
                    for index in [selected.lowerBound, selected.upperBound] {
                        context.fill(Path(roundedRect: CGRect(x: x(index, width) - 0.75, y: baseline + 3, width: 1.5, height: 6), cornerRadius: 0.75),
                                     with: .color(refined ? Theme.accent : Theme.ink.opacity(0.7)))
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        pointer = value.location.x
                        let index = nearest(value.location.x, width)
                        let current = selection
                        let handle = dragging ?? grab(value.startLocation.x, width, current, moving: index)
                        dragging = handle
                        let moved: ClosedRange<Int>
                        switch handle {
                        case .lower: moved = min(index, current.upperBound)...current.upperBound
                        case .upper: moved = current.lowerBound...max(index, current.lowerBound)
                        }
                        if moved != current { detent(handle == .lower ? moved.lowerBound : moved.upperBound) }
                        set(moved)
                    }
                    .onEnded { _ in dragging = nil })
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    let index = nearest(pointer, width)
                    set(selection == index...index ? all : index...index)
                })
            }
            .frame(height: baseline + 11)
            Button { set(all) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help(L10n.tr("Show All Photos"))
                .opacity(selection == all ? 0 : 1).disabled(selection == all)
                .padding(.top, baseline - 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(selection == all ? L10n.tr("All") : label(selection))
        .accessibilityAdjustableAction { direction in
            let current = selection
            switch direction {
            case .increment: set(current.lowerBound...min(current.upperBound + 1, all.upperBound))
            case .decrement: set(current.lowerBound...max(current.upperBound - 1, current.lowerBound))
            @unknown default: break
            }
        }
    }
    private func fraction(_ index: Int) -> CGFloat { CGFloat(ticks[index].position) }
    private func x(_ index: Int, _ width: CGFloat) -> CGFloat { inset + fraction(index) * (width - inset * 2) }
    private func nearest(_ position: CGFloat, _ width: CGFloat) -> Int {
        ticks.indices.min { abs(x($0, width) - position) < abs(x($1, width) - position) } ?? 0
    }
    /// The handle nearer the press; with both on one tick, the one on the side the pointer moves to.
    private func grab(_ start: CGFloat, _ width: CGFloat, _ current: ClosedRange<Int>, moving index: Int) -> Handle {
        if current.lowerBound == current.upperBound { return index < current.lowerBound ? .lower : .upper }
        return abs(start - x(current.lowerBound, width)) <= abs(start - x(current.upperBound, width)) ? .lower : .upper
    }
    /// A click on a Force Touch trackpad as a handle snaps to a tick, firmer on a numbered one, like a ring's detents.
    private func detent(_ index: Int) {
        NSHapticFeedbackManager.defaultPerformer.perform(ticks[index].label != nil ? .levelChange : .alignment, performanceTime: .now)
    }
    private func set(_ range: ClosedRange<Int>) {
        let updated = range == all ? nil : ticks[range.lowerBound].value...ticks[range.upperBound].value
        if updated != self.range { self.range = updated }
    }
    private func label(_ range: ClosedRange<Int>) -> String { describe(ticks[range.lowerBound].value...ticks[range.upperBound].value) }
}
