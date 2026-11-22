import Foundation

/// Matches the library's adaptive columns so arrow keys move by whole rows.
enum CatalogGridMove {
    case left, right, up, down, first, last
    static let spacing: CGFloat = 10, padding: CGFloat = 16
    static func columnCount(width: CGFloat, tile: CGFloat) -> Int {
        max(1, Int((max(0, width - 2 * padding) + spacing) / (tile + spacing)))
    }
    /// `rows` are the wall's rows, whose lengths vary: up and down then keep the same share of the way along the row.
    func destination(from index: Int?, count: Int, columns: Int, rows: [Range<Int>]? = nil, keepsColumn: Bool = false) -> Int? {
        guard count > 0 else { return nil }
        if self == .first { return 0 }
        if self == .last { return count - 1 }
        guard let index, (0..<count).contains(index) else { return 0 }
        if let rows, self == .up || self == .down, let row = rows.firstIndex(where: { $0.contains(index) }) {
            let target = self == .up ? row - 1 : row + 1
            guard rows.indices.contains(target) else { return index }
            let position = Double(index - rows[row].lowerBound) / Double(max(1, rows[row].count - 1))
            let next = rows[target]
            if keepsColumn { return next.lowerBound + min(index - rows[row].lowerBound, next.count - 1) }
            return min(count - 1, next.lowerBound + Int((position * Double(max(0, next.count - 1))).rounded()))
        }
        let columns = max(1, columns)
        switch self {
        case .left: return max(0, index - 1)
        case .right: return min(count - 1, index + 1)
        case .up: return index >= columns ? index - columns : index
        case .down: return index / columns < (count - 1) / columns ? min(count - 1, index + columns) : index
        case .first, .last: return nil
        }
    }
}
