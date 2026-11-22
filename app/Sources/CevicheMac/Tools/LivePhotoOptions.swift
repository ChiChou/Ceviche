import SwiftUI
import CevicheCore

/// The Live Photo size presets, each named with the still it makes from a frame of `ratio` cut from `photo`.
struct LivePhotoSizeRow: View {
    @Binding var settings: TimelapseSettings
    let ratio: Double
    let photo: CGSize?
    var body: some View {
        ExportRow(L10n.tr("Size")) {
            FormSelect(L10n.tr("Size"), selection: $settings.livePhotoSize, valueLabel: label(settings.livePhotoSize)) {
                ForEach(LivePhotoSize.allCases) { Text(label($0)).tag($0) }
            }.labelsHidden()
                .help(L10n.tr("The still’s size; the movie stays at 1080p or less"))
        }
    }
    private func label(_ preset: LivePhotoSize) -> String {
        let still = CatalogModel.livePhotoSizes(ratio: ratio, crop: settings.crop, preset: preset, photo: photo).still
        return "\(preset.title) - \(Int(still.width)) × \(Int(still.height))"
    }
}

/// Photos' LIVE badge, for a preview's top-left corner.
struct LivePhotoBadge: View {
    var body: some View {
        Label(L10n.tr("LIVE"), systemImage: "livephoto")
            .font(.system(size: 11, weight: .semibold)).tracking(0.6)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.black.opacity(0.45), in: Capsule()).foregroundStyle(.white)
            .padding(10).allowsHitTesting(false)
    }
}
