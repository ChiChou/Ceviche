import CevicheCore
import SwiftUI

/// Pick and reject share one shape, a flag, so only the mark cut into its banner differs.
/// Both stay neutral: a lit flag is white, an unset one is dim grey, and the check or cross
/// is punched out so the surface shows through whatever the icon sits on.
struct ReviewFlag: View {
    var state: ReviewState
    var active: Bool
    var size: CGFloat = 11
    /// Draws the flag in this color instead of the text colors.
    var color: Color? = nil
    var body: some View {
        ZStack {
            Image(systemName: "flag.fill").font(.system(size: size))
            Image(systemName: state == .rejected ? "xmark" : "checkmark")
                .font(.system(size: size * 0.46, weight: .heavy))
                .offset(x: size * 0.14, y: -size * 0.16)
                .blendMode(.destinationOut)
        }.compositingGroup()
            .foregroundStyle(color ?? (active ? Color.primary : Color.secondary.opacity(0.7)))
    }
}
