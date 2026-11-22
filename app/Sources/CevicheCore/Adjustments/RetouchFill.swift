import Foundation
import CoreImage
import CryptoKit

/// A Remove stroke's AI fill (Big-LaMa), made once when the stroke is drawn (`RawRenderer.prepareInpaint`) and kept with
/// the development. It is stored relative to its surroundings: the network's fill divided by
/// `RetouchRenderer.surroundings` of the photo it was made from. Rendering multiplies it by the surroundings of the photo
/// as developed now, so a later exposure or white balance change relights it exactly, other changes before retouching
/// approximately, and the preview and an export of any size show the same fill.
///
/// The ratio is kept like a mask raster, in the photo's blobs, History and documents, but never in XMP or in edits copied
/// to another photo (`removingFill`). A stroke without one, or whose footprint has changed since, renders as patch Remove.
public struct RetouchFill: Codable, Equatable, Sendable {
    /// The stored rectangle, normalized to the retouch frame with a bottom-left origin, as stroke points are.
    public var x: Double, y: Double, width: Double, height: Double
    /// The blur `RetouchRenderer.surroundings` used, as a fraction of the frame's shorter side.
    public var reach: Double
    /// `footprint(of:)` of the stroke the fill was made for.
    public var footprint: String
    /// The ratio in `RetouchFillRaster`'s format.
    public var raster: Data

    public init(x: Double, y: Double, width: Double, height: Double, reach: Double, footprint: String, raster: Data) {
        self.x = x; self.y = y; self.width = width; self.height = height; self.reach = reach; self.footprint = footprint; self.raster = raster
    }
    /// Identifies what a stroke covers: its points, radius and softness.
    public static func footprint(of stroke: RetouchStroke) -> String {
        var text = "\(stroke.radius) \(stroke.softness)"
        for point in stroke.points { text += " \(point.x),\(point.y)" }
        return SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
    func validate() throws {
        guard [x, y, width, height, reach].allSatisfy(\.isFinite), width > 0, height > 0, x >= -1, y >= -1, x + width <= 2, y + height <= 2,
              reach > 0, reach <= 1, (1...64).contains(footprint.count), RetouchFillRaster.isValid(raster) else {
            throw EditorError.invalidDocument(L10n.tr("Invalid retouch stroke."))
        }
    }
}

extension RetouchStroke {
    /// The stroke without its AI fill, for edits that leave the photo it was made on.
    public var removingFill: RetouchStroke { var copy = self; copy.fill = nil; return copy }
    /// A Remove stroke that asks for an AI fill and has none for its current footprint.
    public var needsFill: Bool {
        mode == .remove && generative && enabled && fill?.footprint != RetouchFill.footprint(of: self)
    }
}

extension Adjustments {
    /// Every retouch stroke without its AI fill: the fills are made from this photo's pixels.
    public var removingRetouchFills: Adjustments {
        guard retouch.contains(where: { $0.fill != nil }) else { return self }
        var copy = self; copy.retouch = retouch.map(\.removingFill); return copy
    }
}

/// A fill's ratio as half floats, in one of two layouts (little endian). Values are stored with the low bytes of all of
/// them before the high bytes, which compresses about a third better than the values in order.
/// - "RFL1", width u32, height u32, then the LZMA-compressed red, green and blue planes, rows top down: one rectangle.
/// - "RFL2", width u32, height u32, tile count u32, each tile's x, y, width and height u32 (in the grid, rows top down),
///   then the LZMA-compressed planes of every tile in turn. Where no tile lies the ratio is neutral, so a long stroke
///   stores only the cells it crosses.
enum RetouchFillRaster {
    static let magic = Data("RFL1".utf8), tiledMagic = Data("RFL2".utf8)
    /// Pixels in one rectangle, or in all of a grid's tiles together.
    static let maxPixels = 4_000_000, maxTiledPixels = 16_000_000
    static let maxTiles = 4096, maxSide = 100_000

    /// A rectangle of the grid, rows top down, with its red, green and blue planes.
    struct Tile: Equatable {
        var x: Int, y: Int, width: Int, height: Int
        var planes: [Float]
    }

    static func isValid(_ data: Data) -> Bool { layout(data) != nil }
    /// The grid's size and the tiles' rectangles, checked against the limits and the grid; nil when malformed.
    private static func layout(_ data: Data) -> (width: Int, height: Int, tiles: [(x: Int, y: Int, width: Int, height: Int)], body: Int)? {
        guard data.count > 12, data.count <= 64_000_000 else { return nil }
        let bytes = [UInt8](data.prefix(16 + 16 * maxTiles))
        func u32(_ i: Int) -> Int? { i + 4 <= bytes.count ? Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24 : nil }
        guard let width = u32(4), let height = u32(8), (1...maxSide).contains(width), (1...maxSide).contains(height) else { return nil }
        switch data.prefix(4) {
        case magic:
            guard width * height <= maxPixels else { return nil }
            return (width, height, [(0, 0, width, height)], 12)
        case tiledMagic:
            guard let count = u32(12), (1...maxTiles).contains(count) else { return nil }
            var tiles: [(x: Int, y: Int, width: Int, height: Int)] = [], total = 0
            for t in 0..<count {
                guard let x = u32(16 + 16 * t), let y = u32(20 + 16 * t), let w = u32(24 + 16 * t), let h = u32(28 + 16 * t),
                      w > 0, h > 0, x + w <= width, y + h <= height else { return nil }
                tiles.append((x, y, w, h)); total += w * h
            }
            guard total <= maxTiledPixels else { return nil }
            return (width, height, tiles, 16 + 16 * count)
        default: return nil
        }
    }
    private static func pack(_ values: [Float]) -> Data {
        let count = values.count
        var body = Data(count: count * 2)
        body.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for i in 0..<count {
                let bits = Float16(values[i]).bitPattern
                bytes[i] = UInt8(bits & 0xFF); bytes[count + i] = UInt8(bits >> 8)
            }
        }
        return body
    }
    private static func u32(_ value: Int) -> Data { withUnsafeBytes(of: UInt32(value).littleEndian) { Data($0) } }
    /// One rectangle; `planes` holds the red, then green, then blue plane, rows top down.
    static func encode(_ planes: [Float], width: Int, height: Int) throws -> Data {
        guard width > 0, height > 0, width * height <= maxPixels, planes.count == width * height * 3 else { throw EditorError.render }
        return magic + u32(width) + u32(height) + (try (pack(planes) as NSData).compressed(using: .lzma) as Data)
    }
    /// Tiles of a `width` × `height` grid.
    static func encode(tiles: [Tile], width: Int, height: Int) throws -> Data {
        guard (1...maxSide).contains(width), (1...maxSide).contains(height), (1...maxTiles).contains(tiles.count),
              tiles.allSatisfy({ $0.width > 0 && $0.height > 0 && $0.x >= 0 && $0.y >= 0 && $0.x + $0.width <= width && $0.y + $0.height <= height && $0.planes.count == $0.width * $0.height * 3 }),
              tiles.reduce(0, { $0 + $1.width * $1.height }) <= maxTiledPixels else { throw EditorError.render }
        var data = tiledMagic + u32(width) + u32(height) + u32(tiles.count)
        for tile in tiles { data += u32(tile.x) + u32(tile.y) + u32(tile.width) + u32(tile.height) }
        return data + (try (pack(tiles.flatMap(\.planes)) as NSData).compressed(using: .lzma) as Data)
    }
    /// The grid's size and its tiles; a one-rectangle raster is one tile covering it.
    static func tiles(_ data: Data) throws -> (width: Int, height: Int, tiles: [Tile]) {
        func fail() -> Error { EditorError.invalidDocument(L10n.tr("Invalid retouch stroke.")) }
        guard let layout = layout(data) else { throw fail() }
        let count = layout.tiles.reduce(0) { $0 + $1.width * $1.height * 3 }
        let body = try (data.dropFirst(layout.body) as NSData).decompressed(using: .lzma) as Data
        guard body.count == count * 2 else { throw fail() }
        var values = [Float](repeating: 0, count: count)
        body.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for i in 0..<count { values[i] = Float(Float16(bitPattern: UInt16(bytes[i]) | UInt16(bytes[count + i]) << 8)) }
        }
        var offset = 0
        let tiles = layout.tiles.map { rect in
            let size = rect.width * rect.height * 3
            defer { offset += size }
            return Tile(x: rect.x, y: rect.y, width: rect.width, height: rect.height, planes: Array(values[offset..<(offset + size)]))
        }
        return (layout.width, layout.height, tiles)
    }
    /// A one-rectangle raster's planes.
    static func decode(_ data: Data) throws -> (planes: [Float], width: Int, height: Int) {
        let grid = try tiles(data)
        guard grid.tiles.count == 1, grid.tiles[0].width == grid.width, grid.tiles[0].height == grid.height else { throw EditorError.invalidDocument(L10n.tr("Invalid retouch stroke.")) }
        return (grid.tiles[0].planes, grid.width, grid.height)
    }
    /// The ratio as an unmanaged RGBA image of the grid's size, origin at zero; clear (neutral) where no tile lies.
    static func image(_ data: Data) throws -> CIImage {
        let grid = try tiles(data)
        var image = CIImage(color: .clear).cropped(to: CGRect(x: 0, y: 0, width: grid.width, height: grid.height))
        for tile in grid.tiles {
            let plane = tile.width * tile.height
            var pixels = [Float16](repeating: 1, count: plane * 4)
            for i in 0..<plane { pixels[i * 4] = Float16(tile.planes[i]); pixels[i * 4 + 1] = Float16(tile.planes[plane + i]); pixels[i * 4 + 2] = Float16(tile.planes[2 * plane + i]) }
            let bitmap = pixels.withUnsafeBytes { Data($0) }
            let placed = CIImage(bitmapData: bitmap, bytesPerRow: tile.width * 8, size: CGSize(width: tile.width, height: tile.height), format: .RGBAh, colorSpace: nil)
                .transformed(by: CGAffineTransform(translationX: CGFloat(tile.x), y: CGFloat(grid.height - tile.y - tile.height)))
            image = placed.composited(over: image)
        }
        return image
    }
}

/// Where a Remove stroke's fill is made. Big-LaMa learned on 256-pixel crops: a hole up to about 160 network pixels across
/// comes out coherent, while a wider one repeats the structure around it as faint ghosts, at 1024 as much as at 512.
/// What counts is how far the hole's middle is from known pixels, not its length: so the frame is scaled until the
/// stroke is at most `maxHole` network pixels thick, which leaves anything up to that at the photo's own resolution,
/// a wire across the whole frame included. The scaled frame is cut into square cells along the stroke, each filled in a
/// window of `side` pixels around it. A cell's window sees the cells filled before it as known, so the fill runs on
/// from them, and treats the rest of the stroke as missing, so nothing the stroke covers is continued into the hole.
struct InpaintPlan: Equatable {
    static let maxHole = 160.0, side = 512, cell = 384
    /// Network pixels per frame pixel.
    var scale: Double
    /// The scaled frame, in network pixels.
    var width: Int, height: Int
    /// Cells in network pixels of the scaled frame (Core Image coordinates, the frame's corner at the origin), in the order
    /// they are filled: rows top down, each left to right.
    var cells: [CGRect]

    /// The window a cell is filled in: centered on it, moved inside the scaled frame.
    func window(_ cell: CGRect) -> CGRect {
        let side = Double(Self.side)
        func origin(_ middle: Double, _ limit: Int) -> Double { min(max(0, floor(middle - side / 2)), Double(limit) - side) }
        return CGRect(x: origin(cell.midX, width), y: origin(cell.midY, height), width: side, height: side)
    }

    /// `thickness` is the largest distance from a pixel of the footprint to the nearest pixel outside it, in frame pixels.
    /// Nil when the stroke is too thick to fill even with the frame's shorter side in a window. Each `variant` after the
    /// first (Refresh) shows the network the hole at another size and moves the cells, so it fills it differently.
    static func plan(footprint: CGRect, thickness: Double, frame: CGRect, variant: Int = 0) -> InpaintPlan? {
        guard !footprint.isEmpty, thickness > 0, frame.width >= 1, frame.height >= 1 else { return nil }
        let sizes = [1, 0.8, 1.2], offsets = [(0.0, 0.0), (1, 1), (-1, -1), (1, -1), (-1, 1)]
        let limit = maxHole * sizes[variant % sizes.count]
        // Frame pixels a window covers: `side` at full resolution, more for a thicker stroke, never more than fits.
        let length = min(floor(min(frame.width, frame.height)), (Double(side) * max(1, 2 * thickness / limit)).rounded(.up))
        let scale = Double(side) / length
        guard 2 * thickness * scale <= limit * 1.5 else { return nil }
        let width = Int(floor(frame.width * scale + 1e-6)), height = Int(floor(frame.height * scale + 1e-6))
        let area = CGRect(x: (footprint.minX - frame.minX) * scale, y: (footprint.minY - frame.minY) * scale, width: footprint.width * scale, height: footprint.height * scale)
        // A grid of cells centered on the stroke, moved by up to an eighth of a cell for a refresh.
        let cell = Double(Self.cell), shift = offsets[variant % offsets.count]
        func axis(_ low: Double, _ length: Double, _ offset: Double, _ limit: Int) -> [(Double, Double)] {
            let count = Int(ceil((length + cell / 4) / cell))
            let start = floor(low + length / 2 - Double(count) * cell / 2 + offset * cell / 8)
            return (0..<count).compactMap { i in
                let a = max(0, start + Double(i) * cell), b = min(Double(limit), start + Double(i + 1) * cell)
                return b > a ? (a, b) : nil
            }
        }
        let columns = axis(area.minX, area.width, shift.0, width), rows = axis(area.minY, area.height, shift.1, height)
        let cells = rows.reversed().flatMap { row in columns.map { CGRect(x: $0.0, y: row.0, width: $0.1 - $0.0, height: row.1 - row.0) } }
            .filter { $0.intersects(area) }
        guard !cells.isEmpty else { return nil }
        return InpaintPlan(scale: scale, width: width, height: height, cells: cells)
    }

    /// The largest distance, in pixels, from a pixel where `coverage` is above zero to the nearest one where it is not
    /// (3-4 chamfer). Past the grid's edges the pixels count as known, except on the sides in `open`, the frame's edges,
    /// where nothing is known.
    static func thickness(_ coverage: [Float], width: Int, height: Int, open: (left: Bool, right: Bool, bottom: Bool, top: Bool)) -> Double {
        let far = Int.max / 4
        var distance = coverage.map { $0 > 1e-4 ? far : 0 }
        func at(_ x: Int, _ y: Int) -> Int {
            if x < 0 { return open.left ? far : 0 }
            if x >= width { return open.right ? far : 0 }
            if y < 0 { return open.top ? far : 0 }
            if y >= height { return open.bottom ? far : 0 }
            return distance[y * width + x]
        }
        // Rows top down: `top` is row -1.
        for y in 0..<height { for x in 0..<width where distance[y * width + x] > 0 {
            distance[y * width + x] = min(distance[y * width + x], at(x - 1, y) + 3, at(x, y - 1) + 3, at(x - 1, y - 1) + 4, at(x + 1, y - 1) + 4)
        } }
        var largest = 0
        for y in stride(from: height - 1, through: 0, by: -1) { for x in stride(from: width - 1, through: 0, by: -1) where distance[y * width + x] > 0 {
            distance[y * width + x] = min(distance[y * width + x], at(x + 1, y) + 3, at(x, y + 1) + 3, at(x + 1, y + 1) + 4, at(x - 1, y + 1) + 4)
            largest = max(largest, distance[y * width + x])
        } }
        return Double(min(largest, far)) / 3
    }
}
