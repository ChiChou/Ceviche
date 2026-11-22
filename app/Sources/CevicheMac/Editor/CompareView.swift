import SwiftUI
import AppKit
import CevicheCore

/// Compare: two panes side by side or one above the other. "Before and After" shows the open
/// photo's original beside its live development; "Two Photos" shows the open photo beside another one,
/// chosen with ⌘-click in the filmstrip. The open photo stays editable from the inspector, and clicking
/// the other photo opens it instead.
struct CompareView: View {
    @ObservedObject var catalog: CatalogModel
    @ObservedObject var editor: EditorModel
    /// Both panes zoom and pan together, so the same detail of each photo stays side by side.
    @State private var viewport = ImageViewport()
    var body: some View {
        VStack(spacing: 0) {
            strip
            panes.padding(.horizontal, 16).padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.imageSurround)
        .onChange(of: catalog.compareSource, initial: true) { viewport.fit(); catalog.prepareCompare(editor: editor) }
        .onChange(of: editor.catalogAssetID) { catalog.prepareCompare(editor: editor) }
        .onChange(of: editor.sdrPreview) { catalog.prepareCompare(editor: editor) }
        // Compare has no canvas tools: an open Crop, Remove or Masks panel closes on entry, and choosing one later goes to Detail.
        .onAppear { editor.leaveCanvasTool() }
        .onChange(of: editor.toolTab) { _, tab in if Self.canvasTools.contains(tab) { catalog.viewMode = .detail } }
    }
    private static let canvasTools: [ToolTab] = [.crop, .remove, .face, .masks]
    private var strip: some View {
        HStack(spacing: 18) {
            Spacer()
            PanelPicker(title: L10n.tr("Compare"), selection: $catalog.compareSource, options: Array(CatalogModel.CompareSource.allCases), label: \.title).controlSize(.small).help(L10n.tr("What the two panes show"))
            FormSegments(title: L10n.tr("Orientation"), selection: $catalog.compareOrientation, options: CatalogModel.CompareOrientation.allCases, label: { $0.title }, icon: { $0.icon }).labelsHidden().fixedSize()
            Button { catalog.compareSwapped.toggle() } label: { Label(L10n.tr("Swap"), systemImage: "arrow.left.arrow.right") }
                .buttonStyle(.secondaryAction)
                .help(L10n.tr("Exchange the two panes"))
            Spacer()
        }.controlSize(.small).font(.system(size: 11)).padding(.horizontal, 16).frame(height: 44)
    }
    @ViewBuilder private var panes: some View {
        let layout = catalog.compareOrientation == .columns ? AnyLayout(HStackLayout(spacing: 14)) : AnyLayout(VStackLayout(spacing: 14))
        let pair = catalog.compareSwapped ? (second, first) : (first, second)
        layout { pair.0; pair.1 }
    }
    /// The open photo: its original in Before and After, the live development in Two Photos.
    private var first: ComparePane {
        switch catalog.compareSource {
        case .beforeAfter:
            return ComparePane(viewport: $viewport, image: editor.originalPreview, title: L10n.tr("Before"), caption: editor.info?.filename, active: false, loading: editor.isLoading, placeholder: nil, select: nil)
        case .twoPhotos:
            return ComparePane(viewport: $viewport, image: editor.preview, title: editor.info?.filename ?? "", caption: caption(for: catalog.cullingTargets(editor: editor).first), active: true,
                               loading: editor.isLoading, placeholder: nil, select: nil)
        }
    }
    /// The live development in Before and After, the chosen partner in Two Photos.
    private var second: ComparePane {
        switch catalog.compareSource {
        case .beforeAfter:
            return ComparePane(viewport: $viewport, image: editor.preview, title: L10n.tr("After"), caption: editor.info?.filename, active: true, loading: editor.isLoading, placeholder: nil, select: nil)
        case .twoPhotos:
            guard editor.catalogAssetID != nil else {
                return ComparePane(viewport: $viewport, image: nil, title: "", caption: nil, active: false, loading: false, placeholder: L10n.tr("Two-photo comparison needs photos from the library."), select: nil)
            }
            guard let partner = catalog.compareAsset else {
                return ComparePane(viewport: $viewport, image: nil, title: "", caption: nil, active: false, loading: false, placeholder: L10n.tr("⌘-click a photo in the filmstrip to compare it with this one."), select: nil)
            }
            return ComparePane(viewport: $viewport, image: catalog.comparePreview, title: partner.filename, caption: caption(for: partner), active: false, loading: catalog.compareRendering,
                               placeholder: nil, select: { Task { await catalog.openPhoto(partner, editor: editor, keepSequence: true) } })
        }
    }
    private func caption(for asset: CatalogAsset?) -> String? {
        guard let asset else { return nil }
        let rating = asset.id == catalog.selected?.id ? catalog.metadata.rating : asset.rating
        let review = asset.id == catalog.selected?.id ? catalog.metadata.review : asset.review
        var parts: [String] = []
        if review == .accepted { parts.append(L10n.tr("Picked")) }
        if review == .rejected { parts.append(L10n.tr("Rejected")) }
        if rating > 0 { parts.append(String(repeating: "★", count: rating)) }
        return parts.isEmpty ? nil : parts.joined(separator: " - ")
    }
}

/// One pane: the photo fitted inside, a white frame around the editable one, and its name underneath.
private struct ComparePane: View {
    @Binding var viewport: ImageViewport
    let image: CGImage?
    let title: String
    let caption: String?
    let active: Bool
    let loading: Bool
    let placeholder: String?
    let select: (() -> Void)?
    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geometry in
                ZStack {
                    if let image {
                        ComparePaneCanvas(image: image, active: active, viewport: $viewport, select: select)
                    } else if loading {
                        ProgressView().controlSize(.small)
                    } else if let placeholder {
                        Text(placeholder).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(24)
                    }
                    if loading, image != nil {
                        VStack { HStack { Spacer(); ProgressView().controlSize(.mini).padding(8) }; Spacer() }
                    }
                }.frame(width: geometry.size.width, height: geometry.size.height)
            }
            .accessibilityElement(children: .ignore).accessibilityLabel(title.isEmpty ? (placeholder ?? L10n.tr("Empty")) : title)
            .accessibilityAddTraits(select == nil ? [] : .isButton)
            .accessibilityAction { select?() }
            HStack(spacing: 8) {
                if !title.isEmpty {
                    Text(title).font(.system(size: 11, weight: active ? .semibold : .regular)).lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(Theme.ink.opacity(active ? 0.14 : 0.07), in: Capsule())
                }
                if let caption { Text(caption).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
            }.frame(height: 18)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A pane's photo in the shared viewport: pinch, a smart-zoom tap or a double-click zooms about the pointer, and a drag
/// or scroll pans once zoomed. A click without a drag selects the pane. The secondary window shows the open
/// photo with it too, without the frame.
struct ComparePaneCanvas: NSViewRepresentable {
    let image: CGImage
    let active: Bool
    var framed = true
    @Binding var viewport: ImageViewport
    let select: (() -> Void)?
    func makeNSView(context: Context) -> ComparePaneCanvasView { ComparePaneCanvasView() }
    func updateNSView(_ view: ComparePaneCanvasView, context: Context) {
        let binding = $viewport
        view.changeViewport = { binding.wrappedValue = $0 }
        view.select = select
        view.update(image: image, active: active, framed: framed, viewport: viewport)
    }
}

final class ComparePaneCanvasView: NSView {
    private(set) var viewport = ImageViewport()
    var changeViewport: (ImageViewport) -> Void = { _ in }
    var select: (() -> Void)?
    private let photograph = ComparePhotographView()
    private var dragStart: CGPoint?
    private var lastDrag: CGPoint?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.masksToBounds = true
        addSubview(photograph)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private var imageSize: CGSize { photograph.image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero }
    func update(image: CGImage, active: Bool, framed: Bool = true, viewport: ImageViewport) {
        photograph.image = image
        photograph.layer?.borderWidth = !framed ? 0 : active ? 2 : 1
        photograph.layer?.borderColor = NSColor.white.withAlphaComponent(active ? 1 : 0.1).cgColor
        self.viewport = viewport
        layoutPhotograph()
    }
    private func layoutPhotograph() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        photograph.frame = viewport.imageRect(image: imageSize, canvas: bounds.size)
        CATransaction.commit()
        window?.invalidateCursorRects(for: self)
    }
    override func layout() { super.layout(); layoutPhotograph() }
    private func change(_ update: (inout ImageViewport) -> Void) {
        var next = viewport; update(&next)
        guard next != viewport else { return }
        viewport = next; layoutPhotograph(); changeViewport(next)
    }
    private func toggleFit(at anchor: CGPoint) {
        change { if $0.isFitted { $0.zoom(to: 2, anchor: anchor, image: imageSize, canvas: bounds.size) } else { $0.fit() } }
    }
    override func magnify(with event: NSEvent) {
        let anchor = convert(event.locationInWindow, from: nil)
        change { $0.zoom(to: $0.scale + event.magnification, anchor: anchor, image: imageSize, canvas: bounds.size) }
    }
    override func smartMagnify(with event: NSEvent) { toggleFit(at: convert(event.locationInWindow, from: nil)) }
    override func scrollWheel(with event: NSEvent) {
        guard !viewport.isFitted else { return super.scrollWheel(with: event) }
        let multiplier = event.hasPreciseScrollingDeltas ? 1.0 : 12.0
        change { $0.pan(by: CGSize(width: event.scrollingDeltaX * multiplier, height: event.scrollingDeltaY * multiplier), image: imageSize, canvas: bounds.size) }
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 { toggleFit(at: point); dragStart = nil; lastDrag = nil; return }
        dragStart = point; lastDrag = point
        if !viewport.isFitted { NSCursor.closedHand.set() }
    }
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let last = lastDrag else { return }
        change { $0.pan(by: CGSize(width: point.x - last.x, height: point.y - last.y), image: imageSize, canvas: bounds.size) }
        lastDrag = point
    }
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let start = dragStart, hypot(point.x - start.x, point.y - start.y) < 3 { select?() }
        dragStart = nil; lastDrag = nil
        window?.invalidateCursorRects(for: self)
    }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: !viewport.isFitted ? .openHand : select != nil ? .pointingHand : .arrow)
    }
}

final class ComparePhotographView: NSView {
    var image: CGImage? { didSet { if image !== oldValue { needsDisplay = true } } }
    override var wantsUpdateLayer: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // EDR display of the float contents: the macOS 26 preference, or the older per-layer opt-in before that.
        if #available(macOS 26, *) { layer?.preferredDynamicRange = .high } else { layer?.wantsExtendedDynamicRangeContent = true }
        layer?.toneMapMode = .automatic
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .trilinear
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func updateLayer() { layer?.contents = image }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
