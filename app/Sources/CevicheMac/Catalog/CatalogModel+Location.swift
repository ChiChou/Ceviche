import Foundation
import CevicheCore

/// A point the Map zooms to once; a new request is a new id, even for the same place.
struct MapFocus: Equatable {
    let id = UUID()
    let latitude: Double
    let longitude: Double
    /// About a walk around the spot: the photos taken there and close by, not the whole trip.
    static let span: Double = 5000
}

extension CatalogModel {
    func canShowNearby(_ targets: [CatalogAsset]) -> Bool {
        store != nil && !isFolderIndex && targets.count == 1 && targets[0].inLibrary && targets[0].latitude != nil && targets[0].longitude != nil
    }
    /// The Map, zoomed to the photo's surroundings, so the photos taken nearby are the ones it shows; the photo stays selected.
    func showNearby(_ asset: CatalogAsset, editor: EditorModel) async {
        guard canShowNearby([asset]), let latitude = asset.latitude, let longitude = asset.longitude else { return }
        if !showingLibrary { await closePhoto(editor: editor) }
        await showCollection(area: .library, geotagged: true)
        mapFocus = MapFocus(latitude: latitude, longitude: longitude)
        if let shown = assets.first(where: { $0.id == asset.id }) {
            selectedIDs = [shown.id]; selectionAnchorID = shown.id
            await selectAsset(shown, preservingSelection: true)
        }
    }

    /// Places photos at one point, or removes their location (nil), as set in Ceviche: one Undo step, and History.
    func setLocation(_ location: (latitude: Double, longitude: Double)?, assetIDs: [String]) async {
        guard let store, await flushMetadata(), self.store === store else { return }
        do {
            var planned: [(id: String, old: CatalogMetadata, new: CatalogMetadata)] = []
            for id in assetIDs {
                let old = try await store.asset(id).metadata
                var new = old
                new.latitude = location?.latitude; new.longitude = location?.longitude
                new.locationSource = location == nil ? nil : .assigned
                if new != old { planned.append((id, old, new)) }
            }
            guard !planned.isEmpty else { return }
            try await store.updateMetadata(Dictionary(uniqueKeysWithValues: planned.map { ($0.id, $0.new) }))
            registerBatchMetadataUndo(planned, name: L10n.tr("Location"))
            for change in planned { acceptAutomationMetadata(change.new, assetID: change.id) }
            placeNamer.workAvailable()
            await refresh()
        } catch { self.failure = Failure(L10n.tr("Couldn’t Set the Location"), error) }
    }
    /// Where the picker opens for these photos: the first one's location, else the photo with one taken closest in time.
    func startingLocation(for assets: [CatalogAsset]) async -> (latitude: Double, longitude: Double)? {
        if let located = assets.first(where: { $0.latitude != nil && $0.longitude != nil }), let latitude = located.latitude, let longitude = located.longitude { return (latitude, longitude) }
        guard let store, let time = assets.compactMap(\.captureTime).first else { return nil }
        return try? await store.nearestLocation(to: time)
    }
}
