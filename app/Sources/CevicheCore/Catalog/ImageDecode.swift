import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// ImageIO thumbnails of originals, made on a thread with a main-thread-sized stack. Apple's RAW decoder (RawCamera)
/// uses 128–256 KB of stack for a thumbnail, and Swift task and dispatch worker threads have 512 KB in all: with the
/// import's own frames above it, some Sony ARWs crashed with a stack overflow (SIGBUS in `___chkstk_darwin`). Run
/// here, the decoder's room no longer depends on what calls it.
public enum ImageDecode {
    /// The main thread's stack size on macOS and iOS.
    static let stackSize = 8 << 20

    /// `CGImageSourceCreateThumbnailAtIndex` with room for the RAW decoder. Use it wherever the source may be an original.
    public static func thumbnail(_ source: CGImageSource, _ index: Int, _ options: CFDictionary?) -> CGImage? {
        onLargeStack { CGImageSourceCreateThumbnailAtIndex(source, index, options) }
    }

    /// An upright image of the photo, at most `pixelSize` on its long edge, to measure rather than to show. The preview
    /// the camera stored in the file is used when it is at least `minimum` on its long edge: ImageIO then reads only
    /// that preview, about 1 MB, where a RAW decoded at any size reads and demosaics the whole original (40 MB over a
    /// network share, and a gigabyte of memory at full size). Photos without such a preview are decoded at `pixelSize`:
    /// a RAW (an enhanced-noise-reduction or panorama DNG from another editor, with a 1024 px preview) through Core Image at that scale, 0.7 GB
    /// where ImageIO took 2 GB for a 60 MP linear DNG; anything else through ImageIO. Either way one at a time: a
    /// layered 16-bit TIFF still takes 1.6 GB, and four such decodes together took a whole-library scan to 4 GB.
    /// `usesPreview` false decodes the photo itself, for a preview framed differently from it.
    public static func analysisImage(_ source: CGImageSource, url: URL? = nil, pixelSize: Int, minimum: Int, usesPreview: Bool = true) -> CGImage? {
        func make(_ key: CFString) -> CGImage? {
            thumbnail(source, 0, [key: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: pixelSize] as CFDictionary)
        }
        let type = (CGImageSourceGetType(source) as String?).flatMap { UTType($0) }
        let isRAW = type?.conforms(to: .rawImage) ?? false
        // JPEG and HEIF decode straight to a small size; ImageIO makes a missing TIFF or PNG thumbnail from the whole image.
        let light = isRAW || type.map { $0.conforms(to: .jpeg) || $0.conforms(to: .heif) || $0.conforms(to: .heic) } ?? false
        if usesPreview, light, let embedded = make(kCGImageSourceCreateThumbnailFromImageIfAbsent), max(embedded.width, embedded.height) >= min(minimum, pixelSize) { return embedded }
        if isRAW, let url, let scaled = oneAtATime({ scaledRAW(url, pixelSize: pixelSize) }) { return scaled }
        if light && !isRAW { return make(kCGImageSourceCreateThumbnailFromImageAlways) }
        return oneAtATime {
            if usesPreview, let stored = make(kCGImageSourceCreateThumbnailFromImageIfAbsent), max(stored.width, stored.height) >= min(minimum, pixelSize) { return stored }
            return make(kCGImageSourceCreateThumbnailFromImageAlways)
        }
    }

    /// Runs a whole-image decode, one at a time across every caller: a layered 16-bit TIFF alone takes 1.6 GB. The
    /// waiting threads only block; there are as many as callers measuring at once (four while culling).
    static func oneAtATime<T>(_ work: () throws -> T) rethrows -> T {
        heavy.lock(); defer { heavy.unlock() }
        return try work()
    }
    private static let heavy = NSLock()
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// The RAW demosaiced at the scale that makes its long edge `pixelSize`, upright, without a full-size image. On the
    /// large stack, like every RAW decode here.
    private static func scaledRAW(_ url: URL, pixelSize: Int) -> CGImage? {
        onLargeStack { scaledRAWOnStack(url, pixelSize: pixelSize) }
    }
    private static func scaledRAWOnStack(_ url: URL, pixelSize: Int) -> CGImage? {
        guard let raw = CIRAWFilter(imageURL: url) else { return nil }
        let long = max(raw.nativeSize.width, raw.nativeSize.height)
        guard long > 0 else { return nil }
        raw.scaleFactor = Float(min(1, Double(pixelSize) / long))
        guard let image = raw.outputImage, !image.extent.isInfinite, !image.extent.isEmpty else { return nil }
        // Core Image keeps the decode's buffers for reuse; dropped here, or the next file's decode adds to them.
        defer { context.clearCaches() }
        return context.createCGImage(image, from: image.extent.integral, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// Runs `work` on a fresh thread with an 8 MB stack and waits for it. The waiting thread only blocks; the work
    /// never needs the Swift concurrency pool, so this cannot deadlock it. The main thread already has the room.
    static func onLargeStack<T>(_ work: @escaping () -> T) -> T {
        if Thread.isMainThread { return work() }
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        // The thread object outlives the signal, so `work` must be escaping.
        let thread = Thread {
            box.value = autoreleasepool { work() }
            done.signal()
        }
        thread.stackSize = stackSize
        thread.qualityOfService = Thread.current.qualityOfService
        thread.start()
        done.wait()
        return box.value!
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}
