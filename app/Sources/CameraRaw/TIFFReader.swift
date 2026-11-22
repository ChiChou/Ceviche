import Foundation

/// Just enough TIFF to find tags: little- or big-endian classic TIFF, directories read on demand. RAW files are TIFF
/// underneath, and so are the maker notes inside them, which keep their own byte order and offset base.
public struct TIFFReader: Sendable {
    public struct Entry: Sendable {
        public var type: Int
        public var count: Int
        /// Where the value is in the file.
        public var offset: Int
        fileprivate var reader: TIFFReader
        /// Byte, short and long values (signed or not), at most the first 64.
        public var ints: [Int] {
            let size = [1: 1, 3: 2, 4: 4, 6: 1, 7: 1, 8: 2, 9: 4, 13: 4][type] ?? 0
            guard size > 0 else { return [] }
            return (0..<min(count, 64)).compactMap { i -> Int? in
                let at = offset + i * size
                switch type {
                case 1, 7: return reader.u8(at).map(Int.init)
                case 6: return reader.u8(at).map { Int(Int8(bitPattern: $0)) }
                case 3: return reader.u16(at).map(Int.init)
                case 8: return reader.u16(at).map { Int(Int16(bitPattern: $0)) }
                case 9: return reader.u32(at).map { Int(Int32(bitPattern: $0)) }
                default: return reader.u32(at).map(Int.init)
                }
            }
        }
        /// Rational values (signed or not) and the integer types, at most the first 64.
        public var doubles: [Double] {
            guard type == 5 || type == 10 else { return ints.map(Double.init) }
            return (0..<min(count, 64)).compactMap { i -> Double? in
                guard let n = reader.u32(offset + i * 8), let d = reader.u32(offset + i * 8 + 4) else { return nil }
                let numerator = type == 10 ? Double(Int32(bitPattern: n)) : Double(n)
                let denominator = type == 10 ? Double(Int32(bitPattern: d)) : Double(d)
                return denominator == 0 ? nil : numerator / denominator
            }
        }
        public var bytes: [UInt8] { (0..<min(count, 4096)).compactMap { reader.u8(offset + $0) } }
        public var text: String {
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }
    }

    public let data: Data
    public let little: Bool
    public let valid: Bool
    /// Added to every offset a directory gives: maker notes count from their own start.
    public var base = 0
    public init(data: Data) {
        self.data = data
        let order = data.count >= 8 ? (data[data.startIndex], data[data.startIndex + 1]) : (0, 0)
        little = order == (0x49, 0x49)
        valid = order == (0x49, 0x49) || order == (0x4D, 0x4D)
    }
    /// The same file read with another byte order and offset base, for a maker note.
    public init(data: Data, little: Bool, base: Int) {
        self.data = data; self.little = little; self.base = base; valid = true
    }
    public var firstIFD: Int { u32(4).map(Int.init) ?? 0 }

    public func u8(_ at: Int) -> UInt8? { at >= 0 && at < data.count ? data[data.startIndex + at] : nil }
    public func u16(_ at: Int) -> UInt16? {
        guard at >= 0, at + 2 <= data.count else { return nil }
        let a = UInt16(data[data.startIndex + at]), b = UInt16(data[data.startIndex + at + 1])
        return little ? a | b << 8 : a << 8 | b
    }
    public func u32(_ at: Int) -> UInt32? {
        guard let a = u16(at), let b = u16(at + 2) else { return nil }
        return little ? UInt32(a) | UInt32(b) << 16 : UInt32(a) << 16 | UInt32(b)
    }

    public func directory(at offset: Int) -> [Int: Entry]? {
        guard offset > 0, let count = u16(offset), count > 0, count < 1000 else { return nil }
        var entries: [Int: Entry] = [:]
        for i in 0..<Int(count) {
            let at = offset + 2 + i * 12
            guard let tag = u16(at), let type = u16(at + 2), let n = u32(at + 4) else { return nil }
            let size = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8, 13: 4][Int(type)] ?? 1
            let inline = size * Int(n) <= 4
            guard let value = inline ? at + 8 : u32(at + 8).map({ Int($0) + base }) else { return nil }
            entries[Int(tag)] = Entry(type: Int(type), count: Int(n), offset: value, reader: self)
        }
        return entries
    }
    /// The directory after the one at `offset`, in a chain of them.
    public func next(after offset: Int) -> Int? {
        guard let count = u16(offset), let next = u32(offset + 2 + Int(count) * 12), next > 0 else { return nil }
        return Int(next) + base
    }
}
