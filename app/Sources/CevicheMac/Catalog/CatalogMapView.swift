import SwiftUI
import MapKit
import CevicheCore

/// The Map collection's overview. Choosing a pin lists its photos below the map; Show Photos (Return) opens them in the
/// wall or the grid. A browsing surface only: coordinates are read from the catalog, never changed here.
struct CatalogMapView: View {
    @ObservedObject var model: CatalogModel
    @ObservedObject var editor: EditorModel
    @State private var placeIDs: Set<String> = []
    private var placePhotos: [CatalogAsset] { model.assets.filter { placeIDs.contains($0.id) } }
    var body: some View {
        VStack(spacing: 0) {
            CatalogPhotoMap(assets: model.assets, previews: model.previews, focus: model.mapFocus) { photos in
                placeIDs = Set(photos.map(\.id))
                if let first = photos.first { model.select(first) }
            }
            if !placePhotos.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text((placePhotos.count == 1 ? L10n.tr("\(placePhotos.count) photo at this location") : L10n.tr("\(placePhotos.count) photos at this location"))).font(.caption)
                        Spacer()
                        Button(L10n.tr("Show Photos")) { let photos = placePhotos; Task { await model.openPlace(photos) } }.keyboardShortcut(.defaultAction).disabled(model.interactionBusy)
                        Button { placeIDs = [] } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help(L10n.tr("Close location photos")).accessibilityLabel(L10n.tr("Close location photos"))
                    }
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 10) {
                            ForEach(placePhotos) { photo in
                                Button { model.select(photo) } label: {
                                    CatalogThumbnail(asset: photo, previews: model.previews)
                                        .frame(width: 110, height: 76)
                                        .selectionRing(model.selected?.id == photo.id ? Theme.accent : nil)
                                }.buttonStyle(.plain).help(photo.filename).accessibilityLabel(photo.filename)
                                    .simultaneousGesture(TapGesture(count: 2).onEnded { model.develop(photo, editor: editor) })
                                    .contextMenu { PhotoContextMenu(catalog: model, editor: editor, asset: photo) }
                            }
                        }
                    }.frame(height: 80)
                }.padding(12).background(.black.opacity(0.15))
            }
        }
    }
}

private final class CatalogPhotoAnnotation: NSObject, MKAnnotation {
    let asset: CatalogAsset
    let coordinate: CLLocationCoordinate2D
    var title: String? { asset.title.isEmpty ? asset.filename : asset.title }
    init(_ asset: CatalogAsset, latitude: Double, longitude: Double) {
        self.asset = asset
        coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        super.init()
    }
}

private struct CatalogMapPin: View {
    let asset: CatalogAsset
    let previews: PreviewStore?
    let count: Int
    /// Every photo in the pin has a location set in Ceviche rather than read from its file: a dashed frame.
    var assigned = false
    var body: some View {
        VStack(spacing: 0) {
            CatalogThumbnail(asset: asset, previews: previews)
                .frame(width: 68, height: 64).background(Theme.placeholder)
                .overlay(alignment: .bottomLeading) {
                    Text(L10n.tr("\(count)")).font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2).background(.black.opacity(0.65), in: Capsule()).environment(\.colorScheme, .dark).padding(4)
                }
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white, style: StrokeStyle(lineWidth: 3, dash: assigned ? [6, 4] : [])))
            Image(systemName: "arrowtriangle.down.fill").font(.system(size: 11)).foregroundStyle(.white).offset(y: -1)
        }.shadow(color: .black.opacity(0.3), radius: 4, y: 2)
    }
}

private final class CatalogMapPinHost: NSHostingView<CatalogMapPin> {
    // The annotation owns selection; the thumbnail is only its visual content.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class CatalogMapAnnotationView: MKAnnotationView {
    private var host: CatalogMapPinHost?
    var selectPhotos: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { selectPhotos?() }
    }
    override func accessibilityPerformPress() -> Bool { selectPhotos?(); return true }
    func configure(asset: CatalogAsset, previews: PreviewStore?, count: Int, assigned: Bool) {
        let content = CatalogMapPin(asset: asset, previews: previews, count: count, assigned: assigned)
        if let host { host.rootView = content }
        else {
            let host = CatalogMapPinHost(rootView: content)
            addSubview(host); self.host = host
        }
        frame.size = NSSize(width: 76, height: 84)
        host?.frame = bounds
        centerOffset = NSPoint(x: 0, y: -42)
        collisionMode = .rectangle
        displayPriority = .defaultHigh
        setAccessibilityLabel(count == 1 ? asset.filename : L10n.tr("\(count) photos. Select to browse this location."))
        setAccessibilityRole(.button)
    }
}

private struct CatalogPhotoMap: NSViewRepresentable {
    let assets: [CatalogAsset]
    let previews: PreviewStore?
    /// Show Nearby Photos' point: zoomed to once, and the camera then stays where the person takes it.
    let focus: MapFocus?
    let select: ([CatalogAsset]) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsZoomControls = true
        map.showsCompass = true
        map.pointOfInterestFilter = .excludingAll
        map.register(CatalogMapAnnotationView.self, forAnnotationViewWithReuseIdentifier: "photo")
        return map
    }
    func updateNSView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        // Keep the user's camera while selecting photos or saving ratings.
        // One hash instead of a string per photo: this runs on every model change.
        var hasher = Hasher()
        for asset in assets { hasher.combine(asset.id); hasher.combine(asset.latitude); hasher.combine(asset.longitude); hasher.combine(asset.locationSource); hasher.combine(asset.thumbnailKey) }
        let key = hasher.finalize()
        let refocus = focus.map { $0.id != context.coordinator.focusID } ?? false
        if refocus, let focus {
            context.coordinator.focusID = focus.id
            map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: focus.latitude, longitude: focus.longitude),
                                             latitudinalMeters: MapFocus.span, longitudinalMeters: MapFocus.span), animated: false)
        }
        guard key != context.coordinator.key || previews !== context.coordinator.previews else { return }
        context.coordinator.key = key; context.coordinator.previews = previews
        map.removeAnnotations(map.annotations)
        let annotations = assets.compactMap { asset -> CatalogPhotoAnnotation? in
            guard let latitude = asset.latitude, let longitude = asset.longitude,
                  latitude.isFinite, longitude.isFinite,
                  (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
            return CatalogPhotoAnnotation(asset, latitude: latitude, longitude: longitude)
        }
        map.addAnnotations(annotations)
        // Zoomed to a photo's surroundings: new photos or thumbnails don't pull the camera back out.
        if focus != nil { return }
        if let first = annotations.first, annotations.allSatisfy({ abs($0.coordinate.latitude - first.coordinate.latitude) < 0.001 && abs($0.coordinate.longitude - first.coordinate.longitude) < 0.001 }) {
            map.setRegion(MKCoordinateRegion(center: first.coordinate, latitudinalMeters: 5000, longitudinalMeters: 5000), animated: false)
        } else if !annotations.isEmpty {
            let rect = annotations.reduce(MKMapRect.null) { result, annotation in
                let point = MKMapPoint(annotation.coordinate)
                return result.union(MKMapRect(x: point.x, y: point.y, width: 1, height: 1))
            }
            map.setVisibleMapRect(rect, edgePadding: NSEdgeInsets(top: 110, left: 65, bottom: 65, right: 65), animated: false)
        }
    }
    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: CatalogPhotoMap
        var key: Int?
        var previews: PreviewStore?
        var focusID: UUID?
        init(_ parent: CatalogPhotoMap) { self.parent = parent }
        func photos(_ annotation: MKAnnotation) -> [CatalogAsset] {
            if let photo = annotation as? CatalogPhotoAnnotation { return [photo.asset] }
            if let cluster = annotation as? MKClusterAnnotation { return cluster.memberAnnotations.flatMap(photos).sorted { $0.id < $1.id } }
            return []
        }
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            let photos = photos(annotation)
            guard let first = photos.first,
                  let view = mapView.dequeueReusableAnnotationView(withIdentifier: "photo", for: annotation) as? CatalogMapAnnotationView else { return nil }
            view.clusteringIdentifier = annotation is MKClusterAnnotation ? nil : "photos"
            view.configure(asset: first, previews: parent.previews, count: photos.count, assigned: photos.allSatisfy { $0.locationSource != nil })
            view.selectPhotos = { [weak self] in self?.parent.select(photos) }
            return view
        }
        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let annotation = view.annotation else { return }
            parent.select(photos(annotation))
            mapView.deselectAnnotation(annotation, animated: false)
        }
    }
}
