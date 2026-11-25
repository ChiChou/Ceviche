import Foundation

/// A photo's metadata before and after a change made to several photos at once.
public typealias CatalogMetadataChange = (id: String, old: CatalogMetadata, new: CatalogMetadata)

extension CatalogMetadata {
    /// At `location`, marked as set in Ceviche, or with no location (nil).
    public func placed(at location: (latitude: Double, longitude: Double)?) -> CatalogMetadata {
        var placed = self
        placed.latitude = location?.latitude; placed.longitude = location?.longitude
        placed.locationSource = location == nil ? nil : .assigned
        return placed
    }
}

/// What one round of naming places found (`CatalogStore.namePlaces`).
public struct PlaceNamingRound: Sendable {
    /// Some photos' places changed.
    public var changed = false
    /// Squares are left to look up: the next round can start straight away.
    public var more = false
    /// A lookup failed (offline or throttled); what was found is kept, and the rest waits.
    public var failed = false
    /// Stopped before the end: cancelled, or `proceed` said no.
    public var stopped = false
    public init() {}
}

extension CatalogStore {
    /// What Set Location changes for `ids`: each photo placed at `location`, or with its location removed (nil), as set
    /// in Ceviche. Photos already so are left out; the rest keep the order given.
    public func locationChanges(_ location: (latitude: Double, longitude: Double)?, for ids: [String]) throws -> [CatalogMetadataChange] {
        try ids.compactMap { id in
            let old = try asset(id).metadata, new = old.placed(at: location)
            return new == old ? nil : (id, old, new)
        }
    }

    /// Where the location picker opens for these photos: the first one's location, else that of the photo taken
    /// closest in time to the first with a capture time.
    public func startingLocation(for assets: [CatalogAsset]) -> (latitude: Double, longitude: Double)? {
        if let located = assets.first(where: { $0.latitude != nil && $0.longitude != nil }), let latitude = located.latitude, let longitude = located.longitude {
            return (latitude, longitude)
        }
        guard let time = assets.compactMap(\.captureTime).first else { return nil }
        return try? nearestLocation(to: time)
    }

    /// One round of naming places: names photos from squares of about a kilometre already looked up, looks up at most
    /// `limit` more through `lookUp` (the platform's geocoder, so it needs the network), one at a time and `pace` apart
    /// since geocoders throttle bursts, then lends the names to photos taken close in time. `proceed` is asked before
    /// each lookup. A read-only catalog is left alone.
    public nonisolated func namePlaces(locale: Locale, limit: Int = 20, pace: Duration = .milliseconds(1500),
                                       proceed: @escaping @Sendable () async -> Bool = { true },
                                       lookUp: @escaping @Sendable (CatalogPlaceCell, Locale) async throws -> CatalogPlace?) async -> PlaceNamingRound {
        var round = PlaceNamingRound()
        guard !isReadOnly else { return round }
        do {
            if try await applyKnownPlaces(locale: locale.identifier) > 0 { round.changed = true }
            let cells = try await pendingPlaceCells(locale: locale.identifier, limit: limit)
            for cell in cells {
                guard await proceed(), !Task.isCancelled else { round.stopped = true; return round }
                let place = try await lookUp(cell, locale)
                try await recordPlace(place, cell: cell.key, locale: locale.identifier)
                round.changed = true
                try await Task.sleep(for: pace)
            }
            if try await inferPlaces() > 0 { round.changed = true }
            round.more = cells.count == limit
        } catch is CancellationError {
            round.stopped = true
        } catch {
            round.failed = true
            if (try? await inferPlaces()) ?? 0 > 0 { round.changed = true }
        }
        return round
    }
}
