import SwiftUI
import CevicheCore

/// The eleven zones under the zone map, each in its own grey with a bar for its share of the photo. Hovering a zone
/// picks it out on the map; clicking keeps it picked out while the sliders move. The zone under the pointer on the
/// photo is ringed.
struct ZoneStrip: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var pointer: ZonePointer
    /// The colour an isolated zone takes on the map (ZoneMap's default tint).
    static let tint = Color(.sRGB, red: 1, green: 0.8, blue: 0.1)
    private static let barHeight: CGFloat = 14

    var body: some View {
        let shares = model.zoneDisplay?.map.shares ?? Array(repeating: 0, count: ZoneMap.count)
        let largest = max(0.0001, shares.max() ?? 0)
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(0..<ZoneMap.count, id: \.self) { zone in cell(zone, share: shares[zone], largest: largest) }
            }
            Text(reading(shares)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.white.opacity(0.85))
                .frame(width: 58, alignment: .leading)
            Button(action: model.toggleZones) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.white.opacity(0.7))
                    .frame(width: 20, height: 18).contentShape(Rectangle())
            }.buttonStyle(.plain).help(L10n.tr("Hide (⌥⌘Z)")).accessibilityLabel(L10n.tr("Hide"))
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .background(Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Color.white.opacity(0.1)))
        .environment(\.colorScheme, .dark)
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .accessibilityElement(children: .contain).accessibilityLabel(L10n.tr("Zones"))
    }

    private func cell(_ zone: Int, share: Double, largest: Double) -> some View {
        let isolated = model.zoneIsolated == zone, pinned = model.zonePinned == zone, under = pointer.zone == zone
        return VStack(spacing: 3) {
            // The zone's share against the largest, so the spread across zones reads like a histogram.
            Capsule().fill(isolated ? Self.tint : Color.white.opacity(0.55))
                .frame(width: 12, height: share > 0 ? max(1.5, Self.barHeight * share / largest) : 0)
                .frame(height: Self.barHeight, alignment: .bottom)
            Text(ZoneMap.numeral(zone)).font(.system(size: 9, weight: .semibold))
                .foregroundStyle(zone >= 6 ? Color.black.opacity(0.75) : Color.white.opacity(0.8))
                .frame(width: 24, height: 18)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.tag).fill(Color(white: ZoneMap.grey(zone))))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tag)
                    .strokeBorder(isolated ? Self.tint : under ? Color.white : Color.white.opacity(0.12), lineWidth: isolated || under ? 2 : 1))
                .overlay(alignment: .bottom) {
                    // A pinned zone keeps a mark while another is hovered.
                    if pinned { Rectangle().fill(Self.tint).frame(width: 10, height: 2).offset(y: 4) }
                }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { model.zoneHovered = zone } else if model.zoneHovered == zone { model.zoneHovered = nil }
        }
        .onTapGesture { model.zonePinned = pinned ? nil : zone }
        .accessibilityElement().accessibilityLabel("\(ZoneMap.numeral(zone)) \(percent(share))")
        .accessibilityAddTraits(isolated ? [.isButton, .isSelected] : .isButton)
    }

    /// The zone hovered in the strip, else under the pointer, else pinned, with its share of the photo.
    private func reading(_ shares: [Double]) -> String {
        guard let zone = model.zoneHovered ?? pointer.zone ?? model.zonePinned else { return "" }
        return "\(ZoneMap.numeral(zone)) \(percent(shares[zone]))"
    }
    private func percent(_ share: Double) -> String {
        share > 0 && share < 0.005 ? "<1%" : String(format: "%.0f%%", locale: Locale.current, share * 100)
    }
}
