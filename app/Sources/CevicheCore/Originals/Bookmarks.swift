import Foundation

/// Bookmarks that carry access to a user-chosen file. On macOS the scope is asked for explicitly; iOS bookmarks to
/// files from the document picker carry it implicitly and have no option for it.
extension URL.BookmarkCreationOptions {
    static var securityScoped: Self {
        #if os(macOS)
        .withSecurityScope
        #else
        []
        #endif
    }
}

extension URL.BookmarkResolutionOptions {
    static var securityScopedResolution: Self {
        #if os(macOS)
        [.withSecurityScope, .withoutUI]
        #else
        .withoutUI
        #endif
    }
}
