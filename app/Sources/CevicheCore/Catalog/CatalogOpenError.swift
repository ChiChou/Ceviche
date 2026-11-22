import Foundation

/// Why a local catalog didn't open as usual. A newer build's catalog, or one whose database failed to open or upgrade,
/// can still be shown read-only (`CatalogStore.init(readOnly:)`); one from before the current schema can't be opened.
public enum CatalogOpenError: LocalizedError, Equatable {
    case earlier, newer
    /// The database's own error.
    case unreadable(String)
    public var canOpenReadOnly: Bool { self != .earlier }
    public var errorDescription: String? {
        switch self {
        case .earlier: return L10n.tr("This catalog was made by an earlier version of Ceviche and can't be opened. Create a new catalog and import the photos again.")
        case .newer: return L10n.tr("This catalog was last opened by a newer version of Ceviche.")
        case .unreadable(let reason): return reason
        }
    }
}
