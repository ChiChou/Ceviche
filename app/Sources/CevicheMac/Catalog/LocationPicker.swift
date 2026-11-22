import MapKit
import SwiftUI
import CevicheCore

/// Places photos on a map by hand: pick a place from the suggestions while typing, type coordinates, or click the
/// map to put the pin. The
/// location is marked as set in Ceviche, as one an AI client writes is.
struct LocationPicker: View {
    @ObservedObject var model: CatalogModel
    let targets: [CatalogAsset]
    @Environment(\.dismiss) private var dismiss
    @State private var pin: CLLocationCoordinate2D?
    @State private var position: MapCameraPosition = .automatic
    @State private var query = ""
    @StateObject private var completer = PlaceCompleter()
    /// The suggestion Return chooses, moved with the arrow keys.
    @State private var highlighted = 0
    /// Resolving a chosen suggestion to its coordinates.
    @State private var resolving: MKLocalSearch?
    /// The field was filled with a chosen suggestion's name, which is not a new query.
    @State private var filling = false
    private var located: Bool { targets.contains { $0.latitude != nil } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("", text: $query, prompt: Text(L10n.tr("Place or latitude, longitude")))
                    .textFieldStyle(.plain)
                    .onChange(of: query) {
                        highlighted = 0
                        if filling { filling = false; return }
                        if Self.coordinate(query) != nil { completer.clear() } else { completer.update(query) }
                    }
                    .onSubmit(submit)
                    .onKeyPress(.downArrow) { move(1) }
                    .onKeyPress(.upArrow) { move(-1) }
                if resolving != nil { ProgressView().controlSize(.small) }
                else if completer.empty { Text(L10n.tr("No Results")).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 12).frame(height: 36)
            Divider()
            ZStack(alignment: .topLeading) {
                MapReader { proxy in
                    Map(position: $position) {
                        if let pin { Marker("", coordinate: pin) }
                    }
                    .onTapGesture { point in if let coordinate = proxy.convert(point, from: .local) { pin = coordinate; completer.clear() } }
                    .onMapCameraChange(frequency: .onEnd) { completer.bias(to: $0.region) }
                }
                if !completer.results.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(completer.results.enumerated()), id: \.offset) { index, item in
                            Button { choose(item) } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title).font(.callout)
                                    if !item.subtitle.isEmpty { Text(item.subtitle).font(.caption).foregroundStyle(.secondary) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 6)
                                .background(index == highlighted ? Theme.accent.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain).onHover { if $0 { highlighted = index } }
                        }
                    }
                    .padding(4)
                    .frame(width: 340).background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                    .padding(10)
                }
            }
            .frame(minWidth: 640, minHeight: 440)
            Divider()
            HStack(spacing: 8) {
                // Apart from Cancel and Set, so it is never pressed for one of them.
                if located {
                    Button(L10n.tr("Remove Location"), role: .destructive) { apply(nil) }.buttonStyle(.textLink(Theme.error))
                }
                if let pin {
                    Text(verbatim: Self.text(pin)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Button(L10n.tr("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.secondaryAction)
                Button(L10n.tr("Set")) { if let pin { apply((pin.latitude, pin.longitude)) } }
                    .keyboardShortcut(.defaultAction).buttonStyle(.primaryAction).disabled(pin == nil)
            }
            .padding(12)
        }
        .background(Theme.panel)
        .task {
            // The photos' own location gets the pin; one borrowed from a photo taken around then only centers the map.
            guard let start = await model.startingLocation(for: targets) else { return }
            let center = CLLocationCoordinate2D(latitude: start.latitude, longitude: start.longitude)
            if located { pin = center }
            position = .region(MKCoordinateRegion(center: center, latitudinalMeters: located ? 3000 : 20000, longitudinalMeters: located ? 3000 : 20000))
        }
    }

    private func apply(_ location: (latitude: Double, longitude: Double)?) {
        let ids = targets.map(\.id)
        Task { await model.setLocation(location, assetIDs: ids); dismiss() }
    }
    private func move(_ step: Int) -> KeyPress.Result {
        guard !completer.results.isEmpty else { return .ignored }
        highlighted = (highlighted + step + completer.results.count) % completer.results.count
        return .handled
    }
    /// Return: typed coordinates go straight to the pin; otherwise the highlighted suggestion is chosen.
    private func submit() {
        if let coordinate = Self.coordinate(query) { place(coordinate); return }
        if completer.results.indices.contains(highlighted) { choose(completer.results[highlighted]) }
    }
    /// A suggestion has no coordinates; one search for it finds them. Choosing again cancels the search before.
    private func choose(_ completion: MKLocalSearchCompletion) {
        resolving?.cancel()
        let search = MKLocalSearch(request: MKLocalSearch.Request(completion: completion))
        resolving = search
        filling = query != completion.title; query = completion.title
        completer.clear()
        search.start { response, _ in
            guard resolving === search else { return }
            resolving = nil
            if let coordinate = response?.mapItems.first?.placemark.coordinate { place(coordinate) }
        }
    }
    private func place(_ coordinate: CLLocationCoordinate2D) {
        pin = coordinate; completer.clear()
        position = .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 3000, longitudinalMeters: 3000))
    }
    /// "48.8584, 2.2945" or "48.8584 2.2945", latitude first.
    static func coordinate(_ text: String) -> CLLocationCoordinate2D? {
        let parts = text.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Double($0) }
        guard parts.count == 2, (-90...90).contains(parts[0]), (-180...180).contains(parts[1]),
              text.split(whereSeparator: { $0 == "," || $0 == " " }).count == 2 else { return nil }
        return CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1])
    }
    static func text(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.6f, %.6f", locale: Locale(identifier: "en_US_POSIX"), coordinate.latitude, coordinate.longitude)
    }
}
