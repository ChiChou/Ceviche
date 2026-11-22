import MapKit
import Combine

/// Place suggestions while typing, from MapKit's completer. Keystrokes are debounced (a query goes out once typing
/// pauses) and throttled (while typing never pauses, one still goes out at least every `maxWait`), so the completer
/// sees a few queries a second at most and Apple's per-app limit isn't reached.
@MainActor
final class PlaceCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    static let debounce = Duration.milliseconds(250)
    static let maxWait = Duration.milliseconds(700)
    @Published private(set) var results: [MKLocalSearchCompletion] = []
    /// The completer answered the latest query with nothing.
    @Published private(set) var empty = false
    private let completer = MKLocalSearchCompleter()
    private var pending: Task<Void, Never>?
    /// When the oldest keystroke not yet sent was typed.
    private var waitingSince: ContinuousClock.Instant?
    /// A query is out; answers arriving after `clear` are dropped.
    private var active = false

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }
    /// Suggestions favour what the map shows.
    func bias(to region: MKCoordinateRegion) { completer.region = region }

    func update(_ text: String) {
        pending?.cancel()
        let fragment = text.trimmingCharacters(in: .whitespaces)
        guard !fragment.isEmpty else { clear(); return }
        let now = ContinuousClock.now
        let since = waitingSince ?? now
        waitingSince = since
        let delay = Self.delay(waitingSince: since, now: now)
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            waitingSince = nil; active = true
            completer.queryFragment = fragment
        }
    }
    /// How long to wait before sending: a pause of `debounce`, but never past `maxWait` after the oldest unsent keystroke.
    nonisolated static func delay(waitingSince: ContinuousClock.Instant, now: ContinuousClock.Instant) -> Duration {
        min(debounce, max(.zero, waitingSince + maxWait - now))
    }
    func clear() {
        pending?.cancel(); pending = nil; waitingSince = nil; active = false
        completer.cancel()
        results = []; empty = false
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated {
            guard active else { return }
            results = Array(completer.results.prefix(8)); empty = completer.results.isEmpty
        }
    }
    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            // Throttled by MapKit: keep showing the last suggestions; the next keystroke asks again.
            guard active, (error as? MKError)?.code != .loadingThrottled else { return }
            results = []; empty = (error as? MKError)?.code == .placemarkNotFound
        }
    }
}
