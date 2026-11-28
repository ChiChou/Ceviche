import SwiftUI
import AppKit
import CevicheCore

/// Undo and Redo in the Edit menu for the open night-sky tool.
struct NightSkyUndoCommands: View {
    @ObservedObject var history: NightSkyHistory
    var body: some View {
        Button(L10n.tr("Undo"), action: history.undo).keyboardShortcut("z").disabled(history.undoStack.isEmpty)
        Button(L10n.tr("Redo"), action: history.redo).keyboardShortcut("z", modifiers: [.command, .shift]).disabled(history.redoStack.isEmpty)
    }
}

/// Opens the requested tool's own window.
struct NightSkyView: View {
    @ObservedObject var catalog: CatalogModel
    let request: NightSkyRequest
    var body: some View {
        switch request.tool {
        case .starTrails: StarTrailsView(catalog: catalog, request: request)
        case .denoise: NightSkyDenoiseView(catalog: catalog, request: request)
        case .meteorShower: MeteorShowerView(catalog: catalog, request: request)
        }
    }
}

/// The pieces the three tools share: like HDR merge, the preview fills the window, the photos run in a strip below, the
/// options sit in one row under the title bar, and Cancel and Merge are in the title bar.
struct NightSkyChrome<Workflow: NightSkyWorkflow, Toolbar: View, Sidebar: View, Overlay: View>: View {
    @ObservedObject var catalog: CatalogModel
    @ObservedObject var model: NightSkyModel<Workflow>
    let status: String
    let statusIsWarning: Bool
    /// The preview to show instead of the model's, as when comparing with the reference photo.
    var image: CGImage?
    /// The title bar's main button: Merge, or Render Video… for a tool making a video.
    var primaryTitle = L10n.tr("Merge")
    /// Whether the overlay takes drags on the preview, as while a video's frame is edited, so they don't pan it.
    var overlayTakesDrags = false
    /// Whether the main button also offers a TIFF of processed photos: not for a video.
    var offersTIFF = true
    let onMerge: (ProcessedFormat) -> Void
    @ViewBuilder let toolbar: () -> Toolbar
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let overlay: () -> Overlay
    let filmstrip: [NightSkyFrameInfo]
    let cell: (NightSkyFrameInfo) -> NightSkyFrameCell
    @State private var keyMonitor: Any?
    @State private var host = HostWindow()
    /// Shared by the night sky tools, and kept across launches.
    @AppStorage("nightSkyFilmstripHeight") private var filmstripHeight = 138.0
    private static var filmstripHeights: ClosedRange<Double> { 118...320 }
    private var stripHeight: Double { min(Self.filmstripHeights.upperBound, max(Self.filmstripHeights.lowerBound, filmstripHeight)) }

    /// The tool's cell with its photo as tall as the strip allows: 80 points at the default height.
    private func sizedCell(_ frame: NightSkyFrameInfo) -> NightSkyFrameCell {
        var shown = cell(frame)
        shown.thumbnailHeight = stripHeight - 58
        return shown
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rule()
            ToolOptionsBar {
                toolbar()
                if !model.opensLatent {
                    Rule(.vertical).frame(height: 16)
                    LatentCheckbox(type: model.request.tool.rawValue) { if $0 { model.latentTicked() } }
                }
            }.disabled(model.analysis == nil)
            Rule()
            HStack(spacing: 0) {
                canvas
                sidebar()
            }
            if !filmstrip.isEmpty {
                // Above the preview, so the line it draws while dragging shows over it.
                FilmstripResizeHandle(height: $filmstripHeight, range: Self.filmstripHeights, defaultHeight: 138).zIndex(1)
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) { ForEach(filmstrip) { sizedCell($0) } }.padding(.horizontal, 16).padding(.vertical, 10)
                }
                .frame(height: stripHeight).background(Theme.statusBar)
            }
        }
        .background(Theme.canvas)
        .disabled(model.closing)
        .alert(L10n.tr("Other Lines Found"), isPresented: Binding(get: { model.askingAboutLines }, set: { _ in })) {
            Button(L10n.tr("Use New Lines"), role: .destructive) { model.useNewLines() }
            Button(L10n.tr("Keep Previous Lines"), role: .cancel) { model.keepPreviousLines() }
        } message: {
            Text(L10n.tr("Aligning again found other lines. Using them clears the lines you chose."))
        }
        .onDisappear { model.stop() }
        .onExitCommand { model.close(catalog: catalog) }
    }

    private var header: some View {
        ToolHeader(title: model.request.tool.title, status: currentStatus, statusIsWarning: warning) {
            ToolCancelButton(title: model.analysis == nil ? L10n.tr("Cancel") : L10n.tr("Close")) { model.close(catalog: catalog) }
            if model.skyChangedSinceAligning, model.stage == .ready {
                Button(L10n.tr("Align Again")) { model.alignAgain() }.buttonStyle(.secondaryAction)
                    .help(L10n.tr("The stars were found and aligned with the sky as it was. Aligning again uses the corrected sky, which matters most when the sky finder missed part of it."))
            }
            if offersTIFF, CatalogModel.processed(model.request.assets) {
                SplitActionButton(title: primaryTitle, action: { onMerge(.original) }, options: [(L10n.tr("Merge to TIFF"), { onMerge(.tiff) })]).disabled(!model.canMerge)
            } else {
                ToolPrimaryButton(title: primaryTitle, action: { onMerge(.original) }).disabled(!model.canMerge)
            }
        }
    }

    private var currentStatus: String {
        if case .failed(let message) = model.stage { return message }
        return model.previewError ?? model.saveError ?? status
    }
    private var warning: Bool {
        if case .failed = model.stage { return true }
        return model.previewError != nil || model.saveError != nil || statusIsWarning
    }

    /// The preview on the shared canvas. The outlines, the sky tint and the brush lie over the picture at its shown
    /// size, so they move and zoom with it and keep their own line widths; while a brush is up, dragging paints.
    private var canvas: some View {
        ZStack {
            ZoomCanvas(image: image ?? model.preview?.image, dragPans: model.brush == nil && !overlayTakesDrags) { _ in
                if model.showSky, let sky = model.preview?.sky {
                    Color.cyan.opacity(0.35).mask(Image(decorative: sky, scale: 1).resizable().interpolation(.high).luminanceToAlpha())
                }
                overlay()
                NightSkyBrush(strokes: model.brush == .photo ? $model.settings.photoRegions : $model.settings.skyStrokes, mode: model.brush, diameter: model.brushDiameter)
            }
            if model.stage == .ready, model.showSky {
                NightSkyMaskBar(brush: $model.brush, settings: $model.settings)
                    .frame(maxHeight: .infinity, alignment: .top).transition(.opacity)
            }
            switch model.stage {
            case .preparing(let message, let fraction): ToolProgressCard(message: message, fraction: fraction)
            case .failed(let message):
                ContentUnavailableView { Label { Text(L10n.tr("Can’t Combine These Photos")) } icon: { NightSkyToolIcon(tool: model.request.tool) } }
                    description: { Text(message) }
            case .unstackable: NightSkyUnstackableCard(model: model, catalog: catalog)
            case .ready: if model.rendering { ToolProgressCard(message: L10n.tr("Creating preview…")).transition(.opacity) }
            }
        }
        .background(HostWindowReader(host: host))
        .onAppear { watchBrushKeys() }
        .onDisappear { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil }
    }

    /// [ and ] make the brush smaller and larger, unless a text field is being typed in.
    private func watchBrushKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard host.owns(event) else { return event }
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty, let key = event.charactersIgnoringModifiers,
                  key == "[" || key == "]", !(event.window?.firstResponder is NSText) else { return event }
            model.brushDiameter = NightSkyBrushSize.stepped(model.brushDiameter, larger: key == "]")
            return nil
        }
    }
}

/// Painting over the preview: each drag lays dabs a few percent of the width across, committed when the drag ends so the
/// preview redraws once per stroke. Areas from one photo show as a tint while painting; sky strokes show in the sky tint
/// once the preview redraws, so only the stroke being drawn shows here.
struct NightSkyBrush: View {
    @Binding var strokes: [NightSkyStroke]
    let mode: NightSkyBrushMode?
    /// The brush's width on screen in points, whatever the zoom, so a zoomed preview paints finer.
    let diameter: CGFloat
    @State private var pending: [NightSkyStroke] = []
    /// Where the pointer is, for showing the brush's size under it.
    @State private var pointer: CGPoint?
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            Canvas { context, size in
                guard let mode else { return }
                // One shape, so overlapping dabs don't darken where they meet.
                var path = Path()
                for stroke in (mode == .photo ? strokes : []) + pending {
                    let r = stroke.radius * size.width
                    path.addEllipse(in: CGRect(x: stroke.x * size.width - r, y: stroke.y * size.height - r, width: 2 * r, height: 2 * r))
                }
                context.fill(path, with: .color(mode == .photo ? NightSkyBrushColor.deghost.opacity(0.35) : mode == .addSky ? NightSkyBrushColor.sky.opacity(0.45) : NightSkyBrushColor.ground.opacity(0.45)))
                if let pointer {
                    // A dark ring under a light one, so the outline shows on sky and ground alike.
                    let ring = Path(ellipseIn: CGRect(x: pointer.x - diameter / 2, y: pointer.y - diameter / 2, width: diameter, height: diameter))
                    context.stroke(ring, with: .color(.black.opacity(0.6)), lineWidth: 3)
                    context.stroke(ring, with: .color(.white.opacity(0.9)), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in if case .active(let location) = phase { pointer = location } else { pointer = nil } }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    pointer = value.location
                    let radius = Double(diameter / 2 / max(1, size.width))
                    let point = NightSkyStroke(x: max(0, min(1, value.location.x / size.width)), y: max(0, min(1, value.location.y / size.height)), radius: radius,
                                               sky: mode?.sky)
                    // Dabs half a radius apart make a continuous stroke; a fast drag reports positions further apart, so the
                    // dabs between them are filled in.
                    guard let last = pending.last else { pending.append(point); return }
                    let step = radius * size.width / 2, distance = hypot((point.x - last.x) * size.width, (point.y - last.y) * size.height)
                    guard distance >= step else { return }
                    let count = Int((distance / step).rounded(.up))
                    for i in 1...count {
                        let t = Double(i) / Double(count)
                        pending.append(NightSkyStroke(x: last.x + (point.x - last.x) * t, y: last.y + (point.y - last.y) * t, radius: radius, sky: point.sky))
                    }
                }
                .onEnded { _ in strokes += pending; pending = [] })
            .allowsHitTesting(mode != nil)
        }
    }
}

/// The brush's size: a slider and a number in a popover from the toolbar, and [ and ] while the window is open.
struct NightSkyBrushSize: View {
    @Binding var diameter: Double
    @State private var showing = false
    static let range: ClosedRange<Double> = 4...400
    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 3) {
                Circle().strokeBorder(lineWidth: 1.2).frame(width: 11, height: 11)
                Text(verbatim: "\(Int(diameter.rounded()))").monospacedDigit()
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .frame(height: 22).padding(.horizontal, 5).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.tr("Brush size, in points on screen; [ and ] make it smaller and larger"))
        .accessibilityLabel(L10n.tr("Brush Size"))
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            HStack(spacing: 10) {
                Text(L10n.tr("Size"))
                FormSlider(value: Binding(get: { log(diameter) }, set: { diameter = Self.clamped(exp($0)).rounded() }), in: log(Self.range.lowerBound)...log(Self.range.upperBound))
                    .frame(width: 160)
                TextField(L10n.tr("Size"), value: Binding(get: { Int(diameter.rounded()) }, set: { diameter = Self.clamped(Double($0)) }), format: .number)
                    .textFieldStyle(.formField).labelsHidden().frame(width: 52).multilineTextAlignment(.trailing)
                Text(L10n.tr("pt")).foregroundStyle(.secondary)
            }.padding(12)
        }
    }
    static func clamped(_ value: Double) -> Double { min(range.upperBound, max(range.lowerBound, value)) }
    /// One press of [ or ]: about a fifth smaller or larger, and at least a point.
    static func stepped(_ value: Double, larger: Bool) -> Double {
        clamped(larger ? max(value + 1, (value * 1.2).rounded()) : min(value - 1, (value / 1.2).rounded()))
    }
}

/// Undo and Redo for the retouching, as toolbar icons.
struct NightSkyHistoryButtons: View {
    @ObservedObject var history: NightSkyHistory
    var body: some View {
        HStack(spacing: 2) {
            NightSkyIconButton(icon: "arrow.uturn.backward", label: L10n.tr("Undo"), action: history.undo).disabled(history.undoStack.isEmpty)
                .help(L10n.tr("Undoes the last brush stroke or retouching change (⌘Z)"))
            NightSkyIconButton(icon: "arrow.uturn.forward", label: L10n.tr("Redo"), action: history.redo).disabled(history.redoStack.isEmpty)
                .help(L10n.tr("Redoes what Undo took back (⇧⌘Z)"))
        }
    }
}

/// What the mask brushes paint with over the preview, and the colour of each tool.
enum NightSkyBrushColor {
    static let sky = Color.cyan
    static let ground = Color.orange
    static let deghost = Color.purple
}

/// Deghost, the brush that takes areas from the base photo alone, a Clear once it has painted, and while any
/// brush is in use (the sky's included) the size it paints with.
struct NightSkyPhotoBrushes<Settings: NightSkyEditableSettings>: View {
    @Binding var brush: NightSkyBrushMode?
    @Binding var settings: Settings
    @Binding var diameter: Double
    var body: some View {
        HStack(spacing: 6) {
            Button { brush = brush == .photo ? nil : .photo } label: {
                // In the colour it paints with over the preview.
                Label(L10n.tr("Deghost"), systemImage: "figure.walk.motion").labelStyle(.titleAndIcon).fixedSize()
                    .padding(.horizontal, 7).frame(height: 22)
                    .foregroundStyle(brush == .photo ? Color.white : NightSkyBrushColor.deghost)
                    .background(brush == .photo ? NightSkyBrushColor.deghost : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityAddTraits(brush == .photo ? .isSelected : [])
            .help(L10n.tr("Paint over the preview to take those areas from the base photo alone, such as something that moved"))
            // Each shows only while it does something: Clear once there is something to clear, the size while painting.
            if !settings.photoRegions.isEmpty {
                Button(L10n.tr("Clear")) { settings.photoRegions = [] }
                    .buttonStyle(.plain).foregroundStyle(.secondary).fixedSize()
                    .help(L10n.tr("Removes the areas painted from the base photo"))
            }
            if brush != nil { NightSkyBrushSize(diameter: $diameter).fixedSize() }
        }
    }
}

/// Editing the sky mask, over the preview while the mask shows: brushes that add to it and take from it (at the
/// toolbar's brush size), marking the whole frame as sky, and back to the sky as detected. A brush clicked again puts it down.
struct NightSkyMaskBar<Settings: NightSkyEditableSettings>: View {
    @Binding var brush: NightSkyBrushMode?
    @Binding var settings: Settings
    var body: some View {
        HStack(spacing: 4) {
            // Named for what the area is, in the colours they paint with.
            tool(L10n.tr("Sky"), icon: "sparkles", color: NightSkyBrushColor.sky, on: brush == .addSky) { use(.addSky) }
                .help(L10n.tr("Paint over the preview to treat those areas as sky"))
            tool(L10n.tr("Ground"), icon: "mountain.2", color: NightSkyBrushColor.ground, on: brush == .removeSky) { use(.removeSky) }
                .help(L10n.tr("Paint over the preview to keep those areas out of the sky"))
            Rule(.vertical).frame(height: 16).overlay(Color.white.opacity(0.25))
            // An action, not a state: it makes the whole frame sky once, and Ground then takes areas out.
            tool(L10n.tr("Mark All as Sky"), icon: "square.dashed.inset.filled", on: false) { reset(allSky: true) }
                .disabled(settings.allSky && settings.skyStrokes.isEmpty)
                .help(L10n.tr("Makes the whole frame sky, for a photo without ground or a sky that isn’t found well. Ground can then keep areas out."))
            tool(L10n.tr("Revert to Detected"), icon: "arrow.counterclockwise", on: false) { reset(allSky: false) }
                .disabled(settings.skyStrokes.isEmpty && !settings.allSky)
                .help(L10n.tr("Goes back to the sky as it was detected: undoes Mark All as Sky and what the Sky and Ground brushes painted"))
        }
        .font(.callout).foregroundStyle(.white)
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(.black.opacity(0.65), in: Capsule()).environment(\.colorScheme, .dark)
        .padding(12)
    }
    private func use(_ mode: NightSkyBrushMode) { brush = brush == mode ? nil : mode }
    /// The whole frame as sky, or the sky as detected, with nothing painted over it: one change, so one step to undo.
    private func reset(allSky: Bool) {
        var value = settings; value.allSky = allSky; value.skyStrokes = []; settings = value
    }
    private func tool(_ title: String, icon: String, color: Color? = nil, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).labelStyle(.titleAndIcon)
                .padding(.horizontal, 8).frame(height: 24)
                .foregroundStyle(on ? (color == nil ? Theme.onAccent : Color.black) : color ?? Color.white)
                .background(on ? color ?? Theme.accent : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A toolbar icon, lit while its mode is on, with an optional small badge such as + or − in its corner.
struct NightSkyIconButton: View {
    let icon: String
    var badge: String? = nil
    let label: String
    var on = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13))
                .overlay(alignment: .bottomTrailing) {
                    if let badge {
                        Image(systemName: badge).font(.system(size: 7, weight: .black)).padding(1.5)
                            .background(Circle().fill(on ? Theme.accent : Theme.statusBar)).offset(x: 5, y: 4)
                    }
                }
                .frame(width: 28, height: 22)
                .foregroundStyle(on ? Theme.onAccent : Color.primary)
                .background(on ? Theme.accent : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label).accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// What counts as sky, which every tool treats differently: Sky Edge moves the boundary out into the ground or in
/// toward the sky, and Sky Mask beside it tints the sky.
struct NightSkyEdgeControls<Settings: NightSkyEditableSettings>: View {
    @Binding var settings: Settings
    @Binding var showSky: Bool
    var body: some View {
        Text(L10n.tr("Sky Edge")).foregroundStyle(.secondary)
        FormSlider(value: Binding(get: { Double(settings.skyEdge) }, set: { settings.skyEdge = Int($0.rounded()) }), in: -40...40, step: 4).frame(width: 80).labelsHidden()
            .help(L10n.tr("Moves the boundary between sky and ground: right takes more of the skyline as sky, left keeps more of it as ground"))
            .disabled(settings.allSky)
        let edge = settings.skyEdge
        Text(edge == 0 ? L10n.tr("0 px") : L10n.tr("\(edge > 0 ? "+" : "−")\(abs(edge)) px")).font(.callout).monospacedDigit().frame(width: 44, alignment: .leading)
            .foregroundStyle(settings.allSky ? .secondary : .primary)
        Toggle(L10n.tr("Sky Mask"), isOn: $showSky).help(L10n.tr("Tints what is treated as sky and shows the tools that correct it"))
    }
}

/// The photos that can't be stacked with the rest, and the one way past them: leaving them out.
struct NightSkyUnstackableCard<Workflow: NightSkyWorkflow>: View {
    @ObservedObject var model: NightSkyModel<Workflow>
    let catalog: CatalogModel
    var body: some View {
        let photos = model.unstackable
        VStack(alignment: .leading, spacing: 12) {
            Text(photos.count == 1 ? L10n.tr("1 photo can’t be stacked with the others") : L10n.tr("\(photos.count) photos can’t be stacked with the others"))
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(photos, id: \.url) { photo in
                        HStack(spacing: 10) {
                            CatalogThumbnail(asset: photo.asset, previews: catalog.previews, fillsFrame: true).frame(width: 48, height: 32).clipped()
                            Text(photo.asset.filename).monospacedDigit()
                            Text(photo.reason).foregroundStyle(.secondary)
                        }.font(.system(size: 12))
                    }
                }
            }.frame(maxHeight: 260)
            HStack {
                Spacer()
                Button(L10n.tr("Cancel")) { model.close(catalog: catalog) }.buttonStyle(.secondaryAction)
                Button(L10n.tr("Leave Out and Continue")) { model.leaveOutUnstackable() }.buttonStyle(.primaryAction)
            }
        }
        .padding(20).frame(width: 460)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: Theme.Radius.panel)).environment(\.colorScheme, .dark)
    }
}

/// How strongly the meteors kept show in one photo's video frame, and whether one appears in it.
struct NightSkyLaneMark: Equatable {
    var strength: Double
    var starts: Bool
    static let empty = NightSkyLaneMark(strength: 0, starts: false)
}

/// One photo in the strip: click to make it the reference (where the tool has one); the checkbox leaves it out.
struct NightSkyFrameCell: View {
    let frame: NightSkyFrameInfo
    let included: Bool
    let canToggle: Bool
    /// "Reference" or "Base" when this photo is it.
    let badge: String?
    let onToggle: () -> Void
    let onSelect: (() -> Void)?
    let selectHelp: String
    /// The meteors over this photo's video frame, while the strip is a video's timeline; nil for none.
    var lane: NightSkyLaneMark? = nil
    /// The strip sets it from its own height; the photo is half again as wide.
    var thumbnailHeight: CGFloat = 80

    /// A bar as bright as the meteors look in this frame, reaching across the gap to the next photo so a meteor's bars
    /// read as one, with a dot where a meteor appears.
    private func laneBar(_ lane: NightSkyLaneMark, width: CGFloat) -> some View {
        let color = Color(red: 0.35, green: 0.86, blue: 0.45)
        return ZStack(alignment: .leading) {
            Capsule().fill(color.opacity(max(0.12, lane.strength))).frame(width: width + 8, height: 3).opacity(lane.strength > 0 ? 1 : 0)
            if lane.starts { Circle().fill(color).frame(width: 7, height: 7) }
        }
        .frame(width: width, height: 7, alignment: .leading)
        .help(lane.strength > 0 ? L10n.tr("Meteors in this frame of the video") : "")
    }

    var body: some View {
        let width = thumbnailHeight * 1.5
        return VStack(alignment: .leading, spacing: 4) {
            if let lane { laneBar(lane, width: width) }
            ZStack(alignment: .topLeading) {
                ToolFrameThumbnail(image: frame.thumbnail, size: CGSize(width: width, height: thumbnailHeight), outline: badge != nil ? Theme.accent : nil, badge: nil, dimmed: !included)
                    .overlay(alignment: .topLeading) {
                        // The time at the top, the filename under the photo: side by side they don't fit.
                        HStack(spacing: 4) {
                            if let badge { AccentBadge(text: badge) }
                            let time = NightSkyFormat.time(frame.time)
                            if !time.isEmpty {
                                Text(time).font(.system(size: 10, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
                                    .padding(.horizontal, 4).padding(.vertical, 1).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: Theme.Radius.tag)).environment(\.colorScheme, .dark)
                            }
                        }.padding(4)
                    }
                if frame.note != nil || !frame.series.isEmpty {
                    // A triangle suggests leaving the photo out; a circle only says how it differs from the series.
                    Image(systemName: frame.note != nil ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill").font(.system(size: 11))
                        .foregroundStyle(frame.note != nil ? Theme.warning : .yellow)
                        .padding(4).frame(width: width, alignment: .trailing)
                        .help(([frame.note?.text].compactMap { $0 } + frame.series.map(\.text)).joined(separator: "\n"))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onSelect?() }
            .help(onSelect == nil ? frame.filename : selectHelp)
            HStack(spacing: 4) {
                Toggle(isOn: Binding(get: { included }, set: { _ in onToggle() })) { EmptyView() }
                    .labelsHidden().toggleStyle(.formCheckbox).controlSize(.small).disabled(!canToggle)
                    .help(L10n.tr("Include this photo"))
                Text(frame.filename).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }.frame(width: width, alignment: .leading)
        }
    }
}

/// How one line's outline is drawn: two strokes beside it, and with `band` the space between them filled.
struct NightSkyOutlineStyle {
    var color: Color
    var width: CGFloat
    var dashed = false
    var band: Color?
}

/// Outlines of lines over a preview, in the preview's own fractions.
struct NightSkyOutlines: View {
    let preview: NightSkyPreview?
    /// Per line id, how to draw it; lines without a style aren't drawn.
    let style: (Int) -> NightSkyOutlineStyle?
    /// The line under the pointer as it moves, nil off every line; with it set the lines take clicks.
    var point: ((Int?) -> Void)? = nil
    /// The lines clicked or boxed, empty for a click off every line; true with ⌘ or ⇧ held, to add to the selection.
    var select: ((Set<Int>, Bool) -> Void)? = nil
    @State private var box: CGRect?
    /// How far from a line, in points, still counts as on it.
    static let reach: CGFloat = 8
    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                for line in preview?.lines ?? [] {
                    guard let style = style(line.id) else { continue }
                    let (a, b) = ends(line, in: size)
                    // Drawn beside the line, not over it, so the meteor itself stays visible.
                    let d = CGPoint(x: b.x - a.x, y: b.y - a.y), length = max(1, (d.x * d.x + d.y * d.y).squareRoot())
                    let n = CGPoint(x: -d.y / length * 5, y: d.x / length * 5)
                    if let band = style.band {
                        var area = Path()
                        area.addLines([CGPoint(x: a.x - n.x, y: a.y - n.y), CGPoint(x: b.x - n.x, y: b.y - n.y),
                                       CGPoint(x: b.x + n.x, y: b.y + n.y), CGPoint(x: a.x + n.x, y: a.y + n.y)])
                        area.closeSubpath()
                        context.fill(area, with: .color(band))
                    }
                    var path = Path()
                    for side in [-1.0, 1.0] {
                        path.move(to: CGPoint(x: a.x + side * n.x, y: a.y + side * n.y)); path.addLine(to: CGPoint(x: b.x + side * n.x, y: b.y + side * n.y))
                    }
                    context.stroke(path, with: .color(style.color), style: StrokeStyle(lineWidth: style.width, lineCap: .round, dash: style.dashed ? [3, 3] : []))
                }
                if let box {
                    context.fill(Path(box), with: .color(Theme.accent.opacity(0.12)))
                    context.stroke(Path(box), with: .color(Theme.accent), lineWidth: 1)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    if case .active(let location) = phase { point?(line(at: location, in: geometry.size)) } else { point?(nil) }
                }
                .onTapGesture { location in select?(line(at: location, in: geometry.size).map { [$0] } ?? [], Self.adding) }
                .gesture(DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        box = CGRect(x: min(value.startLocation.x, value.location.x), y: min(value.startLocation.y, value.location.y),
                                     width: abs(value.location.x - value.startLocation.x), height: abs(value.location.y - value.startLocation.y))
                    }
                    .onEnded { _ in
                        if let box { select?(lines(in: box, size: geometry.size), Self.adding) }
                        box = nil
                    })
        }.allowsHitTesting(point != nil || select != nil)
    }
    private static var adding: Bool { !NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty }
    private func ends(_ line: (id: Int, start: CGPoint, end: CGPoint), in size: CGSize) -> (CGPoint, CGPoint) {
        (CGPoint(x: line.start.x * size.width, y: line.start.y * size.height), CGPoint(x: line.end.x * size.width, y: line.end.y * size.height))
    }
    /// The nearest line within `reach` of `location`, drawn or not.
    private func line(at location: CGPoint, in size: CGSize) -> Int? {
        var best: (id: Int, distance: CGFloat)?
        for line in preview?.lines ?? [] {
            let (a, b) = ends(line, in: size)
            let d = CGPoint(x: b.x - a.x, y: b.y - a.y), squared = max(1e-6, d.x * d.x + d.y * d.y)
            let t = max(0, min(1, ((location.x - a.x) * d.x + (location.y - a.y) * d.y) / squared))
            let distance = hypot(a.x + t * d.x - location.x, a.y + t * d.y - location.y)
            if distance <= Self.reach, distance < best?.distance ?? .infinity { best = (line.id, distance) }
        }
        return best?.id
    }
    /// The lines any part of which lies in `box`, drawn or not.
    func lines(in box: CGRect, size: CGSize) -> Set<Int> {
        Set((preview?.lines ?? []).filter { line in
            let (a, b) = ends(line, in: size)
            return Self.segment(a, b, crosses: box)
        }.map(\.id))
    }
    /// Whether the segment from `a` to `b` reaches into `box`: clipped to each edge in turn (Liang–Barsky), something remains.
    static func segment(_ a: CGPoint, _ b: CGPoint, crosses box: CGRect) -> Bool {
        let d = CGPoint(x: b.x - a.x, y: b.y - a.y)
        var low: CGFloat = 0, high: CGFloat = 1
        for (p, q) in [(-d.x, a.x - box.minX), (d.x, box.maxX - a.x), (-d.y, a.y - box.minY), (d.y, box.maxY - a.y)] {
            if p == 0 { if q < 0 { return false }; continue }
            let t = q / p
            if p < 0 { low = max(low, t) } else { high = min(high, t) }
            if low > high { return false }
        }
        return true
    }
}

enum NightSkyFormat {
    /// Minutes and seconds from the first photo, or nothing without capture times.
    static func time(_ seconds: Double?) -> String {
        guard let seconds else { return "" }
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
    static func duration(_ seconds: Double) -> String {
        Duration.seconds(seconds.rounded()).localized(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
    }
    static func timing(_ timing: NightSkyTiming?) -> String {
        guard let timing else { return "" }
        var text = L10n.tr(" - \(duration(timing.span)), every \(duration(timing.interval))")
        if timing.gaps == 1 { text += L10n.tr(" - 1 pause") } else if timing.gaps > 1 { text += L10n.tr(" - \(timing.gaps) pauses") }
        return text
    }
    /// How the included photos differ from the series, as the timelapse counts it; pauses are in `timing`.
    static func series(_ frames: [NightSkyFrameInfo], excluded: Set<Int>) -> String {
        let marks = frames.filter { !excluded.contains($0.index) }.map(\.series)
        func count(_ test: (NightSkySeriesMark) -> Bool) -> Int { marks.filter { $0.contains(where: test) }.count }
        // Another exposure time draws a longer or shorter piece of trail per photo, which changes the pace like a burst.
        let faster = count { if case .otherExposure = $0 { true } else { $0 == .faster } }, repeats = count { $0 == .sameTime }, untimed = count { $0 == .missingTime }
        let settings = count { if case .otherSettings = $0 { true } else { false } }
        var parts: [String] = []
        if faster > 0 { parts.append(faster == 1 ? L10n.tr("1 photo off pace") : L10n.tr("\(faster) photos off pace")) }
        if repeats > 0 { parts.append(repeats == 1 ? L10n.tr("1 repeat") : L10n.tr("\(repeats) repeats")) }
        if untimed > 0 { parts.append(untimed == 1 ? L10n.tr("1 photo without capture time") : L10n.tr("\(untimed) photos without capture time")) }
        if settings > 0 { parts.append(settings == 1 ? L10n.tr("1 photo with other settings") : L10n.tr("\(settings) photos with other settings")) }
        return parts.map { " - " + $0 }.joined()
    }
}
