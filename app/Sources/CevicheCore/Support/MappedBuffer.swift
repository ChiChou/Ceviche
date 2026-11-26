import Foundation
import Metal

/// Full-size working buffers kept in a temporary file mapped into memory rather than in the app's own memory: the
/// changed pages are the file's, which the system writes back under pressure instead of counting them against the app
/// (iOS ends an app past its limit, with no paging). The file is unlinked as soon as it is open, so nothing is left
/// behind; Metal reads and writes the mapping in place. On every platform: a merge took no longer for it.
enum MappedBuffer {
    /// Tests that compare: false keeps every buffer in memory.
    nonisolated(unsafe) static var enabled = true

    /// A zeroed shared GPU buffer of at least `length` bytes over a mapped temporary file; nil when mapping is off or
    /// fails, and the caller allocates as before.
    static func make(_ device: MTLDevice, length: Int) -> MTLBuffer? {
        guard enabled, length > 0 else { return nil }
        let page = Int(getpagesize()), size = (length + page - 1) / page * page
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("Ceviche Mapped \(UUID().uuidString)").path
        let descriptor = open(path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { return nil }
        unlink(path)
        guard ftruncate(descriptor, off_t(size)) == 0, let base = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0), base != MAP_FAILED else {
            close(descriptor); return nil
        }
        // A file's new pages read as zeros, so it needs no clearing.
        guard let buffer = device.makeBuffer(bytesNoCopy: base, length: size, options: .storageModeShared, deallocator: { pointer, length in
            munmap(pointer, length); close(descriptor)
        }) else { munmap(base, size); close(descriptor); return nil }
        return buffer
    }
}
