import Foundation

/// A Hasselblad H6D-400c MS six-shot FFF: six exposures in one file, the sensor moved by whole and half pixels between
/// them. They are coded together, one difference per exposure from the previous exposure at the same pixel. Apple's
/// decoder shows only a smaller image from it.
public struct HasselbladMultiShot: Sendable {
    public var model = ""
    public var orientation = 1
    /// One exposure's sensor area.
    public var width = 0
    public var height = 0
    /// Where each exposure's pixel (0,0) lands on a grid of twice the sensor's resolution.
    public var places: [(x: Int, y: Int)] = []
    /// The picture on that grid.
    public var crop = (x: 0, y: 0, width: 0, height: 0)
    public var black: Float = 0
    public var white: Float = 65535
    /// As-shot neutral: the camera's response to a white, green 1.
    public var neutral: [Double] = [1, 1, 1]
    /// DNG ColorMatrix1: XYZ to camera, row by row.
    public var colourMatrix: [Double] = []
    private var start = 0, end = 0
    private var lookup: HuffmanLookup?

    /// The one capture this reader was checked against: its model, position table and crop.
    static let model = "Hasselblad H6D-100cMS"
    static let positions: Set<[Int]> = [[3, 0], [3, 2], [0, 0], [0, 2], [2, 1], [2, 3]]

    public static func isMultiShot(_ url: URL) -> Bool { (try? read(url)) != nil }

    public static func read(_ url: URL) throws -> HasselbladMultiShot {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count > 16 else { throw CameraRawError.unreadable }
        return try read(data)
    }
    public static func read(_ data: Data) throws -> HasselbladMultiShot {
        let tiff = TIFFReader(data: data)
        guard tiff.valid, let ifd0 = tiff.directory(at: tiff.firstIFD) else { throw CameraRawError.notRaw }
        var shot = HasselbladMultiShot()
        shot.model = ifd0[0x110]?.text ?? ""
        guard (ifd0[0x10F]?.text ?? "").uppercased().hasPrefix("HASSELBLAD") else { throw CameraRawError.notRaw }
        guard shot.model == model else { throw CameraRawError.unsupportedSensor }
        shot.orientation = ifd0[0x112]?.ints.first ?? 1
        // The six positions, in the maker note: a count and a marker, then x and y for each exposure in half pixels.
        guard let exif = ifd0[0x8769]?.ints.first.flatMap({ tiff.directory(at: $0) }), let note = exif[0x927C],
              let maker = tiff.directory(at: note.offset), let table = maker[0x21]?.ints, table.count == 14, table[0] == 6, table[1] == -1
        else { throw CameraRawError.unsupportedSensor }
        shot.places = stride(from: 2, to: 14, by: 2).map { (table[$0], table[$0 + 1]) }
        guard Set(shot.places.map { [$0.x, $0.y] }) == positions else { throw CameraRawError.unsupportedSensor }

        guard let raw = (ifd0[0x14A]?.ints ?? []).compactMap({ tiff.directory(at: $0) }).first(where: { $0[0x115]?.ints.first == 6 }),
              let width = raw[0x100]?.ints.first, let height = raw[0x101]?.ints.first,
              (raw[0x111]?.count ?? 0) == 1, let offset = raw[0x111]?.ints.first, let length = raw[0x117]?.ints.first,
              offset + length <= data.count else { throw CameraRawError.unsupportedSensor }
        shot.width = width; shot.height = height
        guard let origin = raw[0xC61F]?.ints, let size = raw[0xC620]?.ints, origin.count == 2, size.count == 2,
              origin[0] >= 0, origin[1] >= 0, origin[0] + size[0] <= 2 * width, origin[1] + size[1] <= 2 * height
        else { throw CameraRawError.unsupportedSensor }
        shot.crop = (origin[0], origin[1], size[0], size[1])
        shot.black = Float(raw[0xC61A]?.doubles.first ?? 0)
        shot.white = Float(raw[0xC61D]?.ints.first ?? 65535)
        if let neutral = ifd0[0xC628]?.doubles, neutral.count == 3, neutral.allSatisfy({ $0 > 0 }) { shot.neutral = neutral }
        // Hasselblad keeps the colour matrix in a small TIFF of its own (tag 0xC51B), offsets from its start.
        var matrix = ifd0[0xC621]?.doubles
        if matrix == nil, let embedded = ifd0[0xC51B], embedded.count > 16, tiff.u8(embedded.offset) == 0x49 || tiff.u8(embedded.offset) == 0x4D {
            let reader = TIFFReader(data: tiff.data, little: tiff.u8(embedded.offset) == 0x49, base: embedded.offset)
            if let first = reader.u32(embedded.offset + 4), let directory = reader.directory(at: embedded.offset + Int(first)) {
                matrix = directory[0xC621]?.doubles
            }
        }
        guard let matrix, matrix.count == 9 else { throw CameraRawError.unsupportedSensor }
        shot.colourMatrix = matrix
        guard shot.white > shot.black else { throw CameraRawError.unsupportedSensor }
        try shot.readHeader(data, offset: offset, length: length)
        return shot
    }

    /// The lossless JPEG header: one Huffman table, six components the size of one exposure, and Hasselblad's
    /// predictor 11.
    private mutating func readHeader(_ data: Data, offset: Int, length: Int) throws {
        let bytes = [UInt8](data[(data.startIndex + offset)..<(data.startIndex + offset + min(length, 4096))])
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { throw CameraRawError.corrupt }
        var at = 2, geometry: [Int] = []
        while at + 4 <= bytes.count, bytes[at] == 0xFF {
            let marker = bytes[at + 1], size = Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
            let body = Array(bytes[(at + 4)..<min(bytes.count, at + 2 + size)])
            switch marker {
            case 0xC3:
                guard body.count >= 6 else { throw CameraRawError.corrupt }
                geometry = [Int(body[0]), Int(body[1]) << 8 | Int(body[2]), Int(body[3]) << 8 | Int(body[4]), Int(body[5])]
            case 0xC4:
                guard body.count >= 17, body[0] == 0 else { throw CameraRawError.compressed }
                let counts = (1...16).map { Int(body[$0]) }, total = counts.reduce(0, +)
                guard body.count == 17 + total, body[17...].allSatisfy({ $0 <= 16 }),
                      let table = HuffmanLookup(counts: counts, values: body[17...].map(Int.init)) else { throw CameraRawError.compressed }
                lookup = table
            case 0xDA:
                guard geometry == [16, height, width, 6], lookup != nil, body == [1, 0, 0, 11, 0, 0] else { throw CameraRawError.compressed }
                start = offset + at + 2 + size; end = offset + length
                return
            default: break
            }
            at += 2 + size
        }
        throw CameraRawError.compressed
    }

    /// The six exposures one after another, each `width × height` with the colour filter red, green, green, blue from
    /// (0,0).
    public func planes(_ url: URL) throws -> [UInt16] {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { throw CameraRawError.unreadable }
        return try planes(data)
    }
    public func planes(_ data: Data) throws -> [UInt16] {
        guard let lookup, start > 0, end <= data.count else { throw CameraRawError.corrupt }
        let size = width * height
        var planes = [UInt16](repeating: 0, count: 6 * size)
        try data.withUnsafeBytes { raw in
            var reader = WordReader(raw.bindMemory(to: UInt8.self).baseAddress!, start: start, end: end)
            try planes.withUnsafeMutableBufferPointer { out in
                var deltas = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
                try withUnsafeMutableBytes(of: &deltas) { bytes in
                    let d = bytes.bindMemory(to: Int.self)
                    for y in 0..<height {
                        var left = (32768, 32768)
                        let row = y * width
                        for x in stride(from: 0, to: width, by: 2) {
                            // Two pixels at a time, six exposures each: two lengths, then their two differences.
                            for j in stride(from: 0, to: 12, by: 2) {
                                let a = try reader.length(lookup), b = try reader.length(lookup)
                                d[j] = try reader.difference(a); d[j + 1] = try reader.difference(b)
                            }
                            var prediction = left.0
                            for shot in 0..<6 { prediction += d[shot]; out[shot * size + row + x] = UInt16(truncatingIfNeeded: prediction) }
                            left.0 = Int(UInt16(truncatingIfNeeded: prediction))
                            prediction = left.1
                            for shot in 0..<6 { prediction += d[6 + shot]; out[shot * size + row + x + 1] = UInt16(truncatingIfNeeded: prediction) }
                            left.1 = Int(UInt16(truncatingIfNeeded: prediction))
                        }
                    }
                }
            }
        }
        return planes
    }
}

/// Hasselblad's bit order: 32-bit little-endian words, each read from its most significant bit.
private struct WordReader {
    private let bytes: UnsafePointer<UInt8>
    private var position: Int
    private let end: Int
    private var buffer: UInt64 = 0
    private var count = 0

    init(_ bytes: UnsafePointer<UInt8>, start: Int, end: Int) { self.bytes = bytes; position = start; self.end = end }

    @inline(__always) private mutating func peek(_ n: Int) throws -> Int {
        if count < n {
            guard position + 4 <= end else { throw CameraRawError.corrupt }
            let word = UInt64(bytes[position]) | UInt64(bytes[position + 1]) << 8 | UInt64(bytes[position + 2]) << 16 | UInt64(bytes[position + 3]) << 24
            position += 4
            buffer = buffer << 32 | word; count += 32
        }
        return Int((buffer >> UInt64(count - n)) & ((1 << UInt64(n)) - 1))
    }
    @inline(__always) mutating func length(_ lookup: HuffmanLookup) throws -> Int {
        let entry = lookup.table[try peek(lookup.bits)]
        let length = Int(entry >> 8)
        guard length > 0 else { throw CameraRawError.corrupt }
        count -= length
        return Int(entry & 0xFF)
    }
    /// A difference of `n` bits, signed as JPEG signs them; 16 bits stand for −32768.
    @inline(__always) mutating func difference(_ n: Int) throws -> Int {
        guard n > 0 else { return 0 }
        let value = try peek(n)
        count -= n
        if n == 16 { return -32768 }
        return value < 1 << (n - 1) ? value - ((1 << n) - 1) : value
    }
}
