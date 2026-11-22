import SwiftUI
import CevicheCore

/// Choose the region a Scene mask selects; Create makes it. Shown in the Masks panel under the ways to add a mask,
/// as People's choice is.
struct SceneMaskChooser: View {
    @ObservedObject var model: EditorModel
    let target: PeopleMaskTarget
    let dismiss: () -> Void
    @State private var scene: SceneCategory = .vegetation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(MaskKind.scene.localizedTitle).font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(SceneCategory.allCases, id: \.self) { category in
                    Toggle(category.localizedTitle, isOn: Binding(get: { scene == category }, set: { if $0 { scene = category } }))
                        .toggleStyle(.formCheckbox)
                }
            }
            HStack {
                Spacer()
                Button(L10n.tr("Cancel"), action: dismiss).buttonStyle(.secondaryAction).controlSize(.small)
                Button(L10n.tr("Create")) { create() }.buttonStyle(.secondaryAction).controlSize(.small)
            }
        }
        .font(.system(size: 12)).padding(14).card()
    }

    private func create() {
        dismiss()
        switch target {
        case .newMask: model.addMask(.scene, scene: scene)
        case .component(let operation): model.addComponent(.scene, operation: operation, scene: scene)
        }
    }
}
