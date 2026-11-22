import Foundation

/// The ARW files Pixel Shift Multi Shooting writes: uncompressed 14-bit samples in 16 bits. Compressed ARWs are
/// refused; the cameras that shoot Pixel Shift write these sets uncompressed.
public enum SonyARW {
    public static func frame(_ url: URL) throws -> SensorFrame {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count > 16 else { throw CameraRawError.unreadable }
        return try frame(data)
    }
    public static func frame(_ data: Data) throws -> SensorFrame {
        let tiff = TIFFReader(data: data)
        guard tiff.valid, let ifd0 = tiff.directory(at: tiff.firstIFD) else { throw CameraRawError.notRaw }
        var info = SensorFrame()
        info.make = ifd0[0x10F]?.text ?? ""; info.model = ifd0[0x110]?.text ?? ""
        info.orientation = ifd0[0x112]?.ints.first ?? 1
        guard info.make.uppercased().hasPrefix("SONY") else { throw CameraRawError.notRaw }
        // The sensor data is the sub-IFD whose photometric interpretation is a colour filter array.
        let raw = (ifd0[0x14A]?.ints ?? []).compactMap { tiff.directory(at: $0) }.first { $0[0x106]?.ints.first == 32803 }
        guard let raw, let width = raw[0x100]?.ints.first, let height = raw[0x101]?.ints.first, let offset = raw[0x111]?.ints.first,
              width > 16, height > 16 else { throw CameraRawError.notRaw }
        let bytes = raw[0x117]?.ints.first ?? 0
        guard raw[0x103]?.ints.first == 1, raw[0x102]?.ints.first ?? 14 <= 16, bytes >= width * height * 2, offset + width * height * 2 <= data.count else {
            throw CameraRawError.compressed
        }
        info.width = width; info.height = height; info.encoding = .uncompressed(offset: offset, little: tiff.little)
        guard let pattern = raw[0x828E]?.ints, valid(pattern) else { throw CameraRawError.unsupportedSensor }
        info.cfa = pattern
        info.black = [512, 512, 512, 512]
        if let levels = raw[0x7310]?.ints ?? raw[0xC61A]?.ints, !levels.isEmpty {
            info.black = levels.count >= 4 ? byPosition(levels, cfa: info.cfa) : [Float](repeating: Float(levels[0]), count: 4)
        }
        if let white = (raw[0xC61D]?.ints ?? raw[0x787F]?.ints)?.first, white > 0 { info.white = Float(white) }
        if let levels = raw[0x7313]?.ints, levels.count == 4, levels[1] > 0, levels[0] > 0, levels[3] > 0 {
            info.whiteBalance = [Float(levels[0]) / Float(levels[1]), 1, Float(levels[3]) / Float(levels[1])]
        }
        info.crop = (0, 0, width, height)
        if let origin = raw[0xC61F]?.ints, let size = raw[0xC620]?.ints, origin.count == 2, size.count == 2,
           origin[0] >= 0, origin[1] >= 0, size[0] > 16, size[1] > 16, origin[0] + size[0] <= width, origin[1] + size[1] <= height {
            // Whole CFA cells, so the crop never changes which colour a position has.
            info.crop = (origin[0] & ~1, origin[1] & ~1, size[0] & ~1, size[1] & ~1)
        }
        // Maker note 0x202F: group id, then the shot's number and the group's size.
        if let exif = ifd0[0x8769]?.ints.first.flatMap({ tiff.directory(at: $0) }), let note = exif[0x927C],
           let maker = tiff.directory(at: note.offset), let shift = maker[0x202F]?.bytes, shift.count >= 6 {
            let group = UInt32(shift[0]) | UInt32(shift[1]) << 8 | UInt32(shift[2]) << 16 | UInt32(shift[3]) << 24
            let index = Int(shift[4]), shots = Int(shift[5])
            if group != 0, shots == 4 || shots == 16, (1...shots).contains(index) { info.sonyShift = (group, index, shots) }
        }
        return info
    }

    /// A Bayer pattern: one red, two greens, one blue.
    static func valid(_ pattern: [Int]) -> Bool {
        pattern.count == 4 && pattern.allSatisfy { (0...2).contains($0) } && pattern.filter { $0 == 1 }.count == 2
            && pattern.contains(0) && pattern.contains(2)
    }
}
