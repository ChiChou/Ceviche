import Foundation

/// Bits most significant first from a byte buffer, for the Huffman-coded RAW formats. With `jpegStuffing`, a 0xFF byte
/// is followed by a 0x00 that isn't data, and a marker ends the data.
struct BitReader {
    private let bytes: UnsafePointer<UInt8>
    private let end: Int
    private var position: Int
    private var buffer: UInt64 = 0
    private var count = 0
    private let jpegStuffing: Bool
    private var ended = false

    init(_ bytes: UnsafePointer<UInt8>, start: Int, end: Int, jpegStuffing: Bool) {
        self.bytes = bytes; self.position = start; self.end = end; self.jpegStuffing = jpegStuffing
    }

    /// At least 32 bits ready; zeros past the end, which only a corrupt stream reads.
    @inline(__always) private mutating func fill() {
        while count <= 56 {
            var byte: UInt8 = 0
            if !ended && position < end {
                byte = bytes[position]; position += 1
                if jpegStuffing && byte == 0xFF {
                    let next: UInt8 = position < end ? bytes[position] : 0
                    if next == 0 { position += 1 } else { ended = true; byte = 0 }
                }
            }
            buffer |= UInt64(byte) << UInt64(56 - count)
            count += 8
        }
    }
    @inline(__always) mutating func peek(_ n: Int) -> Int {
        if count < n { fill() }
        return Int(buffer >> UInt64(64 - n))
    }
    @inline(__always) mutating func skip(_ n: Int) {
        buffer <<= UInt64(n); count -= n
    }
    @inline(__always) mutating func read(_ n: Int) -> Int {
        guard n > 0 else { return 0 }
        let value = peek(n); skip(n); return value
    }
}

/// A Huffman table as a lookup on the next `bits` bits: each entry is the code's length and the value it codes, a
/// difference's bit count. Lossless JPEG and Pentax both code differences this way.
struct HuffmanLookup: Sendable {
    let bits: Int
    /// Code length in the high byte, value in the low byte; 0 for a code that isn't in the table.
    let table: [UInt16]
    /// From the counts of codes of each length 1...16 and their values in order (JPEG's DHT layout).
    init?(counts: [Int], values: [Int]) {
        guard counts.count == 16, values.count == counts.reduce(0, +) else { return nil }
        let longest = counts.lastIndex { $0 > 0 }.map { $0 + 1 } ?? 0
        guard longest > 0 else { return nil }
        bits = longest
        var table = [UInt16](repeating: 0, count: 1 << longest)
        var code = 0, k = 0
        for length in 1...16 {
            for _ in 0..<counts[length - 1] {
                guard length <= longest else { return nil }
                let shift = longest - length, first = code << shift
                guard first + (1 << shift) <= table.count else { return nil }
                for i in first..<(first + (1 << shift)) { table[i] = UInt16(length << 8 | values[k]) }
                code += 1; k += 1
            }
            code <<= 1
        }
        self.table = table
    }
    init(bits: Int, table: [UInt16]) { self.bits = bits; self.table = table }

    /// The next difference: its bit count from the table, then that many bits, signed as JPEG signs them.
    @inline(__always) func difference(_ reader: inout BitReader) throws -> Int {
        let entry = table[reader.peek(bits)]
        let length = Int(entry >> 8), size = Int(entry & 0xFF)
        guard length > 0 else { throw CameraRawError.corrupt }
        reader.skip(length)
        if size == 0 { return 0 }
        if size == 16 { return -32768 }
        let value = reader.read(size)
        return value & (1 << (size - 1)) == 0 ? value - (1 << size) + 1 : value
    }
}
