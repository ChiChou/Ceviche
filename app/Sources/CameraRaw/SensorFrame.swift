import Foundation

/// Why a file couldn't give its sensor data. The caller words it for the photographer, with the file's name.
public enum CameraRawError: Error, Equatable, Sendable {
    /// The file can't be opened or is cut short.
    case unreadable
    /// Not a RAW photo this reader knows, or not from the expected maker.
    case notRaw
    /// A compression this reader doesn't decode.
    case compressed
    /// A colour filter or layout this reader doesn't handle.
    case unsupportedSensor
    /// The sensor data doesn't decode as its header says.
    case corrupt
}

/// How one exposure's samples are stored in its file.
public enum SensorEncoding: Sendable {
    /// Uncompressed, 16 bits a sample in the file's byte order.
    case uncompressed(offset: Int, little: Bool)
    /// Pentax's lossless Huffman coding, with the table from the maker note.
    case pentax(offset: Int, length: Int, table: PentaxHuffman)
    /// Lossless JPEG (ITU T.81 process 14), as DNG stores it.
    case losslessJPEG(offset: Int, length: Int)
}

/// One exposure as the sensor recorded it, before any development: what Pixel Shift merges.
public struct SensorFrame: Sendable {
    public var make = ""
    public var model = ""
    /// The stored sensor area, which is larger than the picture (`crop`).
    public var width = 0
    public var height = 0
    /// The colour at (0,0), (1,0), (0,1), (1,1): 0 red, 1 green, 2 blue. Indexed by `(y & 1) * 2 + (x & 1)`.
    public var cfa = [0, 1, 1, 2]
    /// Black level of the same four positions.
    public var black: [Float] = [0, 0, 0, 0]
    public var white: Float = 16383
    /// As-shot white balance: what red, green and blue are multiplied by, green 1.
    public var whiteBalance: [Float] = [1, 1, 1]
    /// The picture inside the sensor area, as Apple's decoder crops it: whole CFA cells.
    public var crop = (x: 0, y: 0, width: 0, height: 0)
    /// EXIF orientation of the picture.
    public var orientation = 1
    public var encoding = SensorEncoding.uncompressed(offset: 0, little: true)
    /// Sony's Pixel Shift Multi Shooting group: its id, this shot's place in it from 1, and how many shots it has.
    public var sonyShift: (group: UInt32, index: Int, shots: Int)?
    public init() {}

    /// The sensor's samples, `width × height`, top row first.
    public func samples(_ url: URL) throws -> [UInt16] {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { throw CameraRawError.unreadable }
        return try samples(data)
    }
    public func samples(_ data: Data) throws -> [UInt16] {
        switch encoding {
        case .uncompressed(let offset, let little):
            guard offset >= 0, offset + width * height * 2 <= data.count else { throw CameraRawError.unreadable }
            var samples = [UInt16](repeating: 0, count: width * height)
            samples.withUnsafeMutableBytes { target in
                data.withUnsafeBytes { target.baseAddress!.copyMemory(from: $0.baseAddress! + offset, byteCount: target.count) }
            }
            if little != (1.littleEndian == 1) { for i in samples.indices { samples[i] = samples[i].byteSwapped } }
            return samples
        case .pentax(let offset, let length, let table):
            return try table.decode(data, offset: offset, length: length, width: width, height: height)
        case .losslessJPEG(let offset, let length):
            return try LosslessJPEG.decode(data, offset: offset, length: length, width: width, height: height)
        }
    }
}

/// The four CFA positions' values for levels a camera lists red, green, green, blue.
func byPosition(_ levels: [Int], cfa: [Int]) -> [Float] {
    cfa.enumerated().map { position, colour in
        Float(levels[colour == 0 ? 0 : colour == 2 ? 3 : (position < 2 ? 1 : 2)])
    }
}
