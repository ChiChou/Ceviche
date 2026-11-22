import SwiftUI

/// The outline of a selected or open photo: a ring in `color` with a line of the canvas between it and the photo, so it
/// reads on any photo. A bare stroke on the photo's edge vanishes into a white sky (light ring) or a black frame (dark
/// ring); the canvas line keeps one side of the ring against something it contrasts with.
///
/// `outside` draws it beyond the photo's bounds, for grids that leave room around each photo; edge-to-edge strips
/// (the wall, the filmstrip) draw it inside.
struct SelectionRing: ViewModifier {
    let color: Color?
    var outside = false
    var width: CGFloat = 2
    func body(content: Content) -> some View {
        content.overlay {
            if let color {
                let gap: CGFloat = outside ? 3 : 1.5
                ZStack {
                    Rectangle().inset(by: outside ? -gap : width).strokeBorder(Theme.canvas, lineWidth: gap)
                    Rectangle().inset(by: outside ? -(gap + width) : 0).strokeBorder(color, lineWidth: width)
                }
                .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    func selectionRing(_ color: Color?, outside: Bool = false, width: CGFloat = 2) -> some View {
        modifier(SelectionRing(color: color, outside: outside, width: width))
    }
    /// A card: the quiet fill and the hairline, at the card radius.
    func card() -> some View {
        background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.hairline))
    }
}
