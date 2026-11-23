import SwiftUI
import Charts
import CoreImage
import CevicheCore

/// What the Timelapse Deflicker dialog shows and changes: the frames in capture order, their measured light, the
/// target curve (smoothed light, plus keyframes drawn on it) and the Exposure each frame gets.
@MainActor
final class ExposureRampModel: ObservableObject {
    enum Stage: Equatable { case reading(Double), measuring(Int), ready, failed(String) }

    let request: ExposureRampRequest
    @Published private(set) var stage: Stage = .reading(0)
    @Published private(set) var frames: [CatalogAsset] = []
    @Published private(set) var ramp: ExposureRamp?
    @Published private(set) var offline: [String] = []
    @Published private(set) var interval: Double?
    @Published var reference = 0
    /// The frame the side panel shows.
    @Published var selected = 0
    /// Offsets in EV drawn onto the target curve, by frame (`ExposureRamp.offsets`).
    @Published var keyframes: [Int: Double] = [:]
    @Published var options: ExposureRamp.Options {
        didSet {
            if options.smoothing != oldValue.smoothing, let ramp { self.ramp = ExposureRamp(measured: ramp.measured, current: ramp.current, smoothing: options.smoothing) }
            if let data = try? JSONEncoder().encode(options) { UserDefaults.standard.set(data, forKey: Self.preferenceKey) }
        }
    }
    private(set) var thumbnails: [Data?] = []
    /// Decoded thumbnails and their renders at each Exposure change, so dragging a slider only renders what changed.
    private var decoded: [Int: CIImage] = [:]
    private var rendered: [String: CGImage] = [:]
    private var task: Task<Void, Never>?
    private static let preferenceKey = "exposureRampOptions"
    private let context = CIContext(options: [.cacheIntermediates: false])

    init(request: ExposureRampRequest) {
        self.request = request
        options = UserDefaults.standard.data(forKey: Self.preferenceKey).flatMap { try? JSONDecoder().decode(ExposureRamp.Options.self, from: $0) } ?? ExposureRamp.Options()
    }

    var proposal: (values: [Double], clamped: Int) { ramp?.exposures(reference: reference, options: options, keyframes: keyframes) ?? ([], 0) }
    /// The offset the keyframes give each frame.
    var offsets: [Double] { ExposureRamp.offsets(keyframes, count: frames.count) }
    /// Frames whose Exposure the proposal changes.
    var changes: [String: Double] {
        guard let ramp else { return [:] }
        var changes: [String: Double] = [:]
        for (index, value) in proposal.values.enumerated() where abs(value - ramp.current[index]) >= 0.005 { changes[frames[index].id] = value }
        return changes
    }

    func start(catalog: CatalogModel) {
        guard task == nil else { return }
        task = Task {
            let assets = request.assets
            // Capture order from EXIF, as the timelapse dialog uses; offline originals are left out.
            var captures: [TimelapseCapture] = [], available: [CatalogAsset] = [], missing: [String] = []
            for (number, asset) in assets.enumerated() {
                if Task.isCancelled { return }
                guard let url = try? await catalog.resolveOriginal(asset) else { missing.append(asset.filename); continue }
                let capture = await Task.detached(priority: .userInitiated) {
                    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    return TimelapseCapture.read(url, filename: asset.filename)
                }.value
                captures.append(capture); available.append(asset)
                if number % 16 == 0 { stage = .reading(Double(number + 1) / Double(assets.count)) }
            }
            offline = missing
            guard available.count >= 3 else { abort(catalog: catalog, L10n.tr("Timelapse Deflicker needs three or more photos whose originals are available.")); return }
            let series = TimelapseSeries(captures)
            frames = series.order.map { available[$0] }
            interval = series.interval
            reference = frames.firstIndex { $0.id == request.referenceID } ?? 0
            selected = reference
            stage = .measuring(0)
            do {
                let measured = try await catalog.measureExposure(frames) { done in self.stage = .measuring(done) }
                ramp = ExposureRamp(measured: measured.map(\.light), current: measured.map(\.exposure), smoothing: options.smoothing)
            } catch {
                if !Task.isCancelled { abort(catalog: catalog, error.localizedDescription) }
                return
            }
            var thumbnails: [Data?] = []
            for asset in frames { thumbnails.append(try? await catalog.previews?.data(assetID: asset.id)) }
            self.thumbnails = thumbnails
            stage = .ready
        }
    }
    /// Setup failed outright (an original missing, photos the tool can't take): there is nothing to work with, so the
    /// tool closes and says why.
    private func abort(catalog: CatalogModel, _ message: String) {
        stop(); catalog.exposureRamp = nil
        catalog.failure = Failure(L10n.tr("Can’t Deflicker These Photos"), message)
    }
    func stop() { task?.cancel() }

    /// The Library thumbnail of frame `index`, brightened or darkened by `ev`: an approximation of the result, since
    /// the thumbnail is already tone-mapped.
    func thumbnail(_ index: Int, ev: Double = 0) -> CGImage? {
        // Steps of 0.05 EV look the same in a thumbnail and keep the cache small.
        let step = abs(ev) > 0.005 ? (ev * 20).rounded() / 20 : 0
        let key = "\(index) \(step)"
        if let image = rendered[key] { return image }
        guard thumbnails.indices.contains(index), let data = thumbnails[index], var image = decoded[index] ?? CIImage(data: data) else { return nil }
        decoded[index] = image
        if step != 0 { image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: step]) }
        guard let result = context.createCGImage(image, from: image.extent) else { return nil }
        if rendered.count > 400 { rendered.removeAll() }
        rendered[key] = result
        return result
    }
    /// The chart's light axis: everything the target can reach from this reference with any option and the current
    /// keyframes, so the plot keeps its scale while a slider is dragged (and, frozen by the chart, while a keyframe
    /// is). The result is linear in the light kept, so its ends bound it. Half stops of margin.
    var lightDomain: ClosedRange<Double> {
        guard let ramp else { return 0...1 }
        var values = ramp.result(ramp.current)
        for keep in [0.0, 1.0] {
            for deflicker in [true, false] {
                var bound = options; bound.keep = keep; bound.deflicker = deflicker
                values += ramp.result(ramp.exposures(reference: reference, options: bound, keyframes: keyframes).values)
            }
        }
        let low = floor((values.min() ?? 0) * 2 - 1) / 2, high = ceil((values.max() ?? 1) * 2 + 1) / 2
        return low...max(high, low + 1)
    }

    /// Sets the keyframe at `frame` to `offset` EV, within what Exposure can reach.
    func setKeyframe(_ frame: Int, _ offset: Double) {
        keyframes[frame] = (min(5, max(-5, offset)) * 100).rounded() / 100
    }
}

struct ExposureRampDialog: View {
    @ObservedObject var catalog: CatalogModel
    @ObservedObject var editor: EditorModel
    @StateObject private var model: ExposureRampModel
    /// The frame under the pointer in the chart or the correction lane.
    @State private var hover: Int?
    /// While a keyframe is dragged: its frame, its offset and the light under the pointer when the drag began, and the
    /// light axis, held still so the curve doesn't rescale under the pointer.
    @State private var drag: (frame: Int, offset: Double, light: Double, domain: ClosedRange<Double>, moved: Bool)?
    init(catalog: CatalogModel, editor: EditorModel, request: ExposureRampRequest) {
        self.catalog = catalog; self.editor = editor
        _model = StateObject(wrappedValue: ExposureRampModel(request: request))
    }

    var body: some View {
        let count = model.changes.count
        ToolWorkspace(title: L10n.tr("Timelapse Deflicker"), status: summary,
                      primary: count == 1 ? L10n.tr("Apply to 1 Photo") : L10n.tr("Apply to \(count) Photos"),
                      primaryDisabled: model.stage != .ready || count == 0 || !catalog.canStartJob, cancel: close,
                      action: { catalog.applyExposureRamp(model.frames, exposures: model.changes, editor: editor); close() }) {
            switch model.stage {
            case .reading(let fraction):
                progress(L10n.tr("Reading capture times…"), fraction: fraction)
            case .measuring(let done):
                progress(L10n.tr("Measuring the light of \(done) of \(model.frames.count) photos…"), fraction: Double(done) / Double(max(1, model.frames.count)))
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                HStack(spacing: 0) {
                    GeometryReader { geometry in
                        VStack(alignment: .leading, spacing: 12) {
                            framePreview.frame(maxHeight: .infinity)
                            VStack(alignment: .leading, spacing: 6) {
                                chartHeader
                                chart.frame(height: min(320, max(180, geometry.size.height * 0.3)))
                                correctionLane.frame(height: 56)
                            }
                            filmstrip
                        }
                    }.padding(16)
                    ToolSidePanel { sidePanel }
                }
            }
        }
        .onAppear { model.start(catalog: catalog) }
        .onDisappear { model.stop() }
    }

    private func close() { model.stop(); catalog.exposureRamp = nil }

    private var summary: String {
        var parts = [L10n.tr("\(model.request.assets.count) photos")]
        if let ramp = model.ramp, let low = ramp.smoothed.min(), let high = ramp.smoothed.max() {
            parts.append(L10n.tr("light varies by \(Self.ev(high - low))"))
        }
        if let interval = model.interval { parts.append(L10n.tr("shot every \(TimelapseDialog.duration(interval))")) }
        return parts.joined(separator: " - ")
    }
    static func ev(_ value: Double, signed: Bool = false, digits: Int = 1) -> String {
        let text = value.formatted(.number.precision(.fractionLength(digits)).sign(strategy: signed ? .always(includingZero: false) : .automatic))
        return L10n.tr("\(text) EV")
    }

    private func progress(_ text: String, fraction: Double) -> some View {
        VStack(spacing: 10) {
            ProgressView(value: fraction).frame(maxWidth: 320)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Chart

    private var measuredColor: Color { Theme.ink.opacity(0.45) }
    private var corrections: [Double] {
        guard let ramp = model.ramp else { return [] }
        return zip(model.proposal.values, ramp.current).map { $0 - $1 }
    }

    /// The legend on the left, and the readout of the frame under the pointer (or the selected one) on the right.
    private var chartHeader: some View {
        let frame = hover ?? model.selected
        return HStack(spacing: 14) {
            legend(L10n.tr("Measured")) { Capsule().fill(measuredColor).frame(width: 14, height: 2) }
            legend(L10n.tr("Target")) { Capsule().fill(Theme.accent).frame(width: 14, height: 3) }
            legend(L10n.tr("Keyframe")) { Circle().strokeBorder(Theme.accent, lineWidth: 2).frame(width: 9, height: 9) }
            Spacer(minLength: 8)
            if let ramp = model.ramp, model.frames.indices.contains(frame) {
                let now = ramp.measured[frame] + ramp.current[frame], target = ramp.measured[frame] + model.proposal.values[frame]
                Text(model.frames[frame].filename).foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
                readout(L10n.tr("Light"), "\(Self.ev(now, digits: 2)) → \(Self.ev(target, digits: 2))")
                readout(L10n.tr("Exposure"), Self.ev(corrections[frame], signed: true, digits: 2))
            }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
    }
    private func legend<Swatch: View>(_ title: String, @ViewBuilder swatch: () -> Swatch) -> some View {
        HStack(spacing: 5) { swatch(); Text(title) }
    }
    private func readout(_ title: String, _ value: String) -> some View {
        HStack(spacing: 4) { Text(title); Text(value).foregroundStyle(.primary) }
    }

    private struct Point: Identifiable { let id: Int; let series: Int; let frame: Int; let value: Double }

    private var chart: some View {
        let ramp = model.ramp!, after = ramp.result(model.proposal.values), now = ramp.result(ramp.current)
        let count = now.count
        let points = now.enumerated().map { Point(id: $0.offset, series: 0, frame: $0.offset, value: $0.element) }
            + after.enumerated().map { Point(id: $0.offset + count, series: 1, frame: $0.offset, value: $0.element) }
        let domain = drag?.domain ?? model.lightDomain
        let frameLabel = L10n.tr("Frame"), lightLabel = L10n.tr("Light (EV)")
        return Chart {
            ForEach(Array(ramp.transitions.enumerated()), id: \.offset) { _, transition in
                RectangleMark(xStart: .value(frameLabel, Double(transition.start)), xEnd: .value(frameLabel, Double(transition.end)))
                    .foregroundStyle(Theme.warning.opacity(0.08))
            }
            RuleMark(x: .value(frameLabel, model.selected)).foregroundStyle(Theme.accent.opacity(0.25)).lineStyle(StrokeStyle(lineWidth: 6))
            RuleMark(x: .value(frameLabel, model.reference))
                .foregroundStyle(Theme.ink.opacity(0.4)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .annotation(position: .top, alignment: .leading, spacing: 2) {
                    Text(L10n.tr("Reference")).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                }
            if let hover, hover != model.selected {
                RuleMark(x: .value(frameLabel, hover)).foregroundStyle(Theme.ink.opacity(0.18))
            }
            ForEach(points) { point in
                LineMark(x: .value(frameLabel, point.frame), y: .value(lightLabel, point.value), series: .value("series", point.series))
                    .foregroundStyle(point.series == 1 ? Theme.accent : measuredColor)
                    .lineStyle(StrokeStyle(lineWidth: point.series == 1 ? 2.5 : 1, lineJoin: .round))
                    .interpolationMethod(.linear)
            }
            if count <= 200 {
                ForEach(0..<count, id: \.self) { frame in
                    PointMark(x: .value(frameLabel, frame), y: .value(lightLabel, now[frame])).symbolSize(10).foregroundStyle(measuredColor)
                }
            }
            ForEach(model.keyframes.keys.sorted(), id: \.self) { frame in
                PointMark(x: .value(frameLabel, frame), y: .value(lightLabel, after[frame]))
                    .symbol { Circle().fill(Theme.panel).overlay(Circle().strokeBorder(Theme.accent, lineWidth: 2)).frame(width: 11, height: 11) }
            }
            if let hover, model.keyframes[hover] == nil {
                PointMark(x: .value(frameLabel, hover), y: .value(lightLabel, after[hover])).symbolSize(36).foregroundStyle(Theme.accent.opacity(0.6))
            }
        }
        .chartXScale(domain: 0...max(1, count - 1))
        .chartYScale(domain: domain)
        .chartYAxis { AxisMarks(position: .trailing, values: .stride(by: domain.upperBound - domain.lowerBound > 6 ? 2 : 0.5)) }
        .chartYAxisLabel(lightLabel, position: .trailing)
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        if case .active(let location) = phase { hover = frame(at: location.x, proxy: proxy, geometry: geometry) } else if drag == nil { hover = nil }
                    }
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in dragged(value, proxy: proxy, geometry: geometry) }
                        .onEnded { _ in
                            if let drag, !drag.moved { model.selected = drag.frame }
                            drag = nil
                        })
                    .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { tap in
                        guard let frame = frame(at: tap.location.x, proxy: proxy, geometry: geometry) else { return }
                        // The nearest keyframe within a few frames, so a handle needn't be hit exactly.
                        let reach = max(1, count / 60)
                        if let key = model.keyframes.keys.filter({ abs($0 - frame) <= reach }).min(by: { abs($0 - frame) < abs($1 - frame) }) {
                            model.keyframes[key] = nil
                        }
                    })
            }
        }
        .help(L10n.tr("Drag the target to set a frame's light. Double-click a keyframe to remove it."))
    }

    private func frame(at x: CGFloat, proxy: ChartProxy, geometry: GeometryProxy) -> Int? {
        guard let plot = proxy.plotFrame, let value: Double = proxy.value(atX: x - geometry[plot].origin.x) else { return nil }
        return min(model.frames.count - 1, max(0, Int(value.rounded())))
    }

    /// Starts or continues a keyframe drag: the frame where the drag began moves with the pointer, by the light the
    /// pointer has moved since. A press that barely moves only selects that frame.
    private func dragged(_ value: DragGesture.Value, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let plot = proxy.plotFrame else { return }
        let origin = geometry[plot].origin
        if drag == nil {
            guard let frame = frame(at: value.startLocation.x, proxy: proxy, geometry: geometry),
                  let light: Double = proxy.value(atY: value.startLocation.y - origin.y) else { return }
            drag = (frame, model.keyframes[frame] ?? model.offsets[frame], light, model.lightDomain, false)
        }
        guard var current = drag else { return }
        if !current.moved && hypot(value.translation.width, value.translation.height) < 3 { return }
        current.moved = true
        drag = current
        hover = current.frame; model.selected = current.frame
        if let light: Double = proxy.value(atY: value.location.y - origin.y) { model.setKeyframe(current.frame, current.offset + light - current.light) }
    }

    /// Each frame's Exposure change, as bars around zero; orange where the ±5 EV Exposure stops it short.
    private var correctionLane: some View {
        let values = corrections, exposures = model.proposal.values, count = values.count
        let reach = max(0.5, (values.map(abs).max() ?? 0).rounded(.up))
        let frameLabel = L10n.tr("Frame"), changeLabel = L10n.tr("Exposure")
        return Chart {
            RuleMark(y: .value(changeLabel, 0)).foregroundStyle(Theme.ink.opacity(0.25))
            ForEach(0..<count, id: \.self) { frame in
                let limited = abs(exposures[frame]) >= ExposureRamp.exposureRange.upperBound - 0.005
                BarMark(x: .value(frameLabel, frame), y: .value(changeLabel, values[frame]), width: .ratio(0.7))
                    .foregroundStyle(limited ? Theme.warning : frame == model.selected ? Theme.accent : Theme.accent.opacity(0.55))
            }
        }
        .chartXScale(domain: -0.5...Double(max(1, count - 1)) + 0.5)
        .chartYScale(domain: -reach...reach)
        .chartXAxis(.hidden)
        .chartYAxis { AxisMarks(position: .trailing, values: [-reach, 0, reach]) }
        .chartYAxisLabel(changeLabel, position: .trailing)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        if case .active(let location) = phase { hover = frame(at: location.x, proxy: proxy, geometry: geometry) } else { hover = nil }
                    }
                    .onTapGesture { location in if let frame = frame(at: location.x, proxy: proxy, geometry: geometry) { model.selected = frame } }
            }
        }
    }

    /// Every frame, as it would look balanced, with its Exposure change; the reference and keyframes are marked.
    private var filmstrip: some View {
        let values = corrections
        return ScrollViewReader { reader in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 6) {
                    ForEach(model.frames.indices, id: \.self) { index in
                        VStack(spacing: 3) {
                            ZStack(alignment: .topLeading) {
                                Rectangle().fill(Theme.ink.opacity(0.06))
                                    .overlay { if let image = model.thumbnail(index, ev: values.indices.contains(index) ? values[index] : 0) { Image(decorative: image, scale: 1).resizable().scaledToFill() } }
                                    .frame(width: 108, height: 72).clipped()
                                    .selectionRing(index == model.selected ? Theme.accent : nil)
                                HStack(spacing: 3) {
                                    if index == model.reference { badge(L10n.tr("Ref")) }
                                    if model.keyframes[index] != nil { Circle().fill(Theme.accent).frame(width: 7, height: 7).padding(3) }
                                }.padding(3)
                            }
                            Text(values.indices.contains(index) ? Self.ev(values[index], signed: true, digits: 2) : "")
                                .font(.system(size: 9)).monospacedDigit().foregroundStyle(index == model.selected ? .primary : .secondary)
                        }
                        .id(index)
                        .contentShape(Rectangle())
                        .onTapGesture { model.selected = index }
                        .contextMenu {
                            Button(L10n.tr("Use as Reference")) { model.reference = index }.disabled(index == model.reference)
                            Button(L10n.tr("Remove Keyframe")) { model.keyframes[index] = nil }.disabled(model.keyframes[index] == nil)
                        }
                        .help(model.frames[index].filename)
                    }
                }.padding(.vertical, 2)
            }
            .frame(height: 98)
            .onChange(of: model.selected) { _, selected in withAnimation(.easeOut(duration: 0.15)) { reader.scrollTo(selected, anchor: .center) } }
        }
    }
    private func badge(_ text: String) -> some View {
        Text(text).font(.system(size: 8, weight: .semibold)).padding(.horizontal, 4).padding(.vertical, 1)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.Radius.tag)).foregroundStyle(Theme.onAccent)
    }

    /// The selected frame as shot and balanced, as large as the window allows.
    @ViewBuilder private var framePreview: some View {
        let index = model.selected
        if model.frames.indices.contains(index) {
            let change = corrections.indices.contains(index) ? corrections[index] : 0
            HStack(spacing: 8) {
                preview(model.thumbnail(index), L10n.tr("As Shot"))
                preview(model.thumbnail(index, ev: change), L10n.tr("Balanced"))
            }
        }
    }

    // MARK: Side panel

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            selectedFrame
            Rule()
            options
            findings
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The selected frame as shot and balanced, with its numbers and what can be done with it.
    @ViewBuilder private var selectedFrame: some View {
        let index = model.selected
        if let ramp = model.ramp, model.frames.indices.contains(index) {
            let change = corrections[index]
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(model.frames[index].filename).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(L10n.tr("\(index + 1) of \(model.frames.count)")).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                    GridRow { Text(L10n.tr("Exposure")).foregroundStyle(.secondary)
                        Text("\(Self.ev(ramp.current[index], signed: true, digits: 2)) → \(Self.ev(model.proposal.values[index], signed: true, digits: 2))") }
                    if let key = model.keyframes[index] {
                        GridRow { Text(L10n.tr("Keyframe")).foregroundStyle(.secondary); Text(Self.ev(key, signed: true, digits: 2)) }
                    }
                }.font(.system(size: 11)).monospacedDigit()
                HStack(spacing: 8) {
                    Button(L10n.tr("Use as Reference")) { model.reference = index }.disabled(index == model.reference)
                        .help(L10n.tr("The reference keeps its Exposure; the others follow the target. Other edits stay as they are."))
                    if model.keyframes[index] != nil {
                        Button { model.keyframes[index] = nil } label: { Image(systemName: "trash") }
                            .help(L10n.tr("Remove Keyframe")).accessibilityLabel(L10n.tr("Remove Keyframe"))
                    }
                }.buttonStyle(.secondaryAction).controlSize(.small)
            }
        }
    }
    private func preview(_ image: CGImage?, _ caption: String) -> some View {
        Color.black.opacity(0.22)
            .overlay { if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() } }
            .overlay(alignment: .topLeading) {
                Text(caption).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.control)).padding(8)
            }
            .clipped()
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            ExportRow(L10n.tr("Keep change")) {
                HStack(spacing: 8) {
                    FormSlider(value: $model.options.keep, in: 0...1).accessibilityLabel(L10n.tr("Light change to keep")).frame(maxWidth: 120)
                    Text(L10n.tr("\(Int((model.options.keep * 100).rounded()))%")).monospacedDigit().frame(width: 35, alignment: .trailing)
                }.help(L10n.tr("How much of the change in light to keep. 0% holds it level; 100% leaves it as shot."))
            }
            ExportRow(L10n.tr("Flicker")) {
                Toggle(L10n.tr("Remove flicker"), isOn: $model.options.deflicker)
            }
            ExportRow(L10n.tr("Smoothing")) {
                FormStepper(L10n.tr("Smoothing"), value: Binding(get: { model.ramp?.window ?? 5 }, set: { model.options.smoothing = max(3, $0 | 1) }), in: 3...81, step: 2) {
                    Text(L10n.tr("\(model.ramp?.window ?? 5) frames")).monospacedDigit()
                }
            }
            ExportRow(L10n.tr("Keyframes")) {
                HStack(spacing: 8) {
                    Text(model.keyframes.isEmpty ? L10n.tr("None") : "\(model.keyframes.count)").monospacedDigit()
                    Spacer(minLength: 0)
                    Button { model.keyframes = [:] } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.secondaryAction).controlSize(.small).disabled(model.keyframes.isEmpty)
                        .help(L10n.tr("Remove All Keyframes")).accessibilityLabel(L10n.tr("Remove All Keyframes"))
                }
            }
        }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var findings: some View {
        let transitions = model.ramp?.transitions ?? [], clamped = model.proposal.clamped
        if !transitions.isEmpty || clamped > 0 || !model.offline.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(transitions.enumerated()), id: \.offset) { _, transition in
                    let from = model.frames[transition.start].filename, to = model.frames[transition.end].filename
                    let change = Self.ev(abs(transition.change)), count = transition.end - transition.start + 1
                    Label(transition.change < 0 ? L10n.tr("\(from) to \(to): the light falls \(change) over \(count) frames")
                          : L10n.tr("\(from) to \(to): the light rises \(change) over \(count) frames"),
                          systemImage: transition.change < 0 ? "sunset" : "sunrise")
                }
                if clamped > 0 {
                    Label(clamped == 1 ? L10n.tr("1 photo needs more than the ±5 EV Exposure allows; keep more of the change.")
                          : L10n.tr("\(clamped) photos need more than the ±5 EV Exposure allows; keep more of the change."), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                }
                if !model.offline.isEmpty {
                    Label(L10n.tr("Left out, original offline: \(TimelapseDialog.list(model.offline))"), systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }
}
