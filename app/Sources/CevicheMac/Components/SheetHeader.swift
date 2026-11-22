import SwiftUI

/// The title line of a tool sheet: the title and what it works on side by side on one baseline, as compact as a window
/// title, so the sheet's height goes to its content. `accessory` follows the subtitle (a progress bar while measuring).
struct SheetHeader<Accessory: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1).layoutPriority(1)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            accessory.alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Spacer(minLength: 0)
        }
    }
}

extension SheetHeader where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil) { self.init(title: title, subtitle: subtitle) { EmptyView() } }
}
