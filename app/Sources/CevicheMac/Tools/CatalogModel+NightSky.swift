import AppKit
import SwiftUI
import CevicheCore

/// One of the night-sky tools, each its own workflow over a sequence of photos from a tripod.
enum NightSkyTool: String, Identifiable {
    case starTrails, denoise, meteorShower
    var id: String { rawValue }
    var title: String {
        switch self {
        case .starTrails: L10n.tr("Star Trails")
        case .denoise: L10n.tr("Night Sky Noise Reduction")
        case .meteorShower: L10n.tr("Meteor Shower")
        }
    }
    var menuTitle: String {
        switch self {
        case .starTrails: L10n.tr("Create Star Trails…")
        case .denoise: L10n.tr("Night Sky Noise Reduction…")
        case .meteorShower: L10n.tr("Composite Meteor Shower…")
        }
    }
    var tileTitle: String {
        switch self {
        case .starTrails: L10n.tr("Star Trails")
        case .denoise: L10n.tr("Night Sky Noise Reduction")
        case .meteorShower: L10n.tr("Meteor Shower Composite")
        }
    }
    /// The system symbol, for tools that have one; Meteor Shower draws its own (see `NightSkyToolIcon`).
    var icon: String? {
        switch self {
        case .starTrails: "circle.dashed"
        case .denoise: "sparkles"
        case .meteorShower: nil
        }
    }
    /// Meteors are found against the photos on either side, so the shower needs at least three.
    var minimumCount: Int { self == .meteorShower ? 3 : 2 }
}

struct NightSkyRequest: Identifiable {
    let id = UUID()
    let tool: NightSkyTool
    /// In capture order.
    let assets: [CatalogAsset]
    var latentURL: URL? = nil
    var latentAssetID: String? = nil
}

extension CatalogModel {
    /// The tools sort the photos by capture time themselves, and list any that can't be stacked with the rest (another
    /// kind, camera or size) to be left out before they start.
    func canUseNightSky(_ tool: NightSkyTool, _ targets: [CatalogAsset]) -> Bool {
        let photos = targets.filter { $0.inLibrary && !$0.isLatent }
        return store != nil && canStartJob && !toolOpen && photos.count == targets.count && photos.count >= tool.minimumCount && nightSky == nil
    }

    func requestNightSky(_ tool: NightSkyTool, _ targets: [CatalogAsset]) {
        guard canUseNightSky(tool, targets) else { return }
        nightSky = NightSkyRequest(tool: tool, assets: targets.sorted { ($0.captureTime ?? "", $0.filename) < ($1.captureTime ?? "", $1.filename) })
    }

    func openLatent(_ asset: CatalogAsset) {
        guard let store, canStartJob, !toolOpen else { return }
        Task {
            do {
                let url = try await resolveOriginal(asset)
                let latent = try LatentImage.load(url)
                // Its display options are optional: options that can't be read fall back to the defaults when the tool opens.
                guard latent.catalogID == store.manifest.id else {
                    self.failure = Failure(L10n.tr("Couldn’t Open the Latent Image"), L10n.tr("The latent image’s source catalog is not open.")); return
                }
                var sources: [CatalogAsset] = []
                for source in latent.sources {
                    guard let found = try? await store.asset(source.assetID), found.trashedAt == nil, !found.isLatent else {
                        self.failure = Failure(L10n.tr("Couldn’t Open the Latent Image"), L10n.tr("The source photo “\(source.filename)” is no longer in the library. A latent image opens only with all of its source photos."))
                        return
                    }
                    sources.append(found)
                }
                guard self.store === store else { return }
                if latent.type == LatentImage.creativeFilters {
                    filters = FiltersRequest(assets: sources, latent: .init(assetID: asset.id, stack: try latent.filterStack()))
                    return
                }
                if latent.type == LatentImage.focusStack {
                    focusStack = FocusStackRequest(assets: sources, latent: (asset.id, try latent.focusStackSettings()))
                    return
                }
                if latent.type == LatentImage.panorama {
                    panoramaMerge = PanoramaMergeRequest(assets: sources, latent: (asset.id, try latent.panoramaSettings(), latent.sources))
                    return
                }
                if latent.type == LatentImage.timelapse {
                    timelapse = TimelapseRequest(assets: sources, latent: (asset.id, try latent.timelapseSettings()))
                    return
                }
                guard let tool = NightSkyTool(rawValue: latent.type) else { return }
                nightSky = NightSkyRequest(tool: tool, assets: sources, latentURL: url, latentAssetID: asset.id)
            } catch { self.failure = Failure(L10n.tr("Couldn’t Open the Latent Image"), error) }
        }
    }

    /// Runs a night-sky tool's merge as a background job; the result goes beside `beside` and takes the edits of `editsFrom`.
    func startNightSky(_ tool: NightSkyTool, beside: URL, editsFrom: CatalogAsset?, count: Int, access: [URL], format: ProcessedFormat = .original,
                       merge: @escaping @Sendable (URL, @escaping @Sendable (Double, String) -> Void) throws -> Void) {
        let (suffix, title, done, stopped): (String, String, String, String) = switch tool {
        case .starTrails: ("StarTrails", L10n.tr("Creating star trails"), L10n.tr("Star trails created from \(count) photos"), L10n.tr("Star trails stopped"))
        case .denoise: ("NightSky", L10n.tr("Reducing noise in the night sky"), L10n.tr("Night sky stacked from \(count) photos"), L10n.tr("Night sky noise reduction stopped"))
        case .meteorShower: ("Meteors", L10n.tr("Compositing meteors"), count == 1 ? L10n.tr("Meteor shower composited with 1 meteor") : L10n.tr("Meteor shower composited with \(count) meteors"),
                             L10n.tr("Meteor shower stopped"))
        }
        runMergeJob(beside: beside, suffix: suffix, title: title, editsFrom: editsFrom, access: access, format: format, merge: merge,
                    done: done, detail: "", stopped: stopped, failed: { L10n.tr("The photos couldn’t be combined. \($0)") })
    }
}

/// A tool's icon at the font's size: its system symbol, or for Meteor Shower a streak that tapers away from a bright head,
/// falling to the lower left, as no system symbol shows a meteor.
struct NightSkyToolIcon: View {
    let tool: NightSkyTool
    var body: some View {
        if let icon = tool.icon { Image(systemName: icon) } else { MeteorGlyph() }
    }
}

private struct MeteorGlyph: View {
    var body: some View {
        // A hidden square symbol takes the size the font gives symbols, so the glyph matches its neighbors.
        Image(systemName: "square").hidden().overlay { GeometryReader { geometry in
            let s = min(geometry.size.width, geometry.size.height)
            ZStack(alignment: .topLeading) {
                Path { path in
                    // From a point at the upper right to a rounded width at the head, lower left.
                    path.move(to: CGPoint(x: 1.0 * s, y: 0.0))
                    path.addLine(to: CGPoint(x: 0.27 * s, y: 0.6 * s))
                    path.addQuadCurve(to: CGPoint(x: 0.4 * s, y: 0.73 * s), control: CGPoint(x: 0.24 * s, y: 0.76 * s))
                    path.closeSubpath()
                }
                .fill(.foreground)
                .mask(LinearGradient(colors: [.black.opacity(0.25), .black], startPoint: .topTrailing, endPoint: .bottomLeading))
                Image(systemName: "sparkle").font(.system(size: 0.56 * s, weight: .semibold))
                    .position(x: 0.28 * s, y: 0.72 * s)
                Image(systemName: "sparkle").font(.system(size: 0.24 * s)).opacity(0.75)
                    .position(x: 0.16 * s, y: 0.16 * s)
            }
        } }
    }
}
