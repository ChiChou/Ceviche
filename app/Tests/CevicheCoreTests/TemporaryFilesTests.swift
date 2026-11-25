import XCTest
@testable import CevicheCore

final class TemporaryFilesTests: XCTestCase {
    /// On the Mac the temporary folder is shared: only Ceviche's own leftovers a day old go.
    func testSweepTakesOnlyOldCevicheFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TemporaryFilesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date()
        func make(_ name: String, age: TimeInterval) throws -> URL {
            let url = folder.appendingPathComponent(name)
            try Data([1]).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
            return url
        }
        let leftover = try make("Ceviche Night Sky A.cache", age: 2 * 86_400)
        let running = try make("Ceviche Night Sky B.cache", age: 60)
        let other = try make("Export-someone-else", age: 2 * 86_400)
        TemporaryFiles.sweep(folder, now: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: running.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }
}
