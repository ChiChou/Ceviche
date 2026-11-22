import SwiftUI

/// Shared field chrome; the native TextField still owns editing, formatting, selection and focus.
struct FormFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.textFieldStyle(.plain).modifier(FormFieldSurface())
    }
}

private struct FormFieldSurface: ViewModifier {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlSize) private var size
    func body(content: Content) -> some View {
        content.padding(.horizontal, 8).padding(.vertical, size == .mini || size == .small ? 3 : 5)
            .frame(minHeight: Theme.controlHeight(size))
            .background(Theme.ink.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .opacity(enabled ? 1 : 0.45)
    }
}

extension View {
    /// Also wraps compound fields, such as a numeric value with a unit suffix.
    func formFieldSurface() -> some View { modifier(FormFieldSurface()) }
}

extension TextFieldStyle where Self == FormFieldStyle {
    static var formField: FormFieldStyle { FormFieldStyle() }
}

/// A single value in a form. The inline Picker owns checked selection and disabled choices;
/// commands belong in ActionMenu, never in a synthetic selection value.
struct FormSelect<Value: Hashable, Options: View>: View {
    let title: String
    @Binding var selection: Value
    let valueLabel: String
    var expands = true
    var icon: String?
    @ViewBuilder let options: Options
    init(_ title: String, selection: Binding<Value>, valueLabel: String, expands: Bool = true, icon: String? = nil,
         @ViewBuilder content: () -> Options) {
        self.title = title; _selection = selection; self.valueLabel = valueLabel
        self.expands = expands; self.icon = icon; options = content()
    }
    var body: some View {
        Menu {
            Picker(title, selection: $selection) { options }.pickerStyle(.inline).labelsHidden()
        } label: {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon) }
                MenuCaption(text: valueLabel, expands: expands)
            }
        }
        .menuStyle(.button).buttonStyle(FormSelectStyle()).menuIndicator(.hidden).nativeMenuItems()
        .fixedSize(horizontal: !expands, vertical: true)
        .accessibilityLabel(title).accessibilityValue(valueLabel)
    }
}

extension View {
    /// A menu's items as the system draws them. A menu's choices are toggles, and a toggle style set around the menu
    /// (as `ToolOptionsBar` sets `.formCheckbox`) reaches into it; a native menu can't draw a custom style, so its items
    /// would show only the tick, with no title.
    func nativeMenuItems() -> some View { toggleStyle(.automatic) }
}

/// Commands act on a target; their caption does not represent a selected form value.
struct ActionMenu<Actions: View>: View {
    let title: String
    var icon: String?
    @ViewBuilder let actions: Actions
    init(_ title: String, icon: String? = nil, @ViewBuilder content: () -> Actions) {
        self.title = title; self.icon = icon; actions = content()
    }
    var body: some View {
        Menu { actions.buttonStyle(.borderless) } label: {
            if let icon { Image(systemName: icon) }
            else { MenuCaption(text: title, expands: false) }
        }
            .menuStyle(.button).buttonStyle(.secondaryAction).menuIndicator(.hidden).nativeMenuItems()
            .fixedSize().accessibilityLabel(title)
    }
}

private struct MenuCaption: View {
    let text: String
    let expands: Bool
    var body: some View {
        HStack(spacing: 6) {
            Text(text).lineLimit(1)
            if expands { Spacer(minLength: 0) }
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary).accessibilityHidden(true)
        }.frame(maxWidth: expands ? .infinity : nil)
    }
}

/// Independent on/off options; SwiftUI Toggle retains keyboard and accessibility semantics.
struct FormCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(isOn: configuration.$isOn) { configuration.label }
            .toggleStyle(.checkbox).tint(Theme.controlAccent).controlSize(.small)
    }
}
extension ToggleStyle where Self == FormCheckboxStyle {
    static var formCheckbox: FormCheckboxStyle { FormCheckboxStyle() }
}

/// A discrete number/index with an adjacent readout, not a free-form text field.
struct FormStepper<Readout: View>: View {
    let title: String
    @Binding var value: Int
    let bounds: ClosedRange<Int>
    var step = 1
    @ViewBuilder let readout: Readout
    init(_ title: String, value: Binding<Int>, in bounds: ClosedRange<Int>, step: Int = 1,
         @ViewBuilder label: () -> Readout) {
        self.title = title; _value = value; self.bounds = bounds; self.step = step; readout = label()
    }
    var body: some View {
        HStack(spacing: 8) {
            readout.frame(maxWidth: .infinity, alignment: .leading)
            Stepper(title, value: $value, in: bounds, step: step).labelsHidden().fixedSize()
                .accessibilityLabel(title)
        }.padding(.horizontal, 8).padding(.vertical, 4)
            .background(Theme.ink.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
    }
}

/// Form values use regular text and field insets; command menus retain action-button emphasis.
struct FormSelectStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlSize) private var size
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12)).foregroundStyle(.primary)
            .padding(.horizontal, 8).padding(.vertical, 4).frame(minHeight: Theme.controlHeight(size))
            .background(Theme.ink.opacity(configuration.isPressed ? 0.14 : 0.07), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .opacity(enabled ? 1 : 0.4).contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
    }
}

