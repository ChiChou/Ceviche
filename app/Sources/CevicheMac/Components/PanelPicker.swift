import SwiftUI
import CevicheCore

/// Array-backed convenience for a single panel value. Uses the same selection component as
/// forms while keeping compact sizing and optional icons; command menus use ActionMenu.
struct PanelPicker<Value: Hashable>: View {
    /// Spoken by accessibility; not shown.
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String
    var icon: ((Value) -> String)? = nil
    /// Fills the width it is given instead of hugging the current choice.
    var expands = false

    var body: some View {
        FormSelect(title, selection: $selection, valueLabel: label(selection), expands: expands, icon: icon?(selection)) {
            ForEach(options, id: \.self) { value in
                if let icon { Label(label(value), systemImage: icon(value)).tag(value) }
                else { Text(label(value)).tag(value) }
            }
        }
    }
}
