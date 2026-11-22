import AppKit

extension NSWorkspace {
    /// Show in Finder: a single plain folder opens as its own window, so its contents are what the user sees; files,
    /// packages (a catalog) and several items are selected in their folder.
    func showInFinder(_ urls: [URL]) {
        if urls.count == 1, let url = urls.first,
           let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
           values.isDirectory == true, values.isPackage != true {
            open(url)
        } else {
            activateFileViewerSelecting(urls)
        }
    }
}
