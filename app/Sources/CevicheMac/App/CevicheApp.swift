import SwiftUI
import AppKit
import CevicheCore

/// The app's entry. The executable is a launcher in app/Apps that links this module from CevicheKit.framework.
public enum CevicheMain {
    @MainActor public static func run() { CevicheApp.main() }
}

struct CevicheApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = EditorModel()
    @StateObject private var catalog = CatalogModel()
    @StateObject private var mcp = MCPController()
    @StateObject private var textEditing = TextEditingObserver()
    @StateObject private var keyWindow = KeyWindowObserver()
    init() {
        // `--help` and bad options exit here, before a window opens.
        LaunchOptions.resolveAtLaunch()
        // Before any catalog opens. The iCloud Drive lookup is quick once the container exists; it runs once.
        ResourceStorage.shared = ResourceStorage.forBuild()
        // The community build downloads the pinned set from GitHub; the App Store build will use Apple-hosted assets.
        ModelLibrary.shared.allowsDownloads = !BuildFeatures.appStore
    }
    var body: some Scene {
        Window(L10n.tr("Ceviche RAW Studio"), id: "editor") {
            CatalogWorkspace(catalog: catalog, editor: model)
                .disabled(mcp.activity?.writes == true)
                .overlay(alignment: .bottom) { if let activity = mcp.activity { MCPActivityBanner(activity: activity, cancel: mcp.cancelActivity) } }
                .frame(minWidth: 1000, minHeight: 700)
                .background(MainWindowOpener(delegate: delegate))
                .background(WindowAccessor(model: model, delegate: delegate, catalogName: catalog.manifest.map { catalog.isReadOnly ? L10n.tr("\($0.name) (Read-Only)") : $0.name }))
                .onAppear {
                    delegate.model = model
                    delegate.catalog = catalog
                    delegate.openPendingURLs()
                    catalog.updateDisplayCount(NSScreen.screens.count)
                    delegate.mcp = mcp
                    mcp.attach(editor: model, catalog: catalog)
                    // Camera profiles in Application Support are indexed at launch so sidecars can name them; the
                    // base-profile folders supply each camera's Adobe Standard, the base that film profiles are built on.
                    Task.detached(priority: .utility) { CameraProfileLibrary.shared.reload(folders: LookLibrary.profileFolders) }
                    // A photo to open, given on the command line; flag values such as `-NSDocumentRevisionsDebugMode YES` are not files.
                    if LaunchOptions.current == nil, let path = ProcessInfo.processInfo.arguments.dropFirst().first(where: { !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0) }), !model.hasImage {
                        catalog.viewMode = .detail
                        Task {
                            await model.open(URL(fileURLWithPath: path))
                            #if DEBUG
                            await DebugSnapshot.runIfRequested(model, catalog: catalog)
                            #endif
                        }
                    }
                }
                .toasts(errors: $model.error, $catalog.error, notice: $catalog.notice)
                .catalogOpenAlert(catalog)
                .failureAlerts($model.failure, $catalog.failure)
        }
        .defaultSize(width: 1420, height: 920)
        .windowStyle(.hiddenTitleBar)
        // Catalogs and photos from the Finder or the Dock reach AppDelegate.application(_:open:). Left to SwiftUI, the
        // open event went to this scene, which closed the window until the Dock icon was clicked again.
        .handlesExternalEvents(matching: [])
        .commands { CatalogCommands(catalog: catalog, catalogMenu: catalog.menuState, editor: model, editorMenu: model.menuState, textEditing: textEditing, keyWindow: keyWindow) }
        // The grid or the photo on another display; opened from the bottom bar or the View menu.
        Window(L10n.tr("Secondary Window"), id: SecondaryWindowScene.id) {
            SecondaryWindow(catalog: catalog, editor: model)
                .disabled(mcp.activity?.writes == true)
        }
        .defaultSize(width: 1100, height: 760)
        .restorationBehavior(.disabled)
        .commandsRemoved()
        .handlesExternalEvents(matching: [])
        Window("Ceviche Pro", id: Pro.windowID) { ProView() }
            .windowResizability(.contentSize)
            .handlesExternalEvents(matching: [])
            .restorationBehavior(.disabled)
            .commandsRemoved()
        Window(L10n.tr("Open Source Licenses"), id: LicensesView.windowID) { LicensesView() }
            .defaultSize(width: 540, height: 620)
            .handlesExternalEvents(matching: [])
            .windowResizability(.contentMinSize)
            .restorationBehavior(.disabled)
            .commandsRemoved()
        Window(L10n.tr("System Info"), id: SystemInfoView.windowID) { SystemInfoView() }
            .defaultSize(width: 600, height: 620)
            .handlesExternalEvents(matching: [])
            .windowResizability(.contentMinSize)
            .restorationBehavior(.disabled)
            .commandsRemoved()
        // Sized by each tab's content, so the window narrows again after the wider Models tab.
        Settings { PreferencesView(mcp: mcp) }.windowResizability(.contentSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    weak var model: EditorModel?
    weak var catalog: CatalogModel?
    weak var mcp: MCPController?
    private var approvedClose = false
    /// Catalogs and photos handed over by the Finder before the window, and so the catalog model, was up.
    private var pendingURLs: [URL] = []
    /// Opens the main window again after it was closed; kept from the window's own environment.
    var openMainWindow: (() -> Void)?
    func application(_ application: NSApplication, open urls: [URL]) {
        pendingURLs += urls; openPendingURLs()
        // What was opened shows in the main window, so it comes forward, or back if it was closed.
        if let window = NSApp.windows.first(where: { $0.delegate is AppDelegate }) { window.makeKeyAndOrderFront(nil) }
        else { openMainWindow?() }
    }
    func openPendingURLs() {
        guard let catalog, let model, !pendingURLs.isEmpty else { return }
        let urls = pendingURLs; pendingURLs = []
        catalog.open(urls, editor: model)
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        if let catalog, let model { catalog.pickUpOutsideEdits(editor: model) }
        // Models unzipped into the Models folder while the app was in the background.
        ModelLibrary.shared.rescan()
    }
    func applicationDidChangeScreenParameters(_ notification: Notification) {
        catalog?.updateDisplayCount(NSScreen.screens.count)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppearanceChoice.current.apply()
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        ExternalEditors.shared.refresh()
        Pro.shared.start()
        TemporaryFiles.sweepLeftovers()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.busy || catalog?.interactionBusy == true { NSSound.beep(); return .terminateCancel }
        // Quitting stops imports and exports at the next file; imported photos are already saved.
        ActivityCenter.shared.cancelAll()
        Task {
            while !ActivityCenter.shared.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
            guard await catalog?.flushMetadata() ?? true else { sender.reply(toApplicationShouldTerminate: false); return }
            sender.reply(toApplicationShouldTerminate: await model.flushEdits())
        }
        return .terminateLater
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if approvedClose { approvedClose = false; return true }
        guard let model else { return true }
        guard !model.busy, catalog?.catalogWideBusy != true else { NSSound.beep(); return false }
        Task {
            guard await catalog?.flushMetadata() ?? true else { return }
            if await model.flushEdits() {
                approvedClose = true; model.closeDocument(); catalog?.viewMode = .grid
                SecondaryWindowView.current?.close(); sender.close()
            }
        }
        return false
    }
    func applicationWillTerminate(_ notification: Notification) {
        mcp?.stop(); catalog?.stopIndexing()
        if let status = LaunchOptions.exitStatus { fflush(stdout); exit(status) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // Edit › Copy and Paste end up here when nothing earlier in the responder chain takes them, so a focused text field
    // keeps ⌘C and ⌘V for its text and everywhere else they copy and paste the photo's edits.
    @objc func copy(_ sender: Any?) {
        if let catalog, let model { catalog.copyCurrentEdits(editor: model) }
    }
    @objc func paste(_ sender: Any?) {
        if let catalog, let model { catalog.pasteCopiedEdits(editor: model) }
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let catalog, let model, NSApp.keyWindow?.sheetParent == nil else { return false }
        switch item.action {
        case #selector(copy(_:)): return catalog.canCopyEdits(editor: model)
        case #selector(paste(_:)): return catalog.canPasteEdits(editor: model)
        default: return true
        }
    }
}

/// Hands the delegate a way to reopen the main window, which only a view's environment has.
private struct MainWindowOpener: View {
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Color.clear.onAppear { delegate.openMainWindow = { [openWindow] in openWindow(id: "editor") } }
    }
}

struct WindowAccessor: NSViewRepresentable {
    let model: EditorModel
    let delegate: AppDelegate
    let catalogName: String?
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = view.window, !(window.delegate is AppDelegate) {
                window.delegate = delegate
                window.registerForDraggedTypes([.fileURL])
                NotificationCenter.default.post(name: KeyWindowObserver.mainWindowReady, object: window)
            }
            view.window?.title = model.info?.filename ?? catalogName ?? L10n.tr("Ceviche RAW Studio")
            view.window?.isDocumentEdited = model.dirty
            view.window?.backgroundColor = Theme.nsCanvas
        }
    }
}

/// Tracks text editing so Edit > Undo reaches the focused field's own undo manager.
@MainActor
final class TextEditingObserver: ObservableObject {
    @Published private(set) var editing = false
    private var observers: [NSObjectProtocol] = []
    init() {
        let center = NotificationCenter.default
        for (name, value) in [(NSText.didBeginEditingNotification, true), (NSText.didEndEditingNotification, false)] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.editing = value }
            })
        }
    }
    static func send(undo: Bool) {
        let manager = NSApp.keyWindow?.firstResponder?.undoManager
        if undo { manager?.undo() } else { manager?.redo() }
    }
}

/// Whether the main window is in front, for menu items that only make sense in the other windows.
@MainActor
final class KeyWindowObserver: ObservableObject {
    /// Posted once the main window has its delegate, which can be after it first becomes key.
    static let mainWindowReady = Notification.Name("CevicheMainWindowReady")
    @Published private(set) var mainWindowIsKey = true
    private var observers: [NSObjectProtocol] = []
    init() {
        for name in [NSWindow.didBecomeKeyNotification, Self.mainWindowReady] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            })
        }
    }
    /// The main window is the one the app delegate guards; with no key window the last answer stands.
    private func update() {
        guard let window = NSApp.keyWindow else { return }
        let isMain = window.delegate is AppDelegate
        if mainWindowIsKey != isMain { mainWindowIsKey = isMain }
    }
}

#if DEBUG
/// Renders one window snapshot for scripted visual checks (CEVICHE_SNAPSHOT_PATH and related variables), then quits.
@MainActor
enum DebugSnapshot {
    static func runIfRequested(_ model: EditorModel, catalog: CatalogModel) async {
        guard let snapshot = ProcessInfo.processInfo.environment["CEVICHE_SNAPSHOT_PATH"] else { return }
        try? await Task.sleep(for: .seconds(1))
        // CEVICHE_SNAPSHOT_VIEW=grid or wall shows the library instead of the opened photo, once its thumbnails are in.
        if let view = ProcessInfo.processInfo.environment["CEVICHE_SNAPSHOT_VIEW"], let style = CatalogModel.GridStyle(rawValue: view == "grid" ? "tiles" : view) {
            catalog.gridStyle = style; catalog.viewMode = .grid
            try? await Task.sleep(for: .seconds(4))
        }
        if ProcessInfo.processInfo.environment["CEVICHE_SNAPSHOT_COMPARE"] == "1" {
            model.edit { $0.exposure = 0.6; $0.selectiveColors[2].saturation = -40; $0.vignette = 35 }
            try? await Task.sleep(for: .seconds(2))
            model.comparing = true
            try? await Task.sleep(for: .milliseconds(200))
        }
        if ProcessInfo.processInfo.environment["CEVICHE_SNAPSHOT_ZOOM"] == "2" {
            model.toggleImageFit()
            try? await Task.sleep(for: .milliseconds(200))
        }
        if let tab = ProcessInfo.processInfo.environment["CEVICHE_SNAPSHOT_TAB"], let selected = ToolTab(rawValue: tab) {
            model.toolTab = selected
            if selected == .masks {
                model.addMask(.linear); model.beginMask(at: MaskPoint(x: 0.5, y: 0.2)); model.dragMask(to: MaskPoint(x: 0.5, y: 0.65)); model.endMask()
                model.updateMask { $0.name = "Foreground light"; $0.adjustments.exposure = 0.5 }
                model.addMask(.radial); model.beginMask(at: MaskPoint(x: 0.5, y: 0.5)); model.dragMask(to: MaskPoint(x: 0.7, y: 0.7)); model.endMask()
                model.updateMask { $0.name = "Subject detail"; $0.adjustments.clarity = 20 }
                model.maskTool = nil
            }
            try? await Task.sleep(for: .seconds(2))
        }
        // CEVICHE_SNAPSHOT_PRINT=Photo, Strip or Ring prints the photo on Portra and opens Darkroom in that view.
        if let view = ProcessInfo.processInfo.environment["CEVICHE_SNAPSHOT_PRINT"], let printView = EditorModel.PrintView(rawValue: view) {
            model.edit { $0.film = FilmSimulation() }
            model.toolTab = .darkroom; model.showInspector = true; model.printView = printView
            try? await Task.sleep(for: .seconds(8))
        }
        if ProcessInfo.processInfo.environment["CEVICHE_SNAPSHOT_EXPORT"] == "1" {
            model.prepareExport()
            try? await Task.sleep(for: .seconds(1))
        }
        if let error = model.failure?.message ?? model.error { fputs("Snapshot failed: \(error)\n", stderr); exit(1) }
        guard let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(2) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(3) }
        do { try data.write(to: URL(fileURLWithPath: snapshot)); exit(0) }
        catch { fputs("\(error)\n", stderr); exit(4) }
    }
}
#endif
