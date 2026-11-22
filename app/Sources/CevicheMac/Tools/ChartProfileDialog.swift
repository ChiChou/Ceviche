import SwiftUI
import AppKit
import CevicheCore

struct ChartProfileRequest: Identifiable {
    let id = UUID()
    /// The selection, the photo to look for the chart in first.
    let assets: [CatalogAsset]
}

/// Chart Profile: a camera profile from a photo of a 24-patch colour chart, saved with the camera profiles and put on
/// the photos it was shot for.
extension CatalogModel {
    private func chartCandidates(_ targets: [CatalogAsset]) -> [CatalogAsset] {
        let raw = targets.filter { $0.inLibrary && Self.isRAW($0) }
        // The photo last clicked leads: with a shoot selected, that is the chart frame.
        guard let lead = selected, let index = raw.firstIndex(where: { $0.id == lead.id }) else { return raw }
        return [raw[index]] + raw[..<index] + raw[(index + 1)...]
    }
    func canMakeChartProfile(_ targets: [CatalogAsset]) -> Bool {
        store != nil && !toolOpen && !targets.isEmpty && targets.contains { $0.inLibrary && Self.isRAW($0) }
    }
    func requestChartProfile(_ targets: [CatalogAsset]) {
        guard canMakeChartProfile(targets) else { return }
        chartProfile = ChartProfileRequest(assets: chartCandidates(targets))
    }
    /// The photos this camera took, RAW, among `assets`.
    func chartProfileTargets(_ assets: [CatalogAsset], camera: String) -> [CatalogAsset] {
        let key = CameraProfileResolver.normalized(camera)
        return assets.filter { $0.inLibrary && Self.isRAW($0) && CameraProfileResolver.normalized($0.cameraModel ?? "") == key }
    }
    /// Puts a chart profile on photos in one batch. A photo that carries a look's own camera profile keeps it, and
    /// one developed for light the profile wasn't made in is left alone: both are counted, not reported as failures.
    func applyChartProfile(_ profile: CameraProfile, to targets: [CatalogAsset], editor: EditorModel) async {
        let name = profile.name, skipped = ChartProfileSkips()
        @Sendable func fits(_ edits: Adjustments) -> Bool {
            (edits.cameraProfile.map(\.hasCalibration) ?? true) && profile.suits(temperature: edits.temperature)
        }
        await runEditBatch(targets, editor: editor, title: L10n.tr("Applying camera profile"),
                           inEditor: { if fits(editor.adjustments) { editor.edit { $0.cameraProfile = profile } } else { skipped.add() } },
                           develop: { _, saved, defaults in
                               var settings = saved ?? defaults
                               if fits(settings) { settings.cameraProfile = profile } else { skipped.add() }
                               return settings
                           },
                           save: { store, settings, baseline, id in try await store.saveEdits(settings, assetID: id, baseline: baseline) }) { completed, total, failures in
            let left = skipped.count, applied = max(0, completed - left)
            var notice = applied == 1 ? L10n.tr("Saved “\(name)” and applied it to 1 photo") : L10n.tr("Saved “\(name)” and applied it to \(applied.formatted()) photos")
            if left > 0 { notice += " " + (left == 1 ? L10n.tr("1 in different light left as it was.") : L10n.tr("\(left.formatted()) in different light left as they were.")) }
            if completed > 0 { self.notice = notice }
            if !failures.isEmpty { self.failure = Failure(L10n.tr("Some Photos Weren’t Changed"), summary: L10n.tr("Applied the profile to \(applied) of \(total) photos.\n").trimmingCharacters(in: .newlines), items: failures) }
        }
    }
}

/// How many photos a batch left without the profile, counted from the batch's own tasks.
private final class ChartProfileSkips: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func add() { lock.withLock { value += 1 } }
}

@MainActor
final class ChartProfileModel: ObservableObject {
    enum Stage: Equatable { case reading(String, Double), ready, failed(String) }
    /// Which photos get the profile when it is saved.
    enum Scope: Hashable { case none, chart, selection, day }

    let request: ChartProfileRequest
    @Published private(set) var stage = Stage.reading("", 0)
    @Published private(set) var result: ChartProfileResult?
    /// The photo the chart was found in.
    @Published private(set) var chart: CatalogAsset?
    /// The photo itself when no profile could be made, so what went wrong can be seen.
    @Published private(set) var failedPhoto: CGImage?
    @Published var name = ""
    @Published var showsProfile = true
    @Published var scope = Scope.chart
    private var access: URL?
    private var task: Task<Void, Never>?
    /// A chart is looked for in this many of the selected photos, the lead first.
    private static let searched = 12

    init(request: ChartProfileRequest) { self.request = request }

    /// The photo's Corners crop as saved, in fractions of the photo from its top left; nil without one.
    private static func framed(_ asset: CatalogAsset, catalog: CatalogModel) async -> [CGPoint]? {
        guard let store = catalog.store, let data = try? await store.photo(asset.id).adjustmentsData,
              let settings = try? JSONDecoder().decode(Adjustments.self, from: data),
              let corners = settings.geometry.perspective, corners.isValid else { return nil }
        return corners.corners.map { CGPoint(x: $0.x, y: 1 - $0.y) }
    }

    var canSave: Bool { stage == .ready && result != nil && !name.trimmingCharacters(in: .whitespaces).isEmpty }

    func start(catalog: CatalogModel) {
        guard task == nil else { return }
        let candidates = Array(request.assets.prefix(Self.searched))
        task = Task {
            var failure = L10n.tr("The original isn’t available.")
            for (index, asset) in candidates.enumerated() {
                guard let url = try? await catalog.resolveOriginal(asset) else { continue }
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                let camera = asset.cameraModel ?? "", several = candidates.count > 1
                let progress: @Sendable (Double, String) -> Void = { [weak self] fraction, message in
                    Task { @MainActor [weak self] in
                        guard case .reading = self?.stage, !message.isEmpty else { return }
                        self?.stage = .reading(several ? "\(asset.filename): \(message)" : message, fraction)
                    }
                }
                // Corners placed around the chart in Crop say where it is: the chart is looked for inside them.
                let region = await Self.framed(asset, catalog: catalog)
                let work = Task.detached(priority: .userInitiated) { try ChartProfiler.profile(url, camera: camera, region: region, progress: progress) }
                do {
                    let result = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                    self.result = result; chart = asset; name = result.profile.name
                    scope = targets(.selection, catalog: catalog).count > 1 ? .selection : .chart
                    stage = .ready
                    return
                } catch is CancellationError { return }
                catch {
                    // The photo clicked last is the one reported; the others selected are still looked at for a chart.
                    guard index == 0 else { continue }
                    failure = error.localizedDescription
                    failedPhoto = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                        guard let (renderer, defaults) = try? RawRenderer.open(url) else { return nil }
                        return try? await renderer.displayImage(defaults, maxDimension: 1800, sdr: true)
                    }.value
                }
            }
            if !Task.isCancelled { stage = .failed(failure) }
        }
    }

    /// The photos a scope covers: this camera's RAW photos among the selection, or among the photos shown that were
    /// taken the same day as the chart.
    func targets(_ scope: Scope, catalog: CatalogModel) -> [CatalogAsset] {
        guard let chart, let camera = result?.profile.camera else { return [] }
        switch scope {
        case .none: return []
        case .chart: return [chart]
        case .selection: return catalog.chartProfileTargets(request.assets, camera: camera)
        case .day: return catalog.chartProfileTargets(catalog.assets.filter { $0.captureDay == chart.captureDay }, camera: camera)
        }
    }
    /// The scopes worth offering: a wider one only when it reaches more photos than the one before it.
    func scopes(catalog: CatalogModel) -> [Scope] {
        var offered: [Scope] = [.none, .chart]
        let selection = targets(.selection, catalog: catalog).count, day = targets(.day, catalog: catalog).count
        if selection > 1 { offered.append(.selection) }
        if day > max(1, selection) { offered.append(.day) }
        return offered
    }
    func title(_ scope: Scope, catalog: CatalogModel) -> String {
        let count = targets(scope, catalog: catalog).count
        switch scope {
        case .none: return L10n.tr("No Photos")
        case .chart: return L10n.tr("This Photo")
        case .selection: return L10n.tr("\(count) Selected Photos")
        case .day: return L10n.tr("\(count) Photos from That Day")
        }
    }

    /// Writes the profile into the library's camera profiles and puts it on the chosen photos.
    func save(catalog: CatalogModel, editor: EditorModel) {
        guard canSave, var profile = result?.profile else { return }
        profile.name = name.trimmingCharacters(in: .whitespaces)
        do {
            let saved = try ChartProfileStore.shared.save(profile, library: LookLibrary.current(editor: editor, catalog: catalog))
            let targets = targets(scope, catalog: catalog)
            catalog.notice = L10n.tr("Saved “\(profile.name)”. Choose it under Camera Profile in Develop.")
            close(catalog: catalog)
            if !targets.isEmpty { Task { await catalog.applyChartProfile(saved, to: targets, editor: editor) } }
        } catch { stage = .failed(error.localizedDescription) }
    }

    func close(catalog: CatalogModel) {
        stop()
        catalog.chartProfile = nil
    }
    func stop() {
        task?.cancel()
        access?.stopAccessingSecurityScopedResource(); access = nil
    }
}

/// The chart photo with every patch marked and its error with the profile, the photo with and without the profile,
/// the profile's name, the photos it goes on, and Save.
struct ChartProfileDialog: View {
    @ObservedObject var catalog: CatalogModel
    @ObservedObject var editor: EditorModel
    @StateObject private var model: ChartProfileModel

    init(catalog: CatalogModel, editor: EditorModel, request: ChartProfileRequest) {
        self.catalog = catalog; self.editor = editor
        _model = StateObject(wrappedValue: ChartProfileModel(request: request))
    }

    var body: some View {
        ToolWorkspace(title: L10n.tr("Chart Profile"), status: status, statusIsWarning: statusIsWarning, statusHelp: statusHelp,
                      primary: model.scope == .none || model.result == nil ? L10n.tr("Save") : L10n.tr("Save and Apply"),
                      primaryDisabled: !model.canSave, cancel: { model.close(catalog: catalog) }, action: { model.save(catalog: catalog, editor: editor) },
                      showsToolbar: model.result != nil) {
            if let result = model.result {
                TextField(L10n.tr("Name"), text: $model.name).textFieldStyle(.formField).frame(width: 220)
                    .help(L10n.tr("The profile’s name under Camera Profile in Develop"))
                Text(L10n.tr("\(Int((result.temperature / 50).rounded()) * 50) K")).monospacedDigit().foregroundStyle(.secondary)
                    .help(L10n.tr("The light the profile is for: the white balance that makes the chart’s greys neutral. It suits photos developed near it."))
                Rule(.vertical).frame(height: 16)
                FormSegments(title: L10n.tr("Colour shown"), selection: $model.showsProfile, options: [false, true], label: { $0 ? L10n.tr("Profile") : L10n.tr("Built-in") })
                    .labelsHidden().fixedSize()
                    .help(L10n.tr("The chart with the camera’s own colour, or with the profile"))
                Text(L10n.tr("ΔE \(number(result.before)) → \(number(result.after))")).monospacedDigit().foregroundStyle(.secondary)
                    .help(L10n.tr("Mean colour error of the chart’s patches (ΔE 2000): as decoded, then with the profile. On patches the fit hadn’t seen: \(number(result.heldOut))."))
                Rule(.vertical).frame(height: 16)
                Text(L10n.tr("Apply to")).foregroundStyle(.secondary)
                PanelPicker(title: L10n.tr("Apply to"), selection: $model.scope, options: model.scopes(catalog: catalog), label: { model.title($0, catalog: catalog) })
                    .fixedSize()
                    .help(L10n.tr("The photos that get the profile when it is saved: RAW photos from this camera. It can be changed under Camera Profile in Develop."))
            }
        } content: {
            ZStack {
                ZoomCanvas(image: shown) { size in
                    if let result = model.result { patches(result, in: size) }
                }
                switch model.stage {
                case .reading(let message, let fraction):
                    VStack(spacing: 10) {
                        ProgressView(value: fraction).frame(width: 220)
                        Text(message.isEmpty ? L10n.tr("Reading the photo") : message).font(.callout).foregroundStyle(.secondary)
                    }.padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                case .failed(let message):
                    Text(message).font(.callout).multilineTextAlignment(.center).padding(18).frame(maxWidth: 420)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                        .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 28)
                case .ready: EmptyView()
                }
            }
        } actions: { EmptyView() }
        .onAppear { model.start(catalog: catalog) }
        .onDisappear { model.stop() }
    }

    private var shown: CGImage? {
        guard let result = model.result else { return model.failedPhoto }
        return model.showsProfile ? result.corrected ?? result.preview : result.preview
    }

    private func number(_ value: Double) -> String { String(format: "%.1f", locale: Locale.current, value) }

    /// A ring on every patch with its error, as shown: with the profile or without; a patch left out is crossed.
    private func patches(_ result: ChartProfileResult, in size: CGSize) -> some View {
        let pitch = spacing(result, in: size)
        return ZStack {
            ForEach(result.patches) { patch in
                let centre = CGPoint(x: patch.centre.x * size.width, y: patch.centre.y * size.height)
                Group {
                    if patch.usable, let error = model.showsProfile ? patch.after : patch.before {
                        Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1).frame(width: pitch * 0.42, height: pitch * 0.42)
                            .shadow(color: .black.opacity(0.6), radius: 1)
                        if pitch >= 34 {
                            Text(number(error)).font(.system(size: min(11, pitch * 0.2), weight: .semibold)).monospacedDigit().foregroundStyle(.white)
                                .shadow(color: .black, radius: 1.5).shadow(color: .black.opacity(0.7), radius: 0.5)
                        }
                    } else {
                        Image(systemName: "xmark").font(.system(size: pitch * 0.3, weight: .semibold)).foregroundStyle(Theme.warning).shadow(color: .black, radius: 1.5)
                    }
                }.position(centre)
            }
        }.frame(width: size.width, height: size.height).allowsHitTesting(false)
    }
    /// The distance between neighbouring patches as shown.
    private func spacing(_ result: ChartProfileResult, in size: CGSize) -> CGFloat {
        guard result.patches.count >= 2 else { return 0 }
        let a = result.patches[0].centre, b = result.patches[1].centre
        return hypot((a.x - b.x) * size.width, (a.y - b.y) * size.height)
    }

    private var status: String {
        if case .failed = model.stage { return model.request.assets.count == 1 ? model.request.assets[0].filename : "" }
        guard let result = model.result else { return model.request.assets.count == 1 ? model.request.assets[0].filename : "" }
        if result.tooBright > 0 {
            return result.tooBright == 1 ? L10n.tr("1 patch too bright to use. Shoot the chart about a stop darker.")
                : L10n.tr("\(result.tooBright) patches too bright to use. Shoot the chart about a stop darker.")
        }
        if result.heldOut >= result.before { return L10n.tr("No gain over the camera’s own colour in this light") }
        if result.matrixOnly { return L10n.tr("A simpler profile: the chart didn’t support a finer one") }
        let usable = result.patches.filter(\.usable).count
        return usable < 24 ? L10n.tr("\(usable) of 24 patches used") : model.chart?.filename ?? ""
    }
    private var statusIsWarning: Bool {
        guard let result = model.result else { return false }
        return result.tooBright > 0 || result.heldOut >= result.before
    }
    private var statusHelp: String {
        guard let result = model.result, result.matrixOnly else { return "" }
        return L10n.tr("The profile is a matrix alone: a hue and saturation table didn’t hold on patches it hadn’t seen.")
    }
}
