import SwiftUI
import CevicheCore

/// The zone map drawn over the photo: the preview it was measured from, its zones, and the picture of them.
struct ZoneDisplay {
    let source: CGImage
    let map: ZoneMap
    let image: CGImage
    let isolated: Int?
}

/// The zone under the pointer on the photo, apart from the model so moving the pointer only redraws the zone strip.
final class ZonePointer: ObservableObject {
    @Published var zone: Int?
}

extension EditorModel {
    /// The zone that stands out on the map: the one hovered in the strip, else the one clicked there.
    var zoneIsolated: Int? { zoneHovered ?? zonePinned }
    /// Zones show over the photo in Light & Color only, like the scope overlay, and not while comparing or picking.
    var zonesOnCanvas: Bool {
        zonesShown && toolTab == .light && showInspector && preview != nil && !peekingOriginal && !printing && !comparing && eyedropper == nil
    }
    func toggleZones() {
        zonesShown.toggle()
        if zonesShown, toolTab != .light || !showInspector { endMask(); toolTab = .light; showInspector = true }
    }
    /// Measures the newest preview, or redraws the map for a newly isolated zone. One runs at a time; while a slider
    /// moves, the newest preview is measured next and those in between are skipped.
    func refreshZones() {
        guard zonesShown, let source = preview else {
            zoneTask?.cancel(); zoneTask = nil; zonePending = false
            if !zonesShown || preview == nil { zoneDisplay = nil }
            return
        }
        if zoneTask != nil { zonePending = true; return }
        let isolated = zoneIsolated, previous = zoneDisplay
        if let previous, previous.source === source, previous.isolated == isolated { return }
        zoneTask = Task { [weak self] in
            let display = await Task.detached(priority: .userInitiated) { () -> ZoneDisplay? in
                let map = previous?.source === source ? previous!.map : ZoneMap(source)
                return map.image(isolating: isolated).map { ZoneDisplay(source: source, map: map, image: $0, isolated: isolated) }
            }.value
            guard let self, !Task.isCancelled else { return }
            zoneTask = nil
            if zonesShown { zoneDisplay = display }
            let current = zoneDisplay
            if zonePending || current?.source !== preview || current?.isolated != zoneIsolated { zonePending = false; refreshZones() }
        }
    }
}
