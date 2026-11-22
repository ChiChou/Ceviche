import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CevicheCore

/// The sheets as they'll come out of the printer, filling the canvas: every copy at its true proportions, the selected
/// photo's copies outlined and any copy whose photo needs a fix or a retake marked. Click a copy to select its photo,
/// double-click to adjust its framing, right-click for the rest.
struct IDPhotoSheetCanvas: View {
    @ObservedObject var session: IDPhotoSession
    let export: (IDPhotoModel) -> Void
    /// Pinch zoom, as a factor of the fitted size.
    @State private var zoom = 1.0
    @GestureState private var pinch = 1.0
    @Environment(\.displayScale) private var displayScale
    /// Zoomed in no further than a copy at about four times its print size (the previews hold no more), and out
    /// to half the fitted size to see more sheets at once.
    static let maxPointsPerMM = 16.0, minZoom = 0.5

    var body: some View {
        VStack(spacing: 10) {
            if let layout = session.layout, !session.sheetPreviews.isEmpty {
                GeometryReader { geometry in
                    let fitted = min(geometry.size.height, 720) / paperSize(layout).height
                    let maxZoom = max(1, Self.maxPointsPerMM / fitted)
                    let shown = min(maxZoom, max(Self.minZoom, zoom * pinch))
                    ScrollView([.horizontal, .vertical]) {
                        HStack(spacing: 28) {
                            let pages = session.pages
                            ForEach(Array(session.sheetPreviews.enumerated()), id: \.offset) { index, sheet in
                                page(sheet, places: index < pages.count ? pages[index] : [], layout: layout, scale: fitted * shown)
                            }
                        }.frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                    }
                    .gesture(MagnifyGesture()
                        .updating($pinch) { value, state, _ in state = value.magnification }
                        .onEnded { value in zoom = min(maxZoom, max(Self.minZoom, zoom * value.magnification)) })
                    .onChange(of: fitted * min(maxZoom, max(Self.minZoom, zoom)), initial: true) { _, scale in
                        session.showSheets(atPixelsPerMM: scale * displayScale)
                    }
                }
                Text(caption(layout)).font(.system(size: 11)).foregroundStyle(.secondary)
            } else if session.layout != nil, session.ready.count == session.photos.count {
                ContentUnavailableView(L10n.tr("No Copies"), systemImage: "rectangle.dashed",
                                       description: Text(L10n.tr("Every photo is left out. Give one a copy in the side panel or the strip below.")))
            } else {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(L10n.tr("Developing…")).font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(24)
        .background(Theme.imageSurround)
    }

    private func caption(_ layout: IDPhotoLayout) -> String {
        let pages = session.sheetPreviews.count, copies = session.counts.reduce(0, +)
        if layout.sheet.paper == .single { return L10n.tr("\(pages) photos at \(layout.spec.sizeTitle)") }
        return L10n.tr("\(layout.sheet.paper.title) · \(copies) photos on \(pages) sheets · \(layout.sheet.spacing.title)")
    }

    /// The paper in mm: the sheet, or the print itself on Single Photo paper.
    private func paperSize(_ layout: IDPhotoLayout) -> CGSize {
        var full = layout.sheet; full.copies = nil
        let arrangement = layout.sheet.paper == .single ? nil : full.arrangement(for: layout.spec)
        return arrangement?.paper ?? CGSize(width: layout.spec.widthMM, height: layout.spec.heightMM)
    }

    /// One sheet (or one print) at `scale` points per mm, with a place over each copy for selecting it and its menu.
    private func page(_ image: CGImage, places: [Int], layout: IDPhotoLayout, scale: CGFloat) -> some View {
        let single = layout.sheet.paper == .single
        var full = layout.sheet; full.copies = nil
        let arrangement = single ? nil : full.arrangement(for: layout.spec)
        let paper = paperSize(layout)
        let origins = arrangement?.origins ?? [.zero]
        return ZStack(alignment: .topLeading) {
            Image(decorative: image, scale: 1).resizable().interpolation(.high)
            ForEach(Array(zip(places.indices, places)), id: \.0) { slot, index in
                if slot < origins.count, session.photos.indices.contains(index) {
                    place(session.photos[index], index: index, size: CGSize(width: layout.spec.widthMM * scale, height: layout.spec.heightMM * scale))
                        .offset(x: origins[slot].x * scale, y: origins[slot].y * scale)
                }
            }
        }
        .frame(width: paper.width * scale, height: paper.height * scale)
        .shadow(color: .black.opacity(0.45), radius: 10, y: 3)
    }

    private func place(_ photo: IDPhotoModel, index: Int, size: CGSize) -> some View {
        // A single photo's copies are all the same photo; outlining them would only be noise.
        let selected = session.isBatch && index == session.current
        return Color.clear
            .frame(width: size.width, height: size.height)
            // The system's selection colour: the accent can be neutral, which vanishes against white paper.
            .overlay { if selected { Rectangle().strokeBorder(IDPhotoReadinessTag.selection, lineWidth: 2.5).padding(-3) } }
            .overlay(alignment: .topTrailing) {
                if photo.readiness != .ready {
                    Image(systemName: IDPhotoReadinessTag.symbol(photo.readiness))
                        .font(.system(size: max(10, min(16, size.width * 0.12))))
                        .symbolRenderingMode(.palette).foregroundStyle(.white, IDPhotoReadinessTag.colour(photo.readiness))
                        .shadow(radius: 1).padding(3)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { session.current = index; session.adjusting = true }
            .onTapGesture { session.current = index }
            .help("\(photo.asset.filename) · \(photo.readinessTitle)")
            .contextMenu {
                Button(L10n.tr("Adjust Framing…")) { session.current = index; session.adjusting = true }
                Button(L10n.tr("Export This Photo…")) { export(photo) }
                Divider()
                if session.layout?.sheet.paper != .single {
                    Button(L10n.tr("Remove This Copy")) { session.setCopies(session.copies(of: photo) - 1, of: photo) }
                }
                if session.isBatch {
                    Button(L10n.tr("Leave Out \(photo.asset.filename)")) { session.leaveOut(photo) }
                    Button(L10n.tr("Remove from ID Photo")) { session.remove(photo) }
                }
            }
    }
}

/// The photo around the head with the print's frame on it, the spec's reference lines, and markers for the crown, the
/// chin and the eyes to drag.
struct IDPhotoCanvas: View {
    @ObservedObject var model: IDPhotoModel
    @State private var dragging: Marker?
    @Environment(\.displayScale) private var displayScale
    enum Marker { case crown, chin, eyes }

    /// What the canvas needs rendered at full resolution: the part of the photo in view and its size on screen.
    struct DetailNeed: Equatable { var region: CGRect; var size: CGSize; var generation: Int }

    var body: some View {
        GeometryReader { geometry in
            if let preview = (model.pickingNeutral ? nil : model.replaced) ?? model.preview, let layout = model.layout {
                let map = Mapping(view: geometry.size, image: CGSize(width: preview.width, height: preview.height), region: model.visibleRegion)
                ZStack(alignment: .topLeading) {
                    Theme.imageSurround
                    Image(decorative: preview, scale: 1).resizable().interpolation(.high)
                        .frame(width: map.imageRect.width, height: map.imageRect.height)
                        .offset(x: map.imageRect.minX, y: map.imageRect.minY)
                    if let detail = model.detail {
                        let origin = map.view(detail.region.origin)
                        Image(decorative: detail.image, scale: 1).resizable().interpolation(.high)
                            .frame(width: detail.region.width * map.imageRect.width, height: detail.region.height * map.imageRect.height)
                            .offset(x: origin.x, y: origin.y)
                    }
                    Canvas { context, _ in draw(layout, map: map, in: &context) }.allowsHitTesting(false)
                    handle(.crown, at: layout.crown, map: map, layout: layout)
                    handle(.chin, at: layout.chin, map: map, layout: layout)
                    if let eyes = layout.eyes { handle(.eyes, at: eyes, map: map, layout: layout) }
                    if model.pickingNeutral {
                        // Over the markers, so the click picks rather than moves one.
                        Color.clear.contentShape(Rectangle())
                            .onTapGesture(coordinateSpace: .local) { model.pickNeutral(at: map.fraction($0)) }
                            .onContinuousHover { phase in if case .active = phase { NSCursor.crosshair.set() } else { NSCursor.arrow.set() } }
                    }
                }
                // The photo is larger than the canvas; only the part over it shows.
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                // Opaque, so the photo, markers and guides don't show through around the print.
                .overlay { if model.showingActualSize { actualSize } }
                .clipped()
                .overlay(alignment: .bottomTrailing) { actualSizeButton.padding(10) }
                .task(id: need(map: map, view: geometry.size)) {
                    let need = need(map: map, view: geometry.size)
                    if need.size == .zero { model.dropDetail() } else { model.requestDetail(need.region, size: need.size) }
                }
                .onAppear { measureScreen() }
            }
        }
    }

    /// Full resolution is needed once a preview pixel spans more than a screen pixel; nothing below that.
    private func need(map: Mapping, view: CGSize) -> DetailNeed {
        let screenPerPreview = displayScale * map.imageRect.width / map.image.width
        guard screenPerPreview > 1.05 else { return DetailNeed(region: .zero, size: .zero, generation: model.detailGeneration) }
        let shown = CGRect(origin: map.fraction(.zero), size: CGSize(width: view.width / map.imageRect.width, height: view.height / map.imageRect.height))
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !shown.isNull, shown.width > 0, shown.height > 0 else { return DetailNeed(region: .zero, size: .zero, generation: model.detailGeneration) }
        // No more pixels than the photo has.
        let full = model.renderer?.size ?? map.image
        let wanted = CGSize(width: shown.width * map.imageRect.width * displayScale, height: shown.height * map.imageRect.height * displayScale)
        let limit = min(1, shown.width * full.width / max(1, wanted.width))
        return DetailNeed(region: shown, size: CGSize(width: (wanted.width * limit).rounded(), height: (wanted.height * limit).rounded()), generation: model.detailGeneration)
    }

    private var actualSizeButton: some View {
        Button { model.showingActualSize.toggle() } label: {
            Label(L10n.tr("Actual Size"), systemImage: "ruler").font(.system(size: 11))
        }
        .buttonStyle(.borderless).foregroundStyle(model.showingActualSize ? Theme.accent : .primary)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .help(L10n.tr("Actual size: the print as large as it will be on paper"))
        .accessibilityAddTraits(model.showingActualSize ? .isSelected : [])
    }

    /// The print at physical size, alone on the canvas's surround; a click puts it away.
    private var actualSize: some View {
        ZStack {
            Theme.imageSurround.contentShape(Rectangle()).onTapGesture { model.showingActualSize = false }
            if let image = model.actualSize {
                Image(decorative: image, scale: displayScale).interpolation(.high)
                    .shadow(color: .black.opacity(0.45), radius: 10, y: 3)
                    .onTapGesture { model.showingActualSize = false }
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    /// The screen's physical size, for Actual Size; a display that doesn't report one is taken as 110 points per inch.
    private func measureScreen() {
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        var pointsPerMM = 110 / 25.4
        if let screen, let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            let millimetres = CGDisplayScreenSize(CGDirectDisplayID(number.uint32Value))
            if millimetres.width > 0 { pointsPerMM = screen.frame.width / millimetres.width }
        }
        model.screenScale = (pointsPerMM, Double(screen?.backingScaleFactor ?? displayScale))
    }


    struct Mapping {
        let imageRect: CGRect
        let image: CGSize
        init(view: CGSize, image: CGSize, region: CGRect) {
            self.image = image
            let regionPixels = CGSize(width: region.width * image.width, height: region.height * image.height)
            let scale = min(view.width / max(1, regionPixels.width), view.height / max(1, regionPixels.height))
            let x = (view.width - regionPixels.width * scale) / 2 - region.minX * image.width * scale
            let y = (view.height - regionPixels.height * scale) / 2 - region.minY * image.height * scale
            imageRect = CGRect(x: x, y: y, width: image.width * scale, height: image.height * scale)
        }
        /// A point given as fractions of the photo, on screen.
        func view(_ fraction: CGPoint) -> CGPoint { CGPoint(x: imageRect.minX + fraction.x * imageRect.width, y: imageRect.minY + fraction.y * imageRect.height) }
        func fraction(_ point: CGPoint) -> CGPoint { CGPoint(x: (point.x - imageRect.minX) / imageRect.width, y: (point.y - imageRect.minY) / imageRect.height) }
        /// A point of the print, in millimetres, on screen.
        func view(_ frame: IDPhotoFrame, mm: CGPoint) -> CGPoint {
            let p = frame.photoPoint(mm: mm)
            return view(CGPoint(x: p.x / image.width, y: p.y / image.height))
        }
    }

    private func draw(_ layout: IDPhotoLayout, map: Mapping, in context: inout GraphicsContext) {
        let frame = layout.frame(in: map.image), spec = layout.spec
        let w = spec.widthMM, h = spec.heightMM
        func line(_ y: Double) -> Path {
            Path { $0.move(to: map.view(frame, mm: CGPoint(x: 0, y: y))); $0.addLine(to: map.view(frame, mm: CGPoint(x: w, y: y))) }
        }
        func band(_ y0: Double, _ y1: Double) -> Path {
            Path { path in
                path.addLines([CGPoint(x: 0, y: y0), CGPoint(x: w, y: y0), CGPoint(x: w, y: y1), CGPoint(x: 0, y: y1)].map { map.view(frame, mm: $0) })
                path.closeSubpath()
            }
        }
        let outline = band(0, h)
        // Outside the print is dimmed.
        var outside = Path(CGRect(origin: .zero, size: CGSize(width: 1e5, height: 1e5)).offsetBy(dx: -5e4, dy: -5e4))
        outside.addPath(outline)
        context.fill(outside, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))
        context.stroke(outline, with: .color(.white), lineWidth: 1)

        // Where the spec allows the crown, the chin and the eyes.
        let allowed = Color.green.opacity(0.16)
        if let crown = spec.crownRange { context.fill(band(crown.lowerBound, crown.upperBound), with: .color(allowed)) }
        context.fill(band(frame.crownMM + spec.headRange.lowerBound, frame.crownMM + spec.headRange.upperBound), with: .color(allowed))
        if let eye = spec.eyeRange { context.fill(band(h - eye.upperBound, h - eye.lowerBound), with: .color(Color.cyan.opacity(0.16))) }

        let centre = Path { $0.move(to: map.view(frame, mm: CGPoint(x: w / 2, y: 0))); $0.addLine(to: map.view(frame, mm: CGPoint(x: w / 2, y: h))) }
        context.stroke(centre, with: .color(.white.opacity(0.45)), style: StrokeStyle(lineWidth: 0.75, dash: [4, 4]))
        func colour(_ ok: Bool?) -> Color { ok == false ? Theme.reject : Color.green }
        context.stroke(line(frame.crownMM), with: .color(colour(frame.crownInRange)), lineWidth: 1.5)
        context.stroke(line(frame.chinMM), with: .color(colour(frame.headInRange)), lineWidth: 1.5)
        if layout.eyes != nil {
            context.stroke(line(frame.eyeMM), with: .color(spec.eyeRange == nil ? .cyan.opacity(0.7) : colour(frame.eyeInRange)),
                           style: StrokeStyle(lineWidth: 1, dash: [6, 3]))
        }
    }

    private func handle(_ marker: Marker, at point: CGPoint, map: Mapping, layout: IDPhotoLayout) -> some View {
        let position = map.view(point)
        let title = switch marker { case .crown: L10n.tr("Crown"); case .chin: L10n.tr("Chin"); case .eyes: L10n.tr("Eyes") }
        return Circle()
            .fill(dragging == marker ? Color.white : Color.white.opacity(0.85))
            .overlay { Circle().strokeBorder(Color.black.opacity(0.6), lineWidth: 1) }
            .frame(width: 11, height: 11)
            .frame(width: 26, height: 26).contentShape(Rectangle())
            .position(position)
            .help(title)
            .accessibilityLabel(title)
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                dragging = marker
                let p = map.fraction(drag.location)
                let clamped = CGPoint(x: min(1, max(0, p.x)), y: min(1, max(0, p.y)))
                switch marker {
                case .crown: model.layout?.crown = clamped
                case .chin: model.layout?.chin = clamped
                case .eyes: model.layout?.eyes = clamped
                }
            }.onEnded { _ in dragging = nil })
    }
}
