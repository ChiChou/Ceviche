import SwiftUI
import CevicheCore

/// Keep Latent Image, with an ⓘ that says what that is: has a tool's outputs keep its work as a latent image
/// (`LatentPreference`). It takes the toggle style of the options it sits among.
struct LatentCheckbox: View {
    @AppStorage private var keeps: Bool
    @State private var explaining = false
    /// Told when it is ticked or unticked, for a tool that saves as it goes.
    var changed: ((Bool) -> Void)?
    init(type: String, changed: ((Bool) -> Void)? = nil) { _keeps = AppStorage(wrappedValue: false, LatentPreference.key(type)); self.changed = changed }
    var body: some View {
        HStack(spacing: 4) {
            Toggle(L10n.tr("Keep Latent Image"), isOn: $keeps).fixedSize()
                .onChange(of: keeps) { changed?(keeps) }
            Button { explaining.toggle() } label: { Image(systemName: "info.circle") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .help(L10n.tr("What is a latent image?"))
                .popover(isPresented: $explaining, arrowEdge: .bottom) {
                    Text(L10n.tr("Save this tool's settings as a new item in the catalog. You can open it anytime again to pick up where you left off."))
                        .font(.callout).fixedSize(horizontal: false, vertical: true).padding(14).frame(width: 280)
                }
        }
    }
}
