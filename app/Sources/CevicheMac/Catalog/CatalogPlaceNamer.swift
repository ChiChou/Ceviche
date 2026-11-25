import CoreLocation
import CevicheCore

/// Names the places of photos in the open catalog in the background: looks up each square of about a kilometre that
/// has photos with a location (through Apple's geocoder, so it needs the network), then lends those names to photos
/// without a location taken close in time. One lookup at a time, paced, since the geocoder throttles bursts.
@MainActor
final class CatalogPlaceNamer {
    /// The Settings switch; on unless the person turned it off.
    static let enabledKey = "lookUpPlaces"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    private weak var catalog: CatalogModel?
    private var task: Task<Void, Never>?
    private var idleWait: Task<Void, Error>?
    private var wakeRequested = false
    private let lookUp: @Sendable (CatalogPlaceCell, Locale) async throws -> CatalogPlace?
    private let pace: Duration

    init(pace: Duration = .milliseconds(1500), lookUp: @escaping @Sendable (CatalogPlaceCell, Locale) async throws -> CatalogPlace? = { try await CatalogPlaceNamer.geocode($0, locale: $1) }) {
        self.pace = pace; self.lookUp = lookUp
    }
    func start(catalog: CatalogModel) {
        guard task == nil else { return }
        self.catalog = catalog
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.wakeRequested = false
                let retryAfter = await self?.pass() ?? .seconds(300)
                guard let self, !Task.isCancelled else { break }
                if self.wakeRequested { continue }
                let wait = Task { try await Task.sleep(for: retryAfter) }
                self.idleWait = wait
                _ = await wait.result
                self.idleWait = nil
            }
        }
    }
    /// New photos, a newly opened catalog, or the switch turned on.
    func workAvailable() { wakeRequested = true; idleWait?.cancel() }
    func stop() { task?.cancel(); idleWait?.cancel(); task = nil }

    /// One round of lookups and inference; returns how long to wait before the next.
    private func pass() async -> Duration {
        guard Self.enabled, let catalog, let store = catalog.store, !store.isReadOnly else { return .seconds(300) }
        let round = await store.namePlaces(locale: L10n.locale, pace: pace, proceed: { @MainActor [weak catalog] in
            Self.enabled && catalog?.store === store
        }, lookUp: lookUp)
        if round.changed { Task { await catalog.placesChanged(in: store) } }
        // Offline or throttled: what was found is kept, and the rest waits.
        if round.stopped { return .seconds(300) }
        if round.failed { return .seconds(120) }
        return round.more ? .zero : .seconds(300)
    }

    /// Apple's geocoder; nil where there is nothing to name, such as open sea.
    nonisolated static func geocode(_ cell: CatalogPlaceCell, locale: Locale) async throws -> CatalogPlace? {
        do {
            let marks = try await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: cell.latitude, longitude: cell.longitude), preferredLocale: locale)
            guard let mark = marks.first else { return nil }
            let place = CatalogPlace(country: mark.country, region: mark.administrativeArea, city: mark.locality ?? mark.subAdministrativeArea)
            return place.isEmpty ? nil : place
        } catch let error as CLError where error.code == .geocodeFoundNoResult {
            return nil
        }
    }
}
