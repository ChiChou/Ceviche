import SwiftUI
import MetalKit
import CevicheCore

/// On-demand Metal canvas. Orbit and zoom stay local to the relief; they never edit the stack or layer brush.
struct FocusStackInspectionCanvas: View {
    let preview: FocusStackPreview
    let mode: FocusStackInspectionMode
    var relief: Float = 0.22
    var inverted = false
    var opacity: Float = 0.65
    var reset = 0
    @State private var unavailable = false

    var body: some View {
        FocusStackMetalCanvas(preview: preview, mode: mode, relief: relief, inverted: inverted,
                             opacity: opacity, reset: reset) { unavailable = $0 }
            .overlay {
                if unavailable { Text(L10n.tr("GPU preview unavailable")).foregroundStyle(.secondary) }
            }
            .accessibilityLabel(mode == .relief ? L10n.tr("3D Relief") : (mode == .depth ? L10n.tr("Focus Depth") : L10n.tr("Focus Confidence")))
    }
}

private struct FocusStackMetalCanvas: NSViewRepresentable {
    let preview: FocusStackPreview
    let mode: FocusStackInspectionMode
    let relief: Float
    let inverted: Bool
    let opacity: Float
    let reset: Int
    let failure: (Bool) -> Void

    func makeNSView(context: Context) -> FocusStackMetalView { FocusStackMetalView() }
    func updateNSView(_ view: FocusStackMetalView, context: Context) {
        view.failure = failure
        view.update(preview: preview, mode: mode, relief: relief, inverted: inverted, opacity: opacity, reset: reset)
    }
}

private final class FocusStackMetalView: MTKView, MTKViewDelegate {
    private var renderer: FocusStackInspectionRenderer?
    private var previewImage: CGImage?
    private var camera = FocusStackInspectionCamera()
    private var mode = FocusStackInspectionMode.depth
    private var opacity: Float = 0.65
    private var reset = 0
    private var failed = false
    var failure: ((Bool) -> Void)?

    init() {
        let device = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: device)
        if let device { renderer = try? FocusStackInspectionRenderer(device: device) }
        colorPixelFormat = .bgra8Unorm_srgb
        isPaused = true; enableSetNeedsDisplay = true; delegate = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }

    private func report(_ value: Bool) {
        guard value != failed else { return }
        failed = value
        let callback = failure
        DispatchQueue.main.async { callback?(value) }
    }
    func update(preview: FocusStackPreview, mode: FocusStackInspectionMode, relief: Float, inverted: Bool, opacity: Float, reset: Int) {
        self.mode = mode; self.opacity = opacity
        if reset != self.reset { camera = .init(); self.reset = reset }
        camera.relief = relief; camera.inverted = inverted
        guard let renderer else { report(true); return }
        do {
            if previewImage !== preview.image {
                try renderer.setPreview(preview)
                previewImage = preview.image
            }
            report(false); needsDisplay = true
        } catch { report(true) }
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { needsDisplay = true }
    func draw(in view: MTKView) {
        guard !failed, let renderer, let drawable = currentDrawable else { return }
        do {
            let commands = try renderer.render(target: drawable.texture, mode: mode, camera: camera, opacity: opacity)
            commands.addCompletedHandler { [weak self] buffer in
                if buffer.status == .error { DispatchQueue.main.async { self?.report(true) } }
            }
            commands.present(drawable); commands.commit()
        } catch { report(true) }
    }
    override func mouseDown(with event: NSEvent) { if mode == .relief { window?.makeFirstResponder(self) } }
    override func mouseDragged(with event: NSEvent) {
        guard mode == .relief else { return }
        camera.yaw += Float(event.deltaX) * 0.008
        camera.pitch = min(1.35, max(-1.35, camera.pitch + Float(event.deltaY) * 0.008))
        needsDisplay = true
    }
    override func scrollWheel(with event: NSEvent) {
        guard mode == .relief else { super.scrollWheel(with: event); return }
        let scale: Float = event.hasPreciseScrollingDeltas ? 0.01 : 0.08
        camera.zoom = min(4, max(0.3, camera.zoom * exp(Float(event.scrollingDeltaY) * scale)))
        needsDisplay = true
    }
    override func magnify(with event: NSEvent) {
        guard mode == .relief else { return }
        camera.zoom = min(4, max(0.3, camera.zoom * Float(1 + event.magnification)))
        needsDisplay = true
    }
}
