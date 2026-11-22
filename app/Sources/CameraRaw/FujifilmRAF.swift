import Foundation

/// What a Fujifilm Pixel Shift Multi Shot RAF records about its place in the set. The pixels are left to Apple's
/// decoder, which handles the sensor's own pattern.
public struct FujifilmShot: Sendable, Equatable {
    public var make = ""
    public var model = ""
    public var serial = ""
    public var orientation = 1
    /// Exposure time, aperture and ISO: every shot of a set has the same.
    public var exposure: [Double] = []
    /// Maker note 0x1100: 6 is Pixel Shift.
    public var bracketing = 0
    /// This shot's place in the set, from 1.
    public var sequence = 0
    /// How many shots the set has.
    public var shots = 0
    /// Where the sensor was, in pixels: right and up, in steps of half a pixel.
    public var offset: (x: Double, y: Double)?
    public var isPixelShift: Bool { bracketing == 6 && shots > 1 && (1...shots).contains(sequence) && offset != nil }
    public init() {}
    public static func == (a: FujifilmShot, b: FujifilmShot) -> Bool {
        a.model == b.model && a.serial == b.serial && a.sequence == b.sequence && a.shots == b.shots
            && a.offset?.x == b.offset?.x && a.offset?.y == b.offset?.y
    }
}

public enum FujifilmRAF {
    /// Reads the RAF's header and the EXIF of its embedded JPEG, where the maker note is.
    public static func shot(_ url: URL) throws -> FujifilmShot {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw CameraRawError.unreadable }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 100), header.count == 100,
              header.prefix(16) == Data("FUJIFILMCCD-RAW ".utf8) else { throw CameraRawError.notRaw }
        func be32(_ at: Int) -> Int { header[at ..< at + 4].reduce(0) { $0 << 8 | Int($1) } }
        let jpegOffset = be32(84), jpegLength = be32(88)
        guard jpegOffset >= 100, jpegLength > 16, jpegLength < 64 << 20 else { throw CameraRawError.notRaw }
        try? handle.seek(toOffset: UInt64(jpegOffset))
        guard let jpeg = try? handle.read(upToCount: jpegLength), jpeg.count == jpegLength else { throw CameraRawError.unreadable }
        return try shot(jpeg: jpeg)
    }

    static func shot(jpeg: Data) throws -> FujifilmShot {
        // The EXIF APP1 segment: "Exif\0\0" then a TIFF.
        var at = 2
        let bytes = [UInt8](jpeg)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { throw CameraRawError.notRaw }
        var tiffStart: Int?
        while at + 4 <= bytes.count, bytes[at] == 0xFF {
            let marker = bytes[at + 1], size = Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
            if marker == 0xE1, at + 10 <= bytes.count, Array(bytes[(at + 4)..<(at + 10)]) == Array("Exif\0\0".utf8) { tiffStart = at + 10; break }
            if marker == 0xDA { break }
            at += 2 + size
        }
        guard let tiffStart else { throw CameraRawError.notRaw }
        let tiff = TIFFReader(data: Data(bytes[tiffStart...]))
        guard tiff.valid, let ifd0 = tiff.directory(at: tiff.firstIFD) else { throw CameraRawError.notRaw }
        var shot = FujifilmShot()
        shot.make = ifd0[0x10F]?.text ?? ""; shot.model = ifd0[0x110]?.text ?? ""
        shot.orientation = ifd0[0x112]?.ints.first ?? 1
        guard shot.make.uppercased().hasPrefix("FUJIFILM"), let exif = ifd0[0x8769]?.ints.first.flatMap({ tiff.directory(at: $0) }) else {
            throw CameraRawError.notRaw
        }
        shot.serial = exif[0xA431]?.text ?? ""
        shot.exposure = [exif[0x829A]?.doubles.first ?? 0, exif[0x829D]?.doubles.first ?? 0, Double(exif[0x8827]?.ints.first ?? 0)]
        // The maker note: "FUJIFILM", then where its directory is from the note's start; always little-endian.
        if let note = exif[0x927C], tiff.u8(note.offset).map({ _ in true }) == true,
           (0..<8).compactMap({ tiff.u8(note.offset + $0) }) == Array("FUJIFILM".utf8) {
            let reader = TIFFReader(data: tiff.data, little: true, base: note.offset)
            if let start = reader.u32(note.offset + 8), let maker = reader.directory(at: note.offset + Int(start)) {
                shot.bracketing = maker[0x1100]?.ints.first ?? 0
                shot.sequence = maker[0x1101]?.ints.first ?? 0
                shot.shots = maker[0x1105]?.ints.first ?? 0
                if let offset = maker[0x1106]?.doubles, offset.count == 2 { shot.offset = (offset[0], offset[1]) }
            }
        }
        return shot
    }
}
