import MapKit
import SwiftUI
import CevicheCore

/// A photo's place in the Info panel. With coordinates it is a link: clicking it floats a small map beside the
/// panel, which goes away with a click anywhere else.
struct PlaceLink: View {
    let place: String
    let coordinate: CLLocationCoordinate2D?
    @State private var showing = false
    @State private var hovering = false
    var body: some View {
        if let coordinate {
            Button { showing.toggle() } label: {
                HStack(spacing: 4) {
                    Text(place).underline(hovering).multilineTextAlignment(.leading)
                    Image(systemName: "mappin.and.ellipse").imageScale(.small).foregroundStyle(.tertiary)
                }.font(.caption).foregroundStyle(.secondary).contentShape(Rectangle())
            }
            .buttonStyle(.plain).onHover { hovering = $0 }
            .help(L10n.tr("Show on Map")).accessibilityHint(L10n.tr("Show on Map"))
            .popover(isPresented: $showing, arrowEdge: .leading) { PlaceMapCard(place: place, coordinate: coordinate) { showing = false } }
        } else {
            Text(place).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}

/// The map itself, with what there is to do with a place: copy its name, open it in Maps, or close.
private struct PlaceMapCard: View {
    let place: String
    let coordinate: CLLocationCoordinate2D
    let dismiss: () -> Void
    @State private var copied = false
    private var text: String { String(format: "%.6f, %.6f", locale: Locale(identifier: "en_US_POSIX"), coordinate.latitude, coordinate.longitude) }
    var body: some View {
        VStack(spacing: 0) {
            Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 3000, longitudinalMeters: 3000))) {
                Marker(place, coordinate: coordinate)
            }
            .frame(width: 300, height: 210)
            HStack(spacing: 2) {
                Text(verbatim: text).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
                Spacer(minLength: 8)
                icon(copied ? "checkmark" : "doc.on.doc", L10n.tr("Copy Location")) {
                    // The place by name, as it reads in the panel; the coordinates beside this can be selected.
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(place, forType: .string)
                    copied = true
                }
                icon("map", L10n.tr("Open in Maps")) {
                    let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate)); item.name = place
                    item.openInMaps(launchOptions: [MKLaunchOptionsMapCenterKey: NSValue(mkCoordinate: coordinate)])
                    dismiss()
                }
                icon("xmark", L10n.tr("Close"), action: dismiss).keyboardShortcut(.cancelAction)
            }
            // Opened by a click: no ring around the first button, as if it had been tabbed to.
            .padding(.leading, 10).padding(.trailing, 4).frame(height: 32).focusEffectDisabled()
        }
    }
    private func icon(_ name: String, _ title: String, action: @escaping () -> Void) -> IconButton {
        IconButton(name, title, pointSize: 12, size: CGSize(width: 26, height: 26), action: action)
    }
}
