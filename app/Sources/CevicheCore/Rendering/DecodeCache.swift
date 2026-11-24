import Foundation
import CoreImage
import CryptoKit

/// RAW decoder output kept on disk in the user's Caches folder and mapped back read-only. Apple's decoder is the
/// slowest step of a preview and leaves its working surfaces in the context that ran it (1.5 GB for a 42 MP file at
/// half size); a mapped decode costs neither, and its pages are clean, so the system drops them under pressure
/// instead of counting them against the app. The cache outlives the session: reopening a recent photo with the same
/// decoder settings skips the decode. Entries are keyed by the source's path, size and modification date, the
/// macOS build and every decoder setting, so a changed original or system decoder misses; least recently used
/// entries go first once the folder passes `limit`.
enum DecodeCache {
    /// The decoder settings a decode depends on.
    struct Settings: Codable, Equatable {
        var scale: Float, temperature: Float, tint: Float, exposure: Float, extendedRange: Float, boost: Float
        var luminanceNoise: Float, colorNoise: Float, lensCorrection: Bool
        var profile: CameraProfile?
        var cameraRendering: Bool
    }
    static let limit: Int64 = 4 << 30
    static let bytesPerPixel = 8
    private static let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private static let lock = NSLock()

    /// In the app's Caches folder, always on the startup disk; test runs and tools outside the app use a temporary one.
    static let folder: URL? = {
        let inApp = Bundle.main.bundleURL.pathExtension == "app"
        guard let caches = inApp ? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first : FileManager.default.temporaryDirectory else { return nil }
        let folder = caches.appendingPathComponent(inApp ? Bundle.main.bundleIdentifier ?? "Ceviche" : "CevicheDecodes-\(getpid())", isDirectory: true)
            .appendingPathComponent("Decodes", isDirectory: true)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch { return nil }
        return folder
    }()

    /// What identifies the source and the decoder that reads it; nil when the file's size or date cannot be read.
    static func identity(of url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let date = values.contentModificationDate else { return nil }
        return "1|\(url.standardizedFileURL.path)|\(size)|\(date.timeIntervalSinceReferenceDate)|\(ProcessInfo.processInfo.operatingSystemVersionString)"
    }

    static func file(identity: String, settings: Settings) -> URL? {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        guard let folder, let json = try? encoder.encode(settings) else { return nil }
        let digest = SHA256.hash(data: Data(identity.utf8) + json).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(digest + ".rgbah")
    }

    /// The stored decode of `extent`, mapped, or nil when there is none of the right size.
    static func read(_ url: URL, extent: CGRect) -> CIImage? {
        let width = Int(extent.width), height = Int(extent.height), length = width * height * bytesPerPixel
        guard length > 0 else { return nil }
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0, Int(status.st_size) == length else { try? FileManager.default.removeItem(at: url); return nil }
        guard let map = mmap(nil, length, PROT_READ, MAP_SHARED, fd, 0), map != MAP_FAILED else { return nil }
        // Most recently used: the date the trim goes by.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        let data = Data(bytesNoCopy: map, count: length, deallocator: .custom { pointer, count in munmap(pointer, count) })
        return CIImage(bitmapData: data, bytesPerRow: width * bytesPerPixel, size: extent.size, format: .RGBAh, colorSpace: space)
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }

    /// Decodes `image` into `url` with `context`, then maps it back. The file is written under another name and
    /// renamed into place, so a reader never sees half a decode.
    static func write(_ image: CIImage, to url: URL, context: CIContext) -> CIImage? {
        let extent = image.extent, width = Int(extent.width), height = Int(extent.height), length = width * height * bytesPerPixel
        guard length > 0, extent.minX.rounded() == extent.minX, extent.minY.rounded() == extent.minY else { return nil }
        let partial = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).partial")
        let fd = open(partial.path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return nil }
        var written = false
        defer {
            close(fd)
            if !written { unlink(partial.path) }
        }
        guard ftruncate(fd, off_t(length)) == 0, let map = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0), map != MAP_FAILED else { return nil }
        context.render(image, toBitmap: map, rowBytes: width * bytesPerPixel, bounds: extent, format: .RGBAh, colorSpace: space)
        msync(map, length, MS_ASYNC)
        munmap(map, length)
        guard rename(partial.path, url.path) == 0 else { return nil }
        written = true
        trim()
        return read(url, extent: extent)
    }

    /// Removes the least recently used decodes until the folder is under `limit`, and partial files a crash left.
    static func trim(limit: Int64 = limit) {
        lock.lock(); defer { lock.unlock() }
        guard let folder, let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: []) else { return }
        let stale = Date().addingTimeInterval(-3600)
        var entries: [(url: URL, size: Int64, date: Date)] = []
        for file in files {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
            let date = values.contentModificationDate ?? .distantPast
            if file.pathExtension == "partial" {
                if date < stale { try? FileManager.default.removeItem(at: file) }
                continue
            }
            entries.append((file, Int64(values.fileSize ?? 0), date))
        }
        var total = entries.reduce(0) { $0 + $1.size }
        // A file mapped elsewhere stays readable after it is removed; only its name goes.
        for entry in entries.sorted(by: { $0.date < $1.date }) where total > limit {
            try? FileManager.default.removeItem(at: entry.url); total -= entry.size
        }
    }
}
