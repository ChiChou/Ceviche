import Foundation

/// Lossless JPEG (process 14) as DNG stores CFA data: one or more components interleaved along a row, so a row of the
/// image is the JPEG's width times its components. Only what DNG writers use: one scan, no restart intervals.
enum LosslessJPEG {
    static func decode(_ data: Data, offset: Int, length: Int, width: Int, height: Int) throws -> [UInt16] {
        guard offset >= 0, length > 4, offset + length <= data.count else { throw CameraRawError.unreadable }
        return try data.withUnsafeBytes { raw -> [UInt16] in
            let bytes = raw.bindMemory(to: UInt8.self).baseAddress!
            let end = offset + length
            func u16(_ at: Int) -> Int { Int(bytes[at]) << 8 | Int(bytes[at + 1]) }
            guard bytes[offset] == 0xFF, bytes[offset + 1] == 0xD8 else { throw CameraRawError.corrupt }
            var at = offset + 2
            var tables: [Int: HuffmanLookup] = [:]
            var precision = 0, rows = 0, columns = 0, components: [Int] = []
            var scanTables: [HuffmanLookup] = [], predictor = 1, transform = 0, start = 0
            scan: while at + 4 <= end {
                guard bytes[at] == 0xFF else { throw CameraRawError.corrupt }
                let marker = Int(bytes[at + 1]), size = u16(at + 2)
                let body = at + 4, next = at + 2 + size
                guard size >= 2, next <= end else { throw CameraRawError.corrupt }
                switch marker {
                case 0xC4:
                    var p = body
                    while p < next {
                        let id = Int(bytes[p] & 0x0F)
                        let counts = (0..<16).map { Int(bytes[p + 1 + $0]) }
                        let total = counts.reduce(0, +)
                        guard p + 17 + total <= next, let table = HuffmanLookup(counts: counts, values: (0..<total).map { Int(bytes[p + 17 + $0]) })
                        else { throw CameraRawError.corrupt }
                        tables[id] = table
                        p += 17 + total
                    }
                case 0xC3:
                    precision = Int(bytes[body]); rows = u16(body + 1); columns = u16(body + 3)
                    components = (0..<Int(bytes[body + 5])).map { Int(bytes[body + 6 + $0 * 3]) }
                case 0xDD: throw CameraRawError.compressed
                case 0xDA:
                    let count = Int(bytes[body])
                    guard count == components.count else { throw CameraRawError.corrupt }
                    scanTables = try (0..<count).map { k in
                        guard let table = tables[Int(bytes[body + 2 + k * 2] >> 4)] else { throw CameraRawError.corrupt }
                        return table
                    }
                    predictor = Int(bytes[body + 1 + count * 2]); transform = Int(bytes[body + 3 + count * 2] & 0x0F)
                    start = next
                    break scan
                case 0xC0, 0xC1, 0xC2, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF: throw CameraRawError.compressed
                default: break
                }
                at = next
            }
            let n = components.count
            guard start > 0, n > 0, precision > 0, precision <= 16, (1...7).contains(predictor), columns * n == width, rows == height
            else { throw CameraRawError.compressed }
            var samples = [UInt16](repeating: 0, count: width * height)
            var reader = BitReader(bytes, start: start, end: end, jpegStuffing: true)
            let initial = 1 << (precision - transform - 1), mask = (1 << precision) - 1
            try samples.withUnsafeMutableBufferPointer { out in
                for row in 0..<rows {
                    let line = row * width
                    for col in 0..<columns {
                        for c in 0..<n {
                            let i = line + col * n + c
                            let left = col > 0 ? Int(out[i - n]) : 0, up = row > 0 ? Int(out[i - width]) : 0
                            let corner = row > 0 && col > 0 ? Int(out[i - width - n]) : 0
                            let guess: Int
                            if row == 0 { guess = col == 0 ? initial : left }
                            else if col == 0 { guess = up }
                            else {
                                switch predictor {
                                case 1: guess = left
                                case 2: guess = up
                                case 3: guess = corner
                                case 4: guess = left + up - corner
                                case 5: guess = left + ((up - corner) >> 1)
                                case 6: guess = up + ((left - corner) >> 1)
                                default: guess = (left + up) >> 1
                                }
                            }
                            out[i] = UInt16((guess + (try scanTables[c].difference(&reader))) & mask)
                        }
                    }
                }
            }
            return samples
        }
    }
}
