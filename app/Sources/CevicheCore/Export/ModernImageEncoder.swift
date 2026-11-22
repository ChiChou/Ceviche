import Foundation
import CoreGraphics
import ImageIO
#if canImport(CWebP) && canImport(CJXL)
import CWebP
import CJXL
#endif

/// Encoders bundled from source. Both receive straight-alpha RGB in the requested ICC profile.
/// Lossless means exact rendered samples at the selected depth; these are not camera RAW encoders.
enum ModernImageEncoder {
    /// The codecs are static libraries in Vendor/Frameworks (scripts/vendor.sh), built for macOS (and iOS with
    /// CEVICHE_IOS=1); elsewhere these formats are not offered.
    static var isBuilt: Bool {
        #if canImport(CWebP) && canImport(CJXL)
        true
        #else
        false
        #endif
    }
    static func encode(_ image: CGImage, settings: ExportSettings, properties: [CFString: Any]) throws -> Data {
        #if canImport(CWebP) && canImport(CJXL)
        try checkLimits(settings, width: image.width, height: image.height)
        let pixels = try raster(image, depth: settings.depth)
        let icc = image.colorSpace?.copyICCData().map { $0 as Data }
        let exif = settings.includeMetadata ? try captureMetadata(properties, width: image.width, height: image.height) : nil
        switch settings.format {
        case .webp: return try webp(pixels, width: image.width, height: image.height, settings: settings, icc: icc, exif: exif)
        case .jxl: return try jxl(pixels, width: image.width, height: image.height, settings: settings, icc: icc, exif: exif)
        default: throw EditorError.render
        }
        #else
        throw EditorError.render
        #endif
    }

    static func checkLimits(_ settings: ExportSettings, width: Int, height: Int) throws {
        if settings.format == .webp, width > 16383 || height > 16383 {
            throw EditorError.invalidDocument(L10n.tr("WebP supports at most 16,383 pixels on either edge. Choose a smaller export size."))
        }
    }

#if canImport(CWebP) && canImport(CJXL)
    /// Both libraries do a whole frame inside one call, so cancellation is checked from their own callbacks:
    /// a failed call made while the task is cancelled is reported as cancelled, not as a render error.
    private static func failure() -> Error { Task.isCancelled ? CancellationError() : EditorError.render }

    /// Where libjxl writes the file. Streaming encodes write each 2048-pixel DC group as it is done, and refusing a
    /// buffer stops the encode cleanly; failing a parallel stage instead would abort the process (libjxl 0.10 checks
    /// some with JXL_CHECK). The callbacks run on the encoding thread, so `Task.isCancelled` sees the export's task.
    private final class JXLOutput {
        private var storage: UnsafeMutableRawPointer?
        private var capacity = 0, position = 0, end = 0
        deinit { free(storage) }
        var data: Data { storage.map { Data(bytes: $0, count: end) } ?? Data() }

        func processor() -> JxlEncoderOutputProcessor {
            JxlEncoderOutputProcessor(opaque: Unmanaged.passUnretained(self).toOpaque(), get_buffer: { opaque, size in
                guard let opaque, let size else { return nil }
                let output = Unmanaged<JXLOutput>.fromOpaque(opaque).takeUnretainedValue()
                guard !Task.isCancelled else { size.pointee = 0; return nil }
                size.pointee = max(size.pointee, 1 << 16)
                if output.position + size.pointee > output.capacity {
                    let capacity = max(output.capacity * 2, output.position + size.pointee)
                    guard let grown = realloc(output.storage, capacity) else { size.pointee = 0; return nil }
                    output.storage = grown; output.capacity = capacity
                }
                return output.storage! + output.position
            }, release_buffer: { opaque, written in
                guard let opaque else { return }
                let output = Unmanaged<JXLOutput>.fromOpaque(opaque).takeUnretainedValue()
                output.position += written; output.end = max(output.end, output.position)
            }, seek: { opaque, position in
                guard let opaque else { return }
                Unmanaged<JXLOutput>.fromOpaque(opaque).takeUnretainedValue().position = Int(position)
            }, set_finalized_position: { _, _ in })
        }
    }

    private static func raster(_ image: CGImage, depth: Int) throws -> Data {
        let rowBytes = image.width * 4 * (depth / 8)
        var data = Data(count: rowBytes * image.height)
        try data.withUnsafeMutableBytes { bytes in
            let order: CGBitmapInfo = depth == 16 ? .byteOrder16Little : .byteOrder32Big
            guard let space = image.colorSpace,
                  let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: depth, bytesPerRow: rowBytes, space: space,
                                          bitmapInfo: order.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { throw EditorError.render }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            // Core Graphics uses associated alpha; libwebp and libjxl take unassociated samples.
            if depth == 8 {
                let p = bytes.bindMemory(to: UInt8.self)
                for i in stride(from: 0, to: p.count, by: 4) where p[i + 3] > 0 && p[i + 3] < 255 {
                    let a = Int(p[i + 3])
                    for c in 0..<3 { p[i + c] = UInt8(min(255, (Int(p[i + c]) * 255 + a / 2) / a)) }
                }
            } else {
                let p = bytes.bindMemory(to: UInt16.self)
                for i in stride(from: 0, to: p.count, by: 4) where p[i + 3] > 0 && p[i + 3] < 65535 {
                    let a = UInt64(p[i + 3])
                    for c in 0..<3 { p[i + c] = UInt16(min(65535, (UInt64(p[i + c]) * 65535 + a / 2) / a)) }
                }
            }
        }
        return data
    }

    private static func webp(_ pixels: Data, width: Int, height: Int, settings: ExportSettings, icc: Data?, exif: Data?) throws -> Data {
        var config = WebPConfig()
        guard WebPConfigInit(&config) != 0 else { throw EditorError.render }
        config.lossless = settings.lossless ? 1 : 0
        config.quality = settings.lossless ? 75 : Float(settings.quality * 100)
        config.method = 4; config.exact = 1; config.thread_level = 1
        var picture = WebPPicture()
        guard WebPPictureInit(&picture) != 0 else { throw EditorError.render }
        defer { WebPPictureFree(&picture) }
        picture.width = Int32(width); picture.height = Int32(height); picture.use_argb = 1
        picture.progress_hook = { _, _ in Task.isCancelled ? 0 : 1 }
        guard pixels.withUnsafeBytes({ WebPPictureImportRGBA(&picture, $0.bindMemory(to: UInt8.self).baseAddress, Int32(width * 4)) }) != 0 else { throw EditorError.render }
        var writer = WebPMemoryWriter()
        WebPMemoryWriterInit(&writer)
        defer { WebPMemoryWriterClear(&writer) }
        let success = withUnsafeMutablePointer(to: &writer) { ptr in
            picture.writer = WebPMemoryWrite; picture.custom_ptr = UnsafeMutableRawPointer(ptr)
            return WebPEncode(&config, &picture)
        }
        guard success != 0 else { throw failure() }
        guard let mux = WebPMuxNew() else { throw EditorError.render }
        defer { WebPMuxDelete(mux) }
        var bitstream = WebPData(bytes: UnsafePointer(writer.mem), size: writer.size)
        guard WebPMuxSetImage(mux, &bitstream, 1) == WEBP_MUX_OK else { throw EditorError.render }
        for (tag, data) in [("ICCP", icc), ("EXIF", exif)] {
            if let data {
                let result = data.withUnsafeBytes { bytes in
                    var chunk = WebPData(bytes: bytes.bindMemory(to: UInt8.self).baseAddress, size: bytes.count)
                    return WebPMuxSetChunk(mux, tag, &chunk, 1)
                }
                guard result == WEBP_MUX_OK else { throw EditorError.render }
            }
        }
        var output = WebPData()
        guard WebPMuxAssemble(mux, &output) == WEBP_MUX_OK, let bytes = output.bytes else { throw EditorError.render }
        defer { WebPDataClear(&output) }
        return Data(bytes: bytes, count: output.size)
    }

    private static func jxl(_ pixels: Data, width: Int, height: Int, settings: ExportSettings, icc: Data?, exif: Data?) throws -> Data {
        guard let runner = JxlThreadParallelRunnerCreate(nil, min(8, ProcessInfo.processInfo.activeProcessorCount)) else { throw EditorError.render }
        defer { JxlThreadParallelRunnerDestroy(runner) }
        guard let encoder = JxlEncoderCreate(nil) else { throw EditorError.render }
        defer { JxlEncoderDestroy(encoder) }
        func check(_ status: JxlEncoderStatus) throws { if status != JXL_ENC_SUCCESS { throw failure() } }
        try check(JxlEncoderSetParallelRunner(encoder, JxlThreadParallelRunner, runner))
        let output = JXLOutput()
        try check(JxlEncoderSetOutputProcessor(encoder, output.processor()))
        try check(JxlEncoderUseContainer(encoder, 1))
        var info = JxlBasicInfo()
        JxlEncoderInitBasicInfo(&info)
        info.xsize = UInt32(width); info.ysize = UInt32(height)
        info.bits_per_sample = UInt32(settings.depth)
        info.num_color_channels = 3; info.num_extra_channels = 1
        info.alpha_bits = UInt32(settings.depth); info.alpha_premultiplied = 0
        info.uses_original_profile = settings.lossless ? 1 : 0
        try check(JxlEncoderSetBasicInfo(encoder, &info))
        guard let icc else { throw EditorError.render }
        try icc.withUnsafeBytes { try check(JxlEncoderSetICCProfile(encoder, $0.bindMemory(to: UInt8.self).baseAddress, $0.count)) }
        if let exif {
            try check(JxlEncoderUseBoxes(encoder))
            // Exif box starts with a big-endian offset to its TIFF header (zero here).
            let box = Data(repeating: 0, count: 4) + exif
            try box.withUnsafeBytes { try check(JxlEncoderAddBox(encoder, "Exif", $0.bindMemory(to: UInt8.self).baseAddress, $0.count, 0)) }
            JxlEncoderCloseBoxes(encoder)
        }
        guard let frame = JxlEncoderFrameSettingsCreate(encoder, nil) else { throw EditorError.render }
        try check(JxlEncoderSetFrameLossless(frame, settings.lossless ? 1 : 0))
        try check(JxlEncoderSetFrameDistance(frame, settings.lossless ? 0 : JxlEncoderDistanceFromQuality(Float(settings.quality * 100))))
        try check(JxlEncoderFrameSettingsSetOption(frame, JXL_ENC_FRAME_SETTING_EFFORT, 7))
        var format = JxlPixelFormat(num_channels: 4, data_type: settings.depth == 16 ? JXL_TYPE_UINT16 : JXL_TYPE_UINT8, endianness: JXL_LITTLE_ENDIAN, align: 0)
        try pixels.withUnsafeBytes { try check(JxlEncoderAddImageFrame(frame, &format, $0.baseAddress, $0.count)) }
        JxlEncoderCloseInput(encoder)
        try check(JxlEncoderFlushInput(encoder))
        // A cancelled encode can end between groups without an error; its output is incomplete either way.
        try Task.checkCancellation()
        return withExtendedLifetime(output) { output.data }
    }

    /// Let ImageIO serialize the same capture-only EXIF/TIFF dictionaries as the system formats.
    /// A tiny JPEG is just a metadata serializer; its image data is discarded, never embedded.
    private static func captureMetadata(_ properties: [CFString: Any], width: Int, height: Int) throws -> Data? {
        guard properties[kCGImagePropertyGPSDictionary] != nil || properties[kCGImagePropertyExifDictionary] != nil ||
                !(properties[kCGImagePropertyTIFFDictionary] as? [String: Any] ?? [:]).isEmpty else { return nil }
        let data = NSMutableData()
        guard let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: RGBProfile.sRGB.space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let image = context.makeImage(), let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { throw EditorError.render }
        var properties = properties
        var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        exif[kCGImagePropertyExifPixelXDimension] = width; exif[kCGImagePropertyExifPixelYDimension] = height
        properties[kCGImagePropertyExifDictionary] = exif
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw EditorError.render }
        let bytes = data as Data
        var i = 2
        while i + 4 <= bytes.count, bytes[i] == 0xff {
            let marker = bytes[i + 1]
            if marker == 0xda || marker == 0xd9 { break }
            let length = Int(bytes[i + 2]) * 256 + Int(bytes[i + 3])
            guard length >= 2, i + 2 + length <= bytes.count else { throw EditorError.render }
            if marker == 0xe1, length >= 8, Array(bytes[(i + 4)..<(i + 10)]) == [69, 120, 105, 102, 0, 0] {
                var tiff = bytes.subdata(in: (i + 10)..<(i + 2 + length))
                try restoreDimensions(&tiff, width: width, height: height)
                return tiff
            }
            i += length + 2
        }
        throw EditorError.invalidDocument(L10n.tr("Capture metadata could not be encoded."))
    }

    /// ImageIO overwrites EXIF dimensions with the serializer image's 1×1 size. Restore the
    /// two inline scalar tags in the generated TIFF, without touching strings or capture data.
    private static func restoreDimensions(_ tiff: inout Data, width: Int, height: Int) throws {
        let little = tiff.prefix(2) == Data([0x49, 0x49])
        func number(_ offset: Int, _ count: Int) throws -> Int {
            guard offset >= 0, offset + count <= tiff.count else { throw EditorError.render }
            let bytes = Array(tiff[offset..<(offset + count)])
            return (little ? Array(bytes.reversed()) : bytes).reduce(0) { ($0 << 8) | Int($1) }
        }
        func entry(_ tag: Int, in directory: Int) throws -> Int? {
            let count = try number(directory, 2)
            guard directory + 2 + count * 12 <= tiff.count else { throw EditorError.render }
            for index in 0..<count {
                let offset = directory + 2 + index * 12
                if try number(offset, 2) == tag { return offset }
            }
            return nil
        }
        guard let pointer = try entry(0x8769, in: number(4, 4)) else { throw EditorError.render }
        let exif = try number(pointer + 8, 4)
        let tags = try [(entry(0xa002, in: exif), width), (entry(0xa003, in: exif), height)]
        for (offset, value) in tags {
            guard let offset, value > 0, value <= Int(UInt32.max) else { throw EditorError.render }
            func store(_ number: Int, at offset: Int, count: Int) {
                for i in 0..<count { tiff[offset + i] = UInt8(truncatingIfNeeded: number >> (8 * (little ? i : count - i - 1))) }
            }
            store(4, at: offset + 2, count: 2) // LONG, one inline value
            store(1, at: offset + 4, count: 4)
            store(value, at: offset + 8, count: 4)
        }
    }

#endif
}
