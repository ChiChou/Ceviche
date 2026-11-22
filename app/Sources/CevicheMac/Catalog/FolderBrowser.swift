import AppKit
import CevicheCore

/// The sidebar's folder outline: a few places, the home folder and connected volumes, each opened one level at a time.
///
/// Privacy (TCC): macOS asks before an app reads Desktop, Documents, Downloads, a removable volume or a network
/// volume, and asks at the moment of the first read. So nothing here reads a folder until the person expands or
/// selects it: rows are named from their paths alone, every folder shows a chevron until it has been opened, and the
/// outline is not restored at launch. A refused folder is listed as such, with a way to the privacy settings.
@MainActor
final class FolderBrowser: ObservableObject {
    struct Root: Identifiable, Hashable {
        let id: String
        let url: URL
        let title: String
        let icon: String
        var path: String { CatalogFolders.path(url) }
    }
    enum Contents: Equatable {
        case loading
        case folders([URL])
        case denied
        case missing
    }
    /// A row of the outline: a folder under one of the roots.
    struct Node: Hashable {
        let root: String
        let path: String
        var key: String { root + "\n" + path }
    }

    let places: [Root]
    let home: Root
    @Published private(set) var volumes: [Root] = []
    /// What each opened folder holds, by path; shared by the roots that reach the same folder.
    @Published private(set) var contents: [String: Contents] = [:]
    @Published private(set) var expanded: Set<Node> = []
    /// A folder's contents changed on disk.
    var changed: ((String) -> Void)?
    private var watchers: [String: FolderWatcher] = [:]
    /// Folders watched without being open in the outline: the one shown in the grid.
    private var pinned: Set<String> = []
    /// Watches everything below the shown folder, when it is shown with its subfolders.
    private var tree: TreeWatcher?
    private var active = false
    private var volumeGeneration = 0
    private var observers: [NSObjectProtocol] = []

    /// `home` is the person's home folder; tests give a scratch one.
    init(home homeURL: URL = FileAccess.home) {
        let fm = FileManager.default
        // The standard folders by their fixed names on disk; Finder's localized names are shown.
        places = [("Pictures", "photo.on.rectangle.angled"), ("Desktop", "menubar.dock.rectangle"), ("Documents", "doc"), ("Downloads", "arrow.down.circle")].map {
            let url = homeURL.appendingPathComponent($0.0, isDirectory: true)
            return Root(id: "place:" + $0.0, url: url, title: fm.displayName(atPath: url.path), icon: $0.1)
        }
        home = Root(id: "home", url: homeURL, title: fm.displayName(atPath: homeURL.path), icon: "house")
    }

    /// Called when the Folders tab first shows: names the connected volumes and opens the home folder. Volume names
    /// come from the mount table; no volume is read.
    func activate() {
        guard !active else { return }
        active = true
        reloadVolumes()
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reloadVolumes() }
            })
        }
        // Network volumes send no change events; coming back to the app is when files have most likely changed.
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadAll() }
        })
        if !FileAccess.sandboxed { setExpanded(Node(root: home.id, path: home.path), true) }
    }

    var roots: [Root] { places + [home] + volumes }
    func isExpanded(_ node: Node) -> Bool { expanded.contains(node) }

    func setExpanded(_ node: Node, _ open: Bool) {
        if open {
            guard FileAccess.shared.authorizeFolder(URL(fileURLWithPath: node.path, isDirectory: true)) else { return }
            expanded.insert(node)
            if contents[node.path] == nil { load(node.path) } else if contents[node.path] != .denied { watch(node.path) }
        } else {
            // Closing a folder closes what is open below it, so reopening shows one level again.
            expanded = expanded.filter { !($0.root == node.root && ($0.path == node.path || $0.path.hasPrefix(node.path + "/"))) }
            prune()
        }
    }

    /// Opens the outline down to `path` for a photo opened from the Finder, the one time folders open by themselves:
    /// the deepest root holding it, and each folder between, are expanded; `path` itself stays as it was. Returns the
    /// root it is shown under, or nil when no root holds it (or a sandboxed build would have to ask for each level).
    @discardableResult
    func reveal(_ path: String) -> String? {
        guard !FileAccess.sandboxed else { return nil }
        let root = roots.filter { path == $0.path || path.hasPrefix($0.path + "/") }.max { $0.path.count < $1.path.count }
        guard let root else { return nil }
        var folder = root.path
        let rest = path.dropFirst(root.path.count).split(separator: "/").dropLast()
        setExpanded(Node(root: root.id, path: folder), true)
        for name in rest { folder += "/" + name; setExpanded(Node(root: root.id, path: folder), true) }
        return root.id
    }

    /// Keeps watching `path` while it is shown in the grid, expanded or not. `readable` once the folder has been
    /// read: opening a protected folder to watch it would ask for access on the main thread.
    func pin(_ path: String?, readable: Bool = false, deep: Bool = false) {
        pinned = path.map { [$0] } ?? []
        if let path, readable { watch(path) }
        if let path, readable, deep {
            if tree?.path != path { tree = TreeWatcher(path: path) { [weak self] in self?.changed?(path) } }
        } else if tree?.path != path || !deep { tree = nil }
        prune()
    }

    /// Reads a folder again, after the person allows access in the privacy settings.
    func retry(_ path: String) { load(path) }

    /// A folder was moved to the Trash: it and what was open below it leave the outline, and the folder that held
    /// it is read again.
    func removed(_ path: String) {
        expanded = expanded.filter { !($0.path == path || $0.path.hasPrefix(path + "/")) }
        pinned = pinned.filter { !($0 == path || $0.hasPrefix(path + "/")) }
        prune()
        let parent = (path as NSString).deletingLastPathComponent
        if contents[parent] != nil { load(parent) }
    }

    private func reloadAll() {
        for path in Set(expanded.map(\.path)) { load(path) }
        for path in pinned { changed?(path) }
    }

    private func load(_ path: String) {
        if contents[path] == nil { contents[path] = .loading }
        Task { [weak self] in
            // Off the main thread: the first read of a protected folder waits for the person to answer the system's question.
            let result: Contents = await Task.detached(priority: .userInitiated) {
                do { return .folders(try CatalogFolders.list(URL(fileURLWithPath: path, isDirectory: true), photos: false).folders) }
                catch { return CatalogFolders.isDenied(error) ? .denied : .missing }
            }.value
            guard let self else { return }
            let needed = self.expanded.contains { $0.path == path }
            if needed, case .folders = result { self.watch(path) }
            if needed, self.contents[path] != result { self.contents[path] = result }
        }
    }

    /// Names the connected cards, drives and network volumes. Off the main thread, and without asking how a share
    /// would be remounted: either can wait on a server that has stopped answering, for as long as it stays silent.
    private func reloadVolumes() {
        volumeGeneration += 1
        let generation = volumeGeneration
        Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { Self.mountedVolumes() }.value
            guard let self, self.volumeGeneration == generation else { return }
            if found != self.volumes { self.volumes = found }
            let mounted = Set(found.map(\.id))
            let gone = self.expanded.filter { $0.root.hasPrefix("volume:") && !mounted.contains($0.root) }
            if !gone.isEmpty { self.expanded.subtract(gone); self.prune() }
        }
    }

    /// From the mount table alone: nothing on a volume is opened, so macOS has nothing to ask permission for.
    private nonisolated static func mountedVolumes() -> [Root] {
        let keys: Set<URLResourceKey> = [.volumeUUIDStringKey, .volumeLocalizedNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey, .volumeIsRootFileSystemKey, .volumeIsLocalKey]
        var result: [Root] = []
        for url in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? [] {
            guard let values = try? url.resourceValues(forKeys: keys), values.volumeIsRootFileSystem != true else { continue }
            let network = values.volumeIsLocal == false
            let removable = values.volumeIsRemovable == true || values.volumeIsEjectable == true || values.volumeIsInternal == false
            guard network || removable else { continue }
            result.append(Root(id: "volume:" + (values.volumeUUIDString ?? url.path), url: url, title: values.volumeLocalizedName ?? url.lastPathComponent,
                               icon: network ? "network" : "externaldrive"))
        }
        return result.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func watch(_ path: String) {
        guard watchers[path] == nil, watchers.count < 128 else { return }
        watchers[path] = FolderWatcher(path: path) { [weak self] in
            guard let self else { return }
            if self.expanded.contains(where: { $0.path == path }) { self.load(path) }
            self.changed?(path)
        }
    }

    /// Stops watching folders that are neither open nor shown, and forgets what they held.
    private func prune() {
        let needed = Set(expanded.map(\.path)).union(pinned)
        for path in watchers.keys where !needed.contains(path) { watchers[path] = nil }
        for path in contents.keys where !needed.contains(path) { contents[path] = nil }
    }
}

/// Tells when entries are added to, removed from or renamed in one folder. A kernel event source on the folder itself:
/// no polling, and nothing below the folder is watched. Events are coalesced, since a copy raises one per file. The
/// folder is opened off the main thread, where a volume that has stopped answering cannot hold up the window.
@MainActor
private final class FolderWatcher {
    /// Reachable from `deinit`, which is not on the main actor.
    private final class Box: @unchecked Sendable { var source: DispatchSourceFileSystemObject? }
    private let box = Box()
    private var pending: Task<Void, Never>?

    init(path: String, changed: @escaping @MainActor () -> Void) {
        Task { [weak self] in
            let descriptor = await Task.detached { open(path, O_EVTONLY) }.value
            guard descriptor >= 0 else { return }
            guard let self else { close(descriptor); return }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .revoke], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pending?.cancel()
                    self.pending = Task {
                        try? await Task.sleep(for: .milliseconds(600))
                        if !Task.isCancelled { changed() }
                    }
                }
            }
            source.setCancelHandler { close(descriptor) }
            self.box.source = source
            source.resume()
        }
    }
    deinit { box.source?.cancel() }
}

/// Tells when anything changes below a folder, for a folder shown with its subfolders: one file-system event stream
/// for the whole tree, which the system coalesces. Network volumes send none; they are read again when the app comes
/// forward.
@MainActor
private final class TreeWatcher {
    private final class Box: @unchecked Sendable { var stream: FSEventStreamRef? }
    let path: String
    private let box = Box()
    private let changed: @MainActor () -> Void

    init(path: String, changed: @escaping @MainActor () -> Void) {
        self.path = path; self.changed = changed
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<TreeWatcher>.fromOpaque(info).takeUnretainedValue()
            // Delivered on the main queue, set below.
            MainActor.assumeIsolated { watcher.changed() }
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        box.stream = stream
    }
    deinit {
        guard let stream = box.stream else { return }
        FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
    }
}
