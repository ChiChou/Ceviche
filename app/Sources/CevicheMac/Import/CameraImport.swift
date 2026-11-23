import AppKit
import OSLog
import ImageCaptureCore
import CevicheCore

struct CameraImportEntry: Identifiable {
    let id: ObjectIdentifier
    let file: ICCameraFile
    let path: String
    let filename: String
    let present: Bool
    let recentlyDeleted: Bool
    var isNew: Bool { !present && !recentlyDeleted }
    var kind: String { (filename as NSString).pathExtension.uppercased() }
}

/// Browses through Image Capture, without enumerating /Volumes or reading camera mount points.
/// Menu discovery never opens a device session; only the import sheet does.
@MainActor
final class CameraImportModel: NSObject, ObservableObject, @preconcurrency ICDeviceBrowserDelegate, @preconcurrency ICCameraDeviceDelegate {
    @Published private(set) var cameras: [ICCameraDevice] = []
    @Published private(set) var camera: ICCameraDevice?
    @Published private(set) var entries: [CameraImportEntry] = []
    @Published private(set) var scanning = false
    @Published private(set) var importing = false
    @Published var selected: Set<ObjectIdentifier> = []
    @Published var showingImported = true
    @Published var hiddenKinds: Set<String> = []
    @Published var error: String?
    private let browser = ICDeviceBrowser()
    private let logger = Logger(subsystem: "me.chichou.ceviche", category: "CameraImport")
    private var presence = CatalogPresence()
    private var started = false
    private var browsing = false
    /// macOS has listed the cameras connected when discovery started (`deviceBrowserDidEnumerateLocalDevices`).
    private var enumerated = false
    private var enumerationWaiters: [CheckedContinuation<Void, Never>] = []
    /// Looking for cameras and cards, which is what makes macOS ask for access to a connected card.
    var isDiscovering: Bool { browsing }
    var requestedCamera: ICCameraDevice?
    private var transfer: CameraDownload?
    private var job: UUID?
    private var activity: ActivityCenter?
    var shown: [CameraImportEntry] { entries.filter { (showingImported || !$0.present) && !hiddenKinds.contains($0.kind) } }
    var chosen: [CameraImportEntry] { shown.filter { selected.contains($0.id) } }
    var kinds: [String] { Array(Set(entries.map(\.kind))).sorted() }
    var allShownSelected: Bool {
        get { !shown.isEmpty && shown.allSatisfy { selected.contains($0.id) } }
        set { if newValue { selected.formUnion(shown.map(\.id)) } else { selected.subtract(shown.map(\.id)) } }
    }

    deinit {
        // ImageCaptureCore can deliver queued callbacks after its owner goes away.
        browser.delegate = nil
        for device in browser.devices ?? [] where device.delegate === self {
            device.delegate = nil
            device.requestCloseSession()
        }
        browser.stop()
    }

    func start(store: CatalogStore) async {
        guard !started else { return }
        error = nil
        started = true
        do { presence = try await store.presence() } catch { self.error = error.localizedDescription; return }
        guard started, !Task.isCancelled else { return }
        startDiscovery()
        if let requestedCamera {
            if cameras.contains(where: { $0 === requestedCamera }) { select(requestedCamera) }
            else { error = L10n.tr("Camera disconnected.") }
        } else if let first = cameras.first { select(first) }
    }
    func startDiscovery() {
        guard !browsing else { return }
        browsing = true
        logger.notice("Starting ImageCaptureCore discovery")
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        browser.start()
    }
    /// The cameras connected now, once macOS has listed them. Starts discovery if it hasn't started, which is what
    /// makes macOS ask for access the first time.
    func connectedCameras() async -> [ICCameraDevice] {
        startDiscovery()
        if !enumerated {
            // Not every macOS release reports the end of the listing when access is refused: give up after a while.
            Task { [weak self] in try? await Task.sleep(for: .seconds(10)); self?.resumeWaiters() }
            await withCheckedContinuation { enumerationWaiters.append($0) }
        }
        return cameras
    }
    func deviceBrowserDidEnumerateLocalDevices(_ browser: ICDeviceBrowser) { finishEnumeration() }
    private func finishEnumeration() { enumerated = true; resumeWaiters() }
    private func resumeWaiters() {
        let waiters = enumerationWaiters; enumerationWaiters = []
        waiters.forEach { $0.resume() }
    }
    func stopDiscovery() {
        stop()
        finishEnumeration(); enumerated = false
        browsing = false
        browser.stop()
        cameras = []
    }
    func stop() {
        started = false
        if let job { activity?.cancel(job) }
        transfer?.cancel()
        let previous = camera
        camera = nil; entries = []; selected = []; scanning = false
        previous?.delegate = nil
        previous?.requestCloseSession()
        requestedCamera = nil
    }
    func select(_ device: ICCameraDevice) {
        guard !importing, camera !== device else { return }
        camera?.delegate = nil
        camera?.requestCloseSession()
        camera = device; entries = []; selected = []; hiddenKinds = []; error = nil; scanning = true
        device.delegate = self
        device.mediaPresentation = .originalAssets
        device.requestOpenSession()
    }
    func selectNew() { selected = Set(shown.filter(\.isNew).map(\.id)) }
    func cancelImport() { if let job { activity?.cancel(job) } }

    func importSelection(into catalog: CatalogModel) {
        guard !importing, let store = catalog.store, catalog.canStartJob, !chosen.isEmpty else { return }
        let entries = chosen
        importing = true; error = nil; activity = catalog.activity
        let items = entries.map { entry in
            CatalogModel.ImportItem(url: nil, locator: nil, transferPath: entry.path, download: { [self] progress in
                guard let camera, entry.file.device === camera, cameras.contains(where: { $0 === camera }) else {
                    throw EditorError.invalidDocument(L10n.tr("Camera disconnected."))
                }
                try Task.checkCancellation()
                let download = try CameraDownload(file: entry.file, camera: camera)
                transfer = download
                defer { transfer = nil }
                return try await download.run(progress: progress)
            })
        }
        job = catalog.activity.start(.importing, title: L10n.tr("Importing photos"), total: items.count) { [self] job in
            await catalog.runImport(items, mode: .copy, store: store, job: job)
            do { presence = try await store.presence() } catch { self.error = error.localizedDescription }
            importing = false; self.job = nil
            rebuild()
            selectNew()
        }
    }

    /// Object identity is session-local; filename + size is only a preselection hint.
    /// The shared importer checks the downloaded file's fingerprint again before inserting.
    private func rebuild() {
        guard let camera else { return }
        let previous = Set(entries.map(\.id))
        entries = (camera.mediaFiles ?? []).compactMap { item in
            guard let file = item as? ICCameraFile else { return nil }
            let name = file.name ?? file.originalFilename ?? ""
            guard Self.accepts(name) else { return nil }
            var folders: [String] = []
            var parent = file.parentFolder
            while let folder = parent { folders.insert(folder.name ?? "", at: 0); parent = folder.parentFolder }
            let path = (folders + [name]).joined(separator: "/")
            let fingerprint = ImportFingerprint(name: name, size: file.fileSize > 0 ? Int64(file.fileSize) : nil, captureTime: nil)
            return CameraImportEntry(id: ObjectIdentifier(file), file: file, path: path, filename: name,
                                     present: presence.contains(fingerprint), recentlyDeleted: presence.wasDeleted(fingerprint))
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        selected.formIntersection(entries.map(\.id))
        selected.formUnion(entries.filter { !previous.contains($0.id) && $0.isNew }.map(\.id))
    }
    static func accepts(_ name: String) -> Bool {
        guard !name.isEmpty, (name as NSString).lastPathComponent == name, !name.contains("\\"), name != ".", name != ".." else { return false }
        let url = URL(fileURLWithPath: name)
        return CatalogImporter.supported(url)
    }
    private func removed(_ device: ICDevice) {
        cameras.removeAll { $0 === device }
        guard camera === device else { return }
        transfer?.fail(EditorError.invalidDocument(L10n.tr("Camera disconnected.")))
        camera = nil; entries = []; selected = []; scanning = false
        error = L10n.tr("Camera disconnected.")
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        logger.notice("ImageCaptureCore device added; camera: \(device is ICCameraDevice), browsing: \(self.browsing)")
        guard browsing, let device = device as? ICCameraDevice else { return }
        if !cameras.contains(where: { $0 === device }) { cameras.append(device) }
        if started && camera == nil && !importing && (requestedCamera == nil || requestedCamera === device) { select(device) }
    }
    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) { removed(device) }
    func didRemove(_ device: ICDevice) { removed(device) }
    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        guard device === camera else { return }
        if let error { self.error = error.localizedDescription; scanning = false }
        else { rebuild() }
    }
    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        guard device === camera else { return }
        scanning = false
        transfer?.fail(error ?? EditorError.invalidDocument(L10n.tr("Camera disconnected.")))
        if let error { self.error = error.localizedDescription }
    }
    func device(_ device: ICDevice, didEncounterError error: Error?) {
        guard device === camera, let error else { return }
        self.error = error.localizedDescription; scanning = false; transfer?.fail(error)
    }
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) { if camera === self.camera { rebuild() } }
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) { if camera === self.camera { rebuild() } }
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) { if camera === self.camera { rebuild() } }
    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        guard device === camera else { return }; rebuild(); scanning = false
    }
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        guard device === camera else { return }; error = nil; rebuild()
    }
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        guard device === camera else { return }
        let message = L10n.tr("Unlock the device and allow access to its photos.")
        error = message; transfer?.fail(EditorError.invalidDocument(message))
    }
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
}

/// One transfer at a time per camera. Cancellation/disconnect settles the continuation once;
/// a late framework completion cleans up its staging again rather than importing a partial file.
@MainActor
final class CameraDownload {
    typealias Completion = @Sendable (String?, Error?) -> Void
    let directory: URL
    private let begin: (URL, @escaping Completion) -> Progress?
    private let cancelTransfer: () -> Void
    private var continuation: CheckedContinuation<ImportedPhotoFile, Error>?
    private var progress: Progress?
    private var observation: NSKeyValueObservation?
    private var finished = false
    private var handedOff = false
    init(directory: URL, begin: @escaping (URL, @escaping Completion) -> Progress?, cancel: @escaping () -> Void) throws {
        self.directory = directory; self.begin = begin; cancelTransfer = cancel
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    convenience init(file: ICCameraFile, camera: ICCameraDevice) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ceviche-Camera-\(UUID().uuidString)", isDirectory: true)
        try self.init(directory: directory, begin: { directory, completion in
            file.requestDownload(options: [.downloadsDirectoryURL: directory, .saveAsFilename: file.name ?? file.originalFilename ?? "Photo",
                                           .overwrite: false, .deleteAfterSuccessfulDownload: false, .sidecarFiles: true], completion: completion)
        }, cancel: { camera.cancelDownload() })
    }
    func run(progress report: @escaping @MainActor (Double) -> Void) async throws -> ImportedPhotoFile {
        try await withTaskCancellationHandler {
            if Task.isCancelled { cancel(); throw CancellationError() }
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                progress = begin(directory) { [self] name, error in
                    Task { @MainActor in complete(name: name, error: error) }
                }
                observation = progress?.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self] progress, _ in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor [weak self] in if self?.finished == false { report(fraction) } }
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
    }
    func cancel() { fail(CancellationError()) }
    func fail(_ error: Error) {
        guard !finished else { return }
        finished = true
        progress?.cancel(); cancelTransfer(); observation = nil
        continuation?.resume(throwing: error); continuation = nil
        try? FileManager.default.removeItem(at: directory)
    }
    private func complete(name: String?, error: Error?) {
        guard !finished else {
            if !handedOff { try? FileManager.default.removeItem(at: directory) }
            return
        }
        if let error { fail(error); return }
        guard let name, !name.isEmpty, (name as NSString).lastPathComponent == name else {
            fail(EditorError.invalidDocument(L10n.tr("Camera download failed."))); return
        }
        let url = directory.appendingPathComponent(name)
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            fail(EditorError.invalidDocument(L10n.tr("Camera download failed."))); return
        }
        finished = true; handedOff = true; observation = nil
        continuation?.resume(returning: ImportedPhotoFile(url: url, directory: directory)); continuation = nil
    }
}
