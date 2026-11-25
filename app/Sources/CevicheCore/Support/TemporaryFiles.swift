import Foundation

/// Working files a merge, export or decode left in the temporary folder when the app was stopped before it could remove
/// them (quit from the app switcher, killed for memory, replaced by a new build). A night-sky merge's alone can be gigabytes.
public enum TemporaryFiles {
    /// Removes what earlier runs left, and trims the decode cache, off the main thread; call once when the app starts, before any work begins.
    ///
    /// On iPad and iPhone the temporary folder is the app's own, so all of it goes but the system's folders
    /// (`com.apple.…`). On the Mac it is shared by the user's apps and another copy of Ceviche may be running, so only
    /// what is named for Ceviche and is a day old goes.
    public static func sweepLeftovers() {
        Task.detached(priority: .utility) {
            sweep(FileManager.default.temporaryDirectory)
            // The decode cache trims as it writes; once at launch too, so a lower limit holds before the next decode.
            DecodeCache.trim()
        }
    }

    static func sweep(_ folder: URL, now: Date = Date()) {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: []) else { return }
        for entry in entries {
            let name = entry.lastPathComponent
            #if os(macOS)
            let date = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            guard name.lowercased().hasPrefix("ceviche"), date < now.addingTimeInterval(-86_400) else { continue }
            #else
            guard !name.hasPrefix("com.apple.") else { continue }
            #endif
            try? manager.removeItem(at: entry)
        }
    }
}
