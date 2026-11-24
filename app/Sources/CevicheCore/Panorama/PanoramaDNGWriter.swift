import Foundation
import CoreGraphics
import CDNG

/// Writes a merge as a DNG 1.4 LinearRaw of developed linear sRGB: demosaicing, lens correction and the shared white
/// balance are baked in, but the data stays linear with headroom, so exposure, white balance and color still edit
/// smoothly. The profile is a synthetic linear-sRGB camera (D50-adapted matrices, neutral as-shot white) with no profile
/// tone curve, so Apple's decoder gives the file its standard tone response, which matches what it gives the camera's
/// own RAW files (an identity ProfileToneCurve would replace it and leave the merge flat). The source camera, lens and
/// place are named (`source`).
/// Half-float samples in 256-pixel Deflate tiles (or 16-bit lossless JPEG), plus an 8-bit Deflate transparency mask
/// where the photos don't reach and an sRGB preview. Classic TIFF, little-endian.
struct PanoramaDNGWriter {
    /// What made the file, for its description and the generic camera it names.
    enum Kind: String { case panorama = "Panorama", hdr = "HDR", starTrails = "Star Trails", nightSky = "Night Sky", meteorShower = "Meteor Shower", focusStack = "Focus Stack", stack = "Stack", pixelShift = "Pixel Shift", bestFaces = "Best Faces" }
    var metadata: PanoramaFrameMetadata
    var kind = Kind.panorama
    /// Stops added back when reading, for exposure gains that darkened the stored pixels.
    var baselineExposure = 0.0
    var preview: CGImage?
    /// The one photo the file was made from, whose camera, exposure and location it keeps; nil for merges.
    var source: DNGSourceMetadata?
    /// 16-bit floating-point samples (Deflate with the floating-point predictor): steps of a thousandth at every level,
    /// so the shadows of a stack or an HDR merge keep their precision and highlights above white need no scaling.
    /// Apple's decoder reads them; 32-bit floats it can't open. False writes 16-bit integers under a power-of-two white.
    var floatingPoint = true
    /// EXIF orientation of the stored pixels, for a merge made from the sensor's own samples; the preview is stored the same way.
    var orientation = 1
    /// A file read once and thrown away (a video's frame): the same pixels, packed fast rather than small, with a
    /// token preview.
    var scratch = false

    /// The longest side Apple's decoder develops in a DNG: past it the whole picture comes out transparent (measured on
    /// macOS 27, between 19968 and 19990, the 78th and 79th 256-pixel tile). Larger merges are kept as TIFF or JPEG.
    public static let developableSide = 19968

    func write(_ image: PanoramaRaster, to url: URL, progress: (Double) -> Void = { _ in }, cancelled: () -> Bool = { false }) throws {
        guard image.width <= 65_000, image.height <= 65_000, Double(image.width) * Double(image.height) * 6 < 3.8e9 else {
            throw PanoramaError.message(L10n.tr("The panorama is too large for a DNG file."))
        }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let temporary = staging.appendingPathComponent("Export.dng")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw PanoramaError.message(L10n.tr("Can’t write to \(url.deletingLastPathComponent().path)."))
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        var file = TIFFFile(handle: handle)
        try file.write(Data([0x49, 0x49, 42, 0, 0, 0, 0, 0]))

        let hasMask = stride(from: 3, to: image.rgba.count, by: 4).contains { image.rgba[$0] < 0.999 }
        // Readers clip at WhiteLevel, so recovered highlights above 1 are scaled under a power-of-two white and the
        // baseline exposure gives the stops back. Negative out-of-gamut samples clamp to 0.
        var brightest: Float = 1
        for p in stride(from: 0, to: image.rgba.count, by: 4) where image.rgba[p + 3] > 0 {
            brightest = max(brightest, image.rgba[p], image.rgba[p + 1], image.rgba[p + 2])
        }
        let white = floatingPoint ? 1 : Float(exp2(ceil(log2(Double(min(brightest, 65536))))))
        let main: [(UInt32, UInt32)]
        if floatingPoint {
            let bytes = 2
            main = try writeTiles(image, samples: 3, bytesPerSample: bytes, codec: .deflate, difference: false, file: &file,
                                  progress: { progress(hasMask ? 0.9 * $0 : $0) }, cancelled: cancelled) { rgba, p, out, o in
                for c in 0..<3 {
                    let v = rgba[p + c], clean = v.isFinite ? max(0, v) : 0
                    let bits = UInt32(Float16(min(clean, 65000)).bitPattern)
                    for b in 0..<bytes { out[o + bytes * c + b] = UInt8((bits >> (8 * b)) & 0xFF) }
                }
            }
        } else {
            main = try writeTiles(image, samples: 3, codec: .losslessJPEG, file: &file,
                                  progress: { progress(hasMask ? 0.9 * $0 : $0) }, cancelled: cancelled) { rgba, p, out, o in
                for c in 0..<3 {
                    let v = rgba[p + c] / white
                    // Little-endian 16-bit; uncovered pixels are 0.
                    let q = UInt16((max(0, min(1, v.isFinite ? v : 0)) * 65535).rounded())
                    out[o + 2 * c] = UInt8(q & 0xFF); out[o + 2 * c + 1] = UInt8(q >> 8)
                }
            }
        }
        var subIFDs = [try file.writeIFD(entries: rasterEntries(image, subfile: 0, bits: [16, 16, 16], photometric: 34892,
                                                                codec: floatingPoint ? .deflate : .losslessJPEG, tiles: main, sampleFormat: floatingPoint ? 3 : 1) + [
            (50713, .shorts([1, 1])), (50714, .longs([0, 0, 0])), (50717, .longs(floatingPoint ? [1, 1, 1] : [65535, 65535, 65535])),
            (50718, .rationals([(1, 1), (1, 1)])), (50719, .longs([0, 0])), (50720, .longs([UInt32(image.width), UInt32(image.height)])),
            (50829, .longs([0, 0, UInt32(image.height), UInt32(image.width)])),
        ])]
        if hasMask {
            let mask = try writeTiles(image, samples: 1, bytesPerSample: 1, codec: .deflate, file: &file,
                                      progress: { progress(0.9 + 0.1 * $0) }, cancelled: cancelled) { rgba, p, out, o in
                out[o] = UInt8((max(0, min(1, rgba[p + 3])) * 255).rounded())
            }
            subIFDs.append(try file.writeIFD(entries: rasterEntries(image, subfile: 4, bits: [8], photometric: 52527, codec: .deflate, tiles: mask)))
        }

        let date = metadata.captureTime
        var exif: [(UInt16, TIFFValue)] = [(36864, .undefined(Array("0231".utf8)))]
        if let date { exif.append((36867, .ascii(date))) }
        exif += source?.exif ?? []
        let exifIFD = try file.writeIFD(entries: exif)
        let gpsIFD = try source.flatMap { $0.gps.isEmpty ? nil : try file.writeIFD(entries: $0.gps) }

        // IFD 0: the preview and the DNG color description. Apple's decoder rejects compressed raw data behind a
        // placeholder preview, so there is always a real one.
        let picture = (preview ?? PanoramaFinishing.picture(image, maxDimension: scratch ? 96 : 1024)).flatMap(Self.rgbBytes)
        let previewWidth = picture?.width ?? 1, previewHeight = picture?.height ?? 1
        let stripOffset = try file.append(Data(picture?.bytes ?? [0, 0, 0]))
        let camera = [metadata.make, metadata.model].filter { !$0.isEmpty }.joined(separator: " ")
        var entries: [(UInt16, TIFFValue)] = [
            (254, .longs([1])), (256, .longs([UInt32(previewWidth)])), (257, .longs([UInt32(previewHeight)])),
            (258, .shorts([8, 8, 8])), (259, .shorts([1])), (262, .shorts([2])),
            (270, .ascii(camera.isEmpty ? "\(kind.rawValue) merged in Ceviche" : "\(kind.rawValue) merged in Ceviche from \(camera) photos")),
            // A generic camera, so the decoder applies no camera-specific processing to pixels that already had it.
            (271, .ascii("Ceviche")), (272, .ascii(kind.rawValue)), (273, .longs([stripOffset])), (274, .shorts([UInt16(orientation)])),
            (277, .shorts([3])), (278, .longs([UInt32(previewHeight)])), (279, .longs([UInt32(previewWidth * previewHeight * 3)])),
            (284, .shorts([1])), (305, .ascii("Ceviche \(kind.rawValue) Merge")),
            (330, .longs(subIFDs)), (34665, .longs([exifIFD])),
            (50706, .bytes([1, 4, 0, 0])), (50707, .bytes([1, 1, 0, 0])), (50708, .ascii("Ceviche \(kind.rawValue) Linear sRGB")),
            // Linear sRGB primaries in Bradford-adapted XYZ D50: XYZ → RGB as the color matrix, RGB → XYZ as the forward matrix.
            (50721, .srationals([3.1338561, -1.6168667, -0.4906146, -0.9787684, 1.9161415, 0.0334540, 0.0719453, -0.2289914, 1.4052427].map(Self.rational))),
            (50964, .srationals([0.4360747, 0.3850649, 0.1430804, 0.2225045, 0.7168786, 0.0606169, 0.0139322, 0.0971045, 0.7141733].map(Self.rational))),
            (50728, .rationals([(1, 1), (1, 1), (1, 1)])),
            (50730, .srationals([Self.rational(baselineExposure + log2(Double(white)))])),
            (50778, .shorts([23])), // D50
            (50970, .longs([2])),   // sRGB preview
            (51110, .longs([1])),   // no automatic black subtraction
        ]
        if let date { entries.append((306, .ascii(date))) }
        if let gpsIFD { entries.append((34853, .longs([gpsIFD]))) }
        if let source { entries = source.ifd0(entries) }
        let ifd0 = try file.writeIFD(entries: entries)
        try file.patchFirstIFD(ifd0)
        try handle.close()
        if cancelled() { throw CancellationError() }
        try FileManager.default.moveItem(at: temporary, to: url)
    }

    enum Codec: UInt16 { case losslessJPEG = 7, deflate = 8 }

    private func rasterEntries(_ image: PanoramaRaster, subfile: UInt32, bits: [UInt16], photometric: UInt16, codec: Codec, tiles: [(UInt32, UInt32)],
                               sampleFormat: UInt16 = 1) -> [(UInt16, TIFFValue)] {
        var entries: [(UInt16, TIFFValue)] = [
            (254, .longs([subfile])), (256, .longs([UInt32(image.width)])), (257, .longs([UInt32(image.height)])),
            (258, .shorts(bits)), (259, .shorts([codec.rawValue])), (262, .shorts([photometric])),
            (277, .shorts([UInt16(bits.count)])), (284, .shorts([1])),
            (322, .longs([256])), (323, .longs([256])), (324, .longs(tiles.map(\.0))), (325, .longs(tiles.map(\.1))),
            (339, .shorts(bits.map { _ in sampleFormat })),
        ]
        if codec == .deflate { entries.append((317, .shorts([sampleFormat == 3 ? 3 : 2]))) }
        return entries
    }

    /// Encodes and appends every 256 × 256 tile, a row of tiles at a time with the tiles compressed in parallel.
    private func writeTiles(_ image: PanoramaRaster, samples: Int, bytesPerSample: Int = 2, codec: Codec, difference: Bool = true, file: inout TIFFFile,
                            progress: (Double) -> Void, cancelled: () -> Bool,
                            encode: @escaping (UnsafeBufferPointer<Float>, Int, UnsafeMutablePointer<UInt8>, Int) -> Void) throws -> [(UInt32, UInt32)] {
        let side = 256, across = (image.width + side - 1) / side, down = (image.height + side - 1) / side
        let pixelBytes = samples * bytesPerSample, tileBytes = side * side * pixelBytes
        var tiles: [(UInt32, UInt32)] = []
        for row in 0..<down {
            if cancelled() { throw CancellationError() }
            var encoded = [Data](repeating: Data(), count: across)
            image.rgba.withUnsafeBufferPointer { rgba in
                encoded.withUnsafeMutableBufferPointer { encodedOut in
                    let encodedOut = encodedOut
                    DispatchQueue.concurrentPerform(iterations: across) { column in
                        var tile = [UInt8](repeating: 0, count: tileBytes)
                        tile.withUnsafeMutableBufferPointer { tile in
                            for ty in 0..<side where row * side + ty < image.height {
                                for tx in 0..<side where column * side + tx < image.width {
                                    let p = ((row * side + ty) * image.width + column * side + tx) * 4
                                    encode(rgba, p, tile.baseAddress!, (ty * side + tx) * pixelBytes)
                                }
                            }
                            if codec == .deflate, !difference, bytesPerSample > 1 {
                                // Floating-point predictor (TIFF Technical Note 3): each row's sample bytes regrouped most
                                // significant first, then each byte less the one a pixel's samples before it.
                                let rowBytes = side * pixelBytes, count = side * samples
                                var shuffled = [UInt8](repeating: 0, count: rowBytes)
                                for ty in 0..<side {
                                    let row = ty * rowBytes
                                    for i in 0..<count { for b in 0..<bytesPerSample {
                                        shuffled[(bytesPerSample - 1 - b) * count + i] = tile[row + i * bytesPerSample + b]
                                    } }
                                    for i in stride(from: rowBytes - 1, through: samples, by: -1) { shuffled[i] = shuffled[i] &- shuffled[i - samples] }
                                    for i in 0..<rowBytes { tile[row + i] = shuffled[i] }
                                }
                                return
                            }
                            guard codec == .deflate, difference else { return }
                            // Horizontal differencing per sample, right to left, wrapping.
                            for ty in 0..<side {
                                for tx in stride(from: side - 1, to: 0, by: -1) {
                                    for s in 0..<samples {
                                        let o = (ty * side + tx) * pixelBytes + s * bytesPerSample, q = o - pixelBytes
                                        if bytesPerSample == 2 {
                                            let v = UInt16(tile[o]) | UInt16(tile[o + 1]) << 8, w = UInt16(tile[q]) | UInt16(tile[q + 1]) << 8
                                            let d = v &- w
                                            tile[o] = UInt8(d & 0xFF); tile[o + 1] = UInt8(d >> 8)
                                        } else { tile[o] = tile[o] &- tile[q] }
                                    }
                                }
                            }
                        }
                        switch codec {
                        case .deflate:
                            var out = [UInt8](repeating: 0, count: cdng_deflate_bound(tileBytes))
                            let size = cdng_deflate(tile, tileBytes, &out, out.count, scratch ? 1 : 6)
                            encodedOut[column] = Data(out.prefix(size))
                        case .losslessJPEG:
                            // The tile bytes are little-endian 16-bit samples, the host order.
                            var out = [UInt8](repeating: 0, count: tileBytes * 2 + 1024)
                            let size = tile.withUnsafeBytes { cdng_lossless_jpeg($0.bindMemory(to: UInt16.self).baseAddress, Int32(side), Int32(side), Int32(samples), &out, out.count) }
                            encodedOut[column] = Data(out.prefix(size))
                        }
                    }
                }
            }
            for data in encoded {
                guard !data.isEmpty else { throw PanoramaError.message(L10n.tr("DNG compression failed.")) }
                tiles.append((try file.append(data), UInt32(data.count)))
            }
            progress(Double(row + 1) / Double(down))
        }
        return tiles
    }

    static func rational(_ value: Double) -> (Int32, Int32) {
        guard value.isFinite else { return (0, 1) }
        let denominator: Int32 = 10_000
        return (Int32(max(-2.1e9, min(2.1e9, (value * Double(denominator)).rounded()))), denominator)
    }

    static func rgbBytes(_ image: CGImage) -> (width: Int, height: Int, bytes: [UInt8])? {
        let scale = min(1, 1024 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &rgba, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(gray: 1, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var rgb = [UInt8](); rgb.reserveCapacity(width * height * 3)
        for p in stride(from: 0, to: rgba.count, by: 4) { rgb += rgba[p..<p + 3] }
        return (width, height, rgb)
    }
}

enum TIFFValue {
    case bytes([UInt8]), ascii(String), shorts([UInt16]), longs([UInt32]), rationals([(UInt32, UInt32)]), srationals([(Int32, Int32)]), undefined([UInt8]), floats([Float])
    var type: UInt16 {
        switch self { case .bytes: 1; case .ascii: 2; case .shorts: 3; case .longs: 4; case .rationals: 5; case .srationals: 10; case .undefined: 7; case .floats: 11 }
    }
    var count: Int {
        switch self {
        case .bytes(let v), .undefined(let v): v.count
        case .ascii(let s): s.utf8.count + 1
        case .shorts(let v): v.count
        case .longs(let v): v.count
        case .rationals(let v): v.count
        case .srationals(let v): v.count
        case .floats(let v): v.count
        }
    }
    var data: Data {
        var d = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        switch self {
        case .bytes(let v), .undefined(let v): d.append(contentsOf: v)
        case .ascii(let s): d.append(contentsOf: Array(s.utf8) + [0])
        case .shorts(let v): v.forEach(put)
        case .longs(let v): v.forEach(put)
        case .rationals(let v): v.forEach { put($0.0); put($0.1) }
        case .srationals(let v): v.forEach { put($0.0); put($0.1) }
        case .floats(let v): v.forEach { put($0.bitPattern) }
        }
        return d
    }
}

/// Sequential classic-TIFF writer: data first, each IFD after the values it points to.
struct TIFFFile {
    let handle: FileHandle
    private(set) var offset: UInt64 = 0
    init(handle: FileHandle) { self.handle = handle }

    mutating func write(_ data: Data) throws {
        try handle.write(contentsOf: data); offset += UInt64(data.count)
        guard offset < UInt64(UInt32.max) else { throw PanoramaError.message(L10n.tr("The panorama is too large for a DNG file.")) }
    }
    /// Appends word-aligned data and returns where it starts.
    mutating func append(_ data: Data) throws -> UInt32 {
        if offset % 2 == 1 { try write(Data([0])) }
        let start = UInt32(offset)
        try write(data)
        return start
    }
    mutating func writeIFD(entries: [(UInt16, TIFFValue)]) throws -> UInt32 {
        let sorted = entries.sorted { $0.0 < $1.0 }
        var fields: [(UInt16, UInt16, UInt32, Data)] = []
        for (tag, value) in sorted {
            let data = value.data
            if data.count <= 4 { fields.append((tag, value.type, UInt32(value.count), data + Data(count: 4 - data.count))) }
            else {
                let at = try append(data)
                fields.append((tag, value.type, UInt32(value.count), withUnsafeBytes(of: at.littleEndian) { Data($0) }))
            }
        }
        var ifd = Data()
        withUnsafeBytes(of: UInt16(fields.count).littleEndian) { ifd.append(contentsOf: $0) }
        for (tag, type, count, value) in fields {
            withUnsafeBytes(of: tag.littleEndian) { ifd.append(contentsOf: $0) }
            withUnsafeBytes(of: type.littleEndian) { ifd.append(contentsOf: $0) }
            withUnsafeBytes(of: count.littleEndian) { ifd.append(contentsOf: $0) }
            ifd.append(value)
        }
        ifd.append(contentsOf: [0, 0, 0, 0])
        return try append(ifd)
    }
    func patchFirstIFD(_ ifd: UInt32) throws {
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: withUnsafeBytes(of: ifd.littleEndian) { Data($0) })
        try handle.seekToEnd()
    }
}
