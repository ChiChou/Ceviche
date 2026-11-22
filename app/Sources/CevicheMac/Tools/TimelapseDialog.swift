import SwiftUI
import ImageIO
import CevicheCore

struct TimelapseDialog: View {
    @ObservedObject var catalog: CatalogModel
    @StateObject private var model: TimelapseModel
    init(catalog: CatalogModel, request: TimelapseRequest) {
        self.catalog = catalog; _model = StateObject(wrappedValue: TimelapseModel(request: request, key: catalog.selected?.id))
    }

    private var live: Bool { model.output == .livePhoto }

    var body: some View {
        // The title bar names the tool and says what stops it; the length and size are read at the top of the options.
        ToolWorkspace(title: live ? L10n.tr("Live Photo") : L10n.tr("Timelapse Video"), status: problem ?? "", statusIsWarning: problem != nil, statusHelp: problem ?? "",
                      primary: live ? L10n.tr("Add Live Photo to Photos") : L10n.tr("Create Video…"), primaryDisabled: !model.canCreate,
                      cancel: { model.close(catalog: catalog) }, action: { model.create(catalog: catalog) }) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    player.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
                    ToolSidePanel(width: 340) { TimelapseOptions(model: model, summary: summary, pace: livePace) }
                }
                Rule()
                TimelapseFilmstrip(model: model, catalog: catalog).padding(.horizontal, 16).padding(.vertical, 10).background(Theme.panel)
            }
        }
        .onAppear { model.start(catalog: catalog) }
        .onDisappear { model.stop() }
    }

    /// A Live Photo plays for about 3 seconds: what to change when it is much shorter or longer.
    private var livePace: String? {
        guard live, problem == nil, model.stage == .ready else { return nil }
        if model.livePhotoSeconds > LivePhoto.movieSeconds + 0.5 { return L10n.tr("A Live Photo plays for about 3 seconds. Raise the frame rate or remove frames.") }
        if model.livePhotoSeconds < 1 { return L10n.tr("A Live Photo plays for about 3 seconds. Lower the frame rate or add photos.") }
        return nil
    }

    /// Why the video can’t be made yet, shown in the title bar.
    private var problem: String? {
        guard model.stage == .ready else { return nil }
        if model.offline.isEmpty { return model.validationError }
        return model.offline.count == 1 ? L10n.tr("The original of \(model.offline[0]) is offline. Reconnect it or remove it to make the video.")
            : L10n.tr("\(model.offline.count) originals are offline. Reconnect or remove them to make the video.")
    }

    private var summary: String {
        guard model.stage == .ready else { return L10n.tr("\(model.request.assets.count) photos") }
        if live {
            let size = model.livePhotoSize
            return [L10n.tr("\(model.livePhotoFrameCount) frames"),
                    L10n.tr("\(Self.duration(model.livePhotoSeconds)) at \(model.settings.frameRate.title)"),
                    "\(Int(size.width)) × \(Int(size.height))"].joined(separator: " - ")
        }
        let photos = model.frames.count, count = model.plan?.frames.count ?? photos
        let size = model.outputSize
        var parts = [count == photos ? L10n.tr("\(count) frames") : L10n.tr("\(photos) photos make \(count) video frames"),
                     L10n.tr("\(Self.duration(model.settings.duration(frames: count))) at \(model.settings.frameRate.title)"),
                     "\(Int(size.width)) × \(Int(size.height))"]
        if let interval = model.series?.interval { parts.append(L10n.tr("shot every \(Self.duration(interval))")) }
        return parts.joined(separator: " - ")
    }
    static func list(_ names: [String]) -> String {
        names.count <= 3 ? names.joined(separator: ", ") : names.prefix(3).joined(separator: ", ") + L10n.tr(" and \(names.count - 3) more")
    }
    static func duration(_ seconds: Double) -> String {
        if seconds < 10 { return L10n.tr("\(seconds.formatted(.number.precision(.fractionLength(0...2)))) s") }
        if seconds < 60 { return L10n.tr("\(seconds.formatted(.number.precision(.fractionLength(0...1)))) s") }
        let total = Int(seconds.rounded())
        return total < 3600 ? String(format: "%d:%02d", total / 60, total % 60) : String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    // MARK: Player

    private var player: some View {
        VStack(spacing: 10) {
            ZStack {
                Color.black.opacity(0.22)
                switch model.stage {
                case .reading(let fraction):
                    VStack(spacing: 10) {
                        Text(L10n.tr("Reading capture times…")).font(.callout)
                        ProgressView(value: fraction).progressViewStyle(.linear).frame(width: 180)
                    }
                case .ready:
                    if model.mode == .crop {
                        TimelapseCropCanvas(image: model.thumbnail, ratio: model.ratio, crop: $model.settings.crop)
                    } else {
                        videoFrame
                    }
                }
            }
            .clipped()
            // Crop on the preview it changes; how the paused frame was made beside it.
            .overlay(alignment: .topTrailing) {
                if model.stage == .ready {
                    NightSkyIconButton(icon: "crop", label: L10n.tr("Crop"), on: model.mode == .crop) { model.mode = model.mode == .crop ? .video : .crop }
                        .background(.black.opacity(model.mode == .crop ? 0 : 0.45), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                        .environment(\.colorScheme, .dark)
                        .help(L10n.tr("Crop: edit the video’s frame on the preview, drag it to move it, a corner to resize it"))
                        .padding(10)
                }
            }
            .overlay(alignment: .bottomTrailing) { renderNote.padding(10) }
            transport
        }
    }

    /// Whether the paused frame comes from the original or the library's preview, or why it couldn't be made.
    @ViewBuilder private var renderNote: some View {
        if model.mode == .video && model.stage == .ready {
            HStack(spacing: 5) {
                if model.renderingFrame { ProgressView().controlSize(.mini) }
                if let error = model.renderError {
                    Label(L10n.tr("Frame unavailable"), systemImage: "exclamationmark.circle").help(error)
                } else if !model.playing {
                    Text(model.rendered != nil ? L10n.tr("Rendered from the original") : L10n.tr("Library preview"))
                }
            }
            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 7).padding(.vertical, 3).background(.black.opacity(0.45), in: Capsule())
        }
    }

    /// The video's frame: the thumbnail cut to the crop while playing, the rendered frame once paused.
    private var videoFrame: some View {
        GeometryReader { geometry in
            let output = live ? model.livePhotoSize : model.outputSize
            let fit = min(geometry.size.width / output.width, geometry.size.height / output.height)
            let box = CGSize(width: output.width * fit, height: output.height * fit)
            ZStack {
                Color.black
                if let rendered = model.rendered?.image {
                    Image(decorative: rendered, scale: 1).resizable().interpolation(.high)
                } else if let image = model.thumbnail {
                    let size = CGSize(width: image.width, height: image.height)
                    let rect = model.settings.crop.rect(in: size, aspect: model.ratio)
                    let scale = box.width / max(1, rect.width)
                    Image(decorative: image, scale: 1).resizable().interpolation(.medium)
                        .frame(width: size.width * scale, height: size.height * scale)
                        .offset(x: (size.width / 2 - rect.midX) * scale, y: (size.height / 2 - rect.midY) * scale)
                }
            }
            .frame(width: box.width, height: box.height).clipped()
            .overlay(alignment: .topLeading) { if live { LivePhotoBadge() } }
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
    }

    private var transport: some View {
        let count = max(1, model.frames.count)
        return HStack(spacing: 10) {
            Button { model.step(-1) } label: { Image(systemName: "backward.frame.fill") }.help(L10n.tr("Previous frame"))
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button { model.playing.toggle() } label: { Image(systemName: model.playing ? "pause.fill" : "play.fill").frame(width: 18) }
                .help(model.playing ? L10n.tr("Pause") : L10n.tr("Play")).keyboardShortcut(.space, modifiers: [])
            Button { model.step(1) } label: { Image(systemName: "forward.frame.fill") }.help(L10n.tr("Next frame"))
                .keyboardShortcut(.rightArrow, modifiers: [])
            FormSlider(value: Binding(get: { Double(model.index) }, set: { model.playing = false; model.index = Int($0.rounded()) }),
                   in: 0...Double(max(1, count - 1)))
                .accessibilityLabel(L10n.tr("Frame"))
            VStack(alignment: .trailing, spacing: 1) {
                Text(L10n.tr("\(model.index + 1) of \(count)")).monospacedDigit()
                Text(model.captures.indices.contains(model.index) ? model.captures[model.index].filename : " ")
                    .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }.frame(width: 130, alignment: .trailing)
        }
        .buttonStyle(.borderless).font(.system(size: 11)).disabled(model.stage != .ready || model.frames.count < 2)
    }
}

/// The photo with the video's frame over it: drag inside the frame to move it, drag a corner to resize it in its
/// proportions, double-click to fill the photo again.
private struct TimelapseCropCanvas: View {
    let image: CGImage?
    let ratio: Double
    @Binding var crop: TimelapseCrop
    @State private var drag: (kind: DragKind, start: CGRect)?
    private enum DragKind { case move, corner(Int) }
    private static let handle: CGFloat = 16

    var body: some View {
        GeometryReader { geometry in
            if let image {
                let size = CGSize(width: image.width, height: image.height)
                let fit = min((geometry.size.width - 24) / size.width, (geometry.size.height - 24) / size.height)
                let photo = CGRect(x: (geometry.size.width - size.width * fit) / 2, y: (geometry.size.height - size.height * fit) / 2,
                                   width: size.width * fit, height: size.height * fit)
                let pixels = crop.rect(in: size, aspect: ratio)
                let frame = CGRect(x: photo.minX + pixels.minX * fit, y: photo.minY + pixels.minY * fit, width: pixels.width * fit, height: pixels.height * fit)
                ZStack(alignment: .topLeading) {
                    Image(decorative: image, scale: 1).resizable().interpolation(.medium)
                        .frame(width: photo.width, height: photo.height).position(x: photo.midX, y: photo.midY)
                    Path { path in path.addRect(photo); path.addRect(frame) }
                        .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                    Path { path in
                        for third in [1.0 / 3, 2.0 / 3] {
                            path.move(to: CGPoint(x: frame.minX + frame.width * third, y: frame.minY)); path.addLine(to: CGPoint(x: frame.minX + frame.width * third, y: frame.maxY))
                            path.move(to: CGPoint(x: frame.minX, y: frame.minY + frame.height * third)); path.addLine(to: CGPoint(x: frame.maxX, y: frame.minY + frame.height * third))
                        }
                    }.stroke(Color.white.opacity(0.35), lineWidth: 0.5)
                    Rectangle().stroke(Color.white, lineWidth: 1).frame(width: frame.width, height: frame.height).position(x: frame.midX, y: frame.midY)
                    ForEach(0..<4, id: \.self) { corner in
                        let point = Self.corner(corner, of: frame)
                        Rectangle().fill(Color.white).frame(width: 9, height: 9).position(point)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                    if drag == nil {
                        if let corner = (0..<4).first(where: { hypot(Self.corner($0, of: frame).x - value.startLocation.x, Self.corner($0, of: frame).y - value.startLocation.y) < Self.handle }) {
                            drag = (.corner(corner), pixels)
                        } else if frame.contains(value.startLocation) {
                            drag = (.move, pixels)
                        } else { return }
                    }
                    guard let drag else { return }
                    switch drag.kind {
                    case .move:
                        let moved = drag.start.offsetBy(dx: value.translation.width / fit, dy: value.translation.height / fit)
                        crop = TimelapseCrop.framing(moved, in: size, aspect: ratio)
                    case .corner(let corner):
                        // The opposite corner stays put; the frame follows the pointer in its own proportions.
                        let anchor = Self.corner((corner + 2) % 4, of: drag.start)
                        let pointer = CGPoint(x: (value.location.x - photo.minX) / fit, y: (value.location.y - photo.minY) / fit)
                        let width = max(abs(pointer.x - anchor.x), abs(pointer.y - anchor.y) * ratio)
                        let height = width / ratio
                        let x = pointer.x < anchor.x ? anchor.x - width : anchor.x
                        let y = pointer.y < anchor.y ? anchor.y - height : anchor.y
                        crop = TimelapseCrop.framing(CGRect(x: x, y: y, width: width, height: height), in: size, aspect: ratio)
                    }
                }.onEnded { _ in drag = nil })
                .onTapGesture(count: 2) { crop = TimelapseCrop() }
                .accessibilityLabel(L10n.tr("Video frame"))
                .help(L10n.tr("Drag the frame to move it, a corner to resize it. Double-click to fill the photo."))
            } else {
                ContentUnavailableView(L10n.tr("No preview yet"), systemImage: "photo", description: Text(L10n.tr("The library hasn’t made a thumbnail of this photo.")))
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
    }
    /// Corners clockwise from the top left.
    private static func corner(_ index: Int, of rect: CGRect) -> CGPoint {
        switch index {
        case 0: return CGPoint(x: rect.minX, y: rect.minY)
        case 1: return CGPoint(x: rect.maxX, y: rect.minY)
        case 2: return CGPoint(x: rect.maxX, y: rect.maxY)
        default: return CGPoint(x: rect.minX, y: rect.maxY)
        }
    }
}

private struct TimelapseOptions: View {
    @ObservedObject var model: TimelapseModel
    /// The frames, length and size, read at the top; `pace` says when a Live Photo is much shorter or longer than one.
    let summary: String
    let pace: String?
    private var settings: TimelapseSettings { model.settings }
    private var live: Bool { model.output == .livePhoto }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ExportRow(L10n.tr("Output")) {
                FormSegments(title: L10n.tr("Output"), selection: $model.output, options: TimelapseOutput.allCases, label: { $0.title }).labelsHidden().fixedSize()
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(summary).font(.system(size: 12, weight: .medium)).monospacedDigit().fixedSize(horizontal: false, vertical: true)
                if let pace {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(pace).font(.system(size: 11)).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
                        if let rate = model.liveFitRate {
                            Button(L10n.tr("Use \(rate.title)")) { model.settings.frameRate = rate }
                                .buttonStyle(.secondaryAction).controlSize(.small).fixedSize()
                        }
                    }
                }
            }
            if live {
                OptionsHeading(L10n.tr("Live Photo"))
                ExportRow(L10n.tr("Playback")) {
                    FormSegments(title: L10n.tr("Playback"), selection: $model.bounce, options: [false, true],
                                 label: { $0 ? L10n.tr("Bounce") : L10n.tr("Live") }).labelsHidden().fixedSize()
                        .help(model.bounce ? L10n.tr("Plays forward, then backward") : L10n.tr("Plays forward once"))
                }
                LivePhotoSizeRow(settings: $model.settings, ratio: model.ratio, photo: model.captures.first?.size)
                ExportRow(L10n.tr("Frame")) {
                    FormSelect(L10n.tr("Frame"), selection: $model.settings.aspect, valueLabel: settings.aspect.title) {
                        ForEach(VideoAspect.allCases.filter { $0 != .custom }) { aspect in
                            Text(aspect.title).tag(aspect)
                            if aspect == .scope { Divider() }
                        }
                    }.labelsHidden()
                }
                OptionsHeading(L10n.tr("Motion", context: "options group"))
                ExportRow(L10n.tr("Frame rate")) {
                    FormSelect(L10n.tr("Frame rate"), selection: $model.settings.frameRate, valueLabel: settings.frameRate.title) {
                        ForEach(TimelapseModel.liveRates, id: \.self) { Text($0.title).tag($0) }
                    }.labelsHidden()
                }
            } else {
                OptionsHeading(L10n.tr("Video"))
                VideoEncodingOptions(settings: $model.settings, photoSize: model.photoSize,
                                     frames: model.stage == .ready ? model.plan?.frames.count ?? model.frames.count : nil)
                OptionsHeading(L10n.tr("Motion", context: "options group"))
            }
            ExportRow(L10n.tr("Timing")) {
                FormSelect(L10n.tr("Timing"), selection: $model.settings.timing, valueLabel: settings.timing.title) {
                    ForEach(TimelapseTiming.allCases) { Text($0.title).tag($0) }
                }.labelsHidden()
                    .help(L10n.tr("Follow Capture Time places each photo by when it was taken, so bursts keep the series’ pace and pauses are filled; the video can then have more or fewer frames than photos"))
            }
            if settings.timing == .captureTime {
                ExportRow(L10n.tr("Each frame")) {
                    HStack(spacing: 6) {
                        TextField(L10n.tr("Seconds per frame"), value: Binding(get: { settings.frameStep ?? model.usualStep },
                                                                               set: { model.settings.frameStep = $0 > 0 ? $0 : nil }),
                                  format: .number.precision(.fractionLength(0...2))).frame(width: 64).textFieldStyle(.formField)
                        Text(L10n.tr("s of real time")).foregroundStyle(.secondary)
                        if settings.frameStep != nil {
                            Button(L10n.tr("Usual")) { model.settings.frameStep = nil }.buttonStyle(.secondaryAction).controlSize(.small)
                                .help(L10n.tr("The series’ usual interval, \(TimelapseDialog.duration(model.usualStep)): one frame per photo where the shooting was steady"))
                        }
                    }
                }
                ExportRow(L10n.tr("Between photos")) {
                    Picker(L10n.tr("Between photos"), selection: $model.settings.fill) {
                        ForEach(TimelapseFill.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden()
                        .help(L10n.tr("A frame between two photos shows the nearer one, or both mixed by how near each is, which smooths the motion like a longer shutter"))
                }
                ExportRow(L10n.tr("Long pauses")) {
                    HStack(spacing: 6) {
                        Toggle(L10n.tr("Shorten long pauses"), isOn: Binding(get: { settings.pauseLimit != nil }, set: { model.settings.pauseLimit = $0 ? 3 : nil }))
                            .toggleStyle(.formCheckbox).labelsHidden()
                        if let limit = settings.pauseLimit {
                            Text(L10n.tr("Cut to \(limit.formatted(.number.precision(.fractionLength(0...1))))× the interval")).monospacedDigit().lineLimit(1)
                            Stepper(L10n.tr("Longest pause"), value: Binding(get: { limit }, set: { model.settings.pauseLimit = min(50, max(1.5, $0)) }), in: 1.5...50, step: 0.5)
                                .labelsHidden()
                        } else {
                            Text(L10n.tr("Kept in real time")).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }.help(L10n.tr("A pause longer than this is cut to it, so a break in shooting doesn’t become a long, slow dissolve"))
                }
            }
            Rule()
            Toggle(L10n.tr("Stabilize"), isOn: $model.settings.stabilize)
                .toggleStyle(.formCheckbox)
                .help(L10n.tr("For a tripod: moves each photo back by the drift measured on the land, cropping slightly to cover it. Frames that moved more than a tripod drifts are left as they are."))
            if settings.stabilize, let status = stabilizeStatus {
                Text(status).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            if model.output == .video {
                Toggle(L10n.tr("Sky Noise Reduction"), isOn: $model.settings.temporalDenoise)
                    .toggleStyle(.formCheckbox)
                    .help(L10n.tr("Aligns up to five nearby photos to reduce noise in starry skies. Requires the Sky model."))
                VideoEncodingOptions.metadataToggle($model.settings.includeMetadata)
            }
            if model.request.latent == nil { LatentCheckbox(type: LatentImage.timelapse).toggleStyle(.formCheckbox) }
            Text(footnote).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
    }
    private var stabilizeStatus: String? {
        if model.stabilizing { return L10n.tr("Measuring drift…") }
        guard let steady = model.stabilization else { return nil }
        if steady.followedSky { return L10n.tr("No steady land to hold") }
        let moved = steady.shifts.filter { $0 != nil && $0 != .zero }.count
        guard moved > 0 else { return L10n.tr("Already steady") }
        let crop = Double(max(steady.margin.width, steady.margin.height) * 200).formatted(.number.precision(.fractionLength(1)))
        return moved == 1 ? L10n.tr("1 frame moved back, \(crop) % crop") : L10n.tr("\(moved) frames moved back, \(crop) % crop")
    }
    private var footnote: String {
        let order = L10n.tr("Frames are ordered by the capture time in each original’s metadata.")
        if model.output == .livePhoto { return order }
        let depth = settings.codec.isProRes ? L10n.tr("ProRes keeps 10 bits per channel, 12 in 4444.") : ""
        let range = settings.fileColor.isHDR
            ? L10n.tr("Photos edited in HDR keep their highlights up to their HDR headroom; the preview here shows them in SDR.")
            : L10n.tr("The video is SDR; HDR edits are tone mapped.")
        return [order, depth, range].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// A group's name in the options column.
private struct OptionsHeading: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title).font(.system(size: 10, weight: .semibold)).textCase(.uppercase).tracking(1).foregroundStyle(.secondary)
            .padding(.top, 6).accessibilityAddTraits(.isHeader)
    }
}
