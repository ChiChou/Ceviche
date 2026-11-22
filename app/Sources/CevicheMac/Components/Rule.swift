import SwiftUI

/// A one-pixel line between areas or groups of controls. `Divider` draws one point, which reads as a heavy bar on a
/// Retina display; menus and pickers keep `Divider`, since there it becomes the system's separator item.
struct Rule: View {
    var axis: Axis = .horizontal
    @Environment(\.displayScale) private var scale
    init(_ axis: Axis = .horizontal) { self.axis = axis }
    var body: some View {
        let thickness = 1 / max(scale, 1)
        Theme.rule
            .frame(width: axis == .vertical ? thickness : nil, height: axis == .horizontal ? thickness : nil)
            .accessibilityHidden(true)
    }
}
