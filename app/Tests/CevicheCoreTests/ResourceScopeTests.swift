import XCTest
@testable import CevicheCore

final class ResourceScopeTests: XCTestCase {
    func testOnlyICloudCatalogsKeepLooksInICloudDrive() {
        let drive = FolderResources(root: URL(fileURLWithPath: "/tmp/Drive"), ubiquitous: true)
        let build = ResourceStorage.folder(drive)
        XCTAssertTrue(build.scoped(to: .cloud).folder === drive)
        for kind in [CatalogKind.local, .file] {
            let local = build.scoped(to: kind).folder
            XCTAssertEqual(local?.root, LookLibrary.localRoot.standardizedFileURL, "\(kind)")
            XCTAssertFalse(local?.ubiquitous ?? true)
            XCTAssertEqual(LookLibrary(resources: build.scoped(to: kind)).root, LookLibrary.localRoot.standardizedFileURL)
        }
        // A build without iCloud Drive already keeps everything on this Mac.
        let plain = FolderResources(root: URL(fileURLWithPath: "/tmp/Local"))
        XCTAssertTrue(ResourceStorage.folder(plain).scoped(to: .local).folder === plain)
        XCTAssertNil(ResourceStorage.database.scoped(to: .local).folder)
    }
}
