import SwiftUI
import AppKit
import CevicheCore

/// A second window for another display, as in other RAW editors: it shows the grid or the open photo.
/// The grid is in one window at a time, and its selection is the photo the other window shows. Beside
/// Detail or Compare in the main window it shows the photo alone, following the edits, for a display that
/// serves as the master preview. It has no inspector; editing stays in the main window.
struct SecondaryWindow: View {
    @ObservedObject var catalog: CatalogModel
    @ObservedObject var editor: EditorModel
    /// The master preview's own zoom, apart from the main window's.
    @State private var viewport = ImageViewport()
    var body: some View {
        VStack(spacing: 0) {
            Group {
                if catalog.secondaryViewChoice == .grid {
                    CatalogView(model: catalog, editor: editor)
                } else if catalog.secondaryMirrorsPhoto, editor.preview != nil {
                    SecondaryPreview(editor: editor, viewport: $viewport)
                } else if editor.preview != nil {
                    EditorCanvas(model: editor).openPhotoContextMenu(catalog: catalog, editor: editor)
                } else if let latent = catalog.latentShown {
                    LatentDetailView(catalog: catalog, editor: editor, asset: latent, opensTool: false).id(latent.id)
                } else {
                    ContentUnavailableView(L10n.tr("No Photo Selected"), systemImage: "photo", description: Text(L10n.tr("Select a photo in the grid to see it here.")))
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.imageSurround)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            SecondaryWindowBar(catalog: catalog, editor: editor, viewport: $viewport)
        }
        .frame(minWidth: 640, minHeight: 440)
        .themed().background(Theme.canvas)
        .background(PhotoBrowsingKeys(catalog: catalog, editor: editor, secondary: true))
        .background(SecondaryWindowAccessor())
        .disabled(catalog.handlingXMP || catalog.mutatingCatalog)
        .onAppear {
            // The window can also come back on its own, through state restoration; it then takes the free view.
            if catalog.secondaryViewMode == nil { catalog.showSecondary(catalog.secondaryViewChoice, editor: editor) }
            follow()
        }
        .onDisappear { catalog.closeSecondaryWindow(editor: editor) }
        .onChange(of: catalog.selected?.id) { follow() }
        // A click while the previous photo was still loading waits for it.
        .onChange(of: editor.busy) { if !editor.busy { follow() } }
        .onChange(of: catalog.navigating) { if !catalog.navigating { follow() } }
    }
    private func follow() { Task { await catalog.followSelection(editor: editor) } }
}

/// The bar under the secondary view: its own view switch, then the grid's count and thumbnail size or the
/// photo's flag, rating and zoom.
struct SecondaryWindowBar: View {
    @ObservedObject var catalog: CatalogModel
    @ObservedObject var editor: EditorModel
    @Binding var viewport: ImageViewport
    var body: some View {
        VStack(spacing: 0) {
            Rule()
            HStack(spacing: 12) {
                SecondaryViewModePicker(catalog: catalog, editor: editor)
                Rule(.vertical).frame(height: 12)
                if catalog.secondaryViewChoice == .grid {
                    Text(catalog.selectionCount > 1 ? L10n.tr("\(catalog.selectionCount.formatted()) selected - \(catalog.countLabel)") : catalog.countLabel).monospacedDigit().lineLimit(1)
                    Spacer(minLength: 8)
                    ThumbnailSizeControls(model: catalog)
                } else {
                    PhotoRatingControls(catalog: catalog, editor: editor)
                    if let name = editor.info?.filename { Text(name).lineLimit(1).truncationMode(.middle) }
                    Spacer(minLength: 8)
                    if catalog.secondaryMirrorsPhoto {
                        Button { viewport.fit() } label: { Text(L10n.tr("Fit")).fixedSize().frame(height: 28).contentShape(Rectangle()) }
                            .buttonStyle(.plain).foregroundStyle(viewport.isFitted ? Theme.accent : .secondary)
                        Text(String(format: "%g×", locale: Locale.current, (viewport.scale * 10).rounded() / 10)).monospacedDigit().frame(minWidth: 40, alignment: .trailing)
                    } else {
                        ZoomControls(model: editor)
                    }
                }
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 28)
        }.background(Theme.statusBar)
    }
}

/// The open photo alone, fitted, while the main window edits it: the preview as the sliders move, the
/// main window's full-resolution development once they rest, and the original while it is held there.
/// Pinch, double-click and drag zoom and pan it on its own.
struct SecondaryPreview: View {
    @ObservedObject var editor: EditorModel
    @Binding var viewport: ImageViewport
    private var image: CGImage? {
        if editor.peekingOriginal, let original = editor.originalPreview { return original }
        guard let preview = editor.preview else { return nil }
        // The main window's detail covers the whole photo while it is fitted there.
        if !editor.comparing, editor.toolTab != .crop, let detail = editor.detail, detail.image.width > preview.width,
           detail.region.insetBy(dx: 0.001, dy: 0.001).contains(CGRect(x: 0.002, y: 0.002, width: 0.996, height: 0.996)) { return detail.image }
        return preview
    }
    var body: some View {
        ZStack {
            Theme.imageSurround
            if let image { ComparePaneCanvas(image: image, active: false, framed: false, viewport: $viewport, select: nil) }
        }
        .onChange(of: editor.sourceURL) { viewport.fit() }
    }
}

/// The wall, the grid or Detail for the secondary window; the main window gives up the grid when it is chosen.
struct SecondaryViewModePicker: View {
    @ObservedObject var catalog: CatalogModel
    @ObservedObject var editor: EditorModel
    var body: some View {
        HStack(spacing: 2) {
            ForEach(CatalogModel.GridStyle.allCases.reversed()) { style in
                let active = catalog.secondaryViewChoice == .grid && catalog.gridStyle == style
                ViewSwitchButton(icon: style.icon, title: style.title, active: active, help: style == .tiles ? L10n.tr("Grid (G)") : L10n.tr("Wall (G from the grid)")) {
                    catalog.gridStyle = style; catalog.showSecondary(.grid, editor: editor)
                }.disabled(!active && !catalog.canShowSecondary(.grid, editor: editor))
            }
            let active = catalog.secondaryViewChoice == .detail
            ViewSwitchButton(icon: CatalogModel.ViewMode.detail.icon, title: L10n.tr("Detail"), active: active, help: L10n.tr("Detail (D)")) { catalog.showSecondary(.detail, editor: editor) }
                .disabled(!active && !catalog.canShowSecondary(.detail, editor: editor))
        }
    }
}

/// The main window's menu for the secondary window, beside the view switch: choosing a view opens the
/// window showing it. The check marks what the window shows, or would show when opened.
struct SecondaryWindowMenu: View {
    @ObservedObject var catalog: CatalogModel
    @ObservedObject var editor: EditorModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Menu {
            SecondaryWindowItems(catalog: catalog, editor: editor)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "macwindow.on.rectangle").font(.system(size: 15))
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
            }.frame(height: 28).contentShape(Rectangle())
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().focusable(false)
            .foregroundStyle(catalog.secondaryViewMode == nil ? .secondary : Theme.accent)
            .help(catalog.secondaryViewMode == nil ? L10n.tr("Secondary Window") : L10n.tr("Secondary Window - \(catalog.secondaryViewChoice.title)"))
            .accessibilityLabel(L10n.tr("Secondary Window"))
    }
}

/// The items of the secondary window menu, shared by the bottom bar and the View menu.
struct SecondaryWindowItems: View {
    @ObservedObject var catalog: CatalogModel
    @ObservedObject var editor: EditorModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Section(L10n.tr("Secondary Window")) {
            ForEach(CatalogModel.GridStyle.allCases.reversed()) { style in
                Toggle(isOn: Binding(get: { catalog.secondaryViewChoice == .grid && catalog.gridStyle == style }, set: { _ in
                    catalog.gridStyle = style
                    if catalog.showSecondary(.grid, editor: editor) { openWindow(id: SecondaryWindowScene.id) }
                })) { Label(style.title, systemImage: style.icon) }
                    .disabled(!catalog.canShowSecondary(.grid, editor: editor))
            }
            Toggle(isOn: Binding(get: { catalog.secondaryViewChoice == .detail }, set: { _ in
                if catalog.showSecondary(.detail, editor: editor) { openWindow(id: SecondaryWindowScene.id) }
            })) { Label(L10n.tr("Detail"), systemImage: CatalogModel.ViewMode.detail.icon) }
                .disabled(!catalog.canShowSecondary(.detail, editor: editor))
        }
    }
}

enum SecondaryWindowScene {
    static let id = "secondary"
}

/// Places a new secondary window on the display the main window is not on, filling it, as a second window
/// is for; with one display it opens beside the main window at its default size.
struct SecondaryWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> SecondaryWindowView { SecondaryWindowView() }
    func updateNSView(_ view: SecondaryWindowView, context: Context) {}
}

@MainActor
final class SecondaryWindowView: NSView {
    /// The open secondary window, for closing it with the main window.
    private(set) static weak var current: NSWindow?
    private weak var configured: NSWindow?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, configured !== window else { return }
        configured = window; Self.current = window
        window.title = L10n.tr("Secondary Window")
        window.tabbingMode = .disallowed
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Theme.nsCanvas
        let mainScreen = NSApp.windows.first { $0 !== window && $0.isVisible && $0.delegate is AppDelegate }?.screen ?? NSScreen.main
        if let other = NSScreen.screens.first(where: { $0 !== mainScreen }) {
            window.setFrame(other.visibleFrame, display: true)
        }
    }
}
