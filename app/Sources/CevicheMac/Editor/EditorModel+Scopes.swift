import SwiftUI
import CevicheCore

/// The scope under the histogram in Light & Color, if one is on.
enum EditorScope: String, CaseIterable {
    case waveform, parade, vectorscope
    var title: String {
        switch self {
        case .waveform: L10n.tr("Waveform")
        case .parade: L10n.tr("Parade")
        case .vectorscope: L10n.tr("Vectorscope")
        }
    }
    private static let key = "editorScope", lastKey = "editorLastScope"
    static var saved: Self? { UserDefaults.standard.string(forKey: key).flatMap(Self.init) }
    static func save(_ scope: Self?) {
        UserDefaults.standard.set(scope?.rawValue ?? "", forKey: key)
        if let scope { UserDefaults.standard.set(scope.rawValue, forKey: lastKey) }
    }
    /// The scope View › Scopes turns back on: the last one chosen.
    static var last: Self { UserDefaults.standard.string(forKey: lastKey).flatMap(Self.init) ?? .vectorscope }
}

struct ScopeOptions: Equatable {
    /// The waveform in luma only, instead of the three channels added up.
    var waveformLuma = false
    /// The vectorscope at twice the scale, for the low saturations most photos have.
    var vectorZoom = false
    private static let lumaKey = "editorScopeWaveformLuma", zoomKey = "editorScopeVectorZoom"
    static var saved: Self { Self(waveformLuma: UserDefaults.standard.bool(forKey: lumaKey), vectorZoom: UserDefaults.standard.bool(forKey: zoomKey)) }
    func save() { UserDefaults.standard.set(waveformLuma, forKey: Self.lumaKey); UserDefaults.standard.set(vectorZoom, forKey: Self.zoomKey) }
}

/// A drawn scope: the plot as an image, with what the view needs for its graticule.
struct ScopeDisplay {
    let scope: EditorScope
    let image: CGImage
    /// Stops above SDR white on the upper half of a waveform or parade; nil for SDR.
    let hdrStops: Double?
}

extension EditorModel {
    /// The scopes measured: the panel's, if one is on.
    var scopesShowing: Set<EditorScope> { scope.map { [$0] } ?? [] }
    /// Measures the newest preview for the scopes showing, once for all of them. One measurement runs at a time; while
    /// a slider moves, the newest preview is measured next and those in between are skipped.
    func refreshScope() {
        let wanted = scopesShowing
        guard !wanted.isEmpty, let source = scopeSource else {
            scopeTask?.cancel(); scopeTask = nil; scopePending = false
            if scopeSource == nil { scopeDisplays = [:] }
            return
        }
        if scopeTask != nil { scopePending = true; return }
        let options = scopeOptions
        scopeTask = Task { [weak self] in
            let displays = await Task.detached(priority: .userInitiated) { () -> [EditorScope: ScopeDisplay] in
                let scopes = Scopes(source)
                var displays: [EditorScope: ScopeDisplay] = [:]
                for scope in wanted {
                    let image: CGImage?
                    switch scope {
                    case .waveform: image = scopes.waveformImage(options.waveformLuma ? .luma : .rgb)
                    case .parade: image = scopes.waveformImage(.parade)
                    case .vectorscope: image = scopes.vectorscopeImage()
                    }
                    displays[scope] = image.map { ScopeDisplay(scope: scope, image: $0, hdrStops: scope == .vectorscope ? nil : scopes.hdrStops) }
                }
                return displays
            }.value
            guard let self, !Task.isCancelled else { return }
            // Keep what is still showing; a scope chosen meanwhile is measured next.
            scopeDisplays = displays.filter { scopesShowing.contains($0.key) }
            scopeTask = nil
            if scopePending || !scopesShowing.isSubset(of: displays.keys) { scopePending = false; refreshScope() }
        }
    }
    func scopeOptionOn(_ scope: EditorScope) -> Bool {
        switch scope {
        case .waveform: scopeOptions.waveformLuma
        case .vectorscope: scopeOptions.vectorZoom
        case .parade: false
        }
    }
    /// Turns the last scope chosen on under the histogram, or off; the scope lives in Light & Color's panel.
    func toggleScope() {
        scope = scope == nil ? EditorScope.last : nil
        if scope != nil, toolTab != .light || !showInspector { endMask(); toolTab = .light; showInspector = true }
    }
    /// What a scope shows now: nothing until its first measurement, and nothing without a photo.
    func scopeDisplay(_ scope: EditorScope) -> ScopeDisplay? { hasImage ? scopeDisplays[scope] : nil }
}
