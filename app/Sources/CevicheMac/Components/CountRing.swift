import SwiftUI
import CevicheCore

/// How far along a count is, as a ring with "done/total" inside: the culling tools' progress while photos are measured.
/// From a thousand photos the count no longer fits a small ring, so it shows the percentage and keeps the count in its
/// help.
struct CountRing: View, Equatable {
    let done: Int
    let total: Int
    /// Across, in points: 30 in a title bar, larger on its own.
    var size: CGFloat = 30

    private var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
    private var line: CGFloat { max(2.5, size / 14) }

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.25), lineWidth: line)
            Circle().trim(from: 0, to: max(0.02, fraction))
                .stroke(Theme.controlAccent, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.2), value: fraction)
            Text(total < 1000 ? "\(done)/\(total)" : "\(Int(fraction * 100))%")
                .font(.system(size: size * 0.3, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.4)
                .padding(.horizontal, line + size * 0.08)
        }
        .frame(width: size, height: size)
        .help(L10n.tr("\(done.formatted()) of \(total.formatted()) photos"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.tr("\(done.formatted()) of \(total.formatted()) photos"))
    }
}
