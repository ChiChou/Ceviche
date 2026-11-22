import Foundation

/// Pentax's lossless coding: a difference from the previous sample of the same colour, its bit count Huffman-coded with
/// a table the maker note carries.
public struct PentaxHuffman: Sendable {
    let lookup: HuffmanLookup

    /// Maker note tag 0x220: a count, 12 bytes, then each code left-aligned in 12 bits and each code's length.
    init?(_ entry: TIFFReader.Entry, reader: TIFFReader) {
        guard let first = reader.u16(entry.offset) else { return nil }
        let depth = (Int(first) + 12) & 15
        guard depth > 0, entry.count >= 14 + depth * 3 else { return nil }
        var table = [UInt16](repeating: 0, count: 4096)
        for c in 0..<depth {
            guard let code = reader.u16(entry.offset + 14 + c * 2), let length = reader.u8(entry.offset + 14 + depth * 2 + c),
                  length > 0, length <= 12 else { return nil }
            let start = Int(code) & 4095
            for i in start..<min(4096, start + (4096 >> Int(length))) { table[i] = UInt16(Int(length) << 8 | c) }
        }
        lookup = HuffmanLookup(bits: 12, table: table)
    }

    func decode(_ data: Data, offset: Int, length: Int, width: Int, height: Int) throws -> [UInt16] {
        guard offset >= 0, length > 0, offset + length <= data.count, width > 1, height > 0 else { throw CameraRawError.unreadable }
        var samples = [UInt16](repeating: 0, count: width * height)
        try data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self).baseAddress!
            var reader = BitReader(bytes, start: offset, end: offset + length, jpegStuffing: false)
            // The first two samples of a row follow those two rows up (same colour); the rest follow two to the left.
            var vertical = (0, 0, 0, 0)
            try samples.withUnsafeMutableBufferPointer { out in
                for row in 0..<height {
                    let odd = row & 1 == 1
                    var even = 0, oddColumn = 0
                    for col in 0..<width {
                        let difference = try lookup.difference(&reader)
                        let value: Int
                        switch (col, odd) {
                        case (0, false): vertical.0 += difference; even = vertical.0; value = even
                        case (1, false): vertical.1 += difference; oddColumn = vertical.1; value = oddColumn
                        case (0, true): vertical.2 += difference; even = vertical.2; value = even
                        case (1, true): vertical.3 += difference; oddColumn = vertical.3; value = oddColumn
                        default:
                            if col & 1 == 0 { even += difference; value = even } else { oddColumn += difference; value = oddColumn }
                        }
                        guard value >= 0, value < 65536 else { throw CameraRawError.corrupt }
                        out[row * width + col] = UInt16(truncatingIfNeeded: value)
                    }
                }
            }
        }
        return samples
    }
}

/// Pentax Pixel Shift Resolution writes its four exposures into one PEF or DNG: in a PEF the main image and three
/// sub-images, in a DNG four images in a chain. Apple's decoder shows only the first.
public enum PentaxRAW {
    /// The models whose sets were checked against Pentax's own four-shot development.
    public static let pixelShiftModels: Set<String> = ["PENTAX K-1", "PENTAX K-1 Mark II", "PENTAX K-3 Mark III"]

    /// Every exposure in the file, in the order it stores them; one for a photo without Pixel Shift.
    public static func frames(_ url: URL) throws -> [SensorFrame] {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count > 16 else { throw CameraRawError.unreadable }
        return try frames(data)
    }
    public static func frames(_ data: Data) throws -> [SensorFrame] {
        let tiff = TIFFReader(data: data)
        guard tiff.valid, let ifd0 = tiff.directory(at: tiff.firstIFD) else { throw CameraRawError.notRaw }
        let make = ifd0[0x10F]?.text ?? ""
        guard make.uppercased().hasPrefix("PENTAX") || make.uppercased().hasPrefix("RICOH") else { throw CameraRawError.notRaw }
        let model = ifd0[0x110]?.text ?? ""
        let orientation = ifd0[0x112]?.ints.first ?? 1
        func subs(_ ifd: [Int: TIFFReader.Entry]) -> [[Int: TIFFReader.Entry]] {
            (ifd[0x14A]?.ints ?? []).compactMap { tiff.directory(at: $0) }
        }
        func isRaw(_ ifd: [Int: TIFFReader.Entry]) -> Bool { ifd[0x106]?.ints.first == 32803 }

        var frames: [SensorFrame] = []
        if ifd0[0xC612] != nil {
            // DNG: each image in the chain holds one exposure's CFA data in a sub-image.
            var at: Int? = tiff.firstIFD, seen = Set<Int>()
            while let offset = at, !seen.contains(offset), seen.count < 16, let ifd = tiff.directory(at: offset) {
                seen.insert(offset)
                if let raw = ([ifd] + subs(ifd)).first(where: isRaw) {
                    var frame = try dngFrame(raw, image: ifd, tiff: tiff)
                    frame.make = make; frame.model = model; frame.orientation = orientation
                    frames.append(frame)
                }
                at = tiff.next(after: offset)
            }
        } else {
            for ifd in [ifd0] + subs(ifd0) where isRaw(ifd) {
                var frame = try pefFrame(ifd, tiff: tiff, model: model)
                frame.make = make; frame.model = model; frame.orientation = orientation
                frames.append(frame)
            }
        }
        guard let first = frames.first else { throw CameraRawError.notRaw }
        guard frames.allSatisfy({ $0.width == first.width && $0.height == first.height }) else { throw CameraRawError.unsupportedSensor }
        return frames
    }

    private static func dngFrame(_ raw: [Int: TIFFReader.Entry], image: [Int: TIFFReader.Entry], tiff: TIFFReader) throws -> SensorFrame {
        guard let width = raw[0x100]?.ints.first, let height = raw[0x101]?.ints.first, width > 16, height > 16 else { throw CameraRawError.notRaw }
        guard raw[0x103]?.ints.first == 7, raw[0x142] == nil, let offset = raw[0x111]?.ints.first, (raw[0x111]?.count ?? 0) == 1,
              let length = raw[0x117]?.ints.first else { throw CameraRawError.compressed }
        var frame = SensorFrame()
        frame.width = width; frame.height = height
        frame.encoding = .losslessJPEG(offset: offset, length: length)
        guard let pattern = raw[0x828E]?.ints, SonyARW.valid(pattern) else { throw CameraRawError.unsupportedSensor }
        // The pattern is given from the active area's corner; an odd corner would change which colour (0,0) is.
        let active = raw[0xC68D]?.ints ?? [0, 0, height, width]
        guard active.count == 4, active[0] % 2 == 0, active[1] % 2 == 0 else { throw CameraRawError.unsupportedSensor }
        frame.cfa = pattern
        if let levels = raw[0xC61A]?.doubles, !levels.isEmpty {
            frame.black = levels.count >= 4 ? Array(levels.prefix(4).map(Float.init)) : [Float](repeating: Float(levels[0]), count: 4)
        }
        if let white = raw[0xC61D]?.ints.first, white > 0 { frame.white = Float(white) }
        if let neutral = image[0xC628]?.doubles, neutral.count == 3, neutral.allSatisfy({ $0 > 0 }) {
            frame.whiteBalance = [Float(neutral[1] / neutral[0]), 1, Float(neutral[1] / neutral[2])]
        }
        frame.crop = (active[1], active[0], active[3] - active[1], active[2] - active[0])
        if let origin = raw[0xC61F]?.doubles, let size = raw[0xC620]?.doubles, origin.count == 2, size.count == 2 {
            let x = active[1] + Int(origin[0]), y = active[0] + Int(origin[1]), w = Int(size[0]), h = Int(size[1])
            if x >= 0, y >= 0, w > 16, h > 16, x + w <= width, y + h <= height { frame.crop = (x & ~1, y & ~1, w & ~1, h & ~1) }
        }
        return frame
    }

    private static func pefFrame(_ raw: [Int: TIFFReader.Entry], tiff: TIFFReader, model: String) throws -> SensorFrame {
        guard let width = raw[0x100]?.ints.first, let height = raw[0x101]?.ints.first, width > 16, height > 16,
              let offset = raw[0x111]?.ints.first, let length = raw[0x117]?.ints.first else { throw CameraRawError.notRaw }
        guard raw[0x103]?.ints.first == 65535 else { throw CameraRawError.compressed }
        guard let exif = raw[0x8769]?.ints.first.flatMap({ tiff.directory(at: $0) }), let note = exif[0x927C],
              let maker = makerNote(note, tiff: tiff), let tableEntry = maker.ifd[0x220],
              let table = PentaxHuffman(tableEntry, reader: maker.reader) else { throw CameraRawError.compressed }
        var frame = SensorFrame()
        frame.width = width; frame.height = height
        frame.encoding = .pentax(offset: offset, length: length, table: table)
        // Pentax lists levels red, green, green, blue; these sensors start with red.
        frame.cfa = [0, 1, 1, 2]
        if let levels = maker.ifd[0x200]?.ints, levels.count == 4 { frame.black = byPosition(levels, cfa: frame.cfa) }
        if let levels = maker.ifd[0x201]?.ints, levels.count == 4, levels.allSatisfy({ $0 > 0 }) {
            frame.whiteBalance = [Float(levels[0]) / Float(levels[1]), 1, Float(levels[3]) / Float(levels[1])]
        }
        if let white = maker.ifd[0x7E]?.ints.first, white > 0 { frame.white = Float(white) }
        // A PEF has no crop tags.
        guard let area = activeArea[model], area.x + area.width <= width, area.y + area.height <= height else { throw CameraRawError.unsupportedSensor }
        frame.crop = area
        return frame
    }

    /// The picture Apple's decoder develops from each sensor, in sensor coordinates: measured against its development
    /// of each model (the K-1's DNG crops it the same way).
    static let activeArea: [String: (x: Int, y: Int, width: Int, height: Int)] = [
        "PENTAX K-1": (14, 28, 7360, 4912),
        "PENTAX K-1 Mark II": (14, 28, 7360, 4912),
        "PENTAX K-3 Mark III": (54, 58, 6192, 4128)
    ]

    /// Pentax maker notes start "PENTAX \0" and a byte order, with offsets from the note's start, or "AOC\0" and a byte
    /// order, with offsets from the file's.
    private static func makerNote(_ note: TIFFReader.Entry, tiff: TIFFReader) -> (ifd: [Int: TIFFReader.Entry], reader: TIFFReader)? {
        let start = note.offset
        let header = (0..<8).compactMap { tiff.u8(start + $0) }
        guard header.count == 8 else { return nil }
        if header == Array("PENTAX \0".utf8), let a = tiff.u8(start + 8), let b = tiff.u8(start + 9), a == b, a == 0x49 || a == 0x4D {
            let reader = TIFFReader(data: tiff.data, little: a == 0x49, base: start)
            return reader.directory(at: start + 10).map { ($0, reader) }
        }
        if Array(header.prefix(4)) == Array("AOC\0".utf8), header[4] == header[5], header[4] == 0x49 || header[4] == 0x4D {
            let reader = TIFFReader(data: tiff.data, little: header[4] == 0x49, base: 0)
            return reader.directory(at: start + 6).map { ($0, reader) }
        }
        return nil
    }
}
