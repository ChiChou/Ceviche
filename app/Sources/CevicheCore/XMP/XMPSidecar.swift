import Foundation

/// The XMP file that keeps a photo's development when it is edited outside a catalog. Originals are never written,
/// and nothing is kept anywhere but beside the photo.
///
/// Edits go to the standard sidecar, `IMG.xmp`, so other editors read the portable settings. A sidecar another
/// application wrote is left alone: the edits then go to `IMG.ceviche.xmp` beside it, carrying that application's
/// packet so nothing of it is lost. When the photo's folder can't be written (a locked card, a read-only volume),
/// `write` throws and the caller asks where to save a copy (`saveCopy`).
public struct XMPSidecar: Sendable, Equatable {
    public let image: URL
    /// Where the development was read from; nil when the photo has none yet.
    public let readURL: URL?
    /// Where edits are written.
    public let writeURL: URL
    /// Another application's packet, kept in what Ceviche writes.
    public let preserved: Data?

    /// The same sidecar without another application's packet, so what Ceviche writes next carries only its own
    /// development. A sidecar that application wrote is still never written: edits go to `IMG.ceviche.xmp`.
    public func withoutPreserved() -> XMPSidecar {
        XMPSidecar(image: image, readURL: readURL, writeURL: writeURL, preserved: nil)
    }
    /// `IMG.ceviche.xmp` beside `image`.
    public static func cevicheURL(for image: URL) -> URL {
        image.deletingLastPathComponent().appendingPathComponent(image.deletingPathExtension().lastPathComponent + ".ceviche.xmp")
    }
    /// Read order: `IMG.ceviche.xmp`, then `IMG.xmp` or `IMG.ARW.xmp`.
    public static func resolve(for image: URL) throws -> XMPSidecar {
        if let own = try existingCevicheSidecar(for: image) {
            return XMPSidecar(image: image, readURL: own, writeURL: own, preserved: try XMPPacket(url: own).preservedSource)
        }
        if let standard = try XMPPacket.sidecar(for: image).map({ beside(image, $0) }) {
            let packet = try XMPPacket(url: standard)
            if packet.writtenByCeviche {
                return XMPSidecar(image: image, readURL: standard, writeURL: standard, preserved: packet.preservedSource)
            }
            return XMPSidecar(image: image, readURL: standard, writeURL: cevicheURL(for: image), preserved: packet.data)
        }
        return XMPSidecar(image: image, readURL: nil, writeURL: image.deletingPathExtension().appendingPathExtension("xmp"), preserved: nil)
    }
    /// Where edits to `image` are written, even when what is beside it can't be read (a damaged packet, two
    /// standard sidecars): Ceviche's own sidecar is written over, and another application's file is still left alone,
    /// the edits going to `IMG.ceviche.xmp` without its packet.
    public static func resolveForWriting(for image: URL) -> XMPSidecar {
        if let sidecar = try? resolve(for: image) { return sidecar }
        let own = (try? existingCevicheSidecar(for: image)).flatMap { $0 } ?? cevicheURL(for: image)
        return XMPSidecar(image: image, readURL: nil, writeURL: own, preserved: nil)
    }
    /// Whether edits to `image` can be saved beside it. Checked when the photo opens, so a locked card doesn't fail
    /// an autosave every few seconds; `write` can still fail later, and reports it with `isUnwritable`.
    public static func folderIsWritable(for image: URL) -> Bool {
        FileManager.default.isWritableFile(atPath: image.deletingLastPathComponent().path)
    }
    /// Writes the development to `writeURL`.
    public func write(adjustments: Adjustments, metadata: CatalogMetadata?, defaults: Adjustments) throws {
        let data = try XMPCodec.encode(adjustments: adjustments, metadata: metadata, defaults: defaults, sourceData: preserved, filename: image.lastPathComponent)
        try XMPCodec.write(data, to: writeURL, protecting: image)
    }
    /// Copies the photo and the sidecars beside it to `destination` (the copy's file URL), then writes the
    /// development there. Used when the photo's own folder can't be written: the photo and its edits stay together,
    /// so this app and others find them. Fails rather than replace an existing file.
    public static func saveCopy(of image: URL, to destination: URL, adjustments: Adjustments, metadata: CatalogMetadata?, defaults: Adjustments) throws -> XMPSidecar {
        let manager = FileManager.default
        let sidecars = try [existingCevicheSidecar(for: image), XMPPacket.sidecar(for: image)].compactMap { $0.map { beside(image, $0) } }
        let copies = sidecars.map { source -> (URL, URL) in
            let stem = destination.deletingPathExtension().lastPathComponent
            let name = source.lastPathComponent.lowercased().hasSuffix(".ceviche.xmp") ? stem + ".ceviche.xmp"
                : source.lastPathComponent.lowercased() == image.lastPathComponent.lowercased() + ".xmp" ? destination.lastPathComponent + ".xmp" : stem + ".xmp"
            return (source, destination.deletingLastPathComponent().appendingPathComponent(name))
        }
        for target in [destination] + copies.map(\.1) where manager.fileExists(atPath: target.path) {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: target.path])
        }
        var written: [URL] = []
        do {
            try manager.copyItem(at: image, to: destination); written.append(destination)
            for (source, target) in copies { try manager.copyItem(at: source, to: target); written.append(target) }
            let sidecar = try resolve(for: destination)
            try sidecar.write(adjustments: adjustments, metadata: metadata, defaults: defaults)
            return sidecar
        } catch {
            for url in written { try? manager.removeItem(at: url) }
            throw error
        }
    }
    /// A write that failed because the folder or volume can't be written, rather than for another reason.
    public static func isUnwritable(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, [NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError].contains(error.code) { return true }
        let posix = (error.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap { $0.domain == NSPOSIXErrorDomain ? $0.code : nil } ?? (error.domain == NSPOSIXErrorDomain ? error.code : nil)
        return posix.map { [Int(EACCES), Int(EPERM), Int(EROFS)].contains($0) } ?? false
    }
    static func existingCevicheSidecar(for image: URL) throws -> URL? {
        let name = cevicheURL(for: image).lastPathComponent.lowercased()
        return try FileManager.default.contentsOfDirectory(at: image.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.lowercased() == name }.map { beside(image, $0) }
    }
    /// A listing spells paths resolved (/private/var); found files keep the caller's spelling of the folder.
    static func beside(_ image: URL, _ found: URL) -> URL {
        image.deletingLastPathComponent().appendingPathComponent(found.lastPathComponent)
    }
}

extension XMPPacket {
    /// Last written by Ceviche, rather than by another editor since.
    var writtenByCeviche: Bool { value("CreatorTool", namespace: Self.xmp) == XMPCodec.creatorTool }
    /// The other application's packet this one carries, or this packet itself when another application wrote it.
    var preservedSource: Data? {
        writtenByCeviche ? nativeValue("SourcePacket").flatMap { Data(base64Encoded: $0) } : data
    }
}
