import SwiftUI
import AppKit
import CevicheCore

/// A tool's preview: the picture fitted to the canvas on the image surround, zoomed by pinching or ⌘-scrolling and
/// moved by scrolling or dragging. `overlay` lies over the picture at its shown size, so it moves and zooms with it.
/// A very large picture is drawn reduced, with the part in view at the screen's resolution over it (`ZoomDetail`).
struct ZoomCanvas<Overlay: View>: View {
    let image: CGImage?
    var orientation: Image.Orientation = .up
    /// False leaves dragging to the overlay (a brush, handles); scrolling still moves the picture.
    var dragPans = true
    /// A checkerboard behind the picture, for one with transparent parts (a panorama's uncovered corners).
    var checkerboard = false
    /// False hides the zoom controls, for a tool that shows its own in their place.
    var showsControls = true
    /// Changing it puts the picture back to fitted: for a tool's own Fit button.
    var fit = 0
    /// Shared by canvases of the same size showing versions of one picture, so they zoom and move together.
    var link: Binding<ZoomLink>? = nil
    /// The upright size in pixels of the original `image` is a reduced copy of, so 100% and the zoom limit count the
    /// original's pixels before it is shown whole.
    var fullSize: CGSize? = nil
    /// Each new target zooms to its part of the picture, once the picture is laid out.
    var target: ZoomTarget? = nil
    /// Told the zoom over fitted as it changes.
    var onZoom: ((CGFloat) -> Void)? = nil
    /// A click zooms to 100% at the pointer, and another back to fitted. Only where the picture takes no clicks of its own.
    var clickZooms = false
    /// The shown size of the picture in points, for overlays that place things on it.
    @ViewBuilder var overlay: (CGSize) -> Overlay

    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var pinchStart: (zoom: CGFloat, pan: CGSize)?
    @State private var dragStart: CGSize?
    @State private var pointer: CGPoint?
    @State private var canvasSize: CGSize = .zero
    @State private var scrollMonitor: Any?
    /// The picture's size as last shown. The scroll monitor outlives the view value it was made from, so what it
    /// reads has to be state: the picture itself usually arrives after the canvas appears.
    @State private var picture: CGSize = .zero
    /// What 100% counts: `fullSize`, else the picture.
    @State private var original: CGSize = .zero
    /// A large picture's reduced copy, and the part in view at the resolution the zoom needs.
    @State private var reduced: (source: CGImage, image: CGImage)?
    @State private var piece: ZoomDetail.Piece?
    @State private var pieceTask: Task<Void, Never>?
    /// A target that came before the picture or the canvas had a size.
    @State private var pendingTarget: ZoomTarget?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geometry in
            let area = geometry.size
            ZStack {
                Theme.imageSurround
                // Under the picture, which lets the mouse through: dragging the zoomed picture moves it. The overlay
                // above (a brush, handles) still takes the mouse where it wants it.
                if dragPans {
                    PanCatcher(onDrag: { translation in
                        guard zoom > 1 else { return }
                        guard let translation else { dragStart = nil; return }
                        let start = dragStart ?? pan
                        dragStart = start
                        pan = clamped(CGSize(width: start.width + translation.width, height: start.height + translation.height), zoom: zoom)
                    }, onClick: clickZooms && image != nil ? { clickZoom(at: $0) } : nil)
                }
                if let image {
                    let fitted = fittedSize(in: area, of: imageSize)
                    let size = CGSize(width: fitted.width * zoom, height: fitted.height * zoom)
                    Image(decorative: reduced.flatMap { $0.source === image ? $0.image : nil } ?? image, scale: 1, orientation: orientation)
                        .resizable().interpolation(imagePixelZoom >= 2 ? .none : .high)
                        .background { if checkerboard { Checkerboard() } }
                        .overlay {
                            if let piece, piece.source === image {
                                Image(decorative: piece.image, scale: 1, orientation: orientation).resizable().interpolation(imagePixelZoom >= 2 ? .none : .high)
                                    .frame(width: piece.region.width * size.width, height: piece.region.height * size.height)
                                    .position(x: piece.region.midX * size.width, y: piece.region.midY * size.height)
                            }
                        }
                        .allowsHitTesting(false)
                        .overlay { overlay(CGSize(width: fitted.width * zoom, height: fitted.height * zoom)) }
                        .frame(width: fitted.width * zoom, height: fitted.height * zoom)
                        .position(x: area.width / 2 + pan.width, y: area.height / 2 + pan.height)
                }
            }
            .frame(width: area.width, height: area.height)
            .clipped()
            .contentShape(Rectangle())
            .onContinuousHover { phase in if case .active(let location) = phase { pointer = location } else { pointer = nil } }
            .simultaneousGesture(MagnifyGesture()
                .onChanged { value in
                    let start = pinchStart ?? (zoom, pan)
                    pinchStart = start
                    setZoom(start.zoom * value.magnification, at: value.startLocation, from: start)
                }
                .onEnded { _ in pinchStart = nil })
            .overlay(alignment: .bottomTrailing) { if image != nil, showsControls { zoomControls } }
            .onChange(of: fit) { withAnimation(.easeOut(duration: 0.15)) { zoom = 1; pan = .zero } }
            .onAppear { canvasSize = area; watchScrolling() }
            .onChange(of: area) { _, size in canvasSize = size; pan = clamped(pan, zoom: zoom) }
            .onChange(of: imageSize, initial: true) { _, size in picture = size; original = fullSize ?? size; pan = clamped(pan, zoom: min(zoom, maxZoom)); zoom = min(zoom, maxZoom) }
            .onChange(of: fullSize) { _, size in original = size ?? picture; pan = clamped(pan, zoom: min(zoom, maxZoom)); zoom = min(zoom, maxZoom) }
            .onChange(of: target, initial: true) { _, target in pendingTarget = target; applyTarget() }
            .onDisappear { if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }; scrollMonitor = nil; pieceTask?.cancel() }
            .task(id: image.map { ObjectIdentifier($0) }) {
                piece = nil
                guard let image, ZoomDetail.isLarge(image) else { reduced = nil; return }
                if let copy = await Task.detached(priority: .userInitiated, operation: { ZoomDetail.reduced(image) }).value, !Task.isCancelled {
                    reduced = (image, copy)
                    refreshPiece()
                }
            }
            .onChange(of: zoom) { refreshPiece(); link?.wrappedValue.zoom = zoom; onZoom?(zoom) }
            .onChange(of: pan) { refreshPiece(); link?.wrappedValue.pan = pan }
            .onChange(of: link?.wrappedValue, initial: true) { _, shared in
                guard let shared, shared.zoom != zoom || shared.pan != pan else { return }
                zoom = min(maxZoom, max(1, shared.zoom)); pan = clamped(shared.pan, zoom: zoom)
            }
            .onChange(of: canvasSize) { refreshPiece(); applyTarget() }
            .onChange(of: picture) { applyTarget() }
        }
    }

    /// Fetches the part of a large picture now in view, once the zoom shows more than the reduced copy holds and the
    /// piece already there doesn't cover it. A short wait lets a pinch or a scroll settle first.
    private func refreshPiece() {
        guard let image, let reduced, reduced.source === image, fitted.width > 0, canvasSize.width > 0 else { piece = nil; return }
        let needed = min(1, imagePixelZoom)
        // Until the screen shows more than the reduced copy holds, the copy is all it takes.
        guard needed > CGFloat(reduced.image.width) / CGFloat(image.width) * 1.05 else {
            pieceTask?.cancel(); piece = nil; return
        }
        let size = CGSize(width: fitted.width * zoom, height: fitted.height * zoom)
        let frame = CGRect(x: canvasSize.width / 2 + pan.width - size.width / 2, y: canvasSize.height / 2 + pan.height - size.height / 2, width: size.width, height: size.height)
        let seen = frame.intersection(CGRect(origin: .zero, size: canvasSize))
        guard !seen.isEmpty else { return }
        let visible = CGRect(x: (seen.minX - frame.minX) / size.width, y: (seen.minY - frame.minY) / size.height, width: seen.width / size.width, height: seen.height / size.height)
        if let piece, piece.source === image, piece.region.insetBy(dx: -1e-6, dy: -1e-6).contains(visible), piece.density >= needed * 0.95 { return }
        let orientation = orientation
        pieceTask?.cancel()
        pieceTask = Task {
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            let made = await Task.detached(priority: .userInitiated) { ZoomDetail.piece(of: image, orientation: orientation, visible: visible, density: needed) }.value
            if !Task.isCancelled, let made { piece = made }
        }
    }

    /// The picture's size in pixels, as it is shown.
    private var imageSize: CGSize {
        guard let image else { return .zero }
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored: return CGSize(width: image.height, height: image.width)
        default: return CGSize(width: image.width, height: image.height)
        }
    }
    private func fittedSize(in area: CGSize, of size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        let room = CGSize(width: max(1, area.width - 56), height: max(1, area.height - 56))
        let scale = min(room.width / size.width, room.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
    private var fitted: CGSize { fittedSize(in: canvasSize, of: picture) }
    /// The zoom at which one pixel of the original is one pixel of the screen.
    private var actualSize: CGFloat { fitted.width > 0 ? max(1, original.width / (fitted.width * displayScale)) : 1 }
    /// Screen pixels per pixel of the original.
    private var pixelZoom: CGFloat { zoom / actualSize }
    /// Screen pixels per pixel of the picture as given, which is fewer than the original's when it is a reduced copy.
    private var imagePixelZoom: CGFloat { fitted.width > 0 ? zoom / max(1, picture.width / (fitted.width * displayScale)) : zoom }
    /// To eight times the fitted size, and always far enough to see single pixels.
    private var maxZoom: CGFloat { max(8, actualSize * 4) }

    private var zoomControls: some View {
        HStack(spacing: 6) {
            Button { step(1 / 1.5) } label: { Image(systemName: "minus.magnifyingglass") }.disabled(zoom <= 1).help(L10n.tr("Zoom Out"))
            // The readout is also the way to actual pixels: a separate 100% button beside it only said the same twice.
            Button { withAnimation(.easeOut(duration: 0.15)) { setZoom(actualSize, at: pointer ?? center, from: (zoom, pan)) } } label: {
                Text(L10n.tr("\(Int((pixelZoom * 100).rounded()))%")).monospacedDigit().frame(minWidth: 40)
            }
            .allowsHitTesting(actualSize > 1.05).help(L10n.tr("Actual Size"))
            Button { step(1.5) } label: { Image(systemName: "plus.magnifyingglass") }.disabled(zoom >= maxZoom).help(L10n.tr("Zoom In"))
            Button(L10n.tr("Fit")) { withAnimation(.easeOut(duration: 0.15)) { zoom = 1; pan = .zero } }.disabled(zoom == 1)
        }
        .buttonStyle(.borderless).font(.callout).foregroundStyle(.white)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.black.opacity(0.6), in: Capsule()).environment(\.colorScheme, .dark)
        .padding(12)
        .help(L10n.tr("Pinch or ⌘-scroll to zoom; scroll to move around the zoomed preview"))
    }

    private var center: CGPoint { CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2) }
    /// Zooms to `target`, keeping the point of the picture under `location` (in the canvas) where it is.
    private func setZoom(_ target: CGFloat, at location: CGPoint, from start: (zoom: CGFloat, pan: CGSize)) {
        let z = min(maxZoom, max(1, target))
        let s = CGPoint(x: location.x - canvasSize.width / 2, y: location.y - canvasSize.height / 2)
        let q = CGPoint(x: (s.x - start.pan.width) / start.zoom, y: (s.y - start.pan.height) / start.zoom)
        zoom = z
        pan = clamped(CGSize(width: s.x - q.x * z, height: s.y - q.y * z), zoom: z)
    }
    /// Fitted when zoomed in; otherwise 100% at the click, or twice fitted where that is all 100% is.
    private func clickZoom(at location: CGPoint) {
        withAnimation(.easeOut(duration: 0.15)) {
            if zoom > 1.01 { zoom = 1; pan = .zero } else { setZoom(max(2, actualSize), at: location, from: (zoom, pan)) }
        }
    }
    /// Zooms to the pending target once the picture is laid out.
    private func applyTarget() {
        guard let target = pendingTarget, fitted.width > 0, fitted.height > 0 else { return }
        pendingTarget = nil
        let z: CGFloat, point: CGPoint
        switch target.kind {
        case .fill(let region):
            guard region.width > 0, region.height > 0 else { return }
            // The region fills the canvas.
            z = min(canvasSize.width / fitted.width / region.width, canvasSize.height / fitted.height / region.height)
            point = CGPoint(x: region.midX, y: region.midY)
        case .actualPixels(let at):
            z = actualSize; point = at
        case .fit:
            z = 1; point = CGPoint(x: 0.5, y: 0.5)
        }
        withAnimation(.easeOut(duration: 0.2)) {
            zoom = min(maxZoom, max(1, z))
            pan = clamped(CGSize(width: (0.5 - point.x) * fitted.width * zoom, height: (0.5 - point.y) * fitted.height * zoom), zoom: zoom)
        }
    }
    private func step(_ factor: CGFloat) {
        withAnimation(.easeOut(duration: 0.15)) { setZoom(zoom * factor, at: center, from: (zoom, pan)) }
    }
    private func clamped(_ pan: CGSize, zoom: CGFloat) -> CGSize {
        let x = fitted.width * (zoom - 1) / 2, y = fitted.height * (zoom - 1) / 2
        return CGSize(width: min(x, max(-x, pan.width)), height: min(y, max(-y, pan.height)))
    }
    /// Scrolling over the canvas moves the zoomed picture; ⌘-scrolling zooms at the pointer.
    private func watchScrolling() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let pointer, picture.width > 0 else { return event }
            if event.modifierFlags.contains(.command) {
                let amount = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.1
                setZoom(zoom * exp(amount), at: pointer, from: (zoom, pan))
                return nil
            }
            guard zoom > 1 else { return event }
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            pan = clamped(CGSize(width: pan.width + event.scrollingDeltaX * scale, height: pan.height + event.scrollingDeltaY * scale), zoom: zoom)
            return nil
        }
    }
}

/// Where linked canvases are: the zoom over fitted, and the picture's offset from the centre.
struct ZoomLink: Equatable {
    var zoom: CGFloat = 1
    var pan: CGSize = .zero
}

/// Where to zoom, in fractions of the picture from its top left. A new one zooms again, even to the same place.
struct ZoomTarget: Equatable {
    enum Kind: Equatable {
        /// The region filling the canvas.
        case fill(CGRect)
        /// 100 %, centred on the point.
        case actualPixels(CGPoint)
        /// Back to fitted.
        case fit
    }
    let kind: Kind
    private let id = UUID()
    static func fill(_ region: CGRect) -> ZoomTarget { ZoomTarget(kind: .fill(region)) }
    static func actualPixels(at point: CGPoint) -> ZoomTarget { ZoomTarget(kind: .actualPixels(point)) }
    static var fit: ZoomTarget { ZoomTarget(kind: .fit) }
    private init(kind: Kind) { self.kind = kind }
}

/// Mouse dragging as AppKit reports it: the distance from where the button went down, then nil when it comes up. A
/// SwiftUI drag gesture on the canvas never received the mouse once the picture was zoomed in. A click that doesn't
/// move goes to `onClick`, at its place in the canvas.
private struct PanCatcher: NSViewRepresentable {
    let onDrag: (CGSize?) -> Void
    var onClick: ((CGPoint) -> Void)? = nil
    func makeNSView(context: Context) -> PanView { PanView() }
    func updateNSView(_ view: PanView, context: Context) { view.onDrag = onDrag; view.onClick = onClick }

    final class PanView: NSView {
        var onDrag: (CGSize?) -> Void = { _ in }
        var onClick: ((CGPoint) -> Void)?
        private var start: NSPoint?
        private var moved = false
        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { start = event.locationInWindow; moved = false }
        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            if hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 3 { moved = true }
            // Window coordinates grow upward; the canvas counts downward.
            onDrag(CGSize(width: event.locationInWindow.x - start.x, height: start.y - event.locationInWindow.y))
        }
        override func mouseUp(with event: NSEvent) {
            let clicked = start != nil && !moved
            start = nil; onDrag(nil)
            if clicked, let onClick { onClick(convert(event.locationInWindow, from: nil)) }
        }
    }
}

extension ZoomCanvas where Overlay == EmptyView {
    init(image: CGImage?, orientation: Image.Orientation = .up, checkerboard: Bool = false, showsControls: Bool = true, link: Binding<ZoomLink>? = nil,
         fullSize: CGSize? = nil, target: ZoomTarget? = nil, onZoom: ((CGFloat) -> Void)? = nil, clickZooms: Bool = false) {
        self.init(image: image, orientation: orientation, checkerboard: checkerboard, showsControls: showsControls, link: link,
                  fullSize: fullSize, target: target, onZoom: onZoom, clickZooms: clickZooms, overlay: { _ in EmptyView() })
    }
}

extension Image.Orientation {
    /// The EXIF orientation number's equivalent.
    init(exif: Int) {
        switch exif {
        case 2: self = .upMirrored
        case 3: self = .down
        case 4: self = .downMirrored
        case 5: self = .leftMirrored
        case 6: self = .right
        case 7: self = .rightMirrored
        case 8: self = .left
        default: self = .up
        }
    }
}
