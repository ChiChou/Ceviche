import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CevicheCore

/// The Darkroom's print previews and the Looks tab's thumbnails.
extension EditorModel {
    /// The stock previews give a feel for each film on this photo, at the film's own settings: only the edits
    /// before the film (exposure, white balance, crop…) make new ones, never the Darkroom's own controls.
    static func filmPreviewsKey(_ adjustments: Adjustments) -> Adjustments {
        var key = adjustments
        key.film = nil
        return key
    }
    /// The Darkroom's proofs of the open photo: whole prints by print exposure for the test strip, and small prints by
    /// color balance for the ring-around. Each set holds for one `base` (everything else about the photo and its
    /// development) and drops the prints used longest ago; a new photo starts both empty.
    struct FilmProofs {
        struct Balance: Hashable { let yellow: Double, magenta: Double }
        struct RingBase: Equatable { let adjustments: Adjustments, size: Double }
        private(set) var stripBase: Adjustments?
        private(set) var ringBase: RingBase?
        /// Keyed by exposure in thousandths of a stop.
        private(set) var strip = LRUCache<Int, CGImage>(countLimit: 24, costLimit: 512 << 20)
        private(set) var ring = LRUCache<Balance, CGImage>(countLimit: 81, costLimit: 256 << 20)
        mutating func startStrip(_ base: Adjustments) { strip.removeAll(); stripBase = base }
        mutating func startRing(_ base: RingBase) { ring.removeAll(); ringBase = base }
        mutating func keep(_ print: CGImage, exposure: Int) { strip.insert(print, for: exposure, cost: print.bytesPerRow * print.height) }
        mutating func keep(_ print: CGImage, balance: Balance) { ring.insert(print, for: balance, cost: print.bytesPerRow * print.height) }
        mutating func use(exposures: [Int]) { exposures.forEach { strip.touch($0) } }
        mutating func use(balances: [Balance]) { balances.forEach { ring.touch($0) } }
    }

    func invalidateFilmPreviews() {
        filmPreviewTask?.cancel(); filmPreviewTask = nil
        filmPreviews = [:]; filmPreviewsKey = nil
    }
    /// Invalid previews stay blank while the current photo's stock previews render in batches.
    func prewarmFilmPreviews(after delay: Duration = .milliseconds(300)) {
        guard let renderer, !isLoading, FilmCatalog.shared.isAvailable else { return }
        let snapshot = adjustments, key = Self.filmPreviewsKey(snapshot)
        guard key != filmPreviewsKey else { return }
        invalidateFilmPreviews()
        filmPreviewsKey = key
        let current = snapshot.film?.stock
        // The stock on the photo first, then the list in order.
        let list = FilmCatalog.shared.films
        let films = (list.filter { $0.id == current } + list.filter { $0.id != current }).map { FilmSimulation(stock: $0.id) }
        filmPreviewTask = Task { [weak self] in
            var completed = false
            defer {
                if !completed, !Task.isCancelled, self?.renderer === renderer, self?.filmPreviewsKey == key {
                    self?.invalidateFilmPreviews()
                }
            }
            try? await Task.sleep(for: delay)
            // Two at a time: a film under the pointer waits for no more than that before it is previewed.
            for batch in stride(from: 0, to: films.count, by: 2).map({ Array(films[$0..<min($0 + 2, films.count)]) }) {
                guard !Task.isCancelled else { return }
                guard let images = try? await renderer.filmPreviews(snapshot, films: batch, size: Self.filmPreviewSize),
                      let self, !Task.isCancelled, self.renderer === renderer,
                      self.filmPreviewsKey == key, Self.filmPreviewsKey(self.adjustments) == key else { return }
                for (film, image) in zip(batch, images) { if let image { self.filmPreviews[film.stock] = image } }
            }
            completed = true
        }
    }
    /// Pixels on a preview's long side: two columns of the inspector at 2x.
    static let filmPreviewSize = 260.0
    /// Asks for `look`'s thumbnail on the current edit, when it has none on it yet; tiles ask as they scroll into view.
    func requestLookThumbnail(_ look: LookFile) {
        if lookThumbnails[look.url] != nil { useLookThumbnail(look.url) }
        guard hasImage, lookThumbnails[look.url]?.base != adjustments else { return }
        lookThumbnailQueue.removeAll { $0 == look }
        lookThumbnailQueue.append(look)
        guard lookThumbnailTask == nil else { return }
        lookThumbnailTask = Task { [weak self] in
            await self?.drainLookThumbnails()
            self?.lookThumbnailTask = nil
        }
    }
    /// A tile scrolled out of view before its thumbnail was made.
    func cancelLookThumbnail(_ look: LookFile) { lookThumbnailQueue.removeAll { $0 == look } }
    /// Makes the queued thumbnails one at a time, in the order the tiles came into view (tiles scrolled past have left
    /// the queue); the photo's own renders take their turn on the renderer between them. About 20 to 30 ms each in a
    /// release build, most of it the grading pipeline Core Image builds for each look.
    private func drainLookThumbnails() async {
        while !lookThumbnailQueue.isEmpty, !Task.isCancelled {
            let look = lookThumbnailQueue.removeFirst()
            guard let renderer, let info else { return }
            let base = adjustments
            guard lookThumbnails[look.url]?.base != base else { continue }
            let library = lookResources.folder
            guard let settings = try? await Task.detached(priority: .utility, operation: { try look.kind.develop(look.url, on: base, info: info, library: library).0 }).value,
                  let image = try? await renderer.thumbnail(settings, size: Self.lookThumbnailSize),
                  !Task.isCancelled, self.renderer === renderer else { continue }
            lookThumbnails[look.url] = (base, image); useLookThumbnail(look.url)
            while lookThumbnails.count > Self.lookThumbnailLimit, let oldest = lookThumbnailUse.first {
                lookThumbnailUse.removeFirst(); lookThumbnails[oldest] = nil
            }
        }
    }
    static let lookThumbnailSize = 220.0
    /// The whole photo printed at each of `exposures`, for the bands of a test strip; empty when it cannot be printed
    /// or nobody waits for it any more.
    func filmPrints(_ adjustments: Adjustments, exposures: [Double]) async -> [CGImage] {
        guard let renderer else { return [] }
        do { return try await renderer.filmPrints(adjustments, exposures: exposures) } catch is CancellationError { return [] } catch { self.error = error.localizedDescription; return [] }
    }
    /// The photo printed at each Y and M balance, for a ring-around.
    func filmRingAround(_ adjustments: Adjustments, filtrations: [(yellow: Double, magenta: Double)], size: Double) async -> [CGImage] {
        guard let renderer else { return [] }
        do { return try await renderer.filmRingAround(adjustments, filtrations: filtrations, size: size) } catch is CancellationError { return [] } catch { self.error = error.localizedDescription; return [] }
    }
}
